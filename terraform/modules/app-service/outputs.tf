output "backend_app_name" {
  description = "Name of the backend Web App."
  value       = azurerm_linux_web_app.backend.name
}

output "backend_url" {
  description = "Public HTTPS URL of the backend."
  value       = "https://${azurerm_linux_web_app.backend.default_hostname}"
}

output "frontend_app_name" {
  description = "Name of the frontend Web App."
  value       = azurerm_linux_web_app.frontend.name
}

output "frontend_url" {
  description = "Public HTTPS URL of the frontend."
  value       = "https://${azurerm_linux_web_app.frontend.default_hostname}"
}

output "identity_client_id" {
  description = "Client ID of the Web Apps' identity (for SDKs using DefaultAzureCredential / AZURE_CLIENT_ID)."
  value       = azurerm_user_assigned_identity.web_apps.client_id
}

output "identity_principal_id" {
  description = "Principal ID of the Web Apps' identity, to grant it roles on new resources."
  value       = azurerm_user_assigned_identity.web_apps.principal_id
}

output "service_plan_name" {
  description = "Name of the shared App Service Plan."
  value       = azurerm_service_plan.main.name
}
