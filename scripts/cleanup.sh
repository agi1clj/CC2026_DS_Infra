#!/usr/bin/env bash
# =============================================================================
# CC2026 P1 cleanup: removes what you created, one deliberate step at a time.
#
#   Step 1  terraform destroy of the application infrastructure (RG, ACR, App Service)
#   Step 2  (optional) GitHub Actions identity: role assignments + Entra application
#   Step 3  (optional) Terraform state storage (only after step 1 succeeded)
#
# Every step shows what will be deleted and asks for confirmation.
# Usage (from the root of the Infra repository, after `az login`):
#   ./scripts/cleanup.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly TF_DIR="$REPO_ROOT/terraform/environments/dev"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

# confirm "Question": returns 0 only when the user types "yes".
confirm() {
  local answer
  read -r -p "$1 Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]]
}

# Reads `name = "value"` from a generated .hcl/.tfvars file.
hcl_value() {
  sed -n "s/^$2[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$1"
}

# True only when the state provably tracks no resources. Any other error (e.g. no access
# to the state blob) counts as "not empty", so nothing is ever deleted by mistake.
state_is_empty() {
  local output
  if output="$(cd "$TF_DIR" && terraform state list 2>&1)"; then
    [[ -z "$output" ]]
  else
    [[ "$output" == *"No state file was found"* ]]
  fi
}

load_settings() {
  [[ -f "$TF_DIR/backend.hcl" && -f "$TF_DIR/terraform.tfvars" ]] ||
    die "backend.hcl / terraform.tfvars not found in $TF_DIR. Run ./bootstrap/bootstrap.sh first (it reuses existing resources)."

  STATE_RESOURCE_GROUP="$(hcl_value "$TF_DIR/backend.hcl" resource_group_name)"
  STATE_STORAGE_ACCOUNT="$(hcl_value "$TF_DIR/backend.hcl" storage_account_name)"
  SUBSCRIPTION_ID="$(hcl_value "$TF_DIR/terraform.tfvars" subscription_id)"
  PROJECT_NAME="$(hcl_value "$TF_DIR/terraform.tfvars" project_name)"
  STUDENT_INITIALS="$(hcl_value "$TF_DIR/terraform.tfvars" student_initials)"
  ENTRA_APP_NAME="github-actions-$PROJECT_NAME-$STUDENT_INITIALS"

  az account show --output none 2>/dev/null || die "Not logged in to Azure. Run: az login"
  az account set --subscription "$SUBSCRIPTION_ID"
  info "Subscription: $(az account show --query name --output tsv) ($SUBSCRIPTION_ID)"
}

# ----------------------------------------------------------------------------- step 1

destroy_application_infrastructure() {
  info "Step 1: destroy the application infrastructure with Terraform"
  cd "$TF_DIR"
  terraform init -input=false -reconfigure -backend-config=backend.hcl >/dev/null

  APP_RESOURCE_GROUP="$(echo 'local.resource_group_name' | terraform console | tr -d '"')"

  if state_is_empty; then
    ok "Terraform state is empty: nothing to destroy"
    return
  fi

  # Show exactly what will be deleted before asking.
  terraform plan -destroy -input=false -out=destroy.tfplan
  echo
  warn "This deletes every resource listed above, including resource group $APP_RESOURCE_GROUP."
  if ! confirm "Destroy the application infrastructure?"; then
    rm -f destroy.tfplan
    die "Cancelled. Nothing was deleted."
  fi

  if ! terraform apply -input=false destroy.tfplan; then
    rm -f destroy.tfplan
    die "terraform destroy failed. The state storage was NOT touched. Fix the error and run this script again."
  fi
  rm -f destroy.tfplan

  if [[ "$(az group exists --name "$APP_RESOURCE_GROUP")" == "true" ]]; then
    die "Resource group $APP_RESOURCE_GROUP still exists. Check it in the Azure portal before continuing."
  fi
  ok "Application infrastructure destroyed (resource group $APP_RESOURCE_GROUP is gone)"
}

# ----------------------------------------------------------------------------- step 2

remove_github_identity() {
  info "Step 2 (optional): remove the GitHub Actions identity"
  local client_id
  client_id="$(az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].appId" --output tsv)"
  if [[ -z "$client_id" ]]; then
    ok "No application named $ENTRA_APP_NAME (instructor-managed identities are not touched)"
    return
  fi

  local sp_id
  sp_id="$(az ad sp show --id "$client_id" --query id --output tsv 2>/dev/null || true)"
  if [[ -n "$sp_id" ]]; then
    echo "Role assignments of $ENTRA_APP_NAME:"
    az role assignment list --assignee "$sp_id" --all --query "[].{role:roleDefinitionName, scope:scope}" --output table
  fi
  echo "Application: $ENTRA_APP_NAME ($client_id)"

  if ! confirm "Delete these role assignments and the application? GitHub Actions will no longer be able to sign in to Azure."; then
    ok "Skipped"
    return
  fi

  if [[ -n "$sp_id" ]]; then
    local assignment_ids
    assignment_ids="$(az role assignment list --assignee "$sp_id" --all --query "[].id" --output tsv)"
    if [[ -n "$assignment_ids" ]]; then
      # shellcheck disable=SC2086 # one ID per word is intended
      az role assignment delete --ids $assignment_ids --output none
    fi
    ok "Role assignments removed"
  fi
  az ad app delete --id "$client_id"
  ok "Application $ENTRA_APP_NAME deleted (its federated credentials are deleted with it)"
  warn "GitHub repository variables were not changed. Remove them in each repository's Settings > Variables if you want."
}

# ----------------------------------------------------------------------------- step 3

remove_state_storage() {
  info "Step 3 (optional): delete the Terraform state storage"
  if [[ "$(az group exists --name "$STATE_RESOURCE_GROUP")" != "true" ]]; then
    ok "Resource group $STATE_RESOURCE_GROUP does not exist"
    return
  fi

  # Never delete state that still tracks resources.
  if ! state_is_empty; then
    warn "The state still contains resources (or could not be read). Destroy them first (step 1); state storage was kept."
    return
  fi

  az resource list --resource-group "$STATE_RESOURCE_GROUP" --query "[].{name:name, type:type}" --output table
  if ! confirm "Delete resource group $STATE_RESOURCE_GROUP (storage account $STATE_STORAGE_ACCOUNT)?"; then
    ok "Skipped"
    return
  fi
  az group delete --name "$STATE_RESOURCE_GROUP" --yes
  rm -f "$TF_DIR/backend.hcl"
  rm -rf "$TF_DIR/.terraform"
  ok "State storage deleted. Run bootstrap.sh again if you want to redeploy."
}

main() {
  load_settings
  destroy_application_infrastructure
  echo
  remove_github_identity
  echo
  remove_state_storage
  echo
  info "Cleanup finished."
}

main "$@"
