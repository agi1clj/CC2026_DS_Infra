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
