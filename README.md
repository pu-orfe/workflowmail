# WorkflowMail

Fully secretless email delivery from GitHub Actions via Azure OIDC + Azure Communication Services.

```
GitHub Action (OIDC) → Azure Login → Get Function Key → Azure Function → Managed Identity → ACS Email
```

No passwords, tokens, or credential rotation. OIDC tokens are ephemeral. Function keys are retrieved at runtime and never stored.

## Why

When GitHub Actions workflows need to send email — build reports, failure alerts, scheduled digests — you usually end up storing SMTP credentials as repository secrets. WorkflowMail eliminates that entirely using Azure Workload Identity Federation (OIDC), so even if the GitHub account is compromised, there's no reusable credential an attacker can extract.

## Prerequisites

- [Azure CLI](https://aka.ms/installazurecli) (`az`)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-tools?tabs=v4) (`func`)
- [jq](https://jqlang.github.io/jq/)
- [GitHub CLI](https://cli.github.com/) (`gh`) — optional, for auto-setting repo variables
- An Azure subscription with permission to create resources
- A GitHub repository (or organization) where you want to send email

## Quick Start

```bash
# Deploy the full stack interactively
./deploy.sh deploy

# Check deployment status
./deploy.sh status

# Send a test email to verify everything works
./deploy.sh test

# Tear down all resources when done
./deploy.sh teardown
```

The deploy script is interactive — it prompts for your Azure subscription, tenant, GitHub org/repo, and resource naming preferences. Configuration is saved to `.workflowmail.conf` for subsequent runs.

## What Gets Created

| Resource | Purpose |
|----------|---------|
| Resource Group | Contains all Azure resources |
| Azure Communication Services | Email sending backend |
| Email Service + Azure-managed domain | `DoNotReply@<guid>.azurecomm.net` sender |
| App Registration + Service Principal | GitHub OIDC trust relationship |
| Federated Credential | Ties the GitHub repo to the App Registration |
| Azure Function App (Python, Linux) | HTTP endpoint that sends email via Managed Identity |
| Storage Account | Required by Azure Functions runtime |
| Role Assignments | Contributor on RG (for GitHub SP), Contributor on ACS (for Managed Identity) |

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

## Function API

The Azure Function accepts POST requests to `/api/send`:

```json
{
  "to": "recipient@example.com",
  "subject": "Email subject",
  "body": "Plain text body",
  "html": "<h1>Optional HTML body</h1>",
  "sender": "DoNotReply@xxx.azurecomm.net"
}
```

- `to` — Single email string or array of strings
- `subject` — Required
- `body` — Plain text content
- `html` — HTML content (optional, sent alongside plain text)
- `sender` — Override the default sender address (optional)

## Local Development

```bash
# Run locally with Docker
docker-compose up --build

# The function is available at http://localhost:7071/api/send
# Note: Managed Identity auth won't work locally — use connection strings instead
```

## Security Model

- **No stored credentials** — GitHub authenticates to Azure via OIDC. No client secrets, no certificates, no passwords.
- **Ephemeral tokens** — OIDC tokens are short-lived and scoped to a single workflow run.
- **Function-level auth** — The Azure Function requires a function key, retrieved at runtime via Azure CLI (never stored in GitHub).
- **Managed Identity** — The Function App authenticates to ACS using its system-assigned Managed Identity. No connection strings.
- **Scoped access** — The GitHub Service Principal has Contributor on the resource group only. If the GitHub account is compromised, the attacker gets time-limited OIDC tokens with no extractable credentials.

## File Structure

```
.
├── deploy.sh                              # Deploy/teardown/status/test script
├── function/
│   ├── function_app.py                    # Azure Function (Python v2)
│   ├── requirements.txt                   # Python dependencies
│   ├── host.json                          # Functions host config
│   └── local.settings.json                # Local dev settings (gitignored)
├── .github/workflows/
│   ├── send-email.yml                     # Example: manual email trigger
│   └── email-reusable.yml                 # Reusable workflow for cross-repo
├── Dockerfile                             # Container build for the function
├── docker-compose.yml                     # Local dev with Azurite emulator
└── .gitignore
```

## Teardown

```bash
./deploy.sh teardown
```

This deletes:
- The entire resource group (ACS, Email Service, Function App, Storage Account)
- The App Registration and Service Principal
- The local `.workflowmail.conf` file

Remember to also remove the GitHub repository variables (`AZURE_CLIENT_ID`, etc.) after teardown.

## License

MIT
