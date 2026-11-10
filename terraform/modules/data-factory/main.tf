# Azure Data Factory for the P2 pipeline. Everything is defined here in Terraform ("live mode",
# no Git integration). Do not edit resources in the ADF portal: the next apply overwrites them.
#
#   blob created in bronze/raw/*.csv -> storage event trigger -> pipeline pl-energy-etl
#   pipeline = Mapping Data Flow (bronze CSV -> silver Parquet, rejected rows CSV, gold JSON in gold/_staging/)
#              -> reject-ratio check -> convert to JSON arrays and copy to gold/by-timestamp/<run>/ and gold/latest/ -> Web activity -> Logic App -> Teams

locals {
  # Names used in dataflow/energy_etl.dfs (same order as in the script). The azurerm resource needs them as blocks.
  # Add the name of every new transformation and every new gold sink here.
  transformations = [
    "CleanRows", "AddRejectReason", "DropDuplicates", "AddTypedColumns", "SilverColumns", # clean and silver
    "DailyTotals", "RoundDaily", "SortDaily",                                             # gold: daily
    "AddGroup", "NumberRows", "Latest200", "SortLatest", "LatestColumns",                 # gold: latest readings
    "LocationTotals", "RoundLocation", "LocationColumns", "SortLocation",                 # gold: by location
  ]
  gold_sinks = ["GoldDaily", "GoldLatest", "GoldLocation"]

  # File names written by the gold sinks (partitionFileNames in the script). The pipeline copies exactly these files.
  gold_files       = ["daily_energy_by_device.json", "latest_readings.json", "energy_by_location.json"]
  gold_files_array = "createArray(${join(", ", [for f in local.gold_files : "'${f}'"])})"

  # Pipeline activities whose failure sends the red Teams card.
  failed_activities = ["Run data flow", "Check reject ratio", "Copy to history", "Copy to latest"]

  # Row counts from the data flow metrics (rowsWritten per sink). A sink that wrote zero rows has no entry, hence the contains().
  flow_metrics  = "activity('Run data flow').output.runStatus.metrics"
  rows_silver   = "if(contains(${local.flow_metrics}, 'SilverParquet'), ${local.flow_metrics}.SilverParquet.rowsWritten, 0)"
  rows_rejected = "if(contains(${local.flow_metrics}, 'RejectedCsv'), ${local.flow_metrics}.RejectedCsv.rowsWritten, 0)"

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

# Rejected rows: one CSV file with the reason, silver/rejected/rejected_rows.csv.
resource "azurerm_data_factory_dataset_delimited_text" "silver_rejected" {
  name                = "ds_silver_rejected_csv"
  data_factory_id     = azurerm_data_factory.main.id
  linked_service_name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name

  azure_blob_fs_location {
    file_system = "silver"
    path        = "rejected"
  }

  column_delimiter    = ","
  encoding            = "UTF-8"
  quote_character     = "\""
  escape_character    = "\\"
  first_row_as_header = true
}

# The azurerm JSON dataset does not support ADLS locations, so these use custom datasets (type Json).
# The data flow writes the three gold files to gold/_staging/ as JSON lines (one object per line, the only
# form a data flow sink writes). The pipeline converts each file to ONE JSON array (arrayOfObjects) while it copies it
# to gold/by-timestamp/<run>/ (history, never deleted) and to gold/latest/ (the only path the backend reads).
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
      folderPath = "_staging"
    }
  })
}

# Copy activity sink: one folder per run. The pipeline passes runFolder (yyyyMMddTHHmmssZ).
resource "azurerm_data_factory_custom_dataset" "gold_history_json" {
  name            = "ds_gold_history_json"
  data_factory_id = azurerm_data_factory.main.id
  type            = "Json"
  parameters      = { runFolder = "19700101T000000Z" } # placeholder: the Copy activity always passes the run time

  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name
  }

  type_properties_json = jsonencode({
    location = {
      type       = "AzureBlobFSLocation"
      fileSystem = "gold"
      folderPath = { value = "@concat('by-timestamp/', dataset().runFolder)", type = "Expression" }
    }
    encodingName = "UTF-8 without BOM" # the default "UTF-8" writes a BOM, which breaks json.loads
  })
}

# Copy activity sink: gold/latest/ is the only path the backend reads.
resource "azurerm_data_factory_custom_dataset" "gold_latest_json" {
  name            = "ds_gold_latest_json"
  data_factory_id = azurerm_data_factory.main.id
  type            = "Json"

  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name
  }

  type_properties_json = jsonencode({
    location = {
      type       = "AzureBlobFSLocation"
      fileSystem = "gold"
      folderPath = "latest"
    }
    encodingName = "UTF-8 without BOM" # the default "UTF-8" writes a BOM, which breaks json.loads
  })
}

resource "azurerm_data_factory_data_flow" "energy" {
  name            = "df_energy_etl"
  data_factory_id = azurerm_data_factory.main.id

  # Hand-written data flow script, versioned in the module. The names below must match it.
  # Lines that start with // are comments for students: they are removed before the upload.
  script = replace(file("${path.module}/dataflow/energy_etl.dfs"), "/(?m)^[ \t]*//[^\n]*\n/", "")

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

  sink {
    name = "RejectedCsv"

    dataset {
      name = azurerm_data_factory_dataset_delimited_text.silver_rejected.name
    }
  }

  dynamic "sink" {
    for_each = local.gold_sinks

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
    fileName       = "energy_readings.csv"
    maxRejectRatio = "0.10" # the run fails when rejected / (rejected + silver) is above this ratio
  }

  variables = {
    runTimestamp = ""
  }

  # One run at a time: extra uploads wait in the queue (each run overwrites silver and gold/latest).
  concurrency = 1

  activities_json = templatefile("${path.module}/pipeline/energy_etl.json.tftpl", {
    data_flow_name       = azurerm_data_factory_data_flow.energy.name
    gold_staging_dataset = azurerm_data_factory_custom_dataset.gold_json.name
    gold_history_dataset = azurerm_data_factory_custom_dataset.gold_history_json.name
    gold_latest_dataset  = azurerm_data_factory_custom_dataset.gold_latest_json.name
    gold_files_array     = local.gold_files_array
    failed_activities    = local.failed_activities
    rows_silver          = local.rows_silver
    rows_rejected        = local.rows_rejected
    notification_url     = var.notification_url
    monitor_url_prefix   = local.monitor_url_prefix
    factory_id_encoded   = urlencode(azurerm_data_factory.main.id)
  })

  # The names are already references, so Terraform orders create and update after these resources.
  # Removing or renaming a dataset is different: Terraform deletes the old one without waiting for the
  # pipeline update, and Data Factory refuses (400) while the live pipeline still uses it.
  # To rename: add the new dataset and switch the pipeline in one apply, remove the old one in the next.
  depends_on = [
    azurerm_data_factory_data_flow.energy,
    azurerm_data_factory_custom_dataset.gold_json,
    azurerm_data_factory_custom_dataset.gold_history_json,
    azurerm_data_factory_custom_dataset.gold_latest_json,
  ]
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
