# Offline tests: run with `terraform test`.
# The azurerm provider is mocked, so no Azure credentials are needed and nothing is created.
mock_provider "azurerm" {
  # Resource IDs are validated by the provider, so mocks must return well-formed IDs.
  mock_resource "azurerm_container_registry" {
    defaults = {
      id           = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-cc2026-agi-dev/providers/Microsoft.ContainerRegistry/registries/acrmock"
      login_server = "acrmock.azurecr.io"
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-cc2026-agi-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mock"
      principal_id = "00000000-0000-0000-0000-000000000001"
      client_id    = "00000000-0000-0000-0000-000000000002"
    }
  }

  mock_resource "azurerm_storage_account" {
    defaults = {
      id                    = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-cc2026-agi-dev/providers/Microsoft.Storage/storageAccounts/stmock"
      primary_blob_endpoint = "https://stmock.blob.core.windows.net/"
      primary_dfs_endpoint  = "https://stmock.dfs.core.windows.net/"
    }
  }

  mock_resource "azurerm_data_factory" {
    defaults = {
      id = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-cc2026-agi-dev/providers/Microsoft.DataFactory/factories/adf-mock"
    }
  }

  mock_resource "azurerm_logic_app_workflow" {
    defaults = {
      id = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-cc2026-agi-dev/providers/Microsoft.Logic/workflows/logic-mock"
    }
  }

  mock_resource "azurerm_logic_app_trigger_http_request" {
    defaults = {
      callback_url = "https://prod-00.germanywestcentral.logic.azure.com:443/workflows/mock/triggers/pipeline_status/paths/invoke?sig=mock"
    }
  }

  mock_resource "azurerm_service_plan" {
    defaults = {
      id = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-cc2026-agi-dev/providers/Microsoft.Web/serverFarms/asp-mock"
    }
  }
}

# Mocked resources get random computed values; pin the host names Azure would assign.
override_resource {
  target = module.app_service[0].azurerm_linux_web_app.frontend
  values = { default_hostname = "cc2026-ui-agi-dev-e6d3.azurewebsites.net" }
}

override_resource {
  target = module.app_service[0].azurerm_linux_web_app.backend
  values = { default_hostname = "cc2026-api-agi-dev-e6d3.azurewebsites.net" }
}

variables {
  student_initials = "agi"
  subscription_id  = "11111111-2222-3333-4444-555555555555"
}

run "names_follow_convention" {
  command = apply # against the mocked provider only

  assert {
    condition     = azurerm_resource_group.main.name == "rg-cc2026-agi-dev"
    error_message = "Unexpected resource group name: ${azurerm_resource_group.main.name}"
  }

  assert {
    condition     = can(regex("^acrcc2026agidev[0-9a-f]{4}$", local.acr_name))
    error_message = "ACR name must be alphanumeric with a 4-character suffix: ${local.acr_name}"
  }

  assert {
    condition     = can(regex("^cc2026-api-agi-dev-[0-9a-f]{4}$", local.backend_app_name))
    error_message = "Unexpected backend Web App name: ${local.backend_app_name}"
  }

  assert {
    condition     = can(regex("^cc2026-ui-agi-dev-[0-9a-f]{4}$", local.frontend_app_name))
    error_message = "Unexpected frontend Web App name: ${local.frontend_app_name}"
  }

  assert {
    condition     = can(regex("^stcc2026agidev[0-9a-f]{4}$", local.storage_account_name))
    error_message = "Storage account name must be 3-24 lowercase letters and digits: ${local.storage_account_name}"
  }

  assert {
    condition     = can(regex("^adf-cc2026-agi-dev-[0-9a-f]{4}$", local.data_factory_name))
    error_message = "Unexpected Data Factory name: ${local.data_factory_name}"
  }
}

run "registry_only_first_stage" {
  command = plan

  variables {
    create_web_apps = false
  }

  assert {
    condition     = length(module.app_service) == 0
    error_message = "Web Apps must not be planned while create_web_apps is false."
  }

  assert {
    condition     = length(azurerm_role_assignment.backend_reads_lake) == 0
    error_message = "The backend role assignment needs the Web Apps identity and must not exist without it."
  }
}

run "web_apps_are_wired_together" {
  command = apply # against the mocked provider only

  assert {
    condition     = output.frontend_url == "https://cc2026-ui-agi-dev-e6d3.azurewebsites.net"
    error_message = "Unexpected frontend URL: ${output.frontend_url}"
  }

  assert {
    condition     = output.backend_url == "https://cc2026-api-agi-dev-e6d3.azurewebsites.net"
    error_message = "Unexpected backend URL: ${output.backend_url}"
  }
}

run "backend_gets_gold_access_and_settings" {
  command = apply # against the mocked provider only

  assert {
    condition     = length(azurerm_role_assignment.backend_reads_lake) == 1
    error_message = "The backend identity must get Storage Blob Data Reader on the data lake."
  }

  assert {
    condition     = azurerm_role_assignment.data_factory_writes_lake.role_definition_name == "Storage Blob Data Contributor"
    error_message = "Data Factory must get Storage Blob Data Contributor on the data lake."
  }

  assert {
    condition     = local.backend_app_settings["GOLD_CONTAINER"] == "gold"
    error_message = "The backend must receive GOLD_CONTAINER=gold."
  }

  assert {
    condition     = local.backend_app_settings["STORAGE_ACCOUNT_URL"] == "https://stmock.blob.core.windows.net/"
    error_message = "The backend must receive the blob endpoint as STORAGE_ACCOUNT_URL."
  }

  assert {
    condition     = can(regex("--container-name bronze --name raw/", output.upload_command))
    error_message = "The upload hint must target bronze/raw/."
  }
}

run "teams_disabled_without_webhook_url" {
  command = plan

  assert {
    condition     = module.notification.posts_to_teams == false
    error_message = "Without a webhook URL the Logic App must not post to Teams."
  }
}

run "teams_enabled_with_webhook_url" {
  command = plan

  variables {
    teams_webhook_url = "https://example.invalid/webhook?sig=test"
  }

  assert {
    condition     = module.notification.posts_to_teams == true
    error_message = "With a webhook URL the Logic App must post the card."
  }
}
