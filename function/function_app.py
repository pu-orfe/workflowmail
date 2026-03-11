"""WorkflowMail - Azure Function for sending email via ACS with Managed Identity."""

import json
import logging
import os

import azure.functions as func
from azure.communication.email import EmailClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()


@app.route(route="send", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def send_email(req: func.HttpRequest) -> func.HttpResponse:
    """Send an email via Azure Communication Services.

    Expects JSON body:
    {
        "to": "recipient@example.com" or ["a@example.com", "b@example.com"],
        "subject": "Email subject",
        "body": "Plain text body",
        "html": "<p>Optional HTML body</p>",
        "sender": "DoNotReply@xxx.azurecomm.net"  (optional override)
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

    recipients = [{"address": addr} for addr in to]

    # Build email content
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

    try:
        endpoint = os.environ.get("ACS_ENDPOINT", "")
        if not endpoint:
            return func.HttpResponse(
                json.dumps({"error": "ACS_ENDPOINT not configured. Run './deploy.sh status' to refresh."}),
                status_code=500,
                mimetype="application/json",
            )
        credential = DefaultAzureCredential()
        client = EmailClient(endpoint, credential)

        poller = client.begin_send(message)
        result = poller.result()

        logging.info("Email sent successfully: %s", result["id"])
        return func.HttpResponse(
            json.dumps({
                "status": "sent",
                "messageId": result["id"],
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
