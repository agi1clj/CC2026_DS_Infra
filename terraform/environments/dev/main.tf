resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location

  tags = local.tags
}

module "container_registry" {
  source = "../../modules/container-registry"

  name                = local.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.acr_sku
  tags                = local.tags
}

locals {
  # The backend reads the gold files with its managed identity (DefaultAzureCredential).
  backend_app_settings = {
    STORAGE_ACCOUNT_URL = module.storage.primary_blob_endpoint
    GOLD_CONTAINER      = "gold"
  }
}

# Created only after the first images exist in ACR (see README, "Initial deployment").
module "app_service" {
  source = "../../modules/app-service"
  count  = var.create_web_apps ? 1 : 0

  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  service_plan_name               = local.service_plan_name
  sku_name                        = var.app_service_sku
  identity_name                   = local.identity_name
  backend_app_name                = local.backend_app_name
  frontend_app_name               = local.frontend_app_name
  container_registry_id           = module.container_registry.id
  container_registry_login_server = module.container_registry.login_server
  tags                            = local.tags

  backend_app_settings = local.backend_app_settings
}

# P2 data lake: bronze (raw), silver (clean Parquet), gold (JSON for the backend).
module "storage" {
  source = "../../modules/storage"

  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

module "notification" {
  source = "../../modules/notification"

  name                = local.logic_app_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  teams_webhook_url   = var.teams_webhook_url
  tags                = local.tags
}

module "data_factory" {
  source = "../../modules/data-factory"

  name                 = local.data_factory_name
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  storage_account_id   = module.storage.id
  storage_dfs_endpoint = module.storage.primary_dfs_endpoint
  notification_url     = module.notification.callback_url
  tags                 = local.tags
}

# Data Factory reads bronze and writes silver and gold with its own identity.
resource "azurerm_role_assignment" "data_factory_writes_lake" {
  scope                = module.storage.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.data_factory.identity_principal_id
  principal_type       = "ServicePrincipal"
}

# The backend reads gold only. Same count as the Web Apps: no Web Apps, no assignment.
resource "azurerm_role_assignment" "backend_reads_lake" {
  count = var.create_web_apps ? 1 : 0

  scope                = module.storage.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = module.app_service[0].identity_principal_id
  principal_type       = "ServicePrincipal"
}
