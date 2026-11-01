output "identity_principal_id" {
  description = "Principal ID of the Data Factory's system-assigned identity, to grant it roles on the data lake."
  value       = azurerm_data_factory.main.identity[0].principal_id
}

output "name" {
  description = "Name of the Data Factory."
  value       = azurerm_data_factory.main.name
}
