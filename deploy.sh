#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║  workflowmail - Azure OIDC + ACS Email Deployment                  ║
# ║  Bash 3.2 compatible | Fully secretless | GitHub → Azure → Email   ║
# ╚══════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ── Colors (tput for portability) ───────────────────────────────────────
RED=$(tput setaf 1 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
BLUE=$(tput setaf 4 2>/dev/null || true)
MAGENTA=$(tput setaf 5 2>/dev/null || true)
CYAN=$(tput setaf 6 2>/dev/null || true)
BOLD=$(tput bold 2>/dev/null || true)
DIM=$(tput dim 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

# ── Configuration ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.workflowmail.conf"
FUNCTION_DIR="${SCRIPT_DIR}/function"
API_VERSION_COMM="2023-04-01"
API_VERSION_EMAIL="2023-04-01"

# ── Logging ─────────────────────────────────────────────────────────────
info()    { echo "${BLUE}${BOLD}[INFO]${RESET}    $*"; }
success() { echo "${GREEN}${BOLD}[OK]${RESET}      $*"; }
warn()    { echo "${YELLOW}${BOLD}[WARN]${RESET}    $*"; }
error()   { echo "${RED}${BOLD}[ERROR]${RESET}   $*"; }
step()    { echo "${MAGENTA}${BOLD}  ▸${RESET} $*"; }
prompt()  { echo -n "${CYAN}${BOLD}  ?${RESET} $* "; }
divider() { echo "${DIM}  ────────────────────────────────────────────────────${RESET}"; }

# ── Retry Helper ──────────────────────────────────────────────────────
# Usage: retry <max_attempts> <delay_seconds> <description> <command...>
retry() {
    local max_attempts="$1"; shift
    local delay="$1"; shift
    local desc="$1"; shift
    local attempt=1

    while true; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            # Final attempt: show stderr for debugging
            if "$@"; then
                return 0
            fi
            warn "Failed after ${max_attempts} attempts: ${desc}"
            return 1
        fi
        if "$@" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        info "  Retrying ${desc} (attempt ${attempt}/${max_attempts})..."
        sleep "$delay"
    done
}

banner() {
    echo ""
    echo "${CYAN}${BOLD}"
    echo "  ╦ ╦╔═╗╦═╗╦╔═╔═╗╦  ╔═╗╦ ╦╔╦╗╔═╗╦╦  "
    echo "  ║║║║ ║╠╦╝╠╩╗╠╣ ║  ║ ║║║║║║║╠═╣║║  "
    echo "  ╚╩╝╚═╝╩╚═╩ ╩╚  ╩═╝╚═╝╚╩╝╩ ╩╩ ╩╩╩═╝"
    echo "${RESET}"
    echo "${DIM}  Azure OIDC + ACS Email · Fully Secretless${RESET}"
    echo ""
}

usage() {
    echo "${BOLD}Usage:${RESET} $0 <command>"
    echo ""
    echo "${BOLD}Commands:${RESET}"
    echo "  ${GREEN}deploy${RESET}      Deploy the full stack (interactive)"
    echo "  ${RED}teardown${RESET}    Tear down all deployed resources"
    echo "  ${BLUE}status${RESET}      Show current deployment status"
    echo "  ${CYAN}test${RESET}        Send a test email to verify deployment"
    echo "  ${MAGENTA}add-cred${RESET}    Add OIDC credential for another GitHub repo"
    echo "  ${DIM}logs${RESET}        Stream live Function App logs"
    echo "  ${YELLOW}help${RESET}        Show this help message"
    echo ""
    echo "${BOLD}Architecture:${RESET}"
    echo "  GitHub Action → OIDC → Azure → Function → Managed Identity → ACS Email"
    echo ""
    echo "${BOLD}What gets created:${RESET}"
    echo "  1. Resource Group with ACS + Email Service + Azure-managed domain"
    echo "  2. App Registration + Service Principal + Federated Credential (OIDC)"
    echo "  3. Azure Function App with System-Assigned Managed Identity"
    echo "  4. Role assignments for least-privilege access"
    echo ""
}

# ── Prerequisite Checks ────────────────────────────────────────────────
check_prerequisites() {
    info "Checking prerequisites..."
    local missing=0

    # Azure CLI
    if command -v az >/dev/null 2>&1; then
        local az_ver
        az_ver=$(az version --output tsv --query '"azure-cli"' 2>/dev/null || echo "unknown")
        success "Azure CLI found (v${az_ver})"
    else
        error "Azure CLI (az) not found. Install: https://aka.ms/installazurecli"
        missing=1
    fi

    # jq
    if command -v jq >/dev/null 2>&1; then
        success "jq found"
    else
        error "jq not found. Install: brew install jq / apt-get install jq"
        missing=1
    fi

    # Azure Functions Core Tools (needed for deployment)
    if command -v func >/dev/null 2>&1; then
        success "Azure Functions Core Tools found"
    else
        warn "Azure Functions Core Tools (func) not found."
        warn "Needed for function deployment. Install: npm i -g azure-functions-core-tools@4"
        warn "Continuing anyway — you can deploy the function code later."
    fi

    # GitHub CLI (optional — for auto-setting repo variables)
    if command -v gh >/dev/null 2>&1; then
        success "GitHub CLI (gh) found — can auto-set repo variables"
    else
        warn "GitHub CLI (gh) not found. Repo variables will need to be set manually."
        warn "Install: https://cli.github.com/"
    fi

    # Azure CLI communication extension
    if az extension show --name communication >/dev/null 2>&1; then
        success "Azure CLI 'communication' extension found"
    else
        info "Installing Azure CLI 'communication' extension..."
        az extension add --name communication --yes >/dev/null 2>&1
        if az extension show --name communication >/dev/null 2>&1; then
            success "Azure CLI 'communication' extension installed"
        else
            error "Failed to install 'communication' extension. Install manually: az extension add --name communication"
            missing=1
        fi
    fi

    # Check Azure login
    if az account show >/dev/null 2>&1; then
        local acct_name
        acct_name=$(az account show --query "name" -o tsv 2>/dev/null)
        success "Logged into Azure: ${BOLD}${acct_name}${RESET}"
    else
        error "Not logged into Azure. Run: az login"
        missing=1
    fi

    if [ "$missing" -eq 1 ]; then
        echo ""
        error "Missing prerequisites. Please install them and try again."
        exit 1
    fi

    echo ""
}

# ── Config Persistence ──────────────────────────────────────────────────
save_config() {
    local key="$1"
    local value="$2"
    # Create config file if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        printf '%s\n%s\n' "# workflowmail deployment configuration" "# Auto-generated — do not edit manually" > "$CONFIG_FILE"
    fi
    # Remove existing key if present, then append
    if [ -f "$CONFIG_FILE" ]; then
        local tmp_file="${CONFIG_FILE}.tmp"
        grep -v "^${key}=" "$CONFIG_FILE" > "$tmp_file" 2>/dev/null || true
        mv "$tmp_file" "$CONFIG_FILE"
    fi
    echo "${key}=${value}" >> "$CONFIG_FILE"
}

load_config() {
    local key="$1"
    local default="${2:-}"
    if [ -f "$CONFIG_FILE" ]; then
        local val
        val=$(grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-)
        if [ -n "$val" ]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

# ── Interactive Prompts ─────────────────────────────────────────────────
prompt_value() {
    local description="$1"
    local var_name="$2"
    local default="$3"
    local value=""

    if [ -n "$default" ]; then
        prompt "${description} [${YELLOW}${default}${RESET}]: "
        read -r value
        if [ -z "$value" ]; then
            value="$default"
        fi
    else
        prompt "${description}: "
        read -r value
        while [ -z "$value" ]; do
            error "This field is required."
            prompt "${description}: "
            read -r value
        done
    fi

    printf -v "$var_name" '%s' "$value"
    save_config "$var_name" "$value"
}

prompt_yes_no() {
    local question="$1"
    local default="${2:-y}"
    local answer=""

    if [ "$default" = "y" ]; then
        prompt "${question} [${GREEN}Y${RESET}/n]: "
    else
        prompt "${question} [y/${GREEN}N${RESET}]: "
    fi
    read -r answer

    if [ -z "$answer" ]; then
        answer="$default"
    fi

    case "$answer" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

gather_config() {
    echo "${BOLD}${CYAN}  ┌─ Deployment Configuration ─────────────────────────────┐${RESET}"
    echo ""

    # Subscription
    local current_sub
    current_sub=$(az account show --query "id" -o tsv 2>/dev/null || echo "")
    prompt_value "Azure Subscription ID" "SUBSCRIPTION_ID" "$(load_config SUBSCRIPTION_ID "$current_sub")"

    # Tenant
    local current_tenant
    current_tenant=$(az account show --query "tenantId" -o tsv 2>/dev/null || echo "")
    prompt_value "Azure Tenant ID" "TENANT_ID" "$(load_config TENANT_ID "$current_tenant")"

    # Set subscription
    if ! az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null; then
        error "Could not set subscription '${SUBSCRIPTION_ID}'."
        error "Verify the ID and that you have access: az account list -o table"
        exit 1
    fi

    divider

    # GitHub
    prompt_value "GitHub org/owner (e.g. myorg)" "GITHUB_ORG" "$(load_config GITHUB_ORG "")"
    prompt_value "GitHub repo name (e.g. myrepo)" "GITHUB_REPO" "$(load_config GITHUB_REPO "")"

    echo ""
    info "OIDC subject filter determines which workflows can authenticate."
    info "Azure requires an ${BOLD}exact match${RESET} — wildcards are NOT supported."
    echo "${DIM}    repo:<org>/<repo>:ref:refs/heads/main       — only main branch${RESET}"
    echo "${DIM}    repo:<org>/<repo>:environment:production    — only production env${RESET}"
    echo "${DIM}    repo:<org>/<repo>:pull_request              — only pull requests${RESET}"
    echo "${DIM}    Add more federated credentials later for additional branches/repos.${RESET}"
    prompt_value "OIDC subject filter" "OIDC_SUBJECT" \
        "$(load_config OIDC_SUBJECT "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main")"

    divider

    # Resource naming
    prompt_value "Resource prefix (lowercase, no spaces)" "RESOURCE_PREFIX" \
        "$(load_config RESOURCE_PREFIX "wfmail")"

    prompt_value "Azure region" "LOCATION" "$(load_config LOCATION "eastus")"

    divider

    # Derive resource names
    # Storage accounts must be 3-24 chars, lowercase alphanumeric only
    local safe_prefix
    safe_prefix=$(echo "$RESOURCE_PREFIX" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
    RESOURCE_GROUP="${RESOURCE_PREFIX}-rg"
    ACS_NAME="${RESOURCE_PREFIX}-acs"
    EMAIL_SERVICE_NAME="${RESOURCE_PREFIX}-email"
    FUNC_APP_NAME="${RESOURCE_PREFIX}-func"
    STORAGE_ACCOUNT="${safe_prefix}store"
    APP_REG_NAME="${RESOURCE_PREFIX}-github-oidc"

    # Truncate storage account name to 24 chars
    if [ ${#STORAGE_ACCOUNT} -gt 24 ]; then
        STORAGE_ACCOUNT=$(echo "$STORAGE_ACCOUNT" | cut -c1-24)
    fi

    save_config "RESOURCE_GROUP" "$RESOURCE_GROUP"
    save_config "ACS_NAME" "$ACS_NAME"
    save_config "EMAIL_SERVICE_NAME" "$EMAIL_SERVICE_NAME"
    save_config "FUNC_APP_NAME" "$FUNC_APP_NAME"
    save_config "STORAGE_ACCOUNT" "$STORAGE_ACCOUNT"
    save_config "APP_REG_NAME" "$APP_REG_NAME"

    echo ""
    info "Resource names that will be created:"
    echo "${DIM}    Resource Group:    ${BOLD}${RESOURCE_GROUP}${RESET}"
    echo "${DIM}    ACS:               ${BOLD}${ACS_NAME}${RESET}"
    echo "${DIM}    Email Service:     ${BOLD}${EMAIL_SERVICE_NAME}${RESET}"
    echo "${DIM}    Function App:      ${BOLD}${FUNC_APP_NAME}${RESET}"
    echo "${DIM}    Storage Account:   ${BOLD}${STORAGE_ACCOUNT}${RESET}"
    echo "${DIM}    App Registration:  ${BOLD}${APP_REG_NAME}${RESET}"
    echo ""

    # Check name availability for globally unique resources
    local name_ok=1
    local sa_check
    sa_check=$(az storage account check-name --name "$STORAGE_ACCOUNT" --query "nameAvailable" -o tsv 2>/dev/null || echo "true")
    if [ "$sa_check" = "false" ]; then
        local sa_reason
        sa_reason=$(az storage account check-name --name "$STORAGE_ACCOUNT" --query "reason" -o tsv 2>/dev/null || echo "already taken")
        if [ "$sa_reason" = "AlreadyExists" ]; then
            warn "Storage account name '${STORAGE_ACCOUNT}' is already taken globally."
            warn "Choose a different resource prefix or the deploy may fail if it's not yours."
            name_ok=0
        fi
    fi

    # Check function app name availability via a quick DNS probe
    local func_check
    func_check=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://${FUNC_APP_NAME}.azurewebsites.net" 2>/dev/null || echo "000")
    if [ "$func_check" != "000" ] && [ "$func_check" != "404" ]; then
        warn "Function App name '${FUNC_APP_NAME}' may already be in use (got HTTP ${func_check})."
        warn "Choose a different resource prefix if this is not your existing deployment."
        name_ok=0
    fi

    if [ "$name_ok" -eq 0 ]; then
        echo ""
        if ! prompt_yes_no "Name conflicts detected. Continue anyway?" "n"; then
            info "Deployment cancelled. Change RESOURCE_PREFIX and try again."
            exit 0
        fi
    fi

    echo "${BOLD}${CYAN}  └────────────────────────────────────────────────────────┘${RESET}"
    echo ""

    if ! prompt_yes_no "Proceed with deployment?"; then
        info "Deployment cancelled."
        exit 0
    fi
    echo ""
}

# ── Deploy Steps ────────────────────────────────────────────────────────

deploy_resource_group() {
    step "Creating resource group ${BOLD}${RESOURCE_GROUP}${RESET} in ${LOCATION}..."
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output none
    success "Resource group created."
}

deploy_acs() {
    step "Creating Azure Communication Services: ${BOLD}${ACS_NAME}${RESET}..."
    if ! az communication create \
        --name "$ACS_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "Global" \
        --data-location "United States" \
        --output none 2>/dev/null; then
        # Check if it already exists (create fails if it does)
        if az communication show --name "$ACS_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
            warn "Communication Services '${ACS_NAME}' already exists. Reusing."
        else
            error "Failed to create Communication Services resource."
            error "Check your subscription quota and permissions."
            exit 1
        fi
    else
        success "Communication Services resource created."
    fi

    # Create Email Service via REST API
    step "Creating Email Communication Service: ${BOLD}${EMAIL_SERVICE_NAME}${RESET}..."
    local email_body
    email_body=$(cat <<'EJSON'
{
  "location": "Global",
  "properties": {
    "dataLocation": "United States"
  }
}
EJSON
)
    if ! az rest --method PUT \
        --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/emailServices/${EMAIL_SERVICE_NAME}?api-version=${API_VERSION_EMAIL}" \
        --body "$email_body" \
        --output none 2>/dev/null; then
        # PUT is idempotent — check if it already exists
        if az rest --method GET \
            --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/emailServices/${EMAIL_SERVICE_NAME}?api-version=${API_VERSION_EMAIL}" \
            --output none 2>/dev/null; then
            warn "Email Service '${EMAIL_SERVICE_NAME}' already exists. Reusing."
        else
            error "Failed to create Email Communication Service."
            error "Check subscription quotas and permissions."
            exit 1
        fi
    else
        success "Email Communication Service created."
    fi

    # Create Azure-managed domain
    step "Creating Azure-managed email domain (this may take a minute)..."
    local domain_body
    domain_body=$(cat <<'DJSON'
{
  "location": "Global",
  "properties": {
    "domainManagement": "AzureManagedDomain"
  }
}
DJSON
)
    if ! az rest --method PUT \
        --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/emailServices/${EMAIL_SERVICE_NAME}/domains/AzureManagedDomain?api-version=${API_VERSION_EMAIL}" \
        --body "$domain_body" \
        --output none 2>/dev/null; then
        # Check if the domain already exists
        if az rest --method GET \
            --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/emailServices/${EMAIL_SERVICE_NAME}/domains/AzureManagedDomain?api-version=${API_VERSION_EMAIL}" \
            --output none 2>/dev/null; then
            warn "Azure-managed domain already exists. Reusing."
        else
            error "Failed to create Azure-managed email domain."
            exit 1
        fi
    fi

    # Poll until domain is provisioned
    local domain_status="Creating"
    local attempts=0
    while [ "$domain_status" != "Succeeded" ] && [ "$attempts" -lt 60 ]; do
        sleep 10
        domain_status=$(az rest --method GET \
            --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/emailServices/${EMAIL_SERVICE_NAME}/domains/AzureManagedDomain?api-version=${API_VERSION_EMAIL}" \
            --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Creating")
        attempts=$((attempts + 1))
        echo -n "."
        # Break early on terminal failure states
        if [ "$domain_status" = "Failed" ] || [ "$domain_status" = "Canceled" ]; then
            break
        fi
    done
    echo ""

    if [ "$domain_status" = "Failed" ] || [ "$domain_status" = "Canceled" ]; then
        error "Domain provisioning ${domain_status}."
        error "Check the Azure portal for details, then re-run './deploy.sh deploy'."
        exit 1
    elif [ "$domain_status" != "Succeeded" ]; then
        warn "Domain provisioning still in progress (status: ${domain_status}). It may complete shortly."
    else
        success "Azure-managed email domain created."
    fi

    # Get the sender domain (retry — properties may lag behind provisioning status)
    local domain_url="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/emailServices/${EMAIL_SERVICE_NAME}/domains/AzureManagedDomain?api-version=${API_VERSION_EMAIL}"
    SENDER_DOMAIN=""
    local domain_attempts=0
    while [ -z "$SENDER_DOMAIN" ] || [ "$SENDER_DOMAIN" = "None" ]; do
        SENDER_DOMAIN=$(az rest --method GET \
            --url "$domain_url" \
            --query "properties.fromSenderDomain" -o tsv 2>/dev/null || echo "")

        if [ -z "$SENDER_DOMAIN" ] || [ "$SENDER_DOMAIN" = "None" ]; then
            SENDER_DOMAIN=$(az rest --method GET \
                --url "$domain_url" \
                --query "properties.mailFromSenderDomain" -o tsv 2>/dev/null || echo "")
        fi

        if [ -z "$SENDER_DOMAIN" ] || [ "$SENDER_DOMAIN" = "None" ]; then
            domain_attempts=$((domain_attempts + 1))
            if [ "$domain_attempts" -ge 6 ]; then
                warn "Could not retrieve sender domain after ${domain_attempts} attempts."
                warn "It may still be provisioning. Re-run './deploy.sh status' later."
                SENDER_DOMAIN="pending"
                break
            fi
            info "  Sender domain not yet available, retrying (${domain_attempts}/6)..."
            sleep 10
        fi
    done

    SENDER_ADDRESS="DoNotReply@${SENDER_DOMAIN}"
    save_config "SENDER_DOMAIN" "$SENDER_DOMAIN"
    save_config "SENDER_ADDRESS" "$SENDER_ADDRESS"
    info "Sender address: ${BOLD}${SENDER_ADDRESS}${RESET}"

    # Link email domain to ACS
    step "Linking email domain to Communication Services..."
    local domain_resource_id="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/emailServices/${EMAIL_SERVICE_NAME}/domains/AzureManagedDomain"
    local link_body
    link_body=$(jq -n --arg rid "$domain_resource_id" '{"properties":{"linkedDomains":[$rid]}}')
    retry 3 10 "linking email domain to ACS" \
        az rest --method PATCH \
            --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/communicationServices/${ACS_NAME}?api-version=${API_VERSION_COMM}" \
            --body "$link_body" \
            --output none
    success "Email domain linked to Communication Services."

    # Get ACS endpoint (try CLI first, then REST API fallback)
    local acs_host=""
    acs_host=$(az communication show \
        --name "$ACS_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "hostName" -o tsv 2>/dev/null || echo "")

    if [ -z "$acs_host" ] || [ "$acs_host" = "None" ]; then
        # Fallback: query via REST API
        acs_host=$(az rest --method GET \
            --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/communicationServices/${ACS_NAME}?api-version=${API_VERSION_COMM}" \
            --query "properties.hostName" -o tsv 2>/dev/null || echo "")
    fi

    if [ -n "$acs_host" ] && [ "$acs_host" != "None" ]; then
        ACS_ENDPOINT="https://${acs_host}"
    else
        warn "Could not retrieve ACS endpoint. Function app may need manual configuration."
        ACS_ENDPOINT=""
    fi
    save_config "ACS_ENDPOINT" "$ACS_ENDPOINT"
    info "ACS endpoint: ${BOLD}${ACS_ENDPOINT:-pending}${RESET}"
}

deploy_app_registration() {
    step "Creating App Registration: ${BOLD}${APP_REG_NAME}${RESET}..."

    # Check if it already exists
    local existing_app_id
    existing_app_id=$(az ad app list --display-name "$APP_REG_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")

    if [ -n "$existing_app_id" ] && [ "$existing_app_id" != "None" ]; then
        warn "App Registration '${APP_REG_NAME}' already exists (appId: ${existing_app_id}). Reusing."
        APP_CLIENT_ID="$existing_app_id"
        APP_OBJECT_ID=$(az ad app show --id "$APP_CLIENT_ID" --query "id" -o tsv 2>/dev/null)
    else
        local app_json
        app_json=$(az ad app create --display-name "$APP_REG_NAME" --output json 2>/dev/null)
        APP_CLIENT_ID=$(echo "$app_json" | jq -r '.appId')
        APP_OBJECT_ID=$(echo "$app_json" | jq -r '.id')
        success "App Registration created."
    fi

    save_config "APP_CLIENT_ID" "$APP_CLIENT_ID"
    save_config "APP_OBJECT_ID" "$APP_OBJECT_ID"
    info "App (client) ID: ${BOLD}${APP_CLIENT_ID}${RESET}"

    # Create Service Principal
    step "Creating Service Principal..."
    local sp_exists
    sp_exists=$(az ad sp show --id "$APP_CLIENT_ID" --query "id" -o tsv 2>/dev/null || echo "")
    if [ -n "$sp_exists" ]; then
        warn "Service Principal already exists. Reusing."
        SP_OBJECT_ID="$sp_exists"
    else
        SP_OBJECT_ID=$(az ad sp create --id "$APP_CLIENT_ID" --query "id" -o tsv 2>/dev/null)
        success "Service Principal created."
    fi
    save_config "SP_OBJECT_ID" "$SP_OBJECT_ID"

    # Add Federated Credential
    step "Adding Federated Credential for GitHub OIDC..."
    local fed_cred_name="github-oidc-${GITHUB_ORG}-${GITHUB_REPO}"
    # Sanitize credential name (only alphanumeric, hyphens, underscores, max 120 chars)
    fed_cred_name=$(echo "$fed_cred_name" | tr -cd 'a-zA-Z0-9_-' | cut -c1-120)

    # Check if federated credential already exists
    local existing_cred
    existing_cred=$(az ad app federated-credential list --id "$APP_OBJECT_ID" \
        --query "[?name=='${fed_cred_name}'].name" -o tsv 2>/dev/null || echo "")

    if [ -n "$existing_cred" ]; then
        warn "Federated credential '${fed_cred_name}' already exists. Skipping."
    else
        local fed_body
        fed_body=$(jq -n \
            --arg name "$fed_cred_name" \
            --arg subject "$OIDC_SUBJECT" \
            --arg desc "GitHub Actions OIDC for ${GITHUB_ORG}/${GITHUB_REPO}" \
            '{
                name: $name,
                issuer: "https://token.actions.githubusercontent.com",
                subject: $subject,
                audiences: ["api://AzureADTokenExchange"],
                description: $desc
            }')
        az ad app federated-credential create \
            --id "$APP_OBJECT_ID" \
            --parameters "$fed_body" \
            --output none 2>/dev/null
        success "Federated credential added."
    fi
    save_config "FED_CRED_NAME" "$fed_cred_name"

    info "OIDC subject: ${BOLD}${OIDC_SUBJECT}${RESET}"
}

deploy_role_assignments() {
    step "Assigning roles to Service Principal..."

    local rg_scope="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"

    # Contributor on the resource group (for function key access, general management)
    info "  Assigning ${BOLD}Contributor${RESET} on resource group..."
    if ! retry 3 10 "SP Contributor role assignment" \
        az role assignment create \
            --assignee-object-id "$SP_OBJECT_ID" \
            --assignee-principal-type "ServicePrincipal" \
            --role "Contributor" \
            --scope "$rg_scope" \
            --output none; then
        # Check if the role assignment already exists
        local existing_role
        existing_role=$(az role assignment list \
            --assignee "$SP_OBJECT_ID" \
            --role "Contributor" \
            --scope "$rg_scope" \
            --query "[0].id" -o tsv 2>/dev/null || echo "")
        if [ -n "$existing_role" ]; then
            warn "  Contributor role already assigned."
        else
            warn "  Could not assign Contributor role. You may need to assign it manually."
        fi
    fi

    success "Role assignments complete."
}

deploy_function_app() {
    step "Creating Storage Account: ${BOLD}${STORAGE_ACCOUNT}${RESET}..."
    if ! az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku "Standard_LRS" \
        --output none 2>/dev/null; then
        if az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
            warn "Storage account '${STORAGE_ACCOUNT}' already exists. Reusing."
        else
            error "Failed to create storage account '${STORAGE_ACCOUNT}'."
            error "Check subscription quotas and permissions."
            exit 1
        fi
    else
        success "Storage account created."
    fi

    step "Creating Function App: ${BOLD}${FUNC_APP_NAME}${RESET}..."
    if ! az functionapp create \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --storage-account "$STORAGE_ACCOUNT" \
        --consumption-plan-location "$LOCATION" \
        --runtime python \
        --runtime-version "3.11" \
        --functions-version 4 \
        --os-type Linux \
        --output none 2>/dev/null; then
        if az functionapp show --name "$FUNC_APP_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
            warn "Function App '${FUNC_APP_NAME}' already exists. Reusing."
        else
            error "Failed to create Function App '${FUNC_APP_NAME}'."
            error "Check name availability and subscription quotas."
            exit 1
        fi
    else
        success "Function App created."
    fi

    # Enable System-Assigned Managed Identity
    step "Enabling System-Assigned Managed Identity..."
    local mi_json
    mi_json=$(az functionapp identity assign \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --output json 2>/dev/null)
    MI_PRINCIPAL_ID=$(echo "$mi_json" | jq -r '.principalId')
    if [ -z "$MI_PRINCIPAL_ID" ] || [ "$MI_PRINCIPAL_ID" = "null" ]; then
        error "Failed to retrieve Managed Identity principal ID."
        error "Check that the Function App was created successfully."
        exit 1
    fi
    save_config "MI_PRINCIPAL_ID" "$MI_PRINCIPAL_ID"
    success "Managed Identity enabled (principalId: ${MI_PRINCIPAL_ID})"

    # Assign ACS Contributor role to the Managed Identity
    step "Assigning Contributor role to Managed Identity on ACS..."
    local acs_scope="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/communicationServices/${ACS_NAME}"

    # Wait for the identity to propagate in Azure AD (can take 10-60s)
    info "  Waiting for identity propagation..."
    sleep 30

    if ! retry 3 15 "MI Contributor role on ACS" \
        az role assignment create \
            --assignee-object-id "$MI_PRINCIPAL_ID" \
            --assignee-principal-type "ServicePrincipal" \
            --role "Contributor" \
            --scope "$acs_scope" \
            --output none; then
        local existing_mi_role
        existing_mi_role=$(az role assignment list \
            --assignee "$MI_PRINCIPAL_ID" \
            --role "Contributor" \
            --scope "$acs_scope" \
            --query "[0].id" -o tsv 2>/dev/null || echo "")
        if [ -n "$existing_mi_role" ]; then
            warn "  MI Contributor role on ACS already assigned."
        else
            warn "  Could not assign MI Contributor role on ACS. You may need to assign it manually."
        fi
    fi

    success "Managed Identity has Contributor access to ACS."

    # Validate critical settings before configuring
    if [ -z "$ACS_ENDPOINT" ]; then
        warn "ACS endpoint is empty — the function will not be able to send email."
        warn "You can fix this later: az functionapp config appsettings set --name ${FUNC_APP_NAME} --resource-group ${RESOURCE_GROUP} --settings ACS_ENDPOINT=<endpoint>"
    fi
    if [ "$SENDER_DOMAIN" = "pending" ]; then
        warn "Sender domain is still pending — email sending will fail until this resolves."
        warn "Check domain status: az rest --method GET --url 'https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/emailServices/${EMAIL_SERVICE_NAME}/domains/AzureManagedDomain?api-version=${API_VERSION_EMAIL}' --query 'properties.fromSenderDomain'"
    fi

    # Configure app settings
    step "Configuring Function App settings..."
    az functionapp config appsettings set \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --settings \
            "ACS_ENDPOINT=${ACS_ENDPOINT}" \
            "SENDER_ADDRESS=${SENDER_ADDRESS}" \
            "AzureWebJobsFeatureFlags=EnableWorkerIndexing" \
            "SCM_DO_BUILD_DURING_DEPLOYMENT=true" \
            "ENABLE_ORYX_BUILD=true" \
        --output none 2>/dev/null
    success "Function App settings configured."

    # Get Function App URL
    FUNC_APP_URL="https://${FUNC_APP_NAME}.azurewebsites.net"
    save_config "FUNC_APP_URL" "$FUNC_APP_URL"
    info "Function App URL: ${BOLD}${FUNC_APP_URL}${RESET}"
}

deploy_function_code() {
    step "Deploying function code..."

    if ! command -v func >/dev/null 2>&1; then
        warn "Azure Functions Core Tools not installed. Skipping code deployment."
        warn "Deploy manually: cd function && func azure functionapp publish ${FUNC_APP_NAME}"
        return
    fi

    # Deploy from the function directory (--build remote ensures deps are built on Linux)
    if [ -d "$FUNCTION_DIR" ]; then
        (
            cd "$FUNCTION_DIR"
            func azure functionapp publish "$FUNC_APP_NAME" --python --build remote
        )
        success "Function code deployed."

        # Poll for function registration (can take 30-90s on consumption plan)
        info "Waiting for function to register..."
        local reg_attempts=0
        local registered=""
        while [ "$reg_attempts" -lt 12 ]; do
            sleep 10
            registered=$(az functionapp function show \
                --name "$FUNC_APP_NAME" \
                --resource-group "$RESOURCE_GROUP" \
                --function-name "send_email" \
                --query "name" -o tsv 2>/dev/null || echo "")
            if [ -n "$registered" ] && [ "$registered" != "None" ]; then
                break
            fi
            reg_attempts=$((reg_attempts + 1))
            echo -n "."
        done
        echo ""
        if [ -n "$registered" ] && [ "$registered" != "None" ]; then
            success "Function 'send_email' registered and accessible."
        else
            warn "Function 'send_email' not yet visible — it may take a minute to register."
            warn "Verify with: az functionapp function show --name ${FUNC_APP_NAME} --resource-group ${RESOURCE_GROUP} --function-name send_email"
        fi
    else
        warn "Function directory not found at ${FUNCTION_DIR}. Skipping code deployment."
    fi
}

# ── GitHub Variable Management ─────────────────────────────────────────
configure_github_variables() {
    if ! command -v gh >/dev/null 2>&1; then
        info "Install GitHub CLI (gh) to auto-set these variables: https://cli.github.com/"
        return
    fi

    local gh_repo="${GITHUB_ORG}/${GITHUB_REPO}"

    echo ""
    if ! prompt_yes_no "Auto-set GitHub repository variables on ${BOLD}${gh_repo}${RESET}?"; then
        info "Skipped. Set them manually in GitHub → Settings → Variables → Actions."
        return
    fi
    echo ""

    step "Setting GitHub repository variables on ${BOLD}${gh_repo}${RESET}..."

    local failed=0
    if gh variable set AZURE_CLIENT_ID --body "$APP_CLIENT_ID" --repo "$gh_repo" 2>/dev/null; then
        success "  AZURE_CLIENT_ID set"
    else
        warn "  Failed to set AZURE_CLIENT_ID"; failed=1
    fi

    if gh variable set AZURE_TENANT_ID --body "$TENANT_ID" --repo "$gh_repo" 2>/dev/null; then
        success "  AZURE_TENANT_ID set"
    else
        warn "  Failed to set AZURE_TENANT_ID"; failed=1
    fi

    if gh variable set AZURE_SUBSCRIPTION_ID --body "$SUBSCRIPTION_ID" --repo "$gh_repo" 2>/dev/null; then
        success "  AZURE_SUBSCRIPTION_ID set"
    else
        warn "  Failed to set AZURE_SUBSCRIPTION_ID"; failed=1
    fi

    if gh variable set AZURE_RG --body "$RESOURCE_GROUP" --repo "$gh_repo" 2>/dev/null; then
        success "  AZURE_RG set"
    else
        warn "  Failed to set AZURE_RG"; failed=1
    fi

    if gh variable set AZURE_FUNC_NAME --body "$FUNC_APP_NAME" --repo "$gh_repo" 2>/dev/null; then
        success "  AZURE_FUNC_NAME set"
    else
        warn "  Failed to set AZURE_FUNC_NAME"; failed=1
    fi

    echo ""
    if [ "$failed" -eq 0 ]; then
        success "All GitHub repository variables set."
    else
        warn "Some variables failed to set. Check gh auth status and repo permissions."
        warn "You can set them manually in GitHub → Settings → Variables → Actions."
    fi
}

remove_github_variables() {
    if ! command -v gh >/dev/null 2>&1; then
        return
    fi

    local gh_org gh_repo gh_full
    gh_org=$(load_config "GITHUB_ORG" "")
    gh_repo=$(load_config "GITHUB_REPO" "")
    if [ -z "$gh_org" ] || [ -z "$gh_repo" ]; then
        return
    fi
    gh_full="${gh_org}/${gh_repo}"

    echo ""
    if ! prompt_yes_no "Remove GitHub repository variables from ${BOLD}${gh_full}${RESET}?"; then
        info "Skipped. Remove them manually in GitHub → Settings → Variables → Actions."
        return
    fi
    echo ""

    step "Removing GitHub repository variables from ${BOLD}${gh_full}${RESET}..."
    gh variable delete AZURE_CLIENT_ID --repo "$gh_full" 2>/dev/null || true
    gh variable delete AZURE_TENANT_ID --repo "$gh_full" 2>/dev/null || true
    gh variable delete AZURE_SUBSCRIPTION_ID --repo "$gh_full" 2>/dev/null || true
    gh variable delete AZURE_RG --repo "$gh_full" 2>/dev/null || true
    gh variable delete AZURE_FUNC_NAME --repo "$gh_full" 2>/dev/null || true
    success "GitHub repository variables removed."
}

# ── Add Federated Credential (for additional repos) ───────────────────
add_credential() {
    echo "${BOLD}${CYAN}  ┌─ Add Federated Credential ───────────────────────────────┐${RESET}"
    echo ""

    if [ ! -f "$CONFIG_FILE" ]; then
        error "No deployment configuration found."
        info "Run '${BOLD}$0 deploy${RESET}' first to create the base stack."
        exit 1
    fi

    APP_OBJECT_ID=$(load_config "APP_OBJECT_ID" "")
    APP_CLIENT_ID=$(load_config "APP_CLIENT_ID" "")
    TENANT_ID=$(load_config "TENANT_ID" "")
    SUBSCRIPTION_ID=$(load_config "SUBSCRIPTION_ID" "")
    RESOURCE_GROUP=$(load_config "RESOURCE_GROUP" "")
    FUNC_APP_NAME=$(load_config "FUNC_APP_NAME" "")

    if [ -z "$APP_OBJECT_ID" ]; then
        error "App Registration object ID not found in config."
        exit 1
    fi

    info "Adding a federated credential so another GitHub repo can use this deployment."
    info "Existing App Registration: ${BOLD}${APP_CLIENT_ID}${RESET}"
    echo ""

    local new_org=""
    local new_repo=""
    prompt "GitHub org/owner of the calling repo: "
    read -r new_org
    while [ -z "$new_org" ]; do
        error "Required."
        prompt "GitHub org/owner: "
        read -r new_org
    done

    prompt "GitHub repo name: "
    read -r new_repo
    while [ -z "$new_repo" ]; do
        error "Required."
        prompt "GitHub repo name: "
        read -r new_repo
    done

    echo ""
    info "OIDC subject filter for ${BOLD}${new_org}/${new_repo}${RESET}:"
    echo "${DIM}    repo:${new_org}/${new_repo}:ref:refs/heads/main       — only main branch${RESET}"
    echo "${DIM}    repo:${new_org}/${new_repo}:environment:production    — only production env${RESET}"
    local new_subject=""
    prompt "OIDC subject filter [repo:${new_org}/${new_repo}:ref:refs/heads/main]: "
    read -r new_subject
    if [ -z "$new_subject" ]; then
        new_subject="repo:${new_org}/${new_repo}:ref:refs/heads/main"
    fi

    local cred_name="github-oidc-${new_org}-${new_repo}"
    cred_name=$(echo "$cred_name" | tr -cd 'a-zA-Z0-9_-' | cut -c1-120)

    # Check if it already exists
    local existing
    existing=$(az ad app federated-credential list --id "$APP_OBJECT_ID" \
        --query "[?name=='${cred_name}'].name" -o tsv 2>/dev/null || echo "")

    if [ -n "$existing" ]; then
        warn "Federated credential '${cred_name}' already exists."
        if ! prompt_yes_no "Delete and recreate it?"; then
            info "Skipped."
            return
        fi
        az ad app federated-credential delete --id "$APP_OBJECT_ID" \
            --federated-credential-id "$cred_name" --output none 2>/dev/null || true
    fi

    echo ""
    step "Creating federated credential: ${BOLD}${cred_name}${RESET}..."
    local fed_body
    fed_body=$(jq -n \
        --arg name "$cred_name" \
        --arg subject "$new_subject" \
        --arg desc "GitHub Actions OIDC for ${new_org}/${new_repo}" \
        '{
            name: $name,
            issuer: "https://token.actions.githubusercontent.com",
            subject: $subject,
            audiences: ["api://AzureADTokenExchange"],
            description: $desc
        }')
    az ad app federated-credential create \
        --id "$APP_OBJECT_ID" \
        --parameters "$fed_body" \
        --output none 2>/dev/null
    success "Federated credential added."

    echo ""
    info "The calling repo (${BOLD}${new_org}/${new_repo}${RESET}) needs these repository variables:"
    echo ""
    echo "  ${CYAN}AZURE_CLIENT_ID${RESET}       = ${BOLD}${APP_CLIENT_ID}${RESET}"
    echo "  ${CYAN}AZURE_TENANT_ID${RESET}       = ${BOLD}${TENANT_ID}${RESET}"
    echo "  ${CYAN}AZURE_SUBSCRIPTION_ID${RESET} = ${BOLD}${SUBSCRIPTION_ID}${RESET}"
    echo "  ${CYAN}AZURE_RG${RESET}              = ${BOLD}${RESOURCE_GROUP}${RESET}"
    echo "  ${CYAN}AZURE_FUNC_NAME${RESET}       = ${BOLD}${FUNC_APP_NAME}${RESET}"
    echo ""

    # Auto-set if gh CLI available
    if command -v gh >/dev/null 2>&1; then
        local target_repo="${new_org}/${new_repo}"
        if prompt_yes_no "Auto-set these variables on ${BOLD}${target_repo}${RESET}?"; then
            echo ""
            if gh variable set AZURE_CLIENT_ID --body "$APP_CLIENT_ID" --repo "$target_repo" 2>/dev/null; then
                success "  AZURE_CLIENT_ID set"
            else
                warn "  Failed to set AZURE_CLIENT_ID"
            fi
            if gh variable set AZURE_TENANT_ID --body "$TENANT_ID" --repo "$target_repo" 2>/dev/null; then
                success "  AZURE_TENANT_ID set"
            else
                warn "  Failed to set AZURE_TENANT_ID"
            fi
            if gh variable set AZURE_SUBSCRIPTION_ID --body "$SUBSCRIPTION_ID" --repo "$target_repo" 2>/dev/null; then
                success "  AZURE_SUBSCRIPTION_ID set"
            else
                warn "  Failed to set AZURE_SUBSCRIPTION_ID"
            fi
            if gh variable set AZURE_RG --body "$RESOURCE_GROUP" --repo "$target_repo" 2>/dev/null; then
                success "  AZURE_RG set"
            else
                warn "  Failed to set AZURE_RG"
            fi
            if gh variable set AZURE_FUNC_NAME --body "$FUNC_APP_NAME" --repo "$target_repo" 2>/dev/null; then
                success "  AZURE_FUNC_NAME set"
            else
                warn "  Failed to set AZURE_FUNC_NAME"
            fi
            echo ""
        fi
    fi

    echo "${BOLD}${CYAN}  └────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

# ── Deploy Orchestrator ─────────────────────────────────────────────────
deploy() {
    echo "${BOLD}${GREEN}  ┌─ Deploying WorkflowMail Stack ──────────────────────────┐${RESET}"
    echo ""

    gather_config

    divider
    deploy_resource_group
    divider
    deploy_acs
    divider
    deploy_app_registration
    divider
    deploy_role_assignments
    divider
    deploy_function_app
    divider
    deploy_function_code
    divider

    echo ""
    echo "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════════╗${RESET}"
    echo "${GREEN}${BOLD}  ║              Deployment Complete!                       ║${RESET}"
    echo "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "${BOLD}  GitHub Repository Variables needed:${RESET}"
    echo ""
    echo "  ${CYAN}AZURE_CLIENT_ID${RESET}       = ${BOLD}${APP_CLIENT_ID}${RESET}"
    echo "  ${CYAN}AZURE_TENANT_ID${RESET}       = ${BOLD}${TENANT_ID}${RESET}"
    echo "  ${CYAN}AZURE_SUBSCRIPTION_ID${RESET} = ${BOLD}${SUBSCRIPTION_ID}${RESET}"
    echo "  ${CYAN}AZURE_RG${RESET}              = ${BOLD}${RESOURCE_GROUP}${RESET}"
    echo "  ${CYAN}AZURE_FUNC_NAME${RESET}       = ${BOLD}${FUNC_APP_NAME}${RESET}"
    echo ""
    echo "  ${DIM}These are NOT secrets — they're public identifiers.${RESET}"
    echo "  ${DIM}OIDC means no passwords or tokens are stored in GitHub.${RESET}"
    echo ""

    configure_github_variables

    echo "  ${BOLD}Example workflow:${RESET} .github/workflows/send-email.yml"
    echo ""
    echo "  ${DIM}Configuration saved to: ${CONFIG_FILE}${RESET}"
    echo ""
}

# ── Teardown ────────────────────────────────────────────────────────────
teardown() {
    echo "${BOLD}${RED}  ┌─ Tearing Down WorkflowMail Stack ────────────────────────┐${RESET}"
    echo ""

    # Load config
    if [ ! -f "$CONFIG_FILE" ]; then
        error "No configuration file found at ${CONFIG_FILE}"
        error "Nothing to tear down, or the config was deleted."
        exit 1
    fi

    SUBSCRIPTION_ID=$(load_config "SUBSCRIPTION_ID" "")
    TENANT_ID=$(load_config "TENANT_ID" "")
    RESOURCE_GROUP=$(load_config "RESOURCE_GROUP" "")
    APP_CLIENT_ID=$(load_config "APP_CLIENT_ID" "")
    APP_OBJECT_ID=$(load_config "APP_OBJECT_ID" "")
    FUNC_APP_NAME=$(load_config "FUNC_APP_NAME" "")

    echo "  This will ${RED}${BOLD}permanently delete${RESET} the following:"
    echo ""
    echo "  ${RED}▸${RESET} Resource Group:    ${BOLD}${RESOURCE_GROUP}${RESET}"
    echo "    ${DIM}(includes ACS, Email, Function App, Storage)${RESET}"
    echo "  ${RED}▸${RESET} App Registration:  ${BOLD}${APP_CLIENT_ID}${RESET}"
    echo "    ${DIM}(includes Service Principal, Federated Credentials)${RESET}"
    echo ""

    if ! prompt_yes_no "${RED}Are you sure you want to tear down everything?${RESET}" "n"; then
        info "Teardown cancelled."
        exit 0
    fi
    echo ""

    # Double-confirm
    if ! prompt_yes_no "${RED}${BOLD}FINAL CONFIRMATION — this cannot be undone.${RESET} Continue?" "n"; then
        info "Teardown cancelled."
        exit 0
    fi
    echo ""

    # Set subscription
    if [ -n "$SUBSCRIPTION_ID" ]; then
        az account set --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1 || true
    fi

    # Delete resource group (cascades to all resources within)
    if [ -n "$RESOURCE_GROUP" ]; then
        step "Deleting resource group ${BOLD}${RESOURCE_GROUP}${RESET}..."
        step "${DIM}This may take several minutes...${RESET}"
        az group delete \
            --name "$RESOURCE_GROUP" \
            --yes \
            --no-wait \
            --output none 2>/dev/null || warn "Resource group may not exist or already deleted."
        success "Resource group deletion initiated (runs in background)."
    fi

    # Delete App Registration (this also deletes the service principal)
    if [ -n "$APP_OBJECT_ID" ]; then
        step "Deleting App Registration..."
        az ad app delete --id "$APP_OBJECT_ID" --output none 2>/dev/null || warn "App Registration may not exist."
        success "App Registration deleted."
    fi

    # Remove GitHub repository variables (before config is deleted)
    remove_github_variables

    # Remove config file
    step "Removing configuration file..."
    rm -f "$CONFIG_FILE"
    success "Configuration file removed."

    echo ""
    echo "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════════╗${RESET}"
    echo "${GREEN}${BOLD}  ║              Teardown Complete!                          ║${RESET}"
    echo "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  ${DIM}The resource group is being deleted in the background.${RESET}"
    echo "  ${DIM}It may take a few minutes for all resources to be fully removed.${RESET}"
    echo "  ${DIM}Monitor: az group show --name ${RESOURCE_GROUP} 2>/dev/null${RESET}"
    echo ""
}

# ── Status ──────────────────────────────────────────────────────────────
status() {
    echo "${BOLD}${BLUE}  ┌─ WorkflowMail Deployment Status ─────────────────────────┐${RESET}"
    echo ""

    if [ ! -f "$CONFIG_FILE" ]; then
        warn "No deployment configuration found."
        info "Run '${BOLD}$0 deploy${RESET}' to create a deployment."
        return
    fi

    SUBSCRIPTION_ID=$(load_config "SUBSCRIPTION_ID" "")
    RESOURCE_GROUP=$(load_config "RESOURCE_GROUP" "")
    APP_CLIENT_ID=$(load_config "APP_CLIENT_ID" "")
    FUNC_APP_NAME=$(load_config "FUNC_APP_NAME" "")
    ACS_NAME=$(load_config "ACS_NAME" "")
    EMAIL_SERVICE_NAME=$(load_config "EMAIL_SERVICE_NAME" "")
    FUNC_APP_URL=$(load_config "FUNC_APP_URL" "")
    SENDER_ADDRESS=$(load_config "SENDER_ADDRESS" "")
    SENDER_DOMAIN=$(load_config "SENDER_DOMAIN" "")

    if [ -n "$SUBSCRIPTION_ID" ]; then
        az account set --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1 || true
    fi

    # Auto-refresh ACS endpoint if it was empty during initial deploy
    local ACS_ENDPOINT
    ACS_ENDPOINT=$(load_config "ACS_ENDPOINT" "")
    if [ -z "$ACS_ENDPOINT" ] && [ -n "$ACS_NAME" ]; then
        info "ACS endpoint was empty — checking if it's available now..."
        local refreshed_endpoint
        refreshed_endpoint=$(az rest --method GET \
            --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/communicationServices/${ACS_NAME}?api-version=${API_VERSION_COMM}" \
            --query "properties.hostName" -o tsv 2>/dev/null || echo "")
        if [ -n "$refreshed_endpoint" ] && [ "$refreshed_endpoint" != "None" ]; then
            ACS_ENDPOINT="https://${refreshed_endpoint}"
            save_config "ACS_ENDPOINT" "$ACS_ENDPOINT"
            success "ACS endpoint resolved: ${BOLD}${ACS_ENDPOINT}${RESET}"
            # Update function app settings with resolved endpoint
            if [ -n "$FUNC_APP_NAME" ]; then
                info "Updating Function App ACS endpoint..."
                az functionapp config appsettings set \
                    --name "$FUNC_APP_NAME" \
                    --resource-group "$RESOURCE_GROUP" \
                    --settings "ACS_ENDPOINT=${ACS_ENDPOINT}" \
                    --output none 2>/dev/null && success "Function App ACS endpoint updated."
            fi
        else
            warn "ACS endpoint still unavailable."
        fi
        echo ""
    fi

    # Auto-refresh sender domain if it was pending during initial deploy
    if [ "$SENDER_DOMAIN" = "pending" ] && [ -n "$EMAIL_SERVICE_NAME" ]; then
        info "Sender domain was pending — checking if it's available now..."
        local refreshed_domain
        refreshed_domain=$(az rest --method GET \
            --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Communication/emailServices/${EMAIL_SERVICE_NAME}/domains/AzureManagedDomain?api-version=${API_VERSION_EMAIL}" \
            --query "properties.fromSenderDomain" -o tsv 2>/dev/null || echo "")
        if [ -n "$refreshed_domain" ] && [ "$refreshed_domain" != "None" ]; then
            SENDER_DOMAIN="$refreshed_domain"
            SENDER_ADDRESS="DoNotReply@${SENDER_DOMAIN}"
            save_config "SENDER_DOMAIN" "$SENDER_DOMAIN"
            save_config "SENDER_ADDRESS" "$SENDER_ADDRESS"
            success "Sender domain resolved: ${BOLD}${SENDER_DOMAIN}${RESET}"
            # Update function app settings with resolved sender address
            if [ -n "$FUNC_APP_NAME" ]; then
                info "Updating Function App sender address..."
                az functionapp config appsettings set \
                    --name "$FUNC_APP_NAME" \
                    --resource-group "$RESOURCE_GROUP" \
                    --settings "SENDER_ADDRESS=${SENDER_ADDRESS}" \
                    --output none 2>/dev/null && success "Function App sender address updated."
            fi
        else
            warn "Sender domain still pending."
        fi
        echo ""
    fi

    echo "  ${BOLD}Configuration:${RESET}"
    echo "    Subscription:     ${SUBSCRIPTION_ID}"
    echo "    Resource Group:   ${RESOURCE_GROUP}"
    echo "    App Client ID:    ${APP_CLIENT_ID}"
    echo "    Function App:     ${FUNC_APP_NAME}"
    echo "    Function URL:     ${FUNC_APP_URL}"
    echo "    ACS Resource:     ${ACS_NAME}"
    echo "    ACS Endpoint:     ${ACS_ENDPOINT:-${YELLOW}empty${RESET}}"
    echo "    Sender Address:   ${SENDER_ADDRESS}"
    echo ""

    # Check resource group existence
    echo "  ${BOLD}Resource Status:${RESET}"
    if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
        echo "    Resource Group:   ${GREEN}exists${RESET}"
    else
        echo "    Resource Group:   ${RED}not found${RESET}"
    fi

    # Check app registration
    if [ -n "$APP_CLIENT_ID" ] && az ad app show --id "$APP_CLIENT_ID" >/dev/null 2>&1; then
        echo "    App Registration: ${GREEN}exists${RESET}"
    else
        echo "    App Registration: ${RED}not found${RESET}"
    fi

    # Check function app
    if [ -n "$FUNC_APP_NAME" ] && az functionapp show --name "$FUNC_APP_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
        echo "    Function App:     ${GREEN}running${RESET}"

        # Probe the function endpoint
        local probe_code
        probe_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://${FUNC_APP_NAME}.azurewebsites.net/api/send" 2>/dev/null || echo "000")
        if [ "$probe_code" = "000" ]; then
            echo "    Function HTTP:    ${YELLOW}unreachable (cold start or DNS)${RESET}"
        elif [ "$probe_code" = "401" ]; then
            echo "    Function HTTP:    ${GREEN}responding (auth required — expected)${RESET}"
        elif [ "$probe_code" = "405" ]; then
            echo "    Function HTTP:    ${GREEN}responding (method not allowed — expected for GET)${RESET}"
        else
            echo "    Function HTTP:    ${YELLOW}HTTP ${probe_code}${RESET}"
        fi

        # Check function registration
        local func_reg
        func_reg=$(az functionapp function show \
            --name "$FUNC_APP_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --function-name "send_email" \
            --query "name" -o tsv 2>/dev/null || echo "")
        if [ -n "$func_reg" ] && [ "$func_reg" != "None" ]; then
            echo "    Function Code:    ${GREEN}deployed (send_email)${RESET}"
        else
            echo "    Function Code:    ${RED}not deployed or not registered${RESET}"
        fi
    else
        echo "    Function App:     ${RED}not found${RESET}"
    fi

    # Check sender domain
    if [ "$SENDER_DOMAIN" = "pending" ] || [ -z "$SENDER_DOMAIN" ]; then
        echo "    Sender Domain:    ${YELLOW}pending${RESET}"
    else
        echo "    Sender Domain:    ${GREEN}${SENDER_DOMAIN}${RESET}"
    fi

    echo ""
    echo "${BOLD}${BLUE}  └────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

# ── Test Email ──────────────────────────────────────────────────────────
test_email() {
    echo "${BOLD}${CYAN}  ┌─ Send Test Email ──────────────────────────────────────┐${RESET}"
    echo ""

    if [ ! -f "$CONFIG_FILE" ]; then
        error "No deployment configuration found."
        info "Run '${BOLD}$0 deploy${RESET}' first."
        exit 1
    fi

    SUBSCRIPTION_ID=$(load_config "SUBSCRIPTION_ID" "")
    RESOURCE_GROUP=$(load_config "RESOURCE_GROUP" "")
    FUNC_APP_NAME=$(load_config "FUNC_APP_NAME" "")
    FUNC_APP_URL=$(load_config "FUNC_APP_URL" "")
    SENDER_ADDRESS=$(load_config "SENDER_ADDRESS" "")

    if [ -z "$FUNC_APP_NAME" ] || [ -z "$RESOURCE_GROUP" ]; then
        error "Incomplete configuration. Re-run '${BOLD}$0 deploy${RESET}'."
        exit 1
    fi

    if [ -n "$SUBSCRIPTION_ID" ]; then
        az account set --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1 || true
    fi

    # Prompt for recipient
    local test_to=""
    prompt "Recipient email address: "
    read -r test_to
    while [ -z "$test_to" ]; do
        error "Recipient is required."
        prompt "Recipient email address: "
        read -r test_to
    done

    local test_subject="WorkflowMail Test"
    local test_body
    test_body="This is a test email sent by deploy.sh to verify the WorkflowMail deployment is working correctly. Sent at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    echo ""
    info "Retrieving function key..."

    # Try function-level key first, fall back to host-level key
    local func_key=""
    func_key=$(az functionapp function keys list \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --function-name "send_email" \
        --query "default" -o tsv 2>/dev/null || true)

    if [ -z "$func_key" ] || [ "$func_key" = "None" ]; then
        func_key=$(az functionapp keys list \
            --name "$FUNC_APP_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --query "functionKeys.default" -o tsv 2>/dev/null || true)
    fi

    if [ -z "$func_key" ] || [ "$func_key" = "None" ]; then
        error "Could not retrieve function key."
        warn "The function may not be deployed yet. Run:"
        warn "  cd function && func azure functionapp publish ${FUNC_APP_NAME}"
        exit 1
    fi
    success "Function key retrieved."

    # Build JSON payload with jq if available, otherwise manual construction
    local payload=""
    if command -v jq >/dev/null 2>&1; then
        payload=$(jq -n \
            --arg to "$test_to" \
            --arg subject "$test_subject" \
            --arg body "$test_body" \
            '{to: $to, subject: $subject, body: $body}')
    else
        # Safe fallback — escape double quotes in values
        local esc_to esc_subject esc_body
        esc_to="${test_to//\"/\\\"}"
        esc_subject="${test_subject//\"/\\\"}"
        esc_body="${test_body//\"/\\\"}"
        payload="{\"to\":\"${esc_to}\",\"subject\":\"${esc_subject}\",\"body\":\"${esc_body}\"}"
    fi

    local func_url="${FUNC_APP_URL}/api/send?code=${func_key}"

    info "Sending test email to ${BOLD}${test_to}${RESET}..."
    echo ""

    local response=""
    local http_code=""
    response=$(curl -s -w "\n%{http_code}" -X POST "$func_url" \
        -H "Content-Type: application/json" \
        --connect-timeout 10 --max-time 120 \
        -d "$payload" 2>/dev/null)

    http_code=$(echo "$response" | tail -1)
    local resp_body
    resp_body=$(echo "$response" | sed '$d')

    # Validate http_code is numeric before comparison
    if echo "$http_code" | grep -qE '^[0-9]+$' && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        success "Test email sent successfully! (HTTP ${http_code})"
        echo "${DIM}  Response: ${resp_body}${RESET}"
    else
        error "Test email failed (HTTP ${http_code:-unknown})"
        echo "${DIM}  Response: ${resp_body}${RESET}"
        echo ""
        warn "Troubleshooting:"
        warn "  1. Check if the function is deployed: az functionapp show --name ${FUNC_APP_NAME} --resource-group ${RESOURCE_GROUP}"
        warn "  2. Check function logs: az functionapp log tail --name ${FUNC_APP_NAME} --resource-group ${RESOURCE_GROUP}"
        warn "  3. Verify ACS email domain is provisioned: $0 status"
        exit 1
    fi

    echo ""
    echo "${BOLD}${CYAN}  └────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

# ── Live Logs ──────────────────────────────────────────────────────────
stream_logs() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error "No deployment configuration found."
        info "Run '${BOLD}$0 deploy${RESET}' first."
        exit 1
    fi

    SUBSCRIPTION_ID=$(load_config "SUBSCRIPTION_ID" "")
    RESOURCE_GROUP=$(load_config "RESOURCE_GROUP" "")
    FUNC_APP_NAME=$(load_config "FUNC_APP_NAME" "")

    if [ -z "$FUNC_APP_NAME" ] || [ -z "$RESOURCE_GROUP" ]; then
        error "Incomplete configuration. Re-run '${BOLD}$0 deploy${RESET}'."
        exit 1
    fi

    if [ -n "$SUBSCRIPTION_ID" ]; then
        az account set --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1 || true
    fi

    info "Streaming logs for ${BOLD}${FUNC_APP_NAME}${RESET}... (Ctrl+C to stop)"
    echo ""
    az functionapp log tail \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RESOURCE_GROUP"
}

# ── Main ────────────────────────────────────────────────────────────────
main() {
    banner

    local command="${1:-help}"

    case "$command" in
        deploy)
            check_prerequisites
            deploy
            ;;
        teardown|destroy|delete)
            check_prerequisites
            teardown
            ;;
        status)
            status
            ;;
        test)
            check_prerequisites
            test_email
            ;;
        add-cred|add-credential)
            check_prerequisites
            add_credential
            ;;
        logs|log)
            stream_logs
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            error "Unknown command: ${command}"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
