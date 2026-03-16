# WorkflowMail

Email delivery from GitHub Actions via Azure. Two backends:

- **ACS** (default) — Azure Communication Services with Managed Identity. Fully secretless for GitHub OIDC callers. Sends from `DoNotReply@<guid>.azurecomm.net`.
- **Graph** — Microsoft Graph API with OAuth refresh token. Sends as a real O365 mailbox (e.g., `noreply@contoso.com`). Uses delegated permissions — no admin consent required.

```
ACS:   GitHub Action → OIDC → Azure → Function → Managed Identity → ACS Email
Graph: GitHub Action → OIDC → Azure → Function → OAuth Token → Graph sendMail
```

> **Secretless?** Only the ACS backend with GitHub Actions OIDC is truly secretless end-to-end — no credentials stored anywhere (not in GitHub, not in Azure). The Graph backend stores an OAuth refresh token in Azure Function App settings (encrypted at rest). Non-OIDC integrations (e.g., Drupal Webforms) require a static function key regardless of backend. See [Security Model](#security-model) for the full breakdown.

## Email Backends

| | ACS (default) | Graph |
|---|---|---|
| **Sender address** | `DoNotReply@<guid>.azurecomm.net` | Any O365 mailbox (e.g., `noreply@contoso.com`) |
| **Authentication** | Managed Identity (no stored credentials) | OAuth refresh token (stored in Azure) |
| **Admin consent** | Not required | Not required (delegated `Mail.Send`) |
| **Setup** | Automatic (deploy creates ACS resources) | One-time device code login during deploy |
| **Token maintenance** | None | Automatic weekly heartbeat timer |
| **Azure resources** | ACS + Email Service + domain | Function App only (no ACS) |

## Prerequisites

- [Azure CLI](https://aka.ms/installazurecli) (`az`)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-tools?tabs=v4) (`func`)
- [jq](https://jqlang.github.io/jq/)
- [GitHub CLI](https://cli.github.com/) (`gh`) — optional, for auto-setting repo variables
- An Azure subscription with permission to create resources
- A GitHub repository (or organization) where you want to send email
- **Graph backend only:** An O365 mailbox account to authenticate as during deployment

## Quick Start

```bash
# Deploy the full stack interactively (prompts for backend choice)
./deploy.sh deploy

# Check deployment status
./deploy.sh status

# Send a test email to verify everything works
./deploy.sh test

# Tear down all resources when done
./deploy.sh teardown
```

The deploy script is interactive — it prompts for your Azure subscription, tenant, GitHub org/repo, email backend, and resource naming preferences. Configuration is saved to `.workflowmail.conf` for subsequent runs.

### Graph Backend Setup

When you choose the `graph` backend during `./deploy.sh deploy`:

1. The script creates the standard Azure resources (resource group, function app, app registration)
2. It adds delegated `Mail.Send` + `offline_access` permissions to the app registration
3. It initiates a **device code flow** — you'll see a code to enter at `https://microsoft.com/devicelogin`
4. Sign in as the O365 mailbox account (e.g., `noreply@contoso.com`) and consent to the permissions
5. The refresh token is stored as an encrypted Function App setting
6. A weekly timer function keeps the token alive (90-day inactivity timeout, reset on each use)

## What Gets Created

| Resource | ACS Backend | Graph Backend |
|----------|:-----------:|:-------------:|
| Resource Group | Yes | Yes |
| Azure Communication Services | Yes | No |
| Email Service + Azure-managed domain | Yes | No |
| App Registration + Service Principal | Yes | Yes |
| Federated Credential (OIDC) | Yes | Yes |
| Azure Function App (Python, Linux) | Yes | Yes |
| Storage Account | Yes | Yes |
| MI → ACS role assignment | Yes | No |
| SP → RG role assignment | Yes | Yes |
| Refresh token (Function App setting) | No | Yes |

## Using in Your Workflow

After deployment, the script will offer to auto-set GitHub repository variables via `gh` CLI. If `gh` is not installed, set them manually:

| Variable | Description |
|----------|-------------|
| `AZURE_CLIENT_ID` | App Registration client ID |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
| `AZURE_RG` | Resource group name |
| `AZURE_FUNC_NAME` | Function App name |

These are **not secrets** — they're public identifiers. OIDC eliminates the need for stored secrets.

### Direct Workflow

Add this to any workflow in the configured repo:

```yaml
jobs:
  notify:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Get Function Key
        id: func-key
        env:
          FUNC_NAME: ${{ vars.AZURE_FUNC_NAME }}
          RG_NAME: ${{ vars.AZURE_RG }}
        run: |
          KEY=$(az functionapp function keys list \
            --name "$FUNC_NAME" \
            --resource-group "$RG_NAME" \
            --function-name "send_email" \
            --query "default" -o tsv)
          echo "::add-mask::$KEY"
          echo "key=$KEY" >> "$GITHUB_OUTPUT"

      - name: Send Email
        env:
          FUNC_NAME: ${{ vars.AZURE_FUNC_NAME }}
          FUNC_KEY: ${{ steps.func-key.outputs.key }}
        run: |
          curl -sf -X POST \
            "https://${FUNC_NAME}.azurewebsites.net/api/send?code=${FUNC_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"to":"you@example.com","subject":"Build Report","body":"All tests passed."}'

      - if: always()
        run: az logout
```

### Reusable Workflow (Cross-Repo)

Call WorkflowMail from any repo in your organization:

```yaml
permissions:
  id-token: write    # Required for OIDC — must be set in the CALLING workflow
  contents: read

jobs:
  notify:
    uses: <org>/workflowmail/.github/workflows/email-reusable.yml@main
    with:
      to: "team@example.com"
      subject: "Build Report for ${{ github.repository }}"
      body: "Run ${{ github.run_id }} completed successfully."
```

For cross-repo use, add federated credentials for each calling repo:

```bash
# Interactively add OIDC trust for another repo
./deploy.sh add-cred
```

This creates a federated credential and optionally sets the required GitHub variables on the target repo via `gh` CLI.

### Drupal 10 Webforms

The Azure Function's HTTP API works with any client that can POST JSON — including Drupal 10's built-in **Remote Post** webform handler. No site admin access or custom modules required.

#### 1. Get your function key

```bash
az functionapp function keys list \
  --name <your-func-name> \
  --resource-group <your-rg> \
  --function-name send_email \
  --query "default" -o tsv
```

#### 2. Add a Remote Post handler

In Drupal, go to your Webform → **Settings** → **Emails/Handlers** → **Add handler** → **Remote Post**.

| Setting | Value |
|---------|-------|
| URL | `https://<func-name>.azurewebsites.net/api/send?code=<function-key>` |
| Type | JSON |
| Method | POST |

#### 3. Map form fields to the email payload

In the handler's **Custom data** (Completed) field, use Drupal tokens to map your webform fields:

```yaml
to: 'admin@example.com'
subject: 'New submission from [webform_submission:values:name]'
body: '[webform_submission:values:message]'
```

For HTML email:

```yaml
to: 'admin@example.com'
subject: 'Contact form: [webform_submission:values:name]'
html: |
  <h2>New Contact Form Submission</h2>
  <p><strong>Name:</strong> [webform_submission:values:name]</p>
  <p><strong>Email:</strong> [webform_submission:values:email]</p>
  <p><strong>Message:</strong> [webform_submission:values:message]</p>
```

To send a confirmation to the submitter and a copy to an admin, add two separate Remote Post handlers — one with `to: '[webform_submission:values:email]'` and one with `to: 'admin@example.com'`.

#### Security notes for Drupal integration

- The function key is stored in Drupal's handler config. Anyone who can edit the webform can see it.
- The key only grants the ability to send email through your configured backend — no other Azure access.
- Rotate the key if compromised: `az functionapp function keys set --name <func> --resource-group <rg> --function-name send_email --key-name default --key-value <new-key>`
- Unlike the GitHub Actions flow (which uses OIDC and never stores credentials), the Drupal integration relies on a static function key. This is standard for server-to-server calls from a trusted backend.

## Function API

The Azure Function accepts POST requests to `/api/send`:

```json
{
  "to": "recipient@example.com",
  "subject": "Email subject",
  "body": "Plain text body",
  "html": "<h1>Optional HTML body</h1>",
  "sender": "user@example.com"
}
```

- `to` — Single email string or array of strings
- `subject` — Required
- `body` — Plain text content
- `html` — HTML content (optional; with ACS backend both are sent, with Graph backend HTML takes precedence)
- `sender` — Override the default sender address (optional). For ACS this must be a verified domain address. For Graph this must be a mailbox the authenticated user can send as.

## Local Development

```bash
# Run locally with Docker (ACS backend)
docker-compose up --build

# Run locally with Graph backend
EMAIL_BACKEND=graph \
  GRAPH_TENANT_ID=... \
  GRAPH_CLIENT_ID=... \
  GRAPH_REFRESH_TOKEN=... \
  SENDER_ADDRESS=noreply@contoso.com \
  docker-compose up --build

# The function is available at http://localhost:7071/api/send
# Note: ACS Managed Identity auth won't work locally — use connection strings instead
```

## Security Model

**GitHub Actions (no secrets stored in GitHub — both backends):**
- **No stored credentials in GitHub** — GitHub authenticates to Azure via OIDC. No client secrets, no certificates, no passwords stored in your repository or organization.
- **Ephemeral tokens** — OIDC tokens are short-lived and scoped to a single workflow run.
- **Function-level auth** — The Azure Function requires a function key, retrieved at runtime via Azure CLI (never stored in GitHub).
- **Scoped access** — The GitHub Service Principal has Contributor on the resource group only.

**ACS backend (secretless end-to-end):**
- **No credentials stored anywhere** — not in GitHub, not in Azure. The Function App authenticates to ACS using its system-assigned Managed Identity. No connection strings, no tokens, no passwords at any layer.
- If the GitHub account is compromised, the attacker gets time-limited OIDC tokens with no extractable credentials.
- This is the only configuration that is truly secretless across the entire pipeline.

**Graph backend (credential stored in Azure):**
- **Not secretless.** The Graph backend stores a long-lived OAuth refresh token as a Function App setting (encrypted at rest by Azure). The GitHub side remains secret-free (OIDC), but the Azure side holds a credential.
- **Delegated permissions** — The token grants `Mail.Send` as the authenticated user only. No application-level permissions. No admin consent.
- **Weekly heartbeat** — A timer-triggered function exchanges the refresh token weekly, resetting the 90-day inactivity window.
- **Token lifecycle:** The refresh token is NOT revoked by password changes (device code flow tokens are non-password-based). It is only revoked by explicit admin action or user self-service token revocation.
- **Blast radius** — If the token is compromised, the attacker can send email as the authenticated mailbox. They cannot read email, access other users, or perform any other Graph operations.

**Non-OIDC clients (Drupal, scripts, etc.):**
- **Function key required** — External callers authenticate with a static function key passed in the URL. This is a stored credential — treat it like a password.
- **Scoped blast radius** — The key only grants access to the email-sending endpoint. It cannot access other Azure resources.
- **Rotation** — Rotate keys with `az functionapp function keys set`.

## File Structure

```
.
├── deploy.sh                              # Deploy/teardown/status/test script
├── function/
│   ├── function_app.py                    # Azure Function (Python v2, ACS + Graph)
│   ├── test_function_app.py               # Unit tests
│   ├── requirements.txt                   # Python dependencies
│   ├── host.json                          # Functions host config
│   └── local.settings.json                # Local dev settings (gitignored)
├── .github/workflows/
│   ├── send-email.yml                     # Example: manual email trigger
│   └── email-reusable.yml                 # Reusable workflow for cross-repo
├── Dockerfile                             # Container build for the function
├── Dockerfile.test                        # Containerized test runner
├── docker-compose.yml                     # Local dev with Azurite emulator
└── .gitignore
```

## Teardown

```bash
./deploy.sh teardown
```

This deletes:
- The entire resource group (Function App, Storage Account, and ACS resources if applicable)
- The App Registration and Service Principal
- The local `.workflowmail.conf` file

The Graph refresh token is stored as a Function App setting and is deleted with the resource group. Remember to also remove the GitHub repository variables (`AZURE_CLIENT_ID`, etc.) after teardown.

## License

MIT
