# Azure Container Registry that stores the backend and frontend images.
# The admin user stays disabled: Web Apps pull with a managed identity and
# GitHub Actions pushes with its Entra ID (OIDC) identity.
resource "azurerm_container_registry" "main" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku
  admin_enabled       = false

  # Classic RBAC: AcrPull/AcrPush/Contributor apply to the whole registry.
  # (The ABAC mode would require repository-scoped role conditions instead.)
  role_assignment_mode = "LegacyRegistryPermissions"

  tags = var.tags
}
