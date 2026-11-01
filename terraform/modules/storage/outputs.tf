output "id" {
  description = "Resource ID of the storage account (scope for role assignments)."
  value       = azurerm_storage_account.main.id
}

output "name" {
  description = "Name of the storage account."
  value       = azurerm_storage_account.main.name
}

output "primary_blob_endpoint" {
  description = "Blob endpoint, e.g. https://<name>.blob.core.windows.net/ (used by SDKs and az storage)."
  value       = azurerm_storage_account.main.primary_blob_endpoint
}

output "primary_dfs_endpoint" {
  description = "Data Lake (dfs) endpoint, used by the Data Factory linked service."
  value       = azurerm_storage_account.main.primary_dfs_endpoint
}
