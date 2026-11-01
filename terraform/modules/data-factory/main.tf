# Azure Data Factory for the P2 pipeline. Everything is defined here in Terraform ("live mode",
# no Git integration). Do not edit resources in the ADF portal: the next apply overwrites them.
#
#   blob created in bronze/raw/*.csv -> storage event trigger -> pipeline pl-energy-etl
#   pipeline = Mapping Data Flow (bronze CSV -> silver Parquet, rejected rows CSV, gold JSON in gold/by-timestamp/<run>/)
#              -> reject-ratio check -> Copy to gold/latest/ -> Web activity -> Logic App -> Teams

locals {
  # Names used in dataflow/energy_etl.dfs. The azurerm resource needs them as blocks.
  # Add the name of every new transformation and every new gold sink here.
  transformations = [
    "CleanRows", "AddRejectReason", "DropDuplicates", "AddTypedColumns", "SilverColumns", "DailyTotals", "RoundDaily",
    "SortDaily",
    "AddGroup", "NumberRows", "Latest200", "SortLatest", "LatestColumns",
    "LocationTotals", "RoundLocation", "LocationColumns", "SortLocation",
  ]
  gold_sinks = ["GoldDaily", "GoldLatest", "GoldLocation"]

  # Pipeline activities whose failure sends the red Teams card.
  failed_activities = ["Run data flow", "Check reject ratio", "Copy to latest"]

  # Row counts from the data flow metrics. A sink that wrote zero rows has no entry, hence the contains().
  flow_metrics  = "activity('Run data flow').output.runStatus.metrics"
  rows_silver   = "if(contains(${local.flow_metrics}, 'SilverParquet'), ${local.flow_metrics}.SilverParquet.rowsWritten, 0)"
  rows_rejected = "if(contains(${local.flow_metrics}, 'RejectedCsv'), ${local.flow_metrics}.RejectedCsv.rowsWritten, 0)"
  rows_read     = "if(contains(${local.flow_metrics}, 'SilverParquet'), ${local.flow_metrics}.SilverParquet.sources.BronzeCsv.rowsRead, if(contains(${local.flow_metrics}, 'RejectedCsv'), ${local.flow_metrics}.RejectedCsv.sources.BronzeCsv.rowsRead, 0))"

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

# The azurerm JSON and binary datasets do not support ADLS locations, so these use custom datasets.
# Gold history: every run writes gold/by-timestamp/<runFolder>/<file>.json (never deleted).
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

resource "azurerm_data_factory_custom_dataset" "gold_json" {
  name            = "ds_gold_json"
  data_factory_id = azurerm_data_factory.main.id
  type            = "Json"
  parameters      = { runFolder = "19700101T000000Z" }

  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name
  }

  type_properties_json = jsonencode({
    location = {
      type       = "AzureBlobFSLocation"
      fileSystem = "gold"
      folderPath = { value = "@concat('by-timestamp/', dataset().runFolder)", type = "Expression" }
    }
  })
}

# Copy activity source: the files of one run.
resource "azurerm_data_factory_custom_dataset" "gold_run_files" {
  name            = "ds_gold_run_files"
  data_factory_id = azurerm_data_factory.main.id
  type            = "Binary"
  parameters      = { runFolder = "19700101T000000Z" }

  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name
  }

  type_properties_json = jsonencode({
    location = {
      type       = "AzureBlobFSLocation"
      fileSystem = "gold"
      folderPath = { value = "@concat('by-timestamp/', dataset().runFolder)", type = "Expression" }
    }
  })
}

# Copy activity sink: gold/latest/ is the only path the backend reads.
resource "azurerm_data_factory_custom_dataset" "gold_latest" {
  name            = "ds_gold_latest"
  data_factory_id = azurerm_data_factory.main.id
  type            = "Binary"

  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name
  }

  type_properties_json = jsonencode({
    location = {
      type       = "AzureBlobFSLocation"
      fileSystem = "gold"
      folderPath = "latest"
    }
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
        name       = azurerm_data_factory_custom_dataset.gold_json.name
        parameters = { runFolder = "$runTimestamp" }
      }
    }
  }
}

resource "azurerm_data_factory_pipeline" "energy_etl" {
  name            = "pl-energy-etl"
  data_factory_id = azurerm_data_factory.main.id

  parameters = {
    fileName       = "energy_readings.csv"
    maxRejectRatio = "0.10" # the run fails when more than 10% of the rows read are rejected
  }

  variables = {
    runTimestamp = ""
  }

  # One run at a time: extra uploads wait in the queue (each run overwrites silver and gold/latest).
  concurrency = 1

  activities_json = templatefile("${path.module}/pipeline/energy_etl.json.tftpl", {
    data_flow_name      = azurerm_data_factory_data_flow.energy.name
    gold_run_dataset    = azurerm_data_factory_custom_dataset.gold_run_files.name
    gold_latest_dataset = azurerm_data_factory_custom_dataset.gold_latest.name
    failed_activities   = local.failed_activities
    rows_read           = local.rows_read
    rows_silver         = local.rows_silver
    rows_rejected       = local.rows_rejected
    notification_url    = var.notification_url
    monitor_url_prefix  = local.monitor_url_prefix
    factory_id_encoded  = urlencode(azurerm_data_factory.main.id)
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
