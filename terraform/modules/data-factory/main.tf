# Azure Data Factory for the P2 pipeline. Everything is defined here in Terraform ("live mode",
# no Git integration). Do not edit resources in the ADF portal: the next apply overwrites them.
#
#   blob created in bronze/raw/*.csv -> storage event trigger -> pipeline pl-energy-etl
#   pipeline = Mapping Data Flow (bronze CSV -> silver Parquet + 3 gold JSON files) -> Web activity -> Logic App -> Teams

locals {
  # Transformation names in dataflow/energy_etl.dfs. The azurerm resource needs the list as blocks.
  # Sources and sinks are listed separately below.
  transformations = [
    "CleanRows", "DropDuplicates", "AddTypedColumns", "SilverColumns", "DailyTotals", "RoundDaily",
    "SortDaily", "LocationTotals", "RoundLocation", "LocationColumns", "SortLocation", "SortLatest",
    "Latest200", "LatestColumns",
  ]

  # Link to the run in the ADF monitor, built by the Web activities (the run ID is appended).
  monitor_url_prefix = "https://adf.azure.com/en/monitoring/pipelineruns/"
}

resource "azurerm_data_factory" "main" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# Access to the data lake with the factory's own identity (role assignment is in the root module). No keys.
resource "azurerm_data_factory_linked_service_data_lake_storage_gen2" "lake" {
  name                 = "ls_datalake"
  data_factory_id      = azurerm_data_factory.main.id
  url                  = var.storage_dfs_endpoint
  use_managed_identity = true
}

resource "azurerm_data_factory_dataset_delimited_text" "bronze_csv" {
  name                = "ds_bronze_csv"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name

  azure_blob_fs_location {
    file_system = "bronze"
  }

  column_delimiter    = ","
  encoding            = "UTF-8"
  quote_character     = "\""
  escape_character    = "\\"
  first_row_as_header = true

  # The data flow source validates the file against this schema (validateSchema: true).
  dynamic "schema_column" {
    for_each = ["device_id", "timestamp", "temperature", "humidity", "kwh", "location"]

    content {
      name = schema_column.value
      type = "String"
    }
  }
}

resource "azurerm_data_factory_dataset_parquet" "silver" {
  name                = "ds_silver_parquet"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name

  azure_blob_fs_location {
    file_system = "silver"
    path        = "energy_readings"
  }

  compression_codec = "snappy"
}

# The azurerm JSON dataset supports Blob locations only, so the ADLS location uses a custom dataset.
resource "azurerm_data_factory_custom_dataset" "gold_json" {
  name            = "ds_gold_json"
  data_factory_id = azurerm_data_factory.main.id
  type            = "Json"

  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name
  }

  type_properties_json = jsonencode({
    location = {
      type       = "AzureBlobFSLocation"
      fileSystem = "gold"
    }
  })
}

resource "azurerm_data_factory_data_flow" "energy" {
  name            = "df_energy_etl"
  data_factory_id = azurerm_data_factory.main.id

  # Hand-written data flow script, versioned in the module. The names below must match it.
  script = file("${path.module}/dataflow/energy_etl.dfs")

  source {
    name = "BronzeCsv"

    dataset {
      name = azurerm_data_factory_dataset_delimited_text.bronze_csv.name
    }
  }

  dynamic "transformation" {
    for_each = local.transformations

    content {
      name = transformation.value
    }
  }

  sink {
    name = "SilverParquet"

    dataset {
      name = azurerm_data_factory_dataset_parquet.silver.name
    }
  }

  dynamic "sink" {
    for_each = ["GoldDaily", "GoldLocation", "GoldLatest"]

    content {
      name = sink.value

      dataset {
        name = azurerm_data_factory_custom_dataset.gold_json.name
      }
    }
  }
}

resource "azurerm_data_factory_pipeline" "energy_etl" {
  name            = "pl-energy-etl"
  data_factory_id = azurerm_data_factory.main.id

  parameters = {
    fileName = "energy_readings.csv"
  }

  activities_json = templatefile("${path.module}/pipeline/energy_etl.json.tftpl", {
    data_flow_name     = azurerm_data_factory_data_flow.energy.name
    notification_url   = var.notification_url
    monitor_url_prefix = local.monitor_url_prefix
    factory_id_encoded = urlencode(azurerm_data_factory.main.id)
  })
}

# Starts the pipeline when a CSV file appears under bronze/raw/. The trigger needs the
# Microsoft.EventGrid provider; the Event Grid subscription is created on the storage account.
resource "azurerm_data_factory_trigger_blob_event" "csv_uploaded" {
  name                  = "tr-bronze-csv-created"
  data_factory_id       = azurerm_data_factory.main.id
  storage_account_id    = var.storage_account_id
  events                = ["Microsoft.Storage.BlobCreated"]
  blob_path_begins_with = "/bronze/blobs/raw/"
  blob_path_ends_with   = ".csv"
  ignore_empty_blobs    = true
  activated             = true

  pipeline {
    name = azurerm_data_factory_pipeline.energy_etl.name

    parameters = {
      fileName = "@triggerBody().fileName"
    }
  }
}
