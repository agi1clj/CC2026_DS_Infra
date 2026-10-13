variable "location" {
  description = "Azure region for the registry."
  type        = string
}

variable "name" {
  description = "Globally unique registry name (5-50 lowercase letters and digits)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{5,50}$", var.name))
    error_message = "Registry name must be 5-50 lowercase letters and digits."
  }
}

variable "resource_group_name" {
  description = "Resource group that contains the registry."
  type        = string
}

variable "sku" {
  description = "Registry SKU. Basic is sufficient for this project."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "SKU must be Basic, Standard or Premium."
  }
}

variable "tags" {
  description = "Tags applied to the registry."
  type        = map(string)
  default     = {}
}
