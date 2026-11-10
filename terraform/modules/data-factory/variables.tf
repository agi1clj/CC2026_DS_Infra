variable "location" {
  description = "Azure region of the Data Factory."
  type        = string
}

variable "name" {
  description = "Globally unique Data Factory name."
  type        = string
}

variable "notification_url" {
  description = "Callback URL of the Logic App that posts to Teams. It contains a signature, so it is sensitive."
  type        = string
  sensitive   = true
}

variable "resource_group_name" {
  description = "Resource group that contains the Data Factory."
  type        = string
}

variable "storage_account_id" {
  description = "Resource ID of the data lake account that raises the blob events."
  type        = string
}

variable "storage_dfs_endpoint" {
  description = "Data Lake (dfs) endpoint of the data lake account, e.g. https://<name>.dfs.core.windows.net/."
  type        = string
}

variable "tags" {
  description = "Tags applied to the Data Factory."
  type        = map(string)
  default     = {}
}
