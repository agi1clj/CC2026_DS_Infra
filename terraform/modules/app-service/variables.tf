variable "backend_app_settings" {
  description = "Extra application settings (environment variables) for the backend, e.g. a storage account URL in P2."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "backend_app_name" {
  description = "Globally unique name of the backend Web App."
  type        = string
}

variable "container_registry_id" {
  description = "Resource ID of the container registry the Web Apps pull from."
  type        = string
}

variable "container_registry_login_server" {
  description = "Login server of the container registry, e.g. myregistry.azurecr.io."
  type        = string
}

variable "frontend_app_name" {
  description = "Globally unique name of the frontend Web App."
  type        = string
}

variable "frontend_app_settings" {
  description = "Extra application settings for the frontend container. Never put secrets here: the frontend runs in the browser."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "identity_name" {
  description = "Name of the user-assigned identity of the Web Apps (used to pull images from the registry)."
  type        = string
}

variable "initial_image_tag" {
  description = "Image tag used when the Web Apps are first created. Later deployments are done by GitHub Actions."
  type        = string
  default     = "latest"
}

variable "location" {
  description = "Azure region for all App Service resources."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that contains the App Service resources."
  type        = string
}

variable "service_plan_name" {
  description = "Name of the shared Linux App Service Plan."
  type        = string
}

variable "sku_name" {
  description = "App Service Plan SKU. Must support Linux containers and Always On (B1 or higher)."
  type        = string
  default     = "B1"

  validation {
    condition     = contains(["B1", "B2", "B3", "S1", "S2", "S3", "P0v3", "P1v3"], var.sku_name)
    error_message = "Use a Basic, Standard or Premium v3 SKU (Free/Shared tiers do not support Always On)."
  }
}

variable "tags" {
  description = "Tags applied to all App Service resources."
  type        = map(string)
  default     = {}
}
