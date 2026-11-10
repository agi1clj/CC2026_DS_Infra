output "backend_app_name" {
  description = "Name of the backend container app."
  value       = azurerm_container_app.backend.name
}

output "backend_url" {
  description = "Public HTTPS URL of the backend."
  value       = "https://${local.backend_fqdn}"
}

output "frontend_app_name" {
  description = "Name of the frontend container app."
  value       = azurerm_container_app.frontend.name
}

output "frontend_url" {
  description = "Public HTTPS URL of the frontend."
  value       = "https://${local.frontend_fqdn}"
}

output "identity_client_id" {
  description = "Client ID of the apps' identity (for SDKs using DefaultAzureCredential / AZURE_CLIENT_ID)."
  value       = azurerm_user_assigned_identity.apps.client_id
}

output "identity_principal_id" {
  description = "Principal ID of the apps' identity, to grant it roles on new resources."
  value       = azurerm_user_assigned_identity.apps.principal_id
}

output "environment_name" {
  description = "Name of the Container Apps environment."
  value       = azurerm_container_app_environment.main.name
}
