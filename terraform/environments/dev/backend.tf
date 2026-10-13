# Remote state in Azure Blob Storage (created by bootstrap/bootstrap.sh, not by this
# configuration, to avoid a chicken-and-egg problem).
#
# The storage account details are supplied at init time ("partial configuration"):
#   local: terraform init -backend-config=backend.hcl   (file written by bootstrap.sh)
#   CI:    terraform init -backend-config=...           (from GitHub repository variables)
#
# use_azuread_auth: access the blob with Entra ID (RBAC), never with storage keys/SAS.
# Locking uses native blob leases; no extra lock service is required.
terraform {
  backend "azurerm" {
    container_name   = "tfstate"
    key              = "dev.tfstate"
    use_azuread_auth = true
  }
}
