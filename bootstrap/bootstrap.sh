#!/usr/bin/env bash
# =============================================================================
# CC2026 P1 bootstrap: one-time Azure + GitHub setup.
#
# Creates (or reuses, when run again):
#   1. Terraform remote state: resource group, storage account, "tfstate" container
#   2. A Microsoft Entra application + service principal for GitHub Actions
#   3. GitHub OIDC federated credentials for the Apps and Infra repositories (main branch)
#   4. Azure role assignments for that service principal and for you
#   5. GitHub repository variables in both repositories
#   6. terraform/environments/dev/backend.hcl and terraform.tfvars, then `terraform init`
#
# Usage (from the root of the Infra repository):
#   az login
#   gh auth login
#   ./bootstrap/bootstrap.sh
#
# Every prompt can be pre-answered with an environment variable, e.g.
#   STUDENT_INITIALS=agi GITHUB_OWNER=my-user ./bootstrap/bootstrap.sh
#
# Instructor-assisted mode: if your tenant does not allow you to create app
# registrations or role assignments, ask your instructor for an application
# (client) ID and run:  AZURE_CLIENT_ID=<client-id> ./bootstrap/bootstrap.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly TF_DIR="$REPO_ROOT/terraform/environments/dev"

readonly GITHUB_OIDC_ISSUER="https://token.actions.githubusercontent.com"
readonly OIDC_AUDIENCE="api://AzureADTokenExchange"
readonly STATE_CONTAINER="tfstate"
# Built-in roles that Terraform (running as the GitHub identity) may assign to managed identities.
# Extension point: when a later project part needs a new role (e.g. "Storage Blob Data Reader"
# 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1 for P2), add its ID here and re-run this script.
readonly ASSIGNABLE_ROLE_IDS=(
  7f951dda-4ed3-4680-a7ca-43fe172d538d # AcrPull
)
# Extension point: add the namespace of every new Azure service (e.g. Microsoft.DataFactory).
readonly RESOURCE_PROVIDERS=(Microsoft.Storage Microsoft.ContainerRegistry Microsoft.Web Microsoft.ManagedIdentity)

# Steps that failed because of missing permissions; printed at the end.
MANUAL_STEPS=()

# ----------------------------------------------------------------------------- helpers

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

# ask VAR "Question" "default": uses $VAR if already set, otherwise prompts.
ask() {
  local var_name="$1" question="$2" default="${3:-}" answer
  if [[ -n "${!var_name:-}" ]]; then
    return
  fi
  read -r -p "$question${default:+ [$default]}: " answer
  printf -v "$var_name" '%s' "${answer:-$default}"
}

# Retries a command; used where Azure RBAC changes need a minute to propagate.
retry() {
  local attempts="$1" delay="$2"
  shift 2
  local i
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then
      return 0
    fi
    if ((i < attempts)); then
      warn "Attempt $i/$attempts failed, retrying in ${delay}s (role assignments can take a few minutes to propagate)..."
      sleep "$delay"
    fi
  done
  return 1
}

# Deterministic short hash used to make global names unique (same input -> same name).
short_hash() {
  local length="$1" input="$2"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha1sum | cut -c1-"$length"
  else
    printf '%s' "$input" | shasum -a 1 | cut -c1-"$length"
  fi
}

# ----------------------------------------------------------------------------- checks

check_dependencies() {
  info "Checking required tools"
  local tool
  for tool in az gh terraform git; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed. See README > Prerequisites."
  done
  ok "az, gh, terraform and git are installed"
}

check_logins() {
  info "Checking Azure and GitHub authentication"
  az account show --output none 2>/dev/null || die "Not logged in to Azure. Run: az login"
  gh auth status >/dev/null 2>&1 || die "Not logged in to GitHub. Run: gh auth login"
  ok "Azure CLI and GitHub CLI are authenticated"
}

# ----------------------------------------------------------------------------- inputs

select_subscription() {
  info "Selecting the Azure subscription"
  az account list --query "[?state=='Enabled'].{Name:name, SubscriptionId:id}" --output table
  local current
  current="$(az account show --query id --output tsv)"
  ask AZURE_SUBSCRIPTION_ID "Subscription ID to use" "$current"
  az account set --subscription "$AZURE_SUBSCRIPTION_ID" || die "Cannot select subscription $AZURE_SUBSCRIPTION_ID"
  AZURE_TENANT_ID="$(az account show --query tenantId --output tsv)"
  ok "Subscription $(az account show --query name --output tsv) ($AZURE_SUBSCRIPTION_ID)"
}

collect_inputs() {
  info "Project settings"
  ask GITHUB_OWNER "GitHub user or organization that owns both repositories" "$(gh api user --jq .login)"
  ask APPS_REPO "Apps repository name" "CC2026_LastName_FirstName_Apps"
  ask INFRA_REPO "Infra repository name" "CC2026_LastName_FirstName_Infra"
  ask STUDENT_INITIALS "Your initials (2-5 lowercase letters, used in all resource names)" ""
  ask AZURE_LOCATION "Azure region" "westeurope"

  PROJECT_NAME="${PROJECT_NAME:-cc2026}"
  APP_SERVICE_SKU="${APP_SERVICE_SKU:-B1}"
  ACR_SKU="${ACR_SKU:-Basic}"

  [[ "$STUDENT_INITIALS" =~ ^[a-z]{2,5}$ ]] || die "Initials must be 2-5 lowercase letters (got '$STUDENT_INITIALS')."
  az account list-locations --query "[?name=='$AZURE_LOCATION'] | [0].name" --output tsv | grep -qx "$AZURE_LOCATION" ||
    die "Unknown Azure region '$AZURE_LOCATION'. List regions with: az account list-locations -o table"

  local repo
  for repo in "$APPS_REPO" "$INFRA_REPO"; do
    gh repo view "$GITHUB_OWNER/$repo" --json name >/dev/null 2>&1 ||
      die "GitHub repository $GITHUB_OWNER/$repo not found (create it first, or check the name)."
  done

  # Names of the bootstrap resources (separate from the application resource group).
  STATE_RESOURCE_GROUP="rg-$PROJECT_NAME-$STUDENT_INITIALS-tfstate"
  STATE_STORAGE_ACCOUNT="sttf$PROJECT_NAME$STUDENT_INITIALS$(short_hash 6 "$AZURE_SUBSCRIPTION_ID-$STUDENT_INITIALS")"
  STATE_STORAGE_ACCOUNT="${STATE_STORAGE_ACCOUNT:0:24}"
  ENTRA_APP_NAME="github-actions-$PROJECT_NAME-$STUDENT_INITIALS"

  ok "Repositories: $GITHUB_OWNER/$APPS_REPO, $GITHUB_OWNER/$INFRA_REPO"
  ok "State storage: $STATE_RESOURCE_GROUP / $STATE_STORAGE_ACCOUNT / $STATE_CONTAINER"
}

check_permissions() {
  info "Checking your Azure permissions on the subscription"
  SIGNED_IN_USER_ID="$(az ad signed-in-user show --query id --output tsv 2>/dev/null || true)"
  [[ -n "$SIGNED_IN_USER_ID" ]] || die "Run this script as a user (az login), not as a service principal."

  local roles
  roles="$(az role assignment list --assignee "$SIGNED_IN_USER_ID" --include-inherited --include-groups \
    --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID" --query "[].roleDefinitionName" --output tsv 2>/dev/null || true)"

  if grep -qxE "Owner|User Access Administrator|Role Based Access Control Administrator" <<<"$roles"; then
    ok "You can create role assignments (found: $(tr '\n' ' ' <<<"$roles"))"
  else
    warn "You do not appear to be Owner/User Access Administrator on this subscription."
    warn "Role assignments will probably fail; the exact commands will be printed for your instructor."
  fi
}

# ----------------------------------------------------------------------------- Azure resources

register_resource_providers() {
  info "Registering Azure resource providers (needed once per subscription)"
  local provider state
  for provider in "${RESOURCE_PROVIDERS[@]}"; do
    state="$(az provider show --namespace "$provider" --query registrationState --output tsv 2>/dev/null || echo Unknown)"
    if [[ "$state" != "Registered" ]]; then
      az provider register --namespace "$provider" --wait --output none ||
        MANUAL_STEPS+=("az provider register --namespace $provider --subscription $AZURE_SUBSCRIPTION_ID")
    fi
    ok "$provider"
  done
}

create_state_storage() {
  info "Creating Terraform state storage"
  az group create --name "$STATE_RESOURCE_GROUP" --location "$AZURE_LOCATION" \
    --tags project="$PROJECT_NAME" owner="$STUDENT_INITIALS" purpose=terraform-state --output none
  ok "Resource group $STATE_RESOURCE_GROUP"

  if az storage account show --name "$STATE_STORAGE_ACCOUNT" --resource-group "$STATE_RESOURCE_GROUP" --output none 2>/dev/null; then
    ok "Storage account $STATE_STORAGE_ACCOUNT already exists"
  else
    # Shared-key access is disabled: state is accessed only with Entra ID + RBAC.
    az storage account create \
      --name "$STATE_STORAGE_ACCOUNT" \
      --resource-group "$STATE_RESOURCE_GROUP" \
      --location "$AZURE_LOCATION" \
      --sku Standard_LRS \
      --kind StorageV2 \
      --min-tls-version TLS1_2 \
      --https-only true \
      --allow-blob-public-access false \
      --allow-shared-key-access false \
      --tags project="$PROJECT_NAME" owner="$STUDENT_INITIALS" purpose=terraform-state \
      --output none
    ok "Storage account $STATE_STORAGE_ACCOUNT created"
  fi
  STATE_STORAGE_ID="$(az storage account show --name "$STATE_STORAGE_ACCOUNT" --resource-group "$STATE_RESOURCE_GROUP" --query id --output tsv)"

  # Versioning + soft delete let you recover an overwritten or deleted state file.
  az storage account blob-service-properties update \
    --account-name "$STATE_STORAGE_ACCOUNT" --resource-group "$STATE_RESOURCE_GROUP" \
    --enable-versioning true --enable-delete-retention true --delete-retention-days 7 --output none
  ok "Blob versioning and 7-day soft delete enabled"

  # You need data-plane access to create the container and to run Terraform locally.
  assign_role "$SIGNED_IN_USER_ID" User "Storage Blob Data Contributor" "$STATE_STORAGE_ID"

  if retry 20 30 az storage container create --name "$STATE_CONTAINER" \
    --account-name "$STATE_STORAGE_ACCOUNT" --auth-mode login --output none 2>/dev/null; then
    ok "Blob container $STATE_CONTAINER"
  else
    die "Could not create container '$STATE_CONTAINER'. Check that you have 'Storage Blob Data Contributor' on $STATE_STORAGE_ACCOUNT."
  fi
}

# assign_role <principal-object-id> <User|ServicePrincipal> <role> <scope> [condition]
# Idempotent: does nothing when the same assignment (and condition) already exists;
# replaces it when only the condition changed (e.g. a role was added to ASSIGNABLE_ROLE_IDS).
assign_role() {
  local principal_id="$1" principal_type="$2" role="$3" scope="$4" condition="${5:-}"
  local existing_id existing_condition
  existing_id="$(az role assignment list --assignee "$principal_id" --role "$role" --scope "$scope" --query "[0].id" --output tsv 2>/dev/null || true)"
  if [[ -n "$existing_id" ]]; then
    existing_condition="$(az role assignment list --assignee "$principal_id" --role "$role" --scope "$scope" --query "[0].condition" --output tsv 2>/dev/null || true)"
    if [[ "$existing_condition" == "$condition" ]]; then
      ok "$role already assigned on $(basename "$scope")"
      return
    fi
    az role assignment delete --ids "$existing_id" --output none
    info "Updating the condition of $role"
  fi

  local args=(--assignee-object-id "$principal_id" --assignee-principal-type "$principal_type" --role "$role" --scope "$scope" --output none)
  if [[ -n "$condition" ]]; then
    args+=(--condition "$condition" --condition-version "2.0")
  fi

  if az role assignment create "${args[@]}" 2>/dev/null; then
    ok "$role assigned on $(basename "$scope")"
  else
    warn "Could not assign '$role' (insufficient permissions?)"
    local command="az role assignment create --assignee-object-id $principal_id --assignee-principal-type $principal_type --role \"$role\" --scope $scope"
    [[ -z "$condition" ]] || command+=" --condition-version 2.0 --condition \"$condition\""
    MANUAL_STEPS+=("$command")
  fi
}

# ----------------------------------------------------------------------------- identity

create_github_identity() {
  info "Creating the Entra ID application used by GitHub Actions"
  if [[ -n "${AZURE_CLIENT_ID:-}" ]]; then
    az ad sp show --id "$AZURE_CLIENT_ID" --output none 2>/dev/null ||
      die "AZURE_CLIENT_ID=$AZURE_CLIENT_ID has no service principal in this tenant. Ask your instructor to check it."
    ok "Using the application provided by your instructor ($AZURE_CLIENT_ID)"
  else
    AZURE_CLIENT_ID="$(az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].appId" --output tsv)"
    if [[ -n "$AZURE_CLIENT_ID" ]]; then
      ok "Application $ENTRA_APP_NAME already exists ($AZURE_CLIENT_ID)"
    elif AZURE_CLIENT_ID="$(az ad app create --display-name "$ENTRA_APP_NAME" --query appId --output tsv 2>/dev/null)"; then
      ok "Application $ENTRA_APP_NAME created ($AZURE_CLIENT_ID)"
    else
      die "Your tenant does not allow you to create app registrations.
       Ask your instructor to create one (see README > 'Instructor-assisted setup'),
       then run: AZURE_CLIENT_ID=<client-id> ./bootstrap/bootstrap.sh"
    fi

    if ! az ad sp show --id "$AZURE_CLIENT_ID" --output none 2>/dev/null; then
      retry 5 10 az ad sp create --id "$AZURE_CLIENT_ID" --output none || die "Could not create the service principal."
    fi
    ok "Service principal exists"
  fi

  SP_OBJECT_ID="$(az ad sp show --id "$AZURE_CLIENT_ID" --query id --output tsv)"
}

# GitHub Actions jobs on the main branch of <repo> may sign in as the application.
# No secret is stored anywhere: Azure trusts the short-lived token GitHub issues.
add_federated_credential() {
  local name="$1" repo="$2"
  local subject="repo:$GITHUB_OWNER/$repo:ref:refs/heads/main"
  local current
  current="$(az ad app federated-credential list --id "$AZURE_CLIENT_ID" --query "[?name=='$name'] | [0].subject" --output tsv 2>/dev/null || true)"

  if [[ "$current" == "$subject" ]]; then
    ok "Federated credential $name ($subject) already exists"
    return
  fi
  if [[ -n "$current" ]]; then
    az ad app federated-credential delete --id "$AZURE_CLIENT_ID" --federated-credential-id "$name" --output none
  fi

  local parameters
  parameters="$(printf '{"name":"%s","issuer":"%s","subject":"%s","audiences":["%s"],"description":"GitHub Actions, main branch of %s"}' \
    "$name" "$GITHUB_OIDC_ISSUER" "$subject" "$OIDC_AUDIENCE" "$repo")"

  if az ad app federated-credential create --id "$AZURE_CLIENT_ID" --parameters "$parameters" --output none 2>/dev/null; then
    ok "Federated credential $name ($subject)"
  else
    warn "Could not add federated credential $name"
    MANUAL_STEPS+=("az ad app federated-credential create --id $AZURE_CLIENT_ID --parameters '$parameters'")
  fi
}

assign_github_roles() {
  info "Granting Azure roles to the GitHub Actions identity"
  local subscription_scope="/subscriptions/$AZURE_SUBSCRIPTION_ID"

  # Create the application resource group and its resources (Terraform, image deployments).
  assign_role "$SP_OBJECT_ID" ServicePrincipal "Contributor" "$subscription_scope"

  # Contributor cannot create role assignments. Terraform must grant AcrPull to the Web Apps'
  # identity, so the identity may create/delete role assignments, but ONLY for the roles
  # listed in ASSIGNABLE_ROLE_IDS (an ABAC condition on the role assignment).
  local role_ids
  role_ids="$(IFS=,; echo "${ASSIGNABLE_ROLE_IDS[*]}")"
  local condition="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$role_ids})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$role_ids}))"
  assign_role "$SP_OBJECT_ID" ServicePrincipal "Role Based Access Control Administrator" "$subscription_scope" "$condition"

  # Read and write the Terraform state blob with Entra ID (no storage keys).
  assign_role "$SP_OBJECT_ID" ServicePrincipal "Storage Blob Data Contributor" "$STATE_STORAGE_ID"
}

# ----------------------------------------------------------------------------- Terraform

write_terraform_files() {
  info "Writing Terraform configuration files (git-ignored)"
  cat >"$TF_DIR/backend.hcl" <<EOF
# Generated by bootstrap/bootstrap.sh. Used with: terraform init -backend-config=backend.hcl
resource_group_name  = "$STATE_RESOURCE_GROUP"
storage_account_name = "$STATE_STORAGE_ACCOUNT"
EOF
  cat >"$TF_DIR/terraform.tfvars" <<EOF
# Generated by bootstrap/bootstrap.sh. CI uses the same values from GitHub repository variables.
project_name     = "$PROJECT_NAME"
student_initials = "$STUDENT_INITIALS"
environment      = "dev"
location         = "$AZURE_LOCATION"
subscription_id  = "$AZURE_SUBSCRIPTION_ID"

app_service_sku = "$APP_SERVICE_SKU"
acr_sku         = "$ACR_SKU"
EOF
  ok "terraform/environments/dev/backend.hcl"
  ok "terraform/environments/dev/terraform.tfvars"
}

terraform_init() {
  info "Initializing Terraform with the remote state backend"
  (cd "$TF_DIR" && retry 20 30 terraform init -input=false -reconfigure -backend-config=backend.hcl >/dev/null) ||
    die "terraform init failed. Re-run this script in a few minutes (RBAC propagation) or see README > Common errors."
  ok "terraform init succeeded (state: $STATE_STORAGE_ACCOUNT/$STATE_CONTAINER/p1-dev.tfstate)"
}

# Resource names come from Terraform itself (locals.tf), so they are defined in one place.
read_resource_names() {
  info "Reading resource names from the Terraform configuration"
  local names
  names="$(cd "$TF_DIR" && echo 'join(" ", [local.resource_group_name, local.acr_name, local.backend_app_name, local.frontend_app_name])' |
    terraform console | tr -d '"')"
  read -r APP_RESOURCE_GROUP ACR_NAME BACKEND_WEBAPP_NAME FRONTEND_WEBAPP_NAME <<<"$names"
  [[ -n "$FRONTEND_WEBAPP_NAME" ]] || die "Could not read resource names from Terraform."
  ok "Resource group $APP_RESOURCE_GROUP, registry $ACR_NAME"
  ok "Web Apps $BACKEND_WEBAPP_NAME, $FRONTEND_WEBAPP_NAME"
}

# ----------------------------------------------------------------------------- GitHub

set_github_variable() {
  local repo="$1" name="$2" value="$3"
  gh variable set "$name" --repo "$GITHUB_OWNER/$repo" --body "$value" >/dev/null
}

configure_github_variables() {
  info "Setting GitHub repository variables (non-secret configuration)"
  local repo
  for repo in "$APPS_REPO" "$INFRA_REPO"; do
    set_github_variable "$repo" AZURE_CLIENT_ID "$AZURE_CLIENT_ID"
    set_github_variable "$repo" AZURE_TENANT_ID "$AZURE_TENANT_ID"
    set_github_variable "$repo" AZURE_SUBSCRIPTION_ID "$AZURE_SUBSCRIPTION_ID"
    set_github_variable "$repo" ACR_NAME "$ACR_NAME"
  done

  set_github_variable "$APPS_REPO" RESOURCE_GROUP "$APP_RESOURCE_GROUP"
  set_github_variable "$APPS_REPO" BACKEND_WEBAPP_NAME "$BACKEND_WEBAPP_NAME"
  set_github_variable "$APPS_REPO" FRONTEND_WEBAPP_NAME "$FRONTEND_WEBAPP_NAME"
  ok "$APPS_REPO: AZURE_*, ACR_NAME, RESOURCE_GROUP, BACKEND_WEBAPP_NAME, FRONTEND_WEBAPP_NAME"

  set_github_variable "$INFRA_REPO" PROJECT_NAME "$PROJECT_NAME"
  set_github_variable "$INFRA_REPO" STUDENT_INITIALS "$STUDENT_INITIALS"
  set_github_variable "$INFRA_REPO" AZURE_LOCATION "$AZURE_LOCATION"
  set_github_variable "$INFRA_REPO" APP_SERVICE_SKU "$APP_SERVICE_SKU"
  set_github_variable "$INFRA_REPO" ACR_SKU "$ACR_SKU"
  set_github_variable "$INFRA_REPO" TFSTATE_RESOURCE_GROUP "$STATE_RESOURCE_GROUP"
  set_github_variable "$INFRA_REPO" TFSTATE_STORAGE_ACCOUNT "$STATE_STORAGE_ACCOUNT"

  # First deployment creates only the registry. Never reset this once the Web Apps exist,
  # otherwise the next Terraform run would delete them.
  if gh variable get CREATE_WEB_APPS --repo "$GITHUB_OWNER/$INFRA_REPO" >/dev/null 2>&1; then
    ok "$INFRA_REPO: CREATE_WEB_APPS already set to '$(gh variable get CREATE_WEB_APPS --repo "$GITHUB_OWNER/$INFRA_REPO")' (unchanged)"
  else
    set_github_variable "$INFRA_REPO" CREATE_WEB_APPS false
    ok "$INFRA_REPO: CREATE_WEB_APPS=false (first stage: registry only)"
  fi
  ok "$INFRA_REPO: AZURE_*, ACR_NAME, PROJECT_NAME, STUDENT_INITIALS, AZURE_LOCATION, *_SKU, TFSTATE_*"
}

# ----------------------------------------------------------------------------- summary

print_summary() {
  if ((${#MANUAL_STEPS[@]} > 0)); then
    printf '\n\033[1;33mSome steps need someone with more Azure/Entra permissions (e.g. your instructor):\033[0m\n'
    printf '  %s\n' "${MANUAL_STEPS[@]}"
    printf '\nRe-run ./bootstrap/bootstrap.sh after they are done.\n'
    exit 2
  fi

  cat <<EOF

$(printf '\033[1;32m')Bootstrap complete.$(printf '\033[0m')

Next steps (details in README > "Initial deployment"):
  1. Infra repo  -> GitHub Actions -> "terraform" -> Run workflow   (creates resource group + ACR)
  2. Apps repo   -> push to main (or run "backend" and "frontend")  (pushes the first images)
  3. Infra repo  -> gh variable set CREATE_WEB_APPS --body true --repo $GITHUB_OWNER/$INFRA_REPO
                 -> run "terraform" again                            (creates App Service + Web Apps)
  4. Apps repo   -> run "backend" and "frontend" again               (deploys commit-tagged images)

Expected URLs after step 3:
  Frontend: https://$FRONTEND_WEBAPP_NAME.azurewebsites.net
  Backend:  https://$BACKEND_WEBAPP_NAME.azurewebsites.net/api/data
EOF
}

main() {
  check_dependencies
  check_logins
  select_subscription
  collect_inputs
  check_permissions
  register_resource_providers
  create_state_storage
  create_github_identity
  add_federated_credential "github-apps-main" "$APPS_REPO"
  add_federated_credential "github-infra-main" "$INFRA_REPO"
  assign_github_roles
  write_terraform_files
  terraform_init
  read_resource_names
  configure_github_variables
  print_summary
}

main "$@"
