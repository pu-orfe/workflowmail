"""WorkflowMail - Azure Function for sending email via ACS or Microsoft Graph."""

import json
import logging
import os
import uuid

import azure.functions as func
import requests
from azure.communication.email import EmailClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()


def _send_via_acs(sender, to_list, subject, body, html):
    """Send email using Azure Communication Services with Managed Identity."""
    endpoint = os.environ.get("ACS_ENDPOINT", "")
    if not endpoint:
        raise ValueError(
            "ACS_ENDPOINT not configured. Run './deploy.sh status' to refresh."
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

    try:
        backend = os.environ.get("EMAIL_BACKEND", "acs")
        if backend == "graph":
            message_id = _send_via_graph(sender, to, subject, body, html)
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
    """Weekly heartbeat to keep the Graph refresh token alive.

    Runs every Sunday at midnight UTC. Exchanges the refresh token for an
    access token, which resets the 90-day inactivity window. Only active
    when EMAIL_BACKEND=graph.
    """
    backend = os.environ.get("EMAIL_BACKEND", "acs")
    if backend != "graph":
        logging.info("Heartbeat skipped: EMAIL_BACKEND is '%s', not 'graph'.", backend)
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
        _exchange_graph_refresh_token(tenant_id, client_id, refresh_token)
        logging.info("Heartbeat succeeded: refresh token is alive.")
    except Exception as e:
        logging.error("Heartbeat failed: %s", str(e))
        logging.error(
            "The refresh token may be expired. Re-run './deploy.sh deploy' "
            "with the 'graph' backend to re-authenticate."
        )
