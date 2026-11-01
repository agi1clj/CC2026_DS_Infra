# Data lake for the P2 pipeline: one account, three zones (medallion layout).
#   bronze = raw uploads, silver = cleaned Parquet, gold = small JSON files for the backend.
resource "azurerm_storage_account" "main" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  is_hns_enabled           = true # hierarchical namespace = Data Lake Storage Gen2

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false # Entra ID only, no account keys
  allow_nested_items_to_be_public = false

  # Soft delete protects against deleting data by mistake. Blob versioning is not supported
  # on accounts with a hierarchical namespace (Microsoft feature support table), so it stays off.
  blob_properties {
    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}

resource "azurerm_storage_container" "zone" {
  for_each = toset(["bronze", "silver", "gold"])

  name                  = each.key
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}
