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
}
