variable "location" {
  description = "Azure region of the storage account."
  type        = string
}

variable "name" {
  description = "Globally unique storage account name (3-24 lowercase letters and digits)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.name))
    error_message = "Storage account names must be 3-24 lowercase letters and digits."
  }
}

variable "resource_group_name" {
  description = "Resource group that contains the storage account."
  type        = string
}

variable "tags" {
  description = "Tags applied to the storage account."
  type        = map(string)
  default     = {}
}
