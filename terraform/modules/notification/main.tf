# Logic App (Consumption) that turns a small pipeline status message into a Teams Adaptive Card.
#   Data Factory Web activity -> HTTP request trigger -> HTTP action -> Teams Workflows webhook
# A plain HTTP action needs no connector and no OAuth consent. With an empty webhook URL the
# workflow has no action: it accepts the call and does nothing, so the pipeline never fails because of Teams.

locals {
  # `nonsensitive` only reveals whether the URL is set (needed for count), not the URL itself.
  teams_enabled = nonsensitive(var.teams_webhook_url != "")
}

resource "azurerm_logic_app_workflow" "main" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags
}

# Body sent by the pipeline: {status, pipeline, runId, file, message, monitorUrl}.
resource "azurerm_logic_app_trigger_http_request" "pipeline_status" {
  name         = "pipeline_status"
  logic_app_id = azurerm_logic_app_workflow.main.id

  schema = jsonencode({
    type = "object"
    properties = {
      status     = { type = "string" }
      pipeline   = { type = "string" }
      runId      = { type = "string" }
      file       = { type = "string" }
      message    = { type = "string" }
      monitorUrl = { type = "string" }
    }
  })
}

# Defined as custom JSON so that the card is a real object: every expression sits in one
# string value and Logic Apps escapes it correctly (error messages may contain quotes).
resource "azurerm_logic_app_action_custom" "post_card" {
  count = local.teams_enabled ? 1 : 0

  name         = "post_card_to_teams"
  logic_app_id = azurerm_logic_app_workflow.main.id

  body = templatefile("${path.module}/templates/post_card_action.json.tftpl", {
    webhook_url = var.teams_webhook_url
  })

  depends_on = [azurerm_logic_app_trigger_http_request.pipeline_status]
}
