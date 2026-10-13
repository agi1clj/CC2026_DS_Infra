locals {
  registry_url = "https://${var.container_registry_login_server}"

  # The backend must allow the frontend origin (CORS) and the frontend must know the
  # backend URL. Referencing both default_hostname attributes would create a cycle, so
  # the frontend origin is derived from its name (classic *.azurewebsites.net host).
  # The check block at the end of this file verifies the assumption after apply.
  frontend_origin = "https://${var.frontend_app_name}.azurewebsites.net"

  # Settings required by the containers. Merged last, so callers cannot override them
  # through backend_app_settings / frontend_app_settings.
  backend_required_settings = {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    WEBSITES_PORT                       = "8000"
    CORS_ORIGINS                        = local.frontend_origin
    # Lets Azure SDKs (DefaultAzureCredential) pick the user-assigned identity, e.g. for Blob Storage in P2.
    AZURE_CLIENT_ID = azurerm_user_assigned_identity.web_apps.client_id
  }
  frontend_required_settings = {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    WEBSITES_PORT                       = "8080"
    API_BASE_URL                        = "https://${azurerm_linux_web_app.backend.default_hostname}"
  }
}

# One Linux plan hosts both Web Apps to keep the cost to a single instance.
resource "azurerm_service_plan" "main" {
  name                = var.service_plan_name
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.sku_name

  tags = var.tags
}

# Identity of the Web Apps. Today it is used to pull images from ACR; later project parts
# can grant it more roles (e.g. read Blob Storage) via the identity_principal_id output. A user-assigned identity is
# used (instead of system-assigned) so the AcrPull role exists *before* the Web Apps
# start for the first time; otherwise the first image pull fails.
resource "azurerm_user_assigned_identity" "web_apps" {
  name                = var.identity_name
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = var.container_registry_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.web_apps.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_linux_web_app" "backend" {
  name                = var.backend_app_name
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.main.id

  https_only                                     = true
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  app_settings = merge(var.backend_app_settings, local.backend_required_settings)

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.web_apps.id]
  }

  site_config {
    always_on                                     = true
    ftps_state                                    = "Disabled"
    minimum_tls_version                           = "1.2"
    http2_enabled                                 = true
    health_check_path                             = "/health"
    health_check_eviction_time_in_min             = 10
    container_registry_use_managed_identity       = true
    container_registry_managed_identity_client_id = azurerm_user_assigned_identity.web_apps.client_id

    application_stack {
      docker_image_name   = "backend:${var.initial_image_tag}"
      docker_registry_url = local.registry_url
    }
  }

  tags = var.tags

  # The image must be pullable on first start, which needs the AcrPull assignment.
  depends_on = [azurerm_role_assignment.acr_pull]

  lifecycle {
    # GitHub Actions deploys new image tags (backend:<commit-sha>). Ignore only the
    # image name so Terraform does not roll deployments back; every other setting
    # is still managed by Terraform.
    ignore_changes = [site_config[0].application_stack[0].docker_image_name]
  }
}

resource "azurerm_linux_web_app" "frontend" {
  name                = var.frontend_app_name
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.main.id

  https_only                                     = true
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  app_settings = merge(var.frontend_app_settings, local.frontend_required_settings)

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.web_apps.id]
  }

  site_config {
    always_on                                     = true
    ftps_state                                    = "Disabled"
    minimum_tls_version                           = "1.2"
    http2_enabled                                 = true
    health_check_path                             = "/healthz"
    health_check_eviction_time_in_min             = 10
    container_registry_use_managed_identity       = true
    container_registry_managed_identity_client_id = azurerm_user_assigned_identity.web_apps.client_id

    application_stack {
      docker_image_name   = "frontend:${var.initial_image_tag}"
      docker_registry_url = local.registry_url
    }
  }

  tags = var.tags

  depends_on = [azurerm_role_assignment.acr_pull]

  lifecycle {
    ignore_changes = [site_config[0].application_stack[0].docker_image_name]
  }
}

# Warns (does not fail) if Azure assigned a different default host name than the
# one used for the backend CORS setting.
check "frontend_origin_matches_hostname" {
  assert {
    condition     = "https://${azurerm_linux_web_app.frontend.default_hostname}" == local.frontend_origin
    error_message = "Frontend host name differs from the CORS origin configured on the backend (${local.frontend_origin})."
  }
}
