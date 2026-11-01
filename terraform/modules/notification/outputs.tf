output "callback_url" {
  description = "URL that starts the workflow (contains a signature). The Data Factory pipeline posts to it."
  value       = azurerm_logic_app_trigger_http_request.pipeline_status.callback_url
  sensitive   = true
}

output "name" {
  description = "Name of the Logic App workflow."
  value       = azurerm_logic_app_workflow.main.name
}

output "posts_to_teams" {
  description = "True when a webhook URL is set and the workflow posts the card to Teams."
  value       = local.teams_enabled
}
