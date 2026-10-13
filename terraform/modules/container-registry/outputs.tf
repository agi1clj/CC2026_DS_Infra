output "id" {
  description = "Resource ID of the registry (scope for role assignments)."
  value       = azurerm_container_registry.main.id
}

output "login_server" {
  description = "Registry login server, e.g. acrcc2026agidev1a2b.azurecr.io."
  value       = azurerm_container_registry.main.login_server
}

output "name" {
  description = "Registry name."
  value       = azurerm_container_registry.main.name
}
