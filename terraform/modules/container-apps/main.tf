locals {
  registry_server = var.container_registry_login_server

  # Both apps live in one environment, so their host names are <app name>.<default domain>.
  # The domain is known before the apps exist, so the backend can allow the frontend origin
  # (CORS) and the frontend can know the backend URL without a dependency cycle.
  backend_fqdn    = "${var.backend_app_name}.${azurerm_container_app_environment.main.default_domain}"
  frontend_fqdn   = "${var.frontend_app_name}.${azurerm_container_app_environment.main.default_domain}"
  frontend_origin = "https://${local.frontend_fqdn}"

  # Settings required by the containers. Merged last, so callers cannot override them
  # through backend_app_settings / frontend_app_settings.
  backend_settings = merge(var.backend_app_settings, {
    CORS_ORIGINS = local.frontend_origin
    # Lets Azure SDKs (DefaultAzureCredential) pick the user-assigned identity, e.g. for Blob Storage in P2.
    AZURE_CLIENT_ID = azurerm_user_assigned_identity.apps.client_id
  })
  frontend_settings = merge(var.frontend_app_settings, {
    API_BASE_URL = "https://${local.backend_fqdn}"
  })
}

# One environment hosts both apps. The Consumption profile is billed per use and needs no VM quota.
resource "azurerm_container_app_environment" "main" {
  name                = var.environment_name
  resource_group_name = var.resource_group_name
  location            = var.location

  # Azure adds this profile on its own; declaring it avoids a permanent plan diff.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = var.tags
}

# Identity of the apps. Today it is used to pull images from ACR; later project parts
# can grant it more roles (e.g. read Blob Storage) via the identity_principal_id output. A user-assigned identity is
# used (instead of system-assigned) so the AcrPull role exists *before* the apps
# start for the first time; otherwise the first image pull fails.
resource "azurerm_user_assigned_identity" "apps" {
  name                = var.identity_name
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = var.container_registry_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.apps.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_container_app" "backend" {
  name                         = var.backend_app_name
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }

  registry {
    server   = local.registry_server
    identity = azurerm_user_assigned_identity.apps.id
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "backend"
      image  = "${local.registry_server}/backend:${var.initial_image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = local.backend_settings
        content {
          name  = env.key
          value = env.value
        }
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/health"
        port      = 8000
      }
    }
  }

  tags = var.tags

  # The image must be pullable on first start, which needs the AcrPull assignment.
  depends_on = [azurerm_role_assignment.acr_pull]

  lifecycle {
    # GitHub Actions deploys new image tags (backend:<commit-sha>). Ignore only the
    # image so Terraform does not roll deployments back; every other setting
    # is still managed by Terraform.
    ignore_changes = [template[0].container[0].image]
  }
}

resource "azurerm_container_app" "frontend" {
  name                         = var.frontend_app_name
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }

  registry {
    server   = local.registry_server
    identity = azurerm_user_assigned_identity.apps.id
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "frontend"
      image  = "${local.registry_server}/frontend:${var.initial_image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = local.frontend_settings
        content {
          name  = env.key
          value = env.value
        }
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/healthz"
        port      = 8080
      }
    }
  }

  tags = var.tags

  depends_on = [azurerm_role_assignment.acr_pull]

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}
