"""Tests for WorkflowMail Azure Function — ACS and Graph backends."""

import json
import os
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
    ]
    with mock.patch.dict(os.environ, {}, clear=False):
        for k in keys:
            os.environ.pop(k, None)
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
