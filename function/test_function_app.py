"""Tests for WorkflowMail Azure Function — ACS, Graph, and SMTP backends."""

import json
import os
import time
from unittest import mock

import azure.functions as func
import pytest

import function_app


# ── Fixtures ──────────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def _clean_env():
    """Remove backend-related env vars before each test."""
    keys = [
        "EMAIL_BACKEND",
        "ACS_ENDPOINT",
        "SENDER_ADDRESS",
        "GRAPH_TENANT_ID",
        "GRAPH_CLIENT_ID",
        "GRAPH_REFRESH_TOKEN",
        "ALLOWED_RECIPIENTS",
        "RATE_LIMIT_PER_MINUTE",
        "SUBJECT_PATTERN",
    ]
    with mock.patch.dict(os.environ, {}, clear=False):
        for k in keys:
            os.environ.pop(k, None)
        function_app._request_timestamps.clear()
        yield


def _make_request(body: dict) -> func.HttpRequest:
    """Build a mock HttpRequest with JSON body."""
    return func.HttpRequest(
        method="POST",
        url="/api/send",
        body=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )


# ── ACS backend tests ────────────────────────────────────────────────


class TestSendViaAcs:
    def test_send_success(self):
        os.environ["ACS_ENDPOINT"] = "https://test.communication.azure.com"
        mock_poller = mock.MagicMock()
        mock_poller.result.return_value = {"id": "acs-msg-123"}
        mock_client = mock.MagicMock()
        mock_client.begin_send.return_value = mock_poller

        with mock.patch(
            "function_app.DefaultAzureCredential"
        ), mock.patch(
            "function_app.EmailClient", return_value=mock_client
        ):
            msg_id = function_app._send_via_acs(
                "sender@test.azurecomm.net",
                ["to@example.com"],
                "Test Subject",
                "Hello",
                "",
            )
        assert msg_id == "acs-msg-123"
        mock_client.begin_send.assert_called_once()
        sent_msg = mock_client.begin_send.call_args[0][0]
        assert sent_msg["senderAddress"] == "sender@test.azurecomm.net"
        assert sent_msg["content"]["subject"] == "Test Subject"
        assert sent_msg["content"]["plainText"] == "Hello"

    def test_send_html(self):
        os.environ["ACS_ENDPOINT"] = "https://test.communication.azure.com"
        mock_poller = mock.MagicMock()
        mock_poller.result.return_value = {"id": "acs-html-456"}
        mock_client = mock.MagicMock()
        mock_client.begin_send.return_value = mock_poller

        with mock.patch(
            "function_app.DefaultAzureCredential"
        ), mock.patch(
            "function_app.EmailClient", return_value=mock_client
        ):
            function_app._send_via_acs(
                "sender@test.azurecomm.net",
                ["to@example.com"],
                "HTML Test",
                "plain",
                "<p>html</p>",
            )
        sent_msg = mock_client.begin_send.call_args[0][0]
        assert sent_msg["content"]["html"] == "<p>html</p>"
        assert sent_msg["content"]["plainText"] == "plain"

    def test_missing_endpoint_raises(self):
        # ACS_ENDPOINT not set
        with pytest.raises(ValueError, match="ACS_ENDPOINT not configured"):
            function_app._send_via_acs(
                "sender@test.azurecomm.net",
                ["to@example.com"],
                "Test",
                "body",
                "",
            )

    def test_empty_body_sends_placeholder(self):
        os.environ["ACS_ENDPOINT"] = "https://test.communication.azure.com"
        mock_poller = mock.MagicMock()
        mock_poller.result.return_value = {"id": "acs-empty-789"}
        mock_client = mock.MagicMock()
        mock_client.begin_send.return_value = mock_poller

        with mock.patch(
            "function_app.DefaultAzureCredential"
        ), mock.patch(
            "function_app.EmailClient", return_value=mock_client
        ):
            function_app._send_via_acs(
                "sender@test.azurecomm.net",
                ["to@example.com"],
                "Empty",
                "",
                "",
            )
        sent_msg = mock_client.begin_send.call_args[0][0]
        assert sent_msg["content"]["plainText"] == "(empty)"


# ── Graph backend tests ──────────────────────────────────────────────


class TestSendViaGraph:
    def _setup_graph_env(self):
        os.environ["GRAPH_TENANT_ID"] = "tenant-123"
        os.environ["GRAPH_CLIENT_ID"] = "client-456"
        os.environ["GRAPH_REFRESH_TOKEN"] = "refresh-789"

    def test_send_success(self):
        self._setup_graph_env()
        token_response = mock.MagicMock()
        token_response.status_code = 200
        token_response.json.return_value = {"access_token": "at-abc"}
        token_response.raise_for_status = mock.MagicMock()

        send_response = mock.MagicMock()
        send_response.status_code = 202
        send_response.raise_for_status = mock.MagicMock()

        with mock.patch("function_app.requests.post") as mock_post:
            mock_post.side_effect = [token_response, send_response]
            msg_id = function_app._send_via_graph(
                "noreply@contoso.com",
                ["to@example.com"],
                "Graph Test",
                "Hello via Graph",
                "",
            )

        assert msg_id.startswith("graph-")
        # Verify token exchange call
        token_call = mock_post.call_args_list[0]
        assert "oauth2/v2.0/token" in token_call[0][0]
        assert token_call[1]["data"]["grant_type"] == "refresh_token"
        # Verify sendMail call
        send_call = mock_post.call_args_list[1]
        assert "sendMail" in send_call[0][0]
        assert "noreply@contoso.com" in send_call[0][0]
        assert send_call[1]["headers"]["Authorization"] == "Bearer at-abc"
        payload = send_call[1]["json"]
        assert payload["message"]["subject"] == "Graph Test"
        assert payload["message"]["body"]["contentType"] == "Text"
        assert payload["message"]["body"]["content"] == "Hello via Graph"

    def test_send_html_preferred(self):
        self._setup_graph_env()
        token_response = mock.MagicMock()
        token_response.json.return_value = {"access_token": "at-abc"}
        token_response.raise_for_status = mock.MagicMock()

        send_response = mock.MagicMock()
        send_response.status_code = 202
        send_response.raise_for_status = mock.MagicMock()

        with mock.patch("function_app.requests.post") as mock_post:
            mock_post.side_effect = [token_response, send_response]
            function_app._send_via_graph(
                "noreply@contoso.com",
                ["to@example.com"],
                "HTML Test",
                "plain fallback",
                "<h1>Hello</h1>",
            )
        send_call = mock_post.call_args_list[1]
        payload = send_call[1]["json"]
        assert payload["message"]["body"]["contentType"] == "HTML"
        assert payload["message"]["body"]["content"] == "<h1>Hello</h1>"

    def test_missing_env_raises(self):
        # No GRAPH_* env vars
        with pytest.raises(ValueError, match="Graph backend requires"):
            function_app._send_via_graph(
                "noreply@contoso.com",
                ["to@example.com"],
                "Test",
                "body",
                "",
            )

    def test_multiple_recipients(self):
        self._setup_graph_env()
        token_response = mock.MagicMock()
        token_response.json.return_value = {"access_token": "at-abc"}
        token_response.raise_for_status = mock.MagicMock()

        send_response = mock.MagicMock()
        send_response.status_code = 202
        send_response.raise_for_status = mock.MagicMock()

        with mock.patch("function_app.requests.post") as mock_post:
            mock_post.side_effect = [token_response, send_response]
            function_app._send_via_graph(
                "noreply@contoso.com",
                ["a@example.com", "b@example.com"],
                "Multi",
                "body",
                "",
            )
        send_call = mock_post.call_args_list[1]
        payload = send_call[1]["json"]
        recipients = payload["message"]["toRecipients"]
        assert len(recipients) == 2
        assert recipients[0]["emailAddress"]["address"] == "a@example.com"
        assert recipients[1]["emailAddress"]["address"] == "b@example.com"


# ── SMTP backend tests ──────────────────────────────────────────────


class TestSendViaSmtp:
    def _setup_smtp_env(self):
        os.environ["GRAPH_TENANT_ID"] = "tenant-123"
        os.environ["GRAPH_CLIENT_ID"] = "client-456"
        os.environ["GRAPH_REFRESH_TOKEN"] = "refresh-789"

    def _mock_token_response(self):
        resp = mock.MagicMock()
        resp.json.return_value = {"access_token": "at-smtp"}
        resp.raise_for_status = mock.MagicMock()
        return resp

    def test_send_success(self):
        self._setup_smtp_env()
        mock_server = mock.MagicMock()

        with mock.patch("function_app.requests.post", return_value=self._mock_token_response()) as mock_post, \
             mock.patch("function_app.smtplib.SMTP", return_value=mock_server):
            msg_id = function_app._send_via_smtp(
                "noreply@contoso.com",
                ["to@example.com"],
                "SMTP Test",
                "Hello via SMTP",
                "",
            )

        assert msg_id.startswith("smtp-")
        # Verify token exchange used SMTP.Send scope
        call_data = mock_post.call_args[1]["data"]
        assert "SMTP.Send" in call_data["scope"]
        # Verify SMTP interactions
        mock_server.ehlo.assert_called()
        mock_server.starttls.assert_called_once()
        mock_server.auth.assert_called_once()
        assert mock_server.auth.call_args[0][0] == "XOAUTH2"
        mock_server.sendmail.assert_called_once()
        mock_server.quit.assert_called_once()

    def test_send_html_and_plain(self):
        self._setup_smtp_env()
        mock_server = mock.MagicMock()

        with mock.patch("function_app.requests.post", return_value=self._mock_token_response()), \
             mock.patch("function_app.smtplib.SMTP", return_value=mock_server):
            function_app._send_via_smtp(
                "noreply@contoso.com",
                ["to@example.com"],
                "Multi Test",
                "plain text",
                "<p>html</p>",
            )

        sent_msg = mock_server.sendmail.call_args[0][2]
        assert "multipart/alternative" in sent_msg
        assert "plain text" in sent_msg
        assert "<p>html</p>" in sent_msg

    def test_send_html_only(self):
        self._setup_smtp_env()
        mock_server = mock.MagicMock()

        with mock.patch("function_app.requests.post", return_value=self._mock_token_response()), \
             mock.patch("function_app.smtplib.SMTP", return_value=mock_server):
            function_app._send_via_smtp(
                "noreply@contoso.com",
                ["to@example.com"],
                "HTML Only",
                "",
                "<h1>Hello</h1>",
            )

        sent_msg = mock_server.sendmail.call_args[0][2]
        assert "<h1>Hello</h1>" in sent_msg
        assert "text/html" in sent_msg

    def test_missing_env_raises(self):
        with pytest.raises(ValueError, match="SMTP backend requires"):
            function_app._send_via_smtp(
                "noreply@contoso.com",
                ["to@example.com"],
                "Test",
                "body",
                "",
            )

    def test_multiple_recipients(self):
        self._setup_smtp_env()
        mock_server = mock.MagicMock()

        with mock.patch("function_app.requests.post", return_value=self._mock_token_response()), \
             mock.patch("function_app.smtplib.SMTP", return_value=mock_server):
            function_app._send_via_smtp(
                "noreply@contoso.com",
                ["a@example.com", "b@example.com"],
                "Multi Rcpt",
                "body",
                "",
            )

        call_args = mock_server.sendmail.call_args[0]
        assert call_args[0] == "noreply@contoso.com"
        assert call_args[1] == ["a@example.com", "b@example.com"]


# ── Backend dispatch tests ────────────────────────────────────────────


class TestBackendDispatch:
    def test_default_backend_is_acs(self):
        os.environ["SENDER_ADDRESS"] = "sender@test.azurecomm.net"
        os.environ["ACS_ENDPOINT"] = "https://test.communication.azure.com"

        mock_poller = mock.MagicMock()
        mock_poller.result.return_value = {"id": "acs-dispatch-1"}
        mock_client = mock.MagicMock()
        mock_client.begin_send.return_value = mock_poller

        req = _make_request({
            "to": "to@example.com",
            "subject": "Dispatch Test",
            "body": "Hello",
        })

        with mock.patch(
            "function_app.DefaultAzureCredential"
        ), mock.patch(
            "function_app.EmailClient", return_value=mock_client
        ):
            resp = function_app.send_email(req)

        assert resp.status_code == 200
        data = json.loads(resp.get_body())
        assert data["status"] == "sent"
        assert data["messageId"] == "acs-dispatch-1"

    def test_graph_backend_dispatch(self):
        os.environ["EMAIL_BACKEND"] = "graph"
        os.environ["SENDER_ADDRESS"] = "noreply@contoso.com"
        os.environ["GRAPH_TENANT_ID"] = "tenant-123"
        os.environ["GRAPH_CLIENT_ID"] = "client-456"
        os.environ["GRAPH_REFRESH_TOKEN"] = "refresh-789"

        token_response = mock.MagicMock()
        token_response.json.return_value = {"access_token": "at-abc"}
        token_response.raise_for_status = mock.MagicMock()

        send_response = mock.MagicMock()
        send_response.status_code = 202
        send_response.raise_for_status = mock.MagicMock()

        req = _make_request({
            "to": "to@example.com",
            "subject": "Graph Dispatch",
            "body": "Hello Graph",
        })

        with mock.patch("function_app.requests.post") as mock_post:
            mock_post.side_effect = [token_response, send_response]
            resp = function_app.send_email(req)

        assert resp.status_code == 200
        data = json.loads(resp.get_body())
        assert data["status"] == "sent"
        assert data["messageId"].startswith("graph-")

    def test_smtp_backend_dispatch(self):
        os.environ["EMAIL_BACKEND"] = "smtp"
        os.environ["SENDER_ADDRESS"] = "noreply@contoso.com"
        os.environ["GRAPH_TENANT_ID"] = "tenant-123"
        os.environ["GRAPH_CLIENT_ID"] = "client-456"
        os.environ["GRAPH_REFRESH_TOKEN"] = "refresh-789"

        token_response = mock.MagicMock()
        token_response.json.return_value = {"access_token": "at-smtp"}
        token_response.raise_for_status = mock.MagicMock()

        mock_server = mock.MagicMock()

        req = _make_request({
            "to": "to@example.com",
            "subject": "SMTP Dispatch",
            "body": "Hello SMTP",
        })

        with mock.patch("function_app.requests.post", return_value=token_response), \
             mock.patch("function_app.smtplib.SMTP", return_value=mock_server):
            resp = function_app.send_email(req)

        assert resp.status_code == 200
        data = json.loads(resp.get_body())
        assert data["status"] == "sent"
        assert data["messageId"].startswith("smtp-")

    def test_graph_backend_no_acs_endpoint_needed(self):
        """Graph backend should not check ACS_ENDPOINT."""
        os.environ["EMAIL_BACKEND"] = "graph"
        os.environ["SENDER_ADDRESS"] = "noreply@contoso.com"
        os.environ["GRAPH_TENANT_ID"] = "tenant-123"
        os.environ["GRAPH_CLIENT_ID"] = "client-456"
        os.environ["GRAPH_REFRESH_TOKEN"] = "refresh-789"
        # ACS_ENDPOINT intentionally NOT set

        token_response = mock.MagicMock()
        token_response.json.return_value = {"access_token": "at-abc"}
        token_response.raise_for_status = mock.MagicMock()

        send_response = mock.MagicMock()
        send_response.status_code = 202
        send_response.raise_for_status = mock.MagicMock()

        req = _make_request({
            "to": "to@example.com",
            "subject": "No ACS Needed",
            "body": "body",
        })

        with mock.patch("function_app.requests.post") as mock_post:
            mock_post.side_effect = [token_response, send_response]
            resp = function_app.send_email(req)

        assert resp.status_code == 200

    def test_missing_to_returns_400(self):
        os.environ["SENDER_ADDRESS"] = "sender@test.azurecomm.net"
        req = _make_request({"subject": "Missing To"})
        resp = function_app.send_email(req)
        assert resp.status_code == 400

    def test_missing_subject_returns_400(self):
        os.environ["SENDER_ADDRESS"] = "sender@test.azurecomm.net"
        req = _make_request({"to": "to@example.com"})
        resp = function_app.send_email(req)
        assert resp.status_code == 400

    def test_missing_sender_returns_500(self):
        req = _make_request({"to": "to@example.com", "subject": "Test"})
        resp = function_app.send_email(req)
        assert resp.status_code == 500

    def test_invalid_json_returns_400(self):
        req = func.HttpRequest(
            method="POST",
            url="/api/send",
            body=b"not json",
            headers={"Content-Type": "application/json"},
        )
        resp = function_app.send_email(req)
        assert resp.status_code == 400

    def test_send_failure_returns_500(self):
        os.environ["EMAIL_BACKEND"] = "acs"
        os.environ["SENDER_ADDRESS"] = "sender@test.azurecomm.net"
        os.environ["ACS_ENDPOINT"] = "https://test.communication.azure.com"

        mock_client = mock.MagicMock()
        mock_client.begin_send.side_effect = RuntimeError("ACS unavailable")

        req = _make_request({
            "to": "to@example.com",
            "subject": "Fail",
            "body": "body",
        })

        with mock.patch(
            "function_app.DefaultAzureCredential"
        ), mock.patch(
            "function_app.EmailClient", return_value=mock_client
        ):
            resp = function_app.send_email(req)

        assert resp.status_code == 500
        data = json.loads(resp.get_body())
        assert "ACS unavailable" in data["error"]


# ── Heartbeat timer tests ─────────────────────────────────────────────


class TestHeartbeat:
    def test_heartbeat_skips_when_not_graph(self):
        os.environ["EMAIL_BACKEND"] = "acs"
        timer = mock.MagicMock()
        # Should not raise or call any external services
        function_app.graph_token_heartbeat(timer)

    def test_heartbeat_skips_default_backend(self):
        # EMAIL_BACKEND not set — defaults to "acs"
        timer = mock.MagicMock()
        function_app.graph_token_heartbeat(timer)

    def test_heartbeat_exchanges_token(self):
        os.environ["EMAIL_BACKEND"] = "graph"
        os.environ["GRAPH_TENANT_ID"] = "tenant-123"
        os.environ["GRAPH_CLIENT_ID"] = "client-456"
        os.environ["GRAPH_REFRESH_TOKEN"] = "refresh-789"

        token_response = mock.MagicMock()
        token_response.json.return_value = {"access_token": "at-heartbeat"}
        token_response.raise_for_status = mock.MagicMock()

        timer = mock.MagicMock()

        with mock.patch("function_app.requests.post", return_value=token_response) as mock_post:
            function_app.graph_token_heartbeat(timer)

        mock_post.assert_called_once()
        assert "oauth2/v2.0/token" in mock_post.call_args[0][0]

    def test_heartbeat_logs_error_on_failure(self):
        os.environ["EMAIL_BACKEND"] = "graph"
        os.environ["GRAPH_TENANT_ID"] = "tenant-123"
        os.environ["GRAPH_CLIENT_ID"] = "client-456"
        os.environ["GRAPH_REFRESH_TOKEN"] = "refresh-789"

        timer = mock.MagicMock()

        with mock.patch(
            "function_app.requests.post",
            side_effect=RuntimeError("token exchange failed"),
        ):
            # Should not raise — just log the error
            function_app.graph_token_heartbeat(timer)

    def test_heartbeat_missing_env_logs_error(self):
        os.environ["EMAIL_BACKEND"] = "graph"
        # GRAPH_* vars intentionally not set
        timer = mock.MagicMock()
        # Should not raise
        function_app.graph_token_heartbeat(timer)

    def test_heartbeat_runs_for_smtp(self):
        os.environ["EMAIL_BACKEND"] = "smtp"
        os.environ["GRAPH_TENANT_ID"] = "tenant-123"
        os.environ["GRAPH_CLIENT_ID"] = "client-456"
        os.environ["GRAPH_REFRESH_TOKEN"] = "refresh-789"

        token_response = mock.MagicMock()
        token_response.json.return_value = {"access_token": "at-smtp-heartbeat"}
        token_response.raise_for_status = mock.MagicMock()

        timer = mock.MagicMock()

        with mock.patch("function_app.requests.post", return_value=token_response) as mock_post:
            function_app.graph_token_heartbeat(timer)

        mock_post.assert_called_once()
        call_data = mock_post.call_args[1]["data"]
        assert "SMTP.Send" in call_data["scope"]


# ── Token exchange tests ──────────────────────────────────────────────


class TestTokenExchange:
    def test_exchange_success(self):
        mock_resp = mock.MagicMock()
        mock_resp.json.return_value = {"access_token": "new-at"}
        mock_resp.raise_for_status = mock.MagicMock()

        with mock.patch("function_app.requests.post", return_value=mock_resp) as mock_post:
            token = function_app._exchange_graph_refresh_token(
                "tenant-id", "client-id", "refresh-token"
            )

        assert token == "new-at"
        call_data = mock_post.call_args[1]["data"]
        assert call_data["grant_type"] == "refresh_token"
        assert call_data["client_id"] == "client-id"
        assert call_data["refresh_token"] == "refresh-token"

    def test_exchange_failure_raises(self):
        mock_resp = mock.MagicMock()
        mock_resp.raise_for_status.side_effect = Exception("401 Unauthorized")

        with mock.patch("function_app.requests.post", return_value=mock_resp):
            with pytest.raises(Exception, match="401"):
                function_app._exchange_graph_refresh_token(
                    "tenant-id", "client-id", "bad-token"
                )

    def test_smtp_exchange_uses_correct_scope(self):
        mock_resp = mock.MagicMock()
        mock_resp.json.return_value = {"access_token": "smtp-at"}
        mock_resp.raise_for_status = mock.MagicMock()

        with mock.patch("function_app.requests.post", return_value=mock_resp) as mock_post:
            token = function_app._exchange_smtp_refresh_token(
                "tenant-id", "client-id", "refresh-token"
            )

        assert token == "smtp-at"
        call_data = mock_post.call_args[1]["data"]
        assert call_data["scope"] == "https://outlook.office365.com/SMTP.Send offline_access"


# ── Recipient restriction tests ────────────────────────────────────


class TestRecipientRestrictions:
    """Tests for ALLOWED_RECIPIENTS enforcement."""

    def _send(self, to, subject="Test Subject"):
        os.environ["SENDER_ADDRESS"] = "sender@test.azurecomm.net"
        os.environ["ACS_ENDPOINT"] = "https://test.communication.azure.com"
        mock_poller = mock.MagicMock()
        mock_poller.result.return_value = {"id": "acs-rcpt-1"}
        mock_client = mock.MagicMock()
        mock_client.begin_send.return_value = mock_poller

        req = _make_request({"to": to, "subject": subject, "body": "body"})
        with mock.patch("function_app.DefaultAzureCredential"), \
             mock.patch("function_app.EmailClient", return_value=mock_client):
            return function_app.send_email(req)

    def test_unset_allows_all(self):
        resp = self._send("anyone@example.com")
        assert resp.status_code == 200

    def test_empty_allows_all(self):
        os.environ["ALLOWED_RECIPIENTS"] = ""
        resp = self._send("anyone@example.com")
        assert resp.status_code == 200

    def test_allowed_passes(self):
        os.environ["ALLOWED_RECIPIENTS"] = "ok@example.com,another@example.com"
        resp = self._send("ok@example.com")
        assert resp.status_code == 200

    def test_blocked_returns_403(self):
        os.environ["ALLOWED_RECIPIENTS"] = "ok@example.com"
        resp = self._send("hacker@evil.com")
        assert resp.status_code == 403
        data = json.loads(resp.get_body())
        assert "not allowed" in data["error"]

    def test_case_insensitive(self):
        os.environ["ALLOWED_RECIPIENTS"] = "OK@Example.COM"
        resp = self._send("ok@example.com")
        assert resp.status_code == 200

    def test_multi_recipient_one_blocked(self):
        os.environ["ALLOWED_RECIPIENTS"] = "ok@example.com"
        resp = self._send(["ok@example.com", "bad@evil.com"])
        assert resp.status_code == 403


# ── Rate limiting tests ────────────────────────────────────────────


class TestRateLimiting:
    """Tests for RATE_LIMIT_PER_MINUTE enforcement."""

    def _send(self):
        os.environ["SENDER_ADDRESS"] = "sender@test.azurecomm.net"
        os.environ["ACS_ENDPOINT"] = "https://test.communication.azure.com"
        mock_poller = mock.MagicMock()
        mock_poller.result.return_value = {"id": "acs-rl-1"}
        mock_client = mock.MagicMock()
        mock_client.begin_send.return_value = mock_poller

        req = _make_request({"to": "to@example.com", "subject": "Test", "body": "body"})
        with mock.patch("function_app.DefaultAzureCredential"), \
             mock.patch("function_app.EmailClient", return_value=mock_client):
            return function_app.send_email(req)

    def test_default_allows_first(self):
        resp = self._send()
        assert resp.status_code == 200

    def test_zero_disables(self):
        os.environ["RATE_LIMIT_PER_MINUTE"] = "0"
        for _ in range(20):
            resp = self._send()
            assert resp.status_code == 200

    def test_exceeded_returns_429(self):
        os.environ["RATE_LIMIT_PER_MINUTE"] = "2"
        assert self._send().status_code == 200
        assert self._send().status_code == 200
        assert self._send().status_code == 429

    def test_window_expiration(self):
        os.environ["RATE_LIMIT_PER_MINUTE"] = "1"
        # First request at t=0
        with mock.patch("function_app.time.monotonic", return_value=1000.0):
            assert self._send().status_code == 200
        # Second request at t=0.5 — should be rejected
        with mock.patch("function_app.time.monotonic", return_value=1000.5):
            assert self._send().status_code == 429
        # Third request at t=61 — window expired, should pass
        with mock.patch("function_app.time.monotonic", return_value=1061.0):
            assert self._send().status_code == 200

    def test_invalid_value_defaults_to_10(self):
        os.environ["RATE_LIMIT_PER_MINUTE"] = "notanumber"
        # Default is 10, so first request should pass
        resp = self._send()
        assert resp.status_code == 200


# ── Subject pattern tests ──────────────────────────────────────────


class TestSubjectPattern:
    """Tests for SUBJECT_PATTERN enforcement."""

    def _send(self, subject):
        os.environ["SENDER_ADDRESS"] = "sender@test.azurecomm.net"
        os.environ["ACS_ENDPOINT"] = "https://test.communication.azure.com"
        mock_poller = mock.MagicMock()
        mock_poller.result.return_value = {"id": "acs-sp-1"}
        mock_client = mock.MagicMock()
        mock_client.begin_send.return_value = mock_poller

        req = _make_request({"to": "to@example.com", "subject": subject, "body": "body"})
        with mock.patch("function_app.DefaultAzureCredential"), \
             mock.patch("function_app.EmailClient", return_value=mock_client):
            return function_app.send_email(req)

    def test_unset_allows_all(self):
        resp = self._send("Anything goes")
        assert resp.status_code == 200

    def test_subscribe_matches(self):
        os.environ["SUBJECT_PATTERN"] = r"^(SUBSCRIBE|SIGNOFF)\s+.+"
        resp = self._send("SUBSCRIBE MYLIST")
        assert resp.status_code == 200

    def test_signoff_matches(self):
        os.environ["SUBJECT_PATTERN"] = r"^(SUBSCRIBE|SIGNOFF)\s+.+"
        resp = self._send("SIGNOFF MYLIST")
        assert resp.status_code == 200

    def test_non_matching_returns_400(self):
        os.environ["SUBJECT_PATTERN"] = r"^(SUBSCRIBE|SIGNOFF)\s+.+"
        resp = self._send("Hello World")
        assert resp.status_code == 400
        data = json.loads(resp.get_body())
        assert "does not match" in data["error"]

    def test_empty_allows_all(self):
        os.environ["SUBJECT_PATTERN"] = ""
        resp = self._send("Anything goes")
        assert resp.status_code == 200

    def test_invalid_regex_returns_400(self):
        os.environ["SUBJECT_PATTERN"] = "[invalid"
        resp = self._send("Test")
        assert resp.status_code == 400
        data = json.loads(resp.get_body())
        assert "Invalid SUBJECT_PATTERN" in data["error"]
