output "acr_login_server" {
  description = "Login server of the container registry."
  value       = module.container_registry.login_server
}

output "acr_name" {
  description = "Name of the container registry (GitHub variable ACR_NAME in the Apps repository)."
  value       = module.container_registry.name
}

output "backend_url" {
  description = "Public HTTPS URL of the backend (null until the Web Apps are created)."
  value       = one(module.app_service[*].backend_url)
}

output "backend_webapp_name" {
  description = "Name of the backend Web App (GitHub variable BACKEND_WEBAPP_NAME)."
  value       = local.backend_app_name
}

output "frontend_url" {
  description = "Public HTTPS URL of the frontend (null until the Web Apps are created)."
  value       = one(module.app_service[*].frontend_url)
}

output "frontend_webapp_name" {
  description = "Name of the frontend Web App (GitHub variable FRONTEND_WEBAPP_NAME)."
  value       = local.frontend_app_name
}

output "resource_group_name" {
  description = "Name of the application resource group."
  value       = azurerm_resource_group.main.name
}

output "data_factory_name" {
  description = "Name of the Data Factory (watch runs in its Monitor tab; never edit it in the portal)."
  value       = module.data_factory.name
}

output "storage_account_name" {
  description = "Name of the data lake storage account (bronze, silver, gold containers)."
  value       = module.storage.name
}

output "storage_blob_endpoint" {
  description = "Blob endpoint of the data lake. The backend gets it as STORAGE_ACCOUNT_URL."
  value       = module.storage.primary_blob_endpoint
}

output "upload_command" {
  description = "Command that uploads the dataset to bronze and starts the pipeline (needs the Storage Blob Data Contributor role for you)."
  value       = "az storage blob upload --auth-mode login --account-name ${module.storage.name} --container-name bronze --name raw/energy_readings.csv --file data/energy_readings.csv --overwrite"
}
