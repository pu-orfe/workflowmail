"""WorkflowMail - Azure Function for sending email via ACS, Microsoft Graph, or SMTP."""

import json
import logging
import os
import re
import smtplib
import time
import uuid
from collections import deque
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

import azure.functions as func
import requests
from azure.communication.email import EmailClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()

# Sliding-window rate limiter state (module-level for per-instance tracking)
_request_timestamps = deque()


def _send_via_acs(sender, to_list, subject, body, html):
    """Send email using Azure Communication Services with Managed Identity."""
    endpoint = os.environ.get("ACS_ENDPOINT", "")
    if not endpoint:
        raise ValueError(
            "ACS_ENDPOINT not configured. Run './scripts/deploy.sh status' to refresh."
        )

    recipients = [{"address": addr} for addr in to_list]

    content = {"subject": subject}
    if html:
        content["html"] = html
    if body:
        content["plainText"] = body
    if not body and not html:
        content["plainText"] = "(empty)"

    message = {
        "senderAddress": sender,
        "recipients": {"to": recipients},
        "content": content,
    }

    credential = DefaultAzureCredential()
    client = EmailClient(endpoint, credential)
    poller = client.begin_send(message)
    result = poller.result()
    return result["id"]


def _exchange_graph_refresh_token(tenant_id, client_id, refresh_token):
    """Exchange a refresh token for an access token via Azure AD."""
    token_url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
    resp = requests.post(
        token_url,
        data={
            "grant_type": "refresh_token",
            "client_id": client_id,
            "refresh_token": refresh_token,
            "scope": "https://graph.microsoft.com/.default offline_access",
        },
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def _send_via_graph(sender, to_list, subject, body, html):
    """Send email using Microsoft Graph API with OAuth refresh token."""
    tenant_id = os.environ.get("GRAPH_TENANT_ID", "")
    client_id = os.environ.get("GRAPH_CLIENT_ID", "")
    refresh_token = os.environ.get("GRAPH_REFRESH_TOKEN", "")

    if not all([tenant_id, client_id, refresh_token]):
        raise ValueError(
            "Graph backend requires GRAPH_TENANT_ID, GRAPH_CLIENT_ID, "
            "and GRAPH_REFRESH_TOKEN environment variables."
        )

    access_token = _exchange_graph_refresh_token(tenant_id, client_id, refresh_token)

    # Build Graph sendMail payload
    to_recipients = [
        {"emailAddress": {"address": addr}} for addr in to_list
    ]

    # Graph only accepts one body block; prefer HTML when both are provided
    if html:
        mail_body = {"contentType": "HTML", "content": html}
    elif body:
        mail_body = {"contentType": "Text", "content": body}
    else:
        mail_body = {"contentType": "Text", "content": "(empty)"}

    mail_payload = {
        "message": {
            "subject": subject,
            "body": mail_body,
            "toRecipients": to_recipients,
        }
    }

    graph_url = f"https://graph.microsoft.com/v1.0/users/{sender}/sendMail"
    resp = requests.post(
        graph_url,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
        },
        json=mail_payload,
        timeout=30,
    )
    resp.raise_for_status()

    # Graph returns 202 with no body on success
    return f"graph-{uuid.uuid4()}"


def _exchange_smtp_refresh_token(tenant_id, client_id, refresh_token):
    """Exchange a refresh token for an access token scoped to SMTP.Send."""
    token_url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
    resp = requests.post(
        token_url,
        data={
            "grant_type": "refresh_token",
            "client_id": client_id,
            "refresh_token": refresh_token,
            "scope": "https://outlook.office365.com/SMTP.Send offline_access",
        },
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def _send_via_smtp(sender, to_list, subject, body, html):
    """Send email using SMTP with OAuth XOAUTH2 authentication."""
    tenant_id = os.environ.get("GRAPH_TENANT_ID", "")
    client_id = os.environ.get("GRAPH_CLIENT_ID", "")
    refresh_token = os.environ.get("GRAPH_REFRESH_TOKEN", "")

    if not all([tenant_id, client_id, refresh_token]):
        raise ValueError(
            "SMTP backend requires GRAPH_TENANT_ID, GRAPH_CLIENT_ID, "
            "and GRAPH_REFRESH_TOKEN environment variables."
        )

    access_token = _exchange_smtp_refresh_token(tenant_id, client_id, refresh_token)

    # Build MIME message
    if body and html:
        msg = MIMEMultipart("alternative")
        msg.attach(MIMEText(body, "plain"))
        msg.attach(MIMEText(html, "html"))
    elif html:
        msg = MIMEText(html, "html")
    elif body:
        msg = MIMEText(body, "plain")
    else:
        msg = MIMEText("(empty)", "plain")

    msg["From"] = sender
    msg["To"] = ", ".join(to_list)
    msg["Subject"] = subject

    # XOAUTH2 authentication handler
    def xoauth2_handler(challenge=None):
        return f"user={sender}\x01auth=Bearer {access_token}\x01\x01"

    server = smtplib.SMTP("smtp.office365.com", 587)
    server.ehlo()
    server.starttls()
    server.ehlo()
    server.auth("XOAUTH2", xoauth2_handler)
    server.sendmail(sender, to_list, msg.as_string())
    server.quit()

    return f"smtp-{uuid.uuid4()}"


def _check_rate_limit():
    """Sliding-window rate limiter. Returns error string or None."""
    raw = os.environ.get("RATE_LIMIT_PER_MINUTE", "10")
    try:
        limit = int(raw)
    except (ValueError, TypeError):
        limit = 10
    if limit <= 0:
        return None

    now = time.monotonic()
    window_start = now - 60

    # Evict expired timestamps
    while _request_timestamps and _request_timestamps[0] <= window_start:
        _request_timestamps.popleft()

    if len(_request_timestamps) >= limit:
        return f"Rate limit exceeded ({limit}/min)"

    # Record only after passing the check
    _request_timestamps.append(now)
    return None


def _check_allowed_recipients(to_list):
    """Check recipients against allowlist. Returns error string or None."""
    raw = os.environ.get("ALLOWED_RECIPIENTS", "")
    if not raw.strip():
        return None

    allowed = {addr.strip().lower() for addr in raw.split(",") if addr.strip()}
    for addr in to_list:
        if addr.lower() not in allowed:
            return f"Recipient not allowed: {addr}"
    return None


def _check_subject_pattern(subject):
    """Check subject against regex pattern. Returns error string or None."""
    pattern = os.environ.get("SUBJECT_PATTERN", "")
    if not pattern.strip():
        return None

    try:
        if not re.search(pattern, subject):
            return f"Subject does not match required pattern: {pattern}"
    except re.error as exc:
        return f"Invalid SUBJECT_PATTERN regex: {exc}"
    return None


@app.route(route="send", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def send_email(req: func.HttpRequest) -> func.HttpResponse:
    """Send an email via ACS or Microsoft Graph.

    Expects JSON body:
    {
        "to": "recipient@example.com" or ["a@example.com", "b@example.com"],
        "subject": "Email subject",
        "body": "Plain text body",
        "html": "<p>Optional HTML body</p>",
        "sender": "user@example.com"  (optional override)
    }
    """
    logging.info("send_email function triggered")

    try:
        req_body = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "Invalid JSON in request body"}),
            status_code=400,
            mimetype="application/json",
        )

    to = req_body.get("to")
    subject = req_body.get("subject")
    body = req_body.get("body", "")
    html = req_body.get("html", "")
    sender = req_body.get("sender", os.environ.get("SENDER_ADDRESS", ""))

    if not to or not subject:
        return func.HttpResponse(
            json.dumps({"error": "'to' and 'subject' are required"}),
            status_code=400,
            mimetype="application/json",
        )

    if not sender:
        return func.HttpResponse(
            json.dumps({"error": "No sender address configured. Set SENDER_ADDRESS env var."}),
            status_code=500,
            mimetype="application/json",
        )

    # Normalize recipients to a list
    if isinstance(to, str):
        to = [to]

    # ── Security checks (cheapest first) ──
    rate_err = _check_rate_limit()
    if rate_err:
        return func.HttpResponse(
            json.dumps({"error": rate_err}),
            status_code=429,
            mimetype="application/json",
        )

    rcpt_err = _check_allowed_recipients(to)
    if rcpt_err:
        return func.HttpResponse(
            json.dumps({"error": rcpt_err}),
            status_code=403,
            mimetype="application/json",
        )

    subj_err = _check_subject_pattern(subject)
    if subj_err:
        return func.HttpResponse(
            json.dumps({"error": subj_err}),
            status_code=400,
            mimetype="application/json",
        )

    try:
        backend = os.environ.get("EMAIL_BACKEND", "acs")
        if backend == "graph":
            message_id = _send_via_graph(sender, to, subject, body, html)
        elif backend == "smtp":
            message_id = _send_via_smtp(sender, to, subject, body, html)
        else:
            message_id = _send_via_acs(sender, to, subject, body, html)

        logging.info("Email sent successfully via %s: %s", backend, message_id)
        return func.HttpResponse(
            json.dumps({
                "status": "sent",
                "messageId": message_id,
            }),
            status_code=200,
            mimetype="application/json",
        )

    except Exception as e:
        logging.error("Failed to send email: %s", str(e))
        return func.HttpResponse(
            json.dumps({"error": str(e)}),
            status_code=500,
            mimetype="application/json",
        )


@app.timer_trigger(schedule="0 0 0 * * 0", arg_name="timer")
def graph_token_heartbeat(timer: func.TimerRequest) -> None:
    """Weekly heartbeat to keep the OAuth refresh token alive.

    Runs every Sunday at midnight UTC. Exchanges the refresh token for an
    access token, which resets the 90-day inactivity window. Only active
    when EMAIL_BACKEND is 'graph' or 'smtp'.
    """
    backend = os.environ.get("EMAIL_BACKEND", "acs")
    if backend not in ("graph", "smtp"):
        logging.info("Heartbeat skipped: EMAIL_BACKEND is '%s', not 'graph' or 'smtp'.", backend)
        return

    tenant_id = os.environ.get("GRAPH_TENANT_ID", "")
    client_id = os.environ.get("GRAPH_CLIENT_ID", "")
    refresh_token = os.environ.get("GRAPH_REFRESH_TOKEN", "")

    if not all([tenant_id, client_id, refresh_token]):
        logging.error(
            "Heartbeat failed: missing GRAPH_TENANT_ID, GRAPH_CLIENT_ID, "
            "or GRAPH_REFRESH_TOKEN."
        )
        return

    try:
        if backend == "smtp":
            _exchange_smtp_refresh_token(tenant_id, client_id, refresh_token)
        else:
            _exchange_graph_refresh_token(tenant_id, client_id, refresh_token)
        logging.info("Heartbeat succeeded: refresh token is alive.")
    except Exception as e:
        logging.error("Heartbeat failed: %s", str(e))
        logging.error(
            "The refresh token may be expired. Re-run './scripts/deploy.sh deploy' "
            "with the '%s' backend to re-authenticate.", backend
        )
