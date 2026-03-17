#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║  workflowmail - Azure OIDC + ACS Email Deployment                  ║
# ║  Bash 3.2 compatible | ACS, Graph, or SMTP | GitHub → Azure → Email ║
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
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/.workflowmail.conf"
FUNCTION_DIR="${REPO_ROOT}/function"
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
    echo "${DIM}  Azure OIDC Email · ACS, Microsoft Graph, or SMTP${RESET}"
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
    echo "  ${DIM}settings${RESET}    Update security settings (recipients, rate limit, subject)"
    echo "  ${DIM}logs${RESET}        Stream live Function App logs"
    echo "  ${YELLOW}help${RESET}        Show this help message"
    echo ""
    echo "${BOLD}Architecture:${RESET}"
    echo "  ACS backend:   GitHub Action → OIDC → Azure → Function → Managed Identity → ACS Email"
    echo "  Graph backend:  GitHub Action → OIDC → Azure → Function → OAuth Token → Graph sendMail"
    echo "  SMTP backend:   GitHub Action → OIDC → Azure → Function → OAuth XOAUTH2 → SMTP"
    echo ""
    echo "${BOLD}What gets created:${RESET}"
    echo "  1. Resource Group (+ ACS resources when using ACS backend)"
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

    # GitHub CLI (optional — for auto-setting repo variables and secrets)
    if command -v gh >/dev/null 2>&1; then
        success "GitHub CLI (gh) found — can auto-set repo variables and secrets"
    else
        warn "GitHub CLI (gh) not found. Repo variables and secrets will need to be set manually."
        warn "Install: https://cli.github.com/"
    fi

    # Azure CLI communication extension (only needed for ACS backend)
    local configured_backend
    configured_backend=$(load_config "EMAIL_BACKEND" "acs")
    if [ "$configured_backend" = "acs" ] || [ ! -f "$CONFIG_FILE" ]; then
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
    fi

    # curl (needed for Graph device code flow)
    if command -v curl >/dev/null 2>&1; then
        success "curl found"
    else
        error "curl not found."
        missing=1
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

detect_github_repo() {
    local detected_org="" detected_repo=""

    # 1. Try gh CLI (most reliable when authenticated)
    if command -v gh >/dev/null 2>&1; then
        local gh_json
        gh_json=$(gh repo view --json owner,name 2>/dev/null || echo "")
        if [ -n "$gh_json" ]; then
            detected_org=$(echo "$gh_json" | jq -r '.owner.login // empty' 2>/dev/null)
            detected_repo=$(echo "$gh_json" | jq -r '.name // empty' 2>/dev/null)
        fi
    fi

    # 2. Try git remote origin
    if [ -z "$detected_org" ] || [ -z "$detected_repo" ]; then
        local remote_url
        remote_url=$(git remote get-url origin 2>/dev/null || echo "")
        if [ -n "$remote_url" ]; then
            local parsed=""
            case "$remote_url" in
                git@github.com:*)
                    # SSH: git@github.com:owner/repo.git
                    parsed="${remote_url#git@github.com:}"
                    ;;
                https://github.com/*)
                    # HTTPS: https://github.com/owner/repo.git
                    parsed="${remote_url#https://github.com/}"
                    ;;
                ssh://git@github.com/*)
                    # ssh:// URL: ssh://git@github.com/owner/repo.git
                    parsed="${remote_url#ssh://git@github.com/}"
                    ;;
            esac
            if [ -n "$parsed" ]; then
                # Strip trailing .git
                parsed="${parsed%.git}"
                # Strip trailing slash
                parsed="${parsed%/}"
                detected_org="${parsed%%/*}"
                detected_repo="${parsed#*/}"
                # Reject if parsing gave empty or multi-segment repo name
                if [ -z "$detected_org" ] || [ -z "$detected_repo" ] || echo "$detected_repo" | grep -q '/'; then
                    detected_org=""
                    detected_repo=""
                fi
            fi
        fi
    fi

    # 3. Fall back to saved config
    if [ -z "$detected_org" ]; then
        detected_org=$(load_config GITHUB_ORG "")
    fi
    if [ -z "$detected_repo" ]; then
        detected_repo=$(load_config GITHUB_REPO "")
    fi

    # Show detection result
    if [ -n "$detected_org" ] && [ -n "$detected_repo" ]; then
        info "Detected GitHub repository: ${BOLD}${detected_org}/${detected_repo}${RESET}"
    fi

    # 4. Prompt with detected values as defaults (or require manual entry)
    prompt_value "GitHub org/owner (e.g. myorg)" "GITHUB_ORG" "$detected_org"
    prompt_value "GitHub repo name (e.g. myrepo)" "GITHUB_REPO" "$detected_repo"
}

select_subscription() {
    local subs_json
    subs_json=$(az account list --query "[].{id:id, name:name, tenantId:tenantId, isDefault:isDefault}" -o json 2>/dev/null || echo "")

    if [ -z "$subs_json" ] || [ "$subs_json" = "[]" ] || [ "$subs_json" = "" ]; then
        warn "Could not list Azure subscriptions. Falling back to manual entry."
        local current_sub
        current_sub=$(az account show --query "id" -o tsv 2>/dev/null || echo "")
        prompt_value "Azure Subscription ID" "SUBSCRIPTION_ID" "$(load_config SUBSCRIPTION_ID "$current_sub")"
        local current_tenant
        current_tenant=$(az account show --query "tenantId" -o tsv 2>/dev/null || echo "")
        prompt_value "Azure Tenant ID" "TENANT_ID" "$(load_config TENANT_ID "$current_tenant")"
        SUBSCRIPTION_NAME=$(az account show --query "name" -o tsv 2>/dev/null || echo "")
        save_config "SUBSCRIPTION_NAME" "$SUBSCRIPTION_NAME"
        return
    fi

    local count
    count=$(echo "$subs_json" | jq 'length')

    # Auto-select if only one subscription
    if [ "$count" -eq 1 ]; then
        SUBSCRIPTION_ID=$(echo "$subs_json" | jq -r '.[0].id')
        TENANT_ID=$(echo "$subs_json" | jq -r '.[0].tenantId')
        local auto_name
        auto_name=$(echo "$subs_json" | jq -r '.[0].name')
        SUBSCRIPTION_NAME="$auto_name"
        save_config "SUBSCRIPTION_ID" "$SUBSCRIPTION_ID"
        save_config "TENANT_ID" "$TENANT_ID"
        save_config "SUBSCRIPTION_NAME" "$SUBSCRIPTION_NAME"
        info "Auto-selected subscription: ${BOLD}${auto_name}${RESET} (${SUBSCRIPTION_ID})"
        return
    fi

    # Determine pre-selected index
    local saved_sub
    saved_sub=$(load_config "SUBSCRIPTION_ID" "")
    local preselect=0
    local i=0
    while [ "$i" -lt "$count" ]; do
        local sub_id sub_default
        sub_id=$(echo "$subs_json" | jq -r ".[$i].id")
        sub_default=$(echo "$subs_json" | jq -r ".[$i].isDefault")

        if [ -n "$saved_sub" ] && [ "$sub_id" = "$saved_sub" ]; then
            preselect=$((i + 1))
            break
        fi
        if [ "$sub_default" = "true" ] && [ "$preselect" -eq 0 ]; then
            preselect=$((i + 1))
        fi
        i=$((i + 1))
    done
    if [ "$preselect" -eq 0 ]; then
        preselect=1
    fi

    # Display numbered list
    echo ""
    info "Available Azure subscriptions:"
    echo ""
    i=0
    while [ "$i" -lt "$count" ]; do
        local sub_id sub_name sub_default tag=""
        sub_id=$(echo "$subs_json" | jq -r ".[$i].id")
        sub_name=$(echo "$subs_json" | jq -r ".[$i].name")
        sub_default=$(echo "$subs_json" | jq -r ".[$i].isDefault")

        if [ -n "$saved_sub" ] && [ "$sub_id" = "$saved_sub" ]; then
            tag=" ${GREEN}[saved]${RESET}"
        elif [ "$sub_default" = "true" ]; then
            tag=" ${YELLOW}*default${RESET}"
        fi

        local num=$((i + 1))
        echo "    ${BOLD}${num})${RESET} ${sub_name} (${DIM}${sub_id}${RESET})${tag}"
        i=$((i + 1))
    done
    echo ""

    # Prompt for selection
    local selection=""
    while true; do
        prompt "Select subscription [${YELLOW}${preselect}${RESET}]: "
        read -r selection
        if [ -z "$selection" ]; then
            selection="$preselect"
        fi
        # Validate numeric input in range
        if echo "$selection" | grep -qE '^[0-9]+$' && [ "$selection" -ge 1 ] && [ "$selection" -le "$count" ]; then
            break
        fi
        error "Invalid selection. Enter a number between 1 and ${count}."
    done

    local idx=$((selection - 1))
    SUBSCRIPTION_ID=$(echo "$subs_json" | jq -r ".[$idx].id")
    TENANT_ID=$(echo "$subs_json" | jq -r ".[$idx].tenantId")
    local chosen_name
    chosen_name=$(echo "$subs_json" | jq -r ".[$idx].name")

    SUBSCRIPTION_NAME="$chosen_name"
    save_config "SUBSCRIPTION_ID" "$SUBSCRIPTION_ID"
    save_config "TENANT_ID" "$TENANT_ID"
    save_config "SUBSCRIPTION_NAME" "$SUBSCRIPTION_NAME"
    success "Selected: ${BOLD}${chosen_name}${RESET} (${SUBSCRIPTION_ID})"
}

gather_config() {
    echo "${BOLD}${CYAN}  ┌─ Deployment Configuration ─────────────────────────────┐${RESET}"
    echo ""

    # Subscription + Tenant (interactive selector)
    select_subscription

    # Set subscription
    if ! az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null; then
        error "Could not set subscription '${SUBSCRIPTION_ID}'."
        error "Verify the ID and that you have access: az account list -o table"
        exit 1
    fi

    divider

    # GitHub OIDC setup (optional)
    echo ""
    info "GitHub OIDC lets GitHub Actions authenticate to Azure without secrets."
    info "Skip this if you'll call the function directly (e.g. from Drupal, scripts, curl)."
    local saved_oidc
    saved_oidc=$(load_config "SETUP_GITHUB_OIDC" "")
    local oidc_default="y"
    if [ "$saved_oidc" = "false" ]; then
        oidc_default="n"
    fi
    if prompt_yes_no "Set up GitHub Actions OIDC?" "$oidc_default"; then
        SETUP_GITHUB_OIDC="true"
    else
        SETUP_GITHUB_OIDC="false"
    fi
    save_config "SETUP_GITHUB_OIDC" "$SETUP_GITHUB_OIDC"

    if [ "$SETUP_GITHUB_OIDC" = "true" ]; then
        divider

        # GitHub
        detect_github_repo

        echo ""
        info "OIDC subject filter determines which workflows can authenticate."
        info "Azure requires an ${BOLD}exact match${RESET} — wildcards are NOT supported."
        echo "${DIM}    repo:<org>/<repo>:ref:refs/heads/main       — only main branch${RESET}"
        echo "${DIM}    repo:<org>/<repo>:environment:production    — only production env${RESET}"
        echo "${DIM}    repo:<org>/<repo>:pull_request              — only pull requests${RESET}"
        echo "${DIM}    Add more federated credentials later for additional branches/repos.${RESET}"
        prompt_value "OIDC subject filter" "OIDC_SUBJECT" \
            "$(load_config OIDC_SUBJECT "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main")"
    fi

    divider

    # Email backend choice
    echo ""
    info "Email backend determines how the function sends email."
    echo "${DIM}    acs   — Azure Communication Services (default, secretless via Managed Identity)${RESET}"
    echo "${DIM}    graph — Microsoft Graph API (send as a real O365 mailbox via OAuth)${RESET}"
    echo "${DIM}    smtp  — SMTP with OAuth (send as O365 mailbox via SMTP XOAUTH2)${RESET}"
    echo ""
    local backend_input=""
    prompt "Email backend [${YELLOW}$(load_config EMAIL_BACKEND "acs")${RESET}] (acs/graph/smtp): "
    read -r backend_input
    if [ -z "$backend_input" ]; then
        backend_input=$(load_config EMAIL_BACKEND "acs")
    fi
    # Validate
    while [ "$backend_input" != "acs" ] && [ "$backend_input" != "graph" ] && [ "$backend_input" != "smtp" ]; do
        error "Invalid backend '${backend_input}'. Choose 'acs', 'graph', or 'smtp'."
        prompt "Email backend (acs/graph/smtp): "
        read -r backend_input
    done
    EMAIL_BACKEND="$backend_input"
    save_config "EMAIL_BACKEND" "$EMAIL_BACKEND"

    # If graph or smtp, prompt for sender email (O365 mailbox UPN)
    if [ "$EMAIL_BACKEND" = "graph" ] || [ "$EMAIL_BACKEND" = "smtp" ]; then
        prompt_value "O365 sender email (the mailbox UPN, e.g. noreply@contoso.com)" \
            "GRAPH_SENDER" "$(load_config GRAPH_SENDER "")"
        SENDER_ADDRESS="$GRAPH_SENDER"
        save_config "SENDER_ADDRESS" "$SENDER_ADDRESS"
    fi

    if [ "$EMAIL_BACKEND" = "graph" ]; then
        # Graph authentication method
        echo ""
        info "Graph authentication method:"
        echo "${DIM}    1) Auto-detect — try own app registration first, fall back to Thunderbird.${RESET}"
        echo "${DIM}       Recommended for most tenants.${RESET}"
        echo "${DIM}    2) Own app registration — creates an Azure AD app with Mail.Send.${RESET}"
        echo "${DIM}       Use when you know your tenant allows consent on custom apps.${RESET}"
        echo "${DIM}    3) Thunderbird identity — uses Mozilla Thunderbird's pre-approved client ID.${RESET}"
        echo "${DIM}       Use when you know your tenant blocks custom app consent.${RESET}"
        echo ""

        local saved_method method_default="1" method_input=""
        saved_method=$(load_config "GRAPH_AUTH_METHOD" "")
        if [ "$saved_method" = "own_app" ]; then method_default="2"
        elif [ "$saved_method" = "thunderbird" ]; then method_default="3"; fi

        while true; do
            prompt "Graph auth method [${YELLOW}${method_default}${RESET}] (1/2/3): "
            read -r method_input
            if [ -z "$method_input" ]; then method_input="$method_default"; fi
            if [ "$method_input" = "1" ] || [ "$method_input" = "2" ] || [ "$method_input" = "3" ]; then break; fi
            error "Invalid choice. Enter 1, 2, or 3."
        done

        if [ "$method_input" = "3" ]; then
            GRAPH_AUTH_METHOD="thunderbird"
        elif [ "$method_input" = "2" ]; then
            GRAPH_AUTH_METHOD="own_app"
        else
            GRAPH_AUTH_METHOD="auto"
        fi
        save_config "GRAPH_AUTH_METHOD" "$GRAPH_AUTH_METHOD"
    elif [ "$EMAIL_BACKEND" = "smtp" ]; then
        # SMTP authentication method
        echo ""
        info "SMTP authentication method:"
        echo "${DIM}    1) Thunderbird identity — uses Mozilla Thunderbird's pre-approved client ID.${RESET}"
        echo "${DIM}       Recommended: SMTP.Send is typically pre-approved for Thunderbird.${RESET}"
        echo "${DIM}    2) Own app registration — creates an Azure AD app with SMTP.Send.${RESET}"
        echo "${DIM}       Use when you have a custom app that supports SMTP.Send.${RESET}"
        echo ""

        local saved_smtp_method smtp_method_default="1" smtp_method_input=""
        saved_smtp_method=$(load_config "GRAPH_AUTH_METHOD" "")
        if [ "$saved_smtp_method" = "own_app" ]; then smtp_method_default="2"; fi

        while true; do
            prompt "SMTP auth method [${YELLOW}${smtp_method_default}${RESET}] (1/2): "
            read -r smtp_method_input
            if [ -z "$smtp_method_input" ]; then smtp_method_input="$smtp_method_default"; fi
            if [ "$smtp_method_input" = "1" ] || [ "$smtp_method_input" = "2" ]; then break; fi
            error "Invalid choice. Enter 1 or 2."
        done

        if [ "$smtp_method_input" = "2" ]; then
            GRAPH_AUTH_METHOD="own_app"
        else
            GRAPH_AUTH_METHOD="thunderbird"
        fi
        save_config "GRAPH_AUTH_METHOD" "$GRAPH_AUTH_METHOD"
    fi

    divider

    # Derive slug from subscription name for defaults
    local sub_slug
    sub_slug=$(echo "$SUBSCRIPTION_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')

    prompt_value "Azure region" "LOCATION" "$(load_config LOCATION "eastus")"

    divider

    # Individual resource names (defaults from subscription slug)
    prompt_value "Resource group name" "RESOURCE_GROUP" \
        "$(load_config RESOURCE_GROUP "${sub_slug}-rg")"

    prompt_value "Function App name" "FUNC_APP_NAME" \
        "$(load_config FUNC_APP_NAME "${sub_slug}-func")"

    # Storage: alphanumeric only, max 24 chars
    local default_storage
    default_storage=$(echo "${sub_slug}store" | tr -cd 'a-z0-9' | cut -c1-24)
    prompt_value "Storage account name (alphanumeric, max 24 chars)" "STORAGE_ACCOUNT" \
        "$(load_config STORAGE_ACCOUNT "$default_storage")"

    # Sanitize storage account (enforce alphanumeric + length limit)
    STORAGE_ACCOUNT=$(echo "$STORAGE_ACCOUNT" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-24)
    save_config "STORAGE_ACCOUNT" "$STORAGE_ACCOUNT"

    # App registration name (only when needed)
    if [ "$SETUP_GITHUB_OIDC" = "true" ]; then
        prompt_value "App Registration name" "APP_REG_NAME" \
            "$(load_config APP_REG_NAME "${sub_slug}-github-oidc")"
    elif { [ "$EMAIL_BACKEND" = "graph" ] || [ "$EMAIL_BACKEND" = "smtp" ]; } && [ "${GRAPH_AUTH_METHOD:-auto}" != "thunderbird" ]; then
        prompt_value "App Registration name" "APP_REG_NAME" \
            "$(load_config APP_REG_NAME "${sub_slug}-graph-app")"
    fi

    # ACS resources (only for ACS backend)
    if [ "$EMAIL_BACKEND" = "acs" ]; then
        prompt_value "ACS resource name" "ACS_NAME" \
            "$(load_config ACS_NAME "${sub_slug}-acs")"
        prompt_value "Email Service name" "EMAIL_SERVICE_NAME" \
            "$(load_config EMAIL_SERVICE_NAME "${sub_slug}-email")"
    fi

    echo ""
    info "Resource names that will be created:"
    echo "${DIM}    Resource Group:    ${BOLD}${RESOURCE_GROUP}${RESET}"
    if [ "$EMAIL_BACKEND" = "acs" ]; then
        echo "${DIM}    ACS:               ${BOLD}${ACS_NAME}${RESET}"
        echo "${DIM}    Email Service:     ${BOLD}${EMAIL_SERVICE_NAME}${RESET}"
    elif [ "$EMAIL_BACKEND" = "graph" ]; then
        echo "${DIM}    Email Backend:     ${BOLD}graph (Microsoft Graph API)${RESET}"
        echo "${DIM}    Graph Sender:      ${BOLD}${GRAPH_SENDER}${RESET}"
        if [ "${GRAPH_AUTH_METHOD:-auto}" = "thunderbird" ]; then
            echo "${DIM}    Graph Auth:        ${BOLD}Thunderbird identity (Mozilla client ID)${RESET}"
        elif [ "${GRAPH_AUTH_METHOD:-auto}" = "own_app" ]; then
            echo "${DIM}    Graph Auth:        ${BOLD}Own app registration${RESET}"
        else
            echo "${DIM}    Graph Auth:        ${BOLD}Auto-detect (try own app, fall back to Thunderbird)${RESET}"
        fi
    elif [ "$EMAIL_BACKEND" = "smtp" ]; then
        echo "${DIM}    Email Backend:     ${BOLD}smtp (SMTP with OAuth XOAUTH2)${RESET}"
        echo "${DIM}    SMTP Sender:       ${BOLD}${GRAPH_SENDER}${RESET}"
        if [ "${GRAPH_AUTH_METHOD:-thunderbird}" = "thunderbird" ]; then
            echo "${DIM}    SMTP Auth:         ${BOLD}Thunderbird identity (Mozilla client ID)${RESET}"
        else
            echo "${DIM}    SMTP Auth:         ${BOLD}Own app registration${RESET}"
        fi
    fi
    echo "${DIM}    Function App:      ${BOLD}${FUNC_APP_NAME}${RESET}"
    echo "${DIM}    Storage Account:   ${BOLD}${STORAGE_ACCOUNT}${RESET}"
    if [ -n "${APP_REG_NAME:-}" ]; then
        echo "${DIM}    App Registration:  ${BOLD}${APP_REG_NAME}${RESET}"
    fi
    if [ "$SETUP_GITHUB_OIDC" = "true" ]; then
        echo "${DIM}    GitHub OIDC:       ${BOLD}enabled${RESET}"
    else
        echo "${DIM}    GitHub OIDC:       ${BOLD}disabled (direct function key access)${RESET}"
    fi
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
            warn "Choose a different name or the deploy may fail if it's not yours."
            name_ok=0
        fi
    fi

    # Check function app name availability via a quick DNS probe
    local func_check
    func_check=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://${FUNC_APP_NAME}.azurewebsites.net" 2>/dev/null || true)
    if [ -n "$func_check" ] && [ "$func_check" != "000" ] && [ "$func_check" != "404" ]; then
        warn "Function App name '${FUNC_APP_NAME}' may already be in use (got HTTP ${func_check})."
        warn "Choose a different name if this is not your existing deployment."
        name_ok=0
    fi

    if [ "$name_ok" -eq 0 ]; then
        echo ""
        if ! prompt_yes_no "Name conflicts detected. Continue anyway?" "n"; then
            info "Deployment cancelled. Change the resource names and try again."
            exit 0
        fi
    fi

    divider

    # ── Security settings (optional) ─────────────────────────────────
    echo ""
    info "Security settings restrict who can send email through this function."
    info "All are optional — leave empty to keep unrestricted."
    echo ""

    prompt_value "Allowed recipients (comma-separated, empty = unrestricted)" \
        "ALLOWED_RECIPIENTS" "$(load_config ALLOWED_RECIPIENTS "")"

    prompt_value "Rate limit per minute (default 10, 0 = disabled)" \
        "RATE_LIMIT_PER_MINUTE" "$(load_config RATE_LIMIT_PER_MINUTE "10")"

    echo "${DIM}    Example: ^(SUBSCRIBE|SIGNOFF)\\s+.+${RESET}"
    prompt_value "Subject pattern regex (empty = unrestricted)" \
        "SUBJECT_PATTERN" "$(load_config SUBJECT_PATTERN "")"

    echo "${BOLD}${CYAN}  └────────────────────────────────────────────────────────┘${RESET}"
    echo ""

    if ! prompt_yes_no "Proceed with deployment?"; then
        info "Deployment cancelled."
        exit 0
    fi
    echo ""
}

# ── Deploy Steps ────────────────────────────────────────────────────────

ensure_providers() {
    # Determine which resource providers are needed for this deployment
    local required_providers="Microsoft.Storage Microsoft.Web"
    if [ "$EMAIL_BACKEND" = "acs" ]; then
        required_providers="$required_providers Microsoft.Communication"
    fi

    step "Checking Azure resource provider registrations..."
    local providers_registered=""
    local needs_wait=false
    for ns in $required_providers; do
        local state
        state=$(az provider show -n "$ns" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
        if [ "$state" = "Registered" ]; then
            success "  ${ns} — registered"
        else
            info "  ${ns} — ${state}, registering..."
            az provider register --namespace "$ns" --output none 2>/dev/null || true
            providers_registered="${providers_registered:+$providers_registered,}$ns"
            needs_wait=true
        fi
    done

    if [ "$needs_wait" = true ]; then
        info "Waiting for provider registration to complete..."
        local attempts=0
        while [ "$attempts" -lt 24 ]; do
            local all_ready=true
            for ns in $required_providers; do
                local state
                state=$(az provider show -n "$ns" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
                if [ "$state" != "Registered" ]; then
                    all_ready=false
                    break
                fi
            done
            if [ "$all_ready" = true ]; then break; fi
            attempts=$((attempts + 1))
            echo -n "."
            sleep 10
        done
        echo ""

        if [ "$attempts" -ge 24 ]; then
            error "Provider registration timed out. Check status with:"
            error "  az provider show -n <namespace> --query registrationState"
            exit 1
        fi
        success "All resource providers registered."
    fi

    # Track which providers we registered (so teardown can offer to unregister)
    if [ -n "$providers_registered" ]; then
        local existing
        existing=$(load_config "REGISTERED_PROVIDERS" "")
        if [ -n "$existing" ]; then
            providers_registered="${existing},${providers_registered}"
        fi
        # Deduplicate
        providers_registered=$(echo "$providers_registered" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
        save_config "REGISTERED_PROVIDERS" "$providers_registered"
    fi
}

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
        error "Check the Azure portal for details, then re-run './scripts/deploy.sh deploy'."
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
                warn "It may still be provisioning. Re-run './scripts/deploy.sh status' later."
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

deploy_graph_oauth() {
    local THUNDERBIRD_CLIENT_ID="9e5f94bc-e8a4-4e73-b8be-63364c29d753"
    local graph_client_id=""
    local effective_method="${GRAPH_AUTH_METHOD:-auto}"

    if [ "$effective_method" = "thunderbird" ]; then
        info "Using Thunderbird identity for Graph authentication."
        graph_client_id="$THUNDERBIRD_CLIENT_ID"
    else
        # own_app or auto — try adding permissions to the custom app registration
        step "Configuring Graph API permissions on App Registration..."

        # Add delegated Mail.Send (e383f46e...) and offline_access (7427e0e9...) permissions
        local perm_ok=true
        az ad app permission add --id "$APP_OBJECT_ID" \
            --api "00000003-0000-0000-c000-000000000000" \
            --api-permissions "e383f46e-2787-4529-855e-0e479a3ffac0=Scope" \
                "7427e0e9-2fba-42fe-b0c0-848c9e6a8182=Scope" \
            --output none 2>/dev/null || perm_ok=false

        if [ "$perm_ok" = true ]; then
            success "Delegated Mail.Send + offline_access permissions added."
        elif [ "$effective_method" = "auto" ]; then
            # Auto mode: silently fall back to Thunderbird
            warn "Could not add Mail.Send permission — tenant may restrict custom app consent."
            info "Auto-detected: falling back to Thunderbird identity."
            GRAPH_AUTH_METHOD="thunderbird"
            save_config "GRAPH_AUTH_METHOD" "thunderbird"
            graph_client_id="$THUNDERBIRD_CLIENT_ID"
        else
            # own_app mode: interactive fallback
            warn "Could not add Mail.Send permission to the app registration."
            warn "Your tenant may restrict users from granting this permission."
            echo ""
            info "Options:"
            echo "  ${BOLD}1)${RESET} Switch to Thunderbird identity (uses pre-approved client ID)"
            echo "  ${BOLD}2)${RESET} Retry (after admin grants the permission)"
            echo "  ${BOLD}3)${RESET} Cancel Graph setup"
            echo ""
            local fallback=""
            while true; do
                prompt "Choice [${YELLOW}1${RESET}]: "
                read -r fallback
                if [ -z "$fallback" ]; then fallback="1"; fi
                case "$fallback" in 1|2|3) break ;; esac
                error "Enter 1, 2, or 3."
            done

            case "$fallback" in
                1)  info "Switching to Thunderbird identity."
                    GRAPH_AUTH_METHOD="thunderbird"
                    save_config "GRAPH_AUTH_METHOD" "thunderbird"
                    graph_client_id="$THUNDERBIRD_CLIENT_ID"
                    ;;
                2)  info "Retrying..."
                    if ! az ad app permission add --id "$APP_OBJECT_ID" \
                        --api "00000003-0000-0000-c000-000000000000" \
                        --api-permissions "e383f46e-2787-4529-855e-0e479a3ffac0=Scope" \
                            "7427e0e9-2fba-42fe-b0c0-848c9e6a8182=Scope" \
                        --output none 2>&1; then
                        error "Failed again. Ask your admin to grant Mail.Send on app ${APP_CLIENT_ID},"
                        error "or re-run deploy and choose Thunderbird identity."
                        exit 1
                    fi
                    success "Permissions added on retry."
                    graph_client_id="$APP_CLIENT_ID"
                    ;;
                *)  info "Graph setup cancelled."; exit 0 ;;
            esac
        fi

        # Enable public client flows (only when staying on own app path)
        if [ "${GRAPH_AUTH_METHOD:-auto}" != "thunderbird" ]; then
            if [ -z "$graph_client_id" ]; then graph_client_id="$APP_CLIENT_ID"; fi
            az ad app update --id "$APP_OBJECT_ID" --is-fallback-public-client true \
                --output none 2>/dev/null
            success "Public client flows enabled."
        fi
    fi

    # ── Device code OAuth flow (shared) ──────────────────────────────────
    step "Starting device code authentication flow..."
    info "You will authenticate as the O365 mailbox account (${BOLD}${GRAPH_SENDER}${RESET})."
    echo ""

    local device_response
    device_response=$(curl -s -X POST \
        "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/devicecode" \
        -d "client_id=${graph_client_id}" \
        -d "scope=https://graph.microsoft.com/Mail.Send offline_access")

    local user_code device_code interval verification_uri
    user_code=$(echo "$device_response" | jq -r '.user_code')
    device_code=$(echo "$device_response" | jq -r '.device_code')
    interval=$(echo "$device_response" | jq -r '.interval // 5')
    verification_uri=$(echo "$device_response" | jq -r '.verification_uri // "https://microsoft.com/devicelogin"')

    if [ -z "$user_code" ] || [ "$user_code" = "null" ]; then
        error "Device code flow failed. Response:"
        echo "$device_response" | jq . 2>/dev/null || echo "$device_response"
        exit 1
    fi

    echo ""
    echo "  ${BOLD}${CYAN}┌──────────────────────────────────────────────────┐${RESET}"
    echo "  ${BOLD}${CYAN}│${RESET}  Go to: ${BOLD}${verification_uri}${RESET}"
    echo "  ${BOLD}${CYAN}│${RESET}  Enter code: ${BOLD}${YELLOW}${user_code}${RESET}"
    echo "  ${BOLD}${CYAN}│${RESET}"
    echo "  ${BOLD}${CYAN}│${RESET}  ${DIM}Sign in as the sending account (${GRAPH_SENDER})${RESET}"
    echo "  ${BOLD}${CYAN}└──────────────────────────────────────────────────┘${RESET}"
    echo ""
    if [ "$effective_method" = "auto" ] && [ "${GRAPH_AUTH_METHOD:-auto}" != "thunderbird" ]; then
        info "Waiting for authentication (90s timeout — cancel consent to trigger Thunderbird fallback)..."
    else
        info "Waiting for authentication..."
    fi

    # Poll for token
    local token_response=""
    local poll_error=""
    local poll_start poll_elapsed
    poll_start=$(date +%s)
    while true; do
        sleep "$interval"

        # Auto mode: enforce 90s timeout — consent cancellation often doesn't produce
        # authorization_declined; Microsoft leaves the code pending until expiry (~15 min).
        poll_elapsed=$(( $(date +%s) - poll_start ))
        if [ "$effective_method" = "auto" ] && [ "${GRAPH_AUTH_METHOD:-auto}" != "thunderbird" ] \
           && [ "$poll_elapsed" -ge 90 ]; then
            echo ""
            warn "Device code timed out (${poll_elapsed}s) — consent was not completed."
            info "Auto-detected: falling back to Thunderbird identity."
            GRAPH_AUTH_METHOD="thunderbird"
            save_config "GRAPH_AUTH_METHOD" "thunderbird"
            deploy_graph_oauth
            return
        fi

        token_response=$(curl -s -X POST \
            "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
            -d "client_id=${graph_client_id}" \
            -d "device_code=${device_code}")

        poll_error=$(echo "$token_response" | jq -r '.error // empty')

        if [ -z "$poll_error" ]; then
            # Success — record the final method if auto resolved to own_app
            if [ "$effective_method" = "auto" ] && [ "${GRAPH_AUTH_METHOD:-auto}" != "thunderbird" ]; then
                GRAPH_AUTH_METHOD="own_app"
                save_config "GRAPH_AUTH_METHOD" "own_app"
                info "Auto-detected: own app registration works for this tenant."
            fi
            break
        elif [ "$poll_error" = "authorization_pending" ]; then
            echo -n "."
            continue
        elif [ "$poll_error" = "slow_down" ]; then
            interval=$((interval + 5))
            continue
        elif [ "$poll_error" = "authorization_declined" ] || \
             { [ "$poll_error" = "expired_token" ] && [ "$effective_method" = "auto" ]; }; then
            echo ""
            if [ "$effective_method" = "auto" ]; then
                # Auto mode: silently switch to Thunderbird and restart
                warn "Consent failed on custom app (${poll_error}) — tenant may block this permission."
                info "Auto-detected: falling back to Thunderbird identity."
                GRAPH_AUTH_METHOD="thunderbird"
                save_config "GRAPH_AUTH_METHOD" "thunderbird"
                deploy_graph_oauth
                return
            elif [ "$effective_method" = "own_app" ]; then
                # own_app mode: interactive fallback
                warn "Consent denied. Tenant policy may block custom app permissions."
                echo ""
                info "Options:"
                echo "  ${BOLD}1)${RESET} Switch to Thunderbird identity and retry"
                echo "  ${BOLD}2)${RESET} Retry with current app (after admin pre-approval)"
                echo "  ${BOLD}3)${RESET} Cancel"
                echo ""
                local decline_choice=""
                while true; do
                    prompt "Choice [${YELLOW}1${RESET}]: "
                    read -r decline_choice
                    if [ -z "$decline_choice" ]; then decline_choice="1"; fi
                    case "$decline_choice" in 1|2|3) break ;; esac
                    error "Enter 1, 2, or 3."
                done

                case "$decline_choice" in
                    1)  info "Switching to Thunderbird identity."
                        GRAPH_AUTH_METHOD="thunderbird"
                        save_config "GRAPH_AUTH_METHOD" "thunderbird"
                        deploy_graph_oauth
                        return
                        ;;
                    2)  info "Retrying with current app..."
                        deploy_graph_oauth
                        return
                        ;;
                    *)  error "Graph authentication cancelled."; exit 1 ;;
                esac
            else
                # thunderbird path failed — offer SMTP fallback
                local error_desc
                error_desc=$(echo "$token_response" | jq -r '.error_description // "Unknown error"')
                error "Authentication failed: ${poll_error}"
                error "${error_desc}"
                echo ""
                info "Mail.Send (Graph) consent may be blocked in this tenant."
                info "SMTP with OAuth uses the SMTP.Send scope, which is often pre-approved."
                echo ""
                info "Options:"
                echo "  ${BOLD}1)${RESET} Switch to SMTP backend (uses SMTP.Send scope via Thunderbird)"
                echo "  ${BOLD}2)${RESET} Cancel"
                echo ""
                local smtp_fallback=""
                while true; do
                    prompt "Choice [${YELLOW}1${RESET}]: "
                    read -r smtp_fallback
                    if [ -z "$smtp_fallback" ]; then smtp_fallback="1"; fi
                    case "$smtp_fallback" in 1|2) break ;; esac
                    error "Enter 1 or 2."
                done
                case "$smtp_fallback" in
                    1)  info "Switching to SMTP backend with Thunderbird identity."
                        EMAIL_BACKEND="smtp"
                        GRAPH_AUTH_METHOD="thunderbird"
                        save_config "EMAIL_BACKEND" "smtp"
                        save_config "GRAPH_AUTH_METHOD" "thunderbird"
                        deploy_smtp_oauth
                        return
                        ;;
                    *)  error "Graph authentication cancelled."; exit 1 ;;
                esac
            fi
        else
            # expired_token (non-auto) or other error
            echo ""
            local error_desc
            error_desc=$(echo "$token_response" | jq -r '.error_description // "Unknown error"')
            error "Authentication failed: ${poll_error}"
            error "${error_desc}"
            exit 1
        fi
    done
    echo ""

    local refresh_token access_token
    refresh_token=$(echo "$token_response" | jq -r '.refresh_token')
    access_token=$(echo "$token_response" | jq -r '.access_token')

    if [ -z "$refresh_token" ] || [ "$refresh_token" = "null" ]; then
        error "No refresh token in response. Ensure offline_access scope was consented."
        exit 1
    fi
    success "Authentication successful."

    # Verify authenticated user
    if [ -n "$access_token" ] && [ "$access_token" != "null" ]; then
        local me_response auth_user
        me_response=$(curl -s -H "Authorization: Bearer ${access_token}" \
            "https://graph.microsoft.com/v1.0/me?%24select=userPrincipalName,displayName")
        auth_user=$(echo "$me_response" | jq -r '.userPrincipalName // "unknown"')
        info "Authenticated as: ${BOLD}${auth_user}${RESET}"
    fi

    GRAPH_REFRESH_TOKEN="$refresh_token"
    save_config "GRAPH_REFRESH_TOKEN" "(stored in Function App settings)"
    save_config "GRAPH_CLIENT_ID" "$graph_client_id"
    save_config "GRAPH_TENANT_ID" "$TENANT_ID"

    # Store refresh token as Function App setting
    step "Storing refresh token in Function App settings..."
    az functionapp config appsettings set \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --settings \
            "GRAPH_REFRESH_TOKEN=${GRAPH_REFRESH_TOKEN}" \
            "GRAPH_CLIENT_ID=${graph_client_id}" \
            "GRAPH_TENANT_ID=${TENANT_ID}" \
        --output none 2>/dev/null
    success "Graph credentials stored in Function App settings (encrypted at rest)."
}

deploy_smtp_oauth() {
    local THUNDERBIRD_CLIENT_ID="9e5f94bc-e8a4-4e73-b8be-63364c29d753"
    local smtp_client_id=""
    local effective_method="${GRAPH_AUTH_METHOD:-thunderbird}"

    if [ "$effective_method" = "thunderbird" ]; then
        info "Using Thunderbird identity for SMTP authentication."
        smtp_client_id="$THUNDERBIRD_CLIENT_ID"
    else
        # own_app — add SMTP.Send permissions to the custom app registration
        step "Configuring SMTP.Send permissions on App Registration..."

        # Exchange Online resource: 00000002-0000-0ff1-ce00-000000000000
        # SMTP.Send delegated permission GUID: 258f6531-6087-4cc4-bb90-092c5fb3de4f
        local perm_ok=true
        az ad app permission add --id "$APP_OBJECT_ID" \
            --api "00000002-0000-0ff1-ce00-000000000000" \
            --api-permissions "258f6531-6087-4cc4-bb90-092c5fb3de4f=Scope" \
            --output none 2>/dev/null || perm_ok=false

        # Also add offline_access from Microsoft Graph
        az ad app permission add --id "$APP_OBJECT_ID" \
            --api "00000003-0000-0000-c000-000000000000" \
            --api-permissions "7427e0e9-2fba-42fe-b0c0-848c9e6a8182=Scope" \
            --output none 2>/dev/null || perm_ok=false

        if [ "$perm_ok" = true ]; then
            success "Delegated SMTP.Send + offline_access permissions added."
            smtp_client_id="$APP_CLIENT_ID"
        else
            warn "Could not add SMTP.Send permission — falling back to Thunderbird identity."
            GRAPH_AUTH_METHOD="thunderbird"
            save_config "GRAPH_AUTH_METHOD" "thunderbird"
            smtp_client_id="$THUNDERBIRD_CLIENT_ID"
        fi

        # Enable public client flows (only when staying on own app path)
        if [ "${GRAPH_AUTH_METHOD:-thunderbird}" != "thunderbird" ]; then
            az ad app update --id "$APP_OBJECT_ID" --is-fallback-public-client true \
                --output none 2>/dev/null
            success "Public client flows enabled."
        fi
    fi

    # ── Device code OAuth flow ────────────────────────────────────────────
    step "Starting device code authentication flow (SMTP.Send scope)..."
    info "You will authenticate as the O365 mailbox account (${BOLD}${GRAPH_SENDER}${RESET})."
    echo ""

    local device_response
    device_response=$(curl -s -X POST \
        "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/devicecode" \
        -d "client_id=${smtp_client_id}" \
        -d "scope=https://outlook.office365.com/SMTP.Send offline_access")

    local user_code device_code interval verification_uri
    user_code=$(echo "$device_response" | jq -r '.user_code')
    device_code=$(echo "$device_response" | jq -r '.device_code')
    interval=$(echo "$device_response" | jq -r '.interval // 5')
    verification_uri=$(echo "$device_response" | jq -r '.verification_uri // "https://microsoft.com/devicelogin"')

    if [ -z "$user_code" ] || [ "$user_code" = "null" ]; then
        error "Device code flow failed. Response:"
        echo "$device_response" | jq . 2>/dev/null || echo "$device_response"
        exit 1
    fi

    echo ""
    echo "  ${BOLD}${CYAN}┌──────────────────────────────────────────────────┐${RESET}"
    echo "  ${BOLD}${CYAN}│${RESET}  Go to: ${BOLD}${verification_uri}${RESET}"
    echo "  ${BOLD}${CYAN}│${RESET}  Enter code: ${BOLD}${YELLOW}${user_code}${RESET}"
    echo "  ${BOLD}${CYAN}│${RESET}"
    echo "  ${BOLD}${CYAN}│${RESET}  ${DIM}Sign in as the sending account (${GRAPH_SENDER})${RESET}"
    echo "  ${BOLD}${CYAN}└──────────────────────────────────────────────────┘${RESET}"
    echo ""
    info "Waiting for authentication..."

    # Poll for token
    local token_response=""
    local poll_error=""
    while true; do
        sleep "$interval"

        token_response=$(curl -s -X POST \
            "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
            -d "client_id=${smtp_client_id}" \
            -d "device_code=${device_code}")

        poll_error=$(echo "$token_response" | jq -r '.error // empty')

        if [ -z "$poll_error" ]; then
            break
        elif [ "$poll_error" = "authorization_pending" ]; then
            echo -n "."
            continue
        elif [ "$poll_error" = "slow_down" ]; then
            interval=$((interval + 5))
            continue
        else
            echo ""
            local error_desc
            error_desc=$(echo "$token_response" | jq -r '.error_description // "Unknown error"')
            error "Authentication failed: ${poll_error}"
            error "${error_desc}"
            exit 1
        fi
    done
    echo ""

    local refresh_token
    refresh_token=$(echo "$token_response" | jq -r '.refresh_token')

    if [ -z "$refresh_token" ] || [ "$refresh_token" = "null" ]; then
        error "No refresh token in response. Ensure offline_access scope was consented."
        exit 1
    fi
    success "SMTP authentication successful."

    GRAPH_REFRESH_TOKEN="$refresh_token"
    save_config "GRAPH_REFRESH_TOKEN" "(stored in Function App settings)"
    save_config "GRAPH_CLIENT_ID" "$smtp_client_id"
    save_config "GRAPH_TENANT_ID" "$TENANT_ID"

    # Store refresh token as Function App setting
    step "Storing refresh token in Function App settings..."
    az functionapp config appsettings set \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --settings \
            "GRAPH_REFRESH_TOKEN=${GRAPH_REFRESH_TOKEN}" \
            "GRAPH_CLIENT_ID=${smtp_client_id}" \
            "GRAPH_TENANT_ID=${TENANT_ID}" \
        --output none 2>/dev/null
    success "SMTP credentials stored in Function App settings (encrypted at rest)."
}

deploy_app_registration() {
    step "Creating App Registration: ${BOLD}${APP_REG_NAME}${RESET}..."

    # Check if it already exists
    local existing_app_id app_reg_err=""
    existing_app_id=$(az ad app list --display-name "$APP_REG_NAME" --query "[0].appId" -o tsv 2>&1) || {
        app_reg_err="$existing_app_id"
        existing_app_id=""
    }

    if [ -n "$existing_app_id" ] && [ "$existing_app_id" != "None" ]; then
        warn "App Registration '${APP_REG_NAME}' already exists (appId: ${existing_app_id}). Reusing."
        APP_CLIENT_ID="$existing_app_id"
        APP_OBJECT_ID=$(az ad app show --id "$APP_CLIENT_ID" --query "id" -o tsv 2>&1) || {
            error "Failed to look up App Registration details."
            error "$APP_OBJECT_ID"
            exit 1
        }
    else
        if [ -n "$app_reg_err" ]; then
            # The list command itself failed (network, auth, etc.) — not just "no results"
            warn "Could not check for existing app registrations."
            info "Attempting to create a new one..."
        fi
        local app_json
        app_json=$(az ad app create --display-name "$APP_REG_NAME" --output json 2>&1) || {
            error "Failed to create App Registration."
            error "$app_json"
            exit 1
        }
        APP_CLIENT_ID=$(echo "$app_json" | jq -r '.appId')
        APP_OBJECT_ID=$(echo "$app_json" | jq -r '.id')
        success "App Registration created."
    fi

    save_config "APP_CLIENT_ID" "$APP_CLIENT_ID"
    save_config "APP_OBJECT_ID" "$APP_OBJECT_ID"
    info "App (client) ID: ${BOLD}${APP_CLIENT_ID}${RESET}"

    # Service Principal + Federated Credential: only needed for OIDC
    if [ "$SETUP_GITHUB_OIDC" = "true" ]; then
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
    fi
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
    local sa_err=""
    if ! sa_err=$(az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku "Standard_LRS" \
        --output none 2>&1); then
        if az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
            warn "Storage account '${STORAGE_ACCOUNT}' already exists. Reusing."
        else
            error "Failed to create storage account '${STORAGE_ACCOUNT}'."
            [ -n "$sa_err" ] && error "$sa_err"
            exit 1
        fi
    else
        success "Storage account created."
    fi

    step "Creating Function App: ${BOLD}${FUNC_APP_NAME}${RESET}..."
    local fa_err=""
    if ! fa_err=$(az functionapp create \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --storage-account "$STORAGE_ACCOUNT" \
        --consumption-plan-location "$LOCATION" \
        --runtime python \
        --runtime-version "3.11" \
        --functions-version 4 \
        --os-type Linux \
        --output none 2>&1); then
        if az functionapp show --name "$FUNC_APP_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
            warn "Function App '${FUNC_APP_NAME}' already exists. Reusing."
        else
            error "Failed to create Function App '${FUNC_APP_NAME}'."
            [ -n "$fa_err" ] && error "$fa_err"
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

    # Backend-specific: MI-to-ACS role assignment (only for ACS backend)
    if [ "$EMAIL_BACKEND" = "acs" ]; then
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
    fi

    # Configure app settings (backend-specific)
    step "Configuring Function App settings..."
    local sec_allowed sec_rate sec_subject
    sec_allowed=$(load_config "ALLOWED_RECIPIENTS" "")
    sec_rate=$(load_config "RATE_LIMIT_PER_MINUTE" "10")
    sec_subject=$(load_config "SUBJECT_PATTERN" "")

    if [ "$EMAIL_BACKEND" = "graph" ]; then
        az functionapp config appsettings set \
            --name "$FUNC_APP_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --settings \
                "EMAIL_BACKEND=graph" \
                "SENDER_ADDRESS=${SENDER_ADDRESS}" \
                "ALLOWED_RECIPIENTS=${sec_allowed}" \
                "RATE_LIMIT_PER_MINUTE=${sec_rate}" \
                "SUBJECT_PATTERN=${sec_subject}" \
                "AzureWebJobsFeatureFlags=EnableWorkerIndexing" \
                "SCM_DO_BUILD_DURING_DEPLOYMENT=true" \
                "ENABLE_ORYX_BUILD=true" \
            --output none 2>/dev/null
    elif [ "$EMAIL_BACKEND" = "smtp" ]; then
        az functionapp config appsettings set \
            --name "$FUNC_APP_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --settings \
                "EMAIL_BACKEND=smtp" \
                "SENDER_ADDRESS=${SENDER_ADDRESS}" \
                "ALLOWED_RECIPIENTS=${sec_allowed}" \
                "RATE_LIMIT_PER_MINUTE=${sec_rate}" \
                "SUBJECT_PATTERN=${sec_subject}" \
                "AzureWebJobsFeatureFlags=EnableWorkerIndexing" \
                "SCM_DO_BUILD_DURING_DEPLOYMENT=true" \
                "ENABLE_ORYX_BUILD=true" \
            --output none 2>/dev/null
    else
        az functionapp config appsettings set \
            --name "$FUNC_APP_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --settings \
                "EMAIL_BACKEND=acs" \
                "ACS_ENDPOINT=${ACS_ENDPOINT}" \
                "SENDER_ADDRESS=${SENDER_ADDRESS}" \
                "ALLOWED_RECIPIENTS=${sec_allowed}" \
                "RATE_LIMIT_PER_MINUTE=${sec_rate}" \
                "SUBJECT_PATTERN=${sec_subject}" \
                "AzureWebJobsFeatureFlags=EnableWorkerIndexing" \
                "SCM_DO_BUILD_DURING_DEPLOYMENT=true" \
                "ENABLE_ORYX_BUILD=true" \
            --output none 2>/dev/null
    fi
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

# ── Function Key Retrieval ──────────────────────────────────────────────
# Sets global FUNC_KEY. Returns 0 on success, 1 on failure.
retrieve_function_key() {
    FUNC_KEY=""
    # Try function-level key first
    FUNC_KEY=$(az functionapp function keys list \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --function-name "send_email" \
        --query "default" -o tsv 2>/dev/null || true)

    # Fall back to host-level default key
    if [ -z "$FUNC_KEY" ] || [ "$FUNC_KEY" = "None" ]; then
        FUNC_KEY=$(az functionapp keys list \
            --name "$FUNC_APP_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --query "functionKeys.default" -o tsv 2>/dev/null || true)
    fi

    if [ -z "$FUNC_KEY" ] || [ "$FUNC_KEY" = "None" ]; then
        FUNC_KEY=""
        return 1
    fi
    return 0
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

    # Phase 2: Offer to store function key as a GitHub secret
    echo ""
    info "Storing the function key as a GitHub secret lets workflows call"
    info "the function directly without OIDC login."
    if [ "$EMAIL_BACKEND" = "graph" ] || [ "$EMAIL_BACKEND" = "smtp" ]; then
        info "  → With ${EMAIL_BACKEND} backend, workflows won't need Azure login at all."
    else
        info "  → With ACS backend, workflows can skip OIDC and call the function directly."
    fi
    echo ""

    if retrieve_function_key; then
        if prompt_yes_no "Store function key as GitHub Actions secret ${BOLD}AZURE_FUNC_KEY${RESET}?" "n"; then
            echo ""
            if gh secret set AZURE_FUNC_KEY --body "$FUNC_KEY" --repo "$gh_repo" 2>/dev/null; then
                success "  AZURE_FUNC_KEY secret set on ${gh_repo}"
                save_config "FUNC_KEY_IN_GITHUB" "true"
            else
                warn "  Failed to set AZURE_FUNC_KEY secret. Check gh auth status and repo permissions."
            fi
        fi
    else
        warn "Function key not yet available (function may still be deploying)."
        info "You can store it later with:"
        echo "${DIM}    FUNC_KEY=\$(az functionapp function keys list --name ${FUNC_APP_NAME} --resource-group ${RESOURCE_GROUP} --function-name send_email --query default -o tsv)${RESET}"
        echo "${DIM}    gh secret set AZURE_FUNC_KEY --body \"\$FUNC_KEY\" --repo ${gh_repo}${RESET}"
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
    if ! prompt_yes_no "Remove GitHub repository variables and secrets from ${BOLD}${gh_full}${RESET}?"; then
        info "Skipped. Remove them manually in GitHub → Settings → Variables/Secrets → Actions."
        return
    fi
    echo ""

    step "Removing GitHub repository variables and secrets from ${BOLD}${gh_full}${RESET}..."
    gh variable delete AZURE_CLIENT_ID --repo "$gh_full" 2>/dev/null || true
    gh variable delete AZURE_TENANT_ID --repo "$gh_full" 2>/dev/null || true
    gh variable delete AZURE_SUBSCRIPTION_ID --repo "$gh_full" 2>/dev/null || true
    gh variable delete AZURE_RG --repo "$gh_full" 2>/dev/null || true
    gh variable delete AZURE_FUNC_NAME --repo "$gh_full" 2>/dev/null || true
    gh secret delete AZURE_FUNC_KEY --repo "$gh_full" 2>/dev/null || true
    success "GitHub repository variables and secrets removed."
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

            # Offer function key secret on the target repo
            echo ""
            info "You can also store the function key so workflows skip OIDC login."
            if retrieve_function_key; then
                if prompt_yes_no "Store function key as secret ${BOLD}AZURE_FUNC_KEY${RESET} on ${BOLD}${target_repo}${RESET}?" "n"; then
                    echo ""
                    if gh secret set AZURE_FUNC_KEY --body "$FUNC_KEY" --repo "$target_repo" 2>/dev/null; then
                        success "  AZURE_FUNC_KEY secret set on ${target_repo}"
                    else
                        warn "  Failed to set AZURE_FUNC_KEY secret."
                    fi
                fi
            else
                warn "Function key not available. Store it later with:"
                echo "${DIM}    gh secret set AZURE_FUNC_KEY --body \"\$FUNC_KEY\" --repo ${target_repo}${RESET}"
            fi
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
    ensure_providers
    divider
    if [ "$EMAIL_BACKEND" = "acs" ]; then
        deploy_acs
        divider
    fi
    # App registration: needed for OIDC or Graph/SMTP OAuth (own_app or auto)
    if [ "$SETUP_GITHUB_OIDC" = "true" ] || { [ "$EMAIL_BACKEND" = "graph" ] && [ "${GRAPH_AUTH_METHOD:-auto}" != "thunderbird" ]; } || { [ "$EMAIL_BACKEND" = "smtp" ] && [ "${GRAPH_AUTH_METHOD:-thunderbird}" != "thunderbird" ]; }; then
        deploy_app_registration
        divider
    fi
    # Role assignments: only for OIDC (SP needs Contributor to fetch keys)
    if [ "$SETUP_GITHUB_OIDC" = "true" ]; then
        deploy_role_assignments
        divider
    fi
    deploy_function_app
    divider
    deploy_function_code
    divider
    # OAuth flow: graph or smtp
    if [ "$EMAIL_BACKEND" = "graph" ]; then
        deploy_graph_oauth
        divider
    elif [ "$EMAIL_BACKEND" = "smtp" ]; then
        deploy_smtp_oauth
        divider
    fi

    echo ""
    echo "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════════╗${RESET}"
    echo "${GREEN}${BOLD}  ║              Deployment Complete!                       ║${RESET}"
    echo "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if [ "$SETUP_GITHUB_OIDC" = "true" ]; then
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
    else
        echo "${BOLD}  Function URL:${RESET} https://${FUNC_APP_NAME}.azurewebsites.net/api/send"
        echo ""
        echo "${BOLD}  Retrieve your function key:${RESET}"
        echo "  ${DIM}az functionapp function keys list --name ${FUNC_APP_NAME} --resource-group ${RESOURCE_GROUP} --function-name send_email --query default -o tsv${RESET}"
        echo ""
        echo "${BOLD}  Call the function:${RESET}"
        echo "  ${DIM}curl -X POST \"https://${FUNC_APP_NAME}.azurewebsites.net/api/send?code=\$KEY\" \\${RESET}"
        echo "  ${DIM}  -H 'Content-Type: application/json' \\${RESET}"
        echo "  ${DIM}  -d '{\"to\":\"user@example.com\",\"subject\":\"Hello\",\"body\":\"World\"}'${RESET}"
    fi
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
    SETUP_GITHUB_OIDC=$(load_config "SETUP_GITHUB_OIDC" "true")
    EMAIL_BACKEND=$(load_config "EMAIL_BACKEND" "acs")

    echo "  This will ${RED}${BOLD}permanently delete${RESET} the following:"
    echo ""
    echo "  ${RED}▸${RESET} Resource Group:    ${BOLD}${RESOURCE_GROUP}${RESET}"
    echo "    ${DIM}(includes Function App, Storage, and any ACS/Email resources)${RESET}"
    local saved_graph_auth
    saved_graph_auth=$(load_config "GRAPH_AUTH_METHOD" "auto")
    if [ -n "$APP_CLIENT_ID" ]; then
        if [ "$SETUP_GITHUB_OIDC" = "true" ] || { [ "$EMAIL_BACKEND" = "graph" ] && [ "$saved_graph_auth" != "thunderbird" ]; } || { [ "$EMAIL_BACKEND" = "smtp" ] && [ "$saved_graph_auth" != "thunderbird" ]; }; then
            echo "  ${RED}▸${RESET} App Registration:  ${BOLD}${APP_CLIENT_ID}${RESET}"
            if [ "$SETUP_GITHUB_OIDC" = "true" ]; then
                echo "    ${DIM}(includes Service Principal, Federated Credentials)${RESET}"
            else
                echo "    ${DIM}(${EMAIL_BACKEND} OAuth app registration)${RESET}"
            fi
        else
            echo "  ${DIM}▸${RESET} App Registration:  ${DIM}none (Thunderbird identity)${RESET}"
        fi
    fi
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

    # Delete App Registration (OIDC or Graph/SMTP non-thunderbird — skip for Thunderbird-only/ACS without OIDC)
    if [ -n "$APP_OBJECT_ID" ] && { [ "$SETUP_GITHUB_OIDC" = "true" ] || { [ "$EMAIL_BACKEND" = "graph" ] && [ "$saved_graph_auth" != "thunderbird" ]; } || { [ "$EMAIL_BACKEND" = "smtp" ] && [ "$saved_graph_auth" != "thunderbird" ]; }; }; then
        step "Deleting App Registration..."
        az ad app delete --id "$APP_OBJECT_ID" --output none 2>/dev/null || warn "App Registration may not exist."
        success "App Registration deleted."
    fi

    # Unregister resource providers that we registered during deploy
    local registered_providers
    registered_providers=$(load_config "REGISTERED_PROVIDERS" "")
    if [ -n "$registered_providers" ]; then
        echo ""
        info "The following resource providers were registered during deploy:"
        echo "$registered_providers" | tr ',' '\n' | while read -r ns; do
            [ -n "$ns" ] && echo "    ${DIM}${ns}${RESET}"
        done
        echo ""
        if prompt_yes_no "Unregister these providers? (safe if no other resources use them)" "n"; then
            echo "$registered_providers" | tr ',' '\n' | while read -r ns; do
                if [ -n "$ns" ]; then
                    step "Unregistering ${ns}..."
                    az provider unregister --namespace "$ns" --output none 2>/dev/null || true
                fi
            done
            success "Provider unregistration initiated."
        else
            info "Skipped. Providers remain registered."
        fi
    fi

    # Remove GitHub repository variables (only when OIDC was set up)
    if [ "$SETUP_GITHUB_OIDC" = "true" ]; then
        remove_github_variables
    fi

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

# ── Update Settings ──────────────────────────────────────────────────────
update_settings() {
    echo "${BOLD}${CYAN}  ┌─ Update Security Settings ──────────────────────────────┐${RESET}"
    echo ""

    if [ ! -f "$CONFIG_FILE" ]; then
        error "No deployment configuration found."
        info "Run '${BOLD}$0 deploy${RESET}' first to create the base stack."
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

    info "Update security settings for ${BOLD}${FUNC_APP_NAME}${RESET}."
    info "Leave empty to keep unrestricted. No code redeploy needed."
    echo ""

    prompt_value "Allowed recipients (comma-separated, empty = unrestricted)" \
        "ALLOWED_RECIPIENTS" "$(load_config ALLOWED_RECIPIENTS "")"

    prompt_value "Rate limit per minute (default 10, 0 = disabled)" \
        "RATE_LIMIT_PER_MINUTE" "$(load_config RATE_LIMIT_PER_MINUTE "10")"

    echo "${DIM}    Example: ^(SUBSCRIBE|SIGNOFF)\\s+.+${RESET}"
    prompt_value "Subject pattern regex (empty = unrestricted)" \
        "SUBJECT_PATTERN" "$(load_config SUBJECT_PATTERN "")"

    echo ""
    step "Pushing security settings to ${BOLD}${FUNC_APP_NAME}${RESET}..."
    az functionapp config appsettings set \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --settings \
            "ALLOWED_RECIPIENTS=$(load_config ALLOWED_RECIPIENTS "")" \
            "RATE_LIMIT_PER_MINUTE=$(load_config RATE_LIMIT_PER_MINUTE "10")" \
            "SUBJECT_PATTERN=$(load_config SUBJECT_PATTERN "")" \
        --output none 2>/dev/null
    success "Security settings updated."

    echo ""
    echo "${BOLD}${CYAN}  └────────────────────────────────────────────────────────┘${RESET}"
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
    FUNC_APP_URL=$(load_config "FUNC_APP_URL" "")
    SENDER_ADDRESS=$(load_config "SENDER_ADDRESS" "")
    EMAIL_BACKEND=$(load_config "EMAIL_BACKEND" "acs")

    if [ -n "$SUBSCRIPTION_ID" ]; then
        az account set --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1 || true
    fi

    local ACS_ENDPOINT=""
    local SENDER_DOMAIN=""

    if [ "$EMAIL_BACKEND" = "acs" ]; then
        ACS_NAME=$(load_config "ACS_NAME" "")
        EMAIL_SERVICE_NAME=$(load_config "EMAIL_SERVICE_NAME" "")
        SENDER_DOMAIN=$(load_config "SENDER_DOMAIN" "")

        # Auto-refresh ACS endpoint if it was empty during initial deploy
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
    fi

    echo "  ${BOLD}Configuration:${RESET}"
    echo "    Email Backend:    ${BOLD}${EMAIL_BACKEND}${RESET}"
    if [ "$EMAIL_BACKEND" = "graph" ] || [ "$EMAIL_BACKEND" = "smtp" ]; then
        local graph_auth auth_label
        graph_auth=$(load_config "GRAPH_AUTH_METHOD" "auto")
        auth_label=$(echo "$EMAIL_BACKEND" | tr '[:lower:]' '[:upper:]')
        if [ "$graph_auth" = "thunderbird" ]; then
            echo "    ${auth_label} Auth:       Thunderbird identity"
        elif [ "$graph_auth" = "own_app" ]; then
            echo "    ${auth_label} Auth:       Own app registration"
        else
            echo "    ${auth_label} Auth:       Auto-detect"
        fi
    fi
    echo "    Subscription:     ${SUBSCRIPTION_ID}"
    echo "    Resource Group:   ${RESOURCE_GROUP}"
    echo "    App Client ID:    ${APP_CLIENT_ID}"
    echo "    Function App:     ${FUNC_APP_NAME}"
    echo "    Function URL:     ${FUNC_APP_URL}"
    echo "    Sender Address:   ${SENDER_ADDRESS}"
    if [ "$EMAIL_BACKEND" = "acs" ]; then
        echo "    ACS Resource:     ${ACS_NAME}"
        echo "    ACS Endpoint:     ${ACS_ENDPOINT:-${YELLOW}empty${RESET}}"
    fi
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

    # Backend-specific checks
    if [ "$EMAIL_BACKEND" = "acs" ]; then
        if [ "$SENDER_DOMAIN" = "pending" ] || [ -z "$SENDER_DOMAIN" ]; then
            echo "    Sender Domain:    ${YELLOW}pending${RESET}"
        else
            echo "    Sender Domain:    ${GREEN}${SENDER_DOMAIN}${RESET}"
        fi
    elif [ "$EMAIL_BACKEND" = "graph" ] || [ "$EMAIL_BACKEND" = "smtp" ]; then
        local has_token token_label
        has_token=$(load_config "GRAPH_REFRESH_TOKEN" "")
        token_label=$(echo "$EMAIL_BACKEND" | tr '[:lower:]' '[:upper:]')
        if [ -n "$has_token" ]; then
            echo "    ${token_label} Token:      ${GREEN}configured${RESET}"
        else
            echo "    ${token_label} Token:      ${RED}not configured${RESET}"
        fi
    fi

    # Security settings
    echo ""
    echo "  ${BOLD}Security:${RESET}"
    local sec_rcpt sec_rate sec_subj
    sec_rcpt=$(load_config "ALLOWED_RECIPIENTS" "")
    sec_rate=$(load_config "RATE_LIMIT_PER_MINUTE" "10")
    sec_subj=$(load_config "SUBJECT_PATTERN" "")
    if [ -n "$sec_rcpt" ]; then
        echo "    Allowed Recipients: ${BOLD}${sec_rcpt}${RESET}"
    else
        echo "    Allowed Recipients: ${DIM}unrestricted${RESET}"
    fi
    echo "    Rate Limit:         ${BOLD}${sec_rate}/min${RESET}"
    if [ -n "$sec_subj" ]; then
        echo "    Subject Pattern:    ${BOLD}${sec_subj}${RESET}"
    else
        echo "    Subject Pattern:    ${DIM}unrestricted${RESET}"
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

    if ! retrieve_function_key; then
        error "Could not retrieve function key."
        warn "The function may not be deployed yet. Run:"
        warn "  cd function && func azure functionapp publish ${FUNC_APP_NAME}"
        exit 1
    fi
    local func_key="$FUNC_KEY"
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
        update-settings|settings)
            check_prerequisites
            update_settings
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
