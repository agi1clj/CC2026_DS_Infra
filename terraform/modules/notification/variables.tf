variable "location" {
  description = "Azure region of the Logic App."
  type        = string
}

variable "name" {
  description = "Name of the Logic App workflow."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that contains the Logic App."
  type        = string
}

variable "tags" {
  description = "Tags applied to the Logic App."
  type        = map(string)
  default     = {}
}

variable "teams_webhook_url" {
  description = "Teams Workflows webhook URL (a secret). Empty = notifications are skipped."
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false
}
