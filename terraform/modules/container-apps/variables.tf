variable "backend_app_settings" {
  description = "Extra application settings (environment variables) for the backend, e.g. a storage account URL in P2."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "backend_app_name" {
  description = "Globally unique name of the backend container app."
  type        = string
}

variable "container_registry_id" {
  description = "Resource ID of the container registry the container apps pull from."
  type        = string
}

variable "container_registry_login_server" {
  description = "Login server of the container registry, e.g. myregistry.azurecr.io."
  type        = string
}

variable "frontend_app_name" {
  description = "Globally unique name of the frontend container app."
  type        = string
}

variable "frontend_app_settings" {
  description = "Extra application settings for the frontend container. Never put secrets here: the frontend runs in the browser."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "identity_name" {
  description = "Name of the user-assigned identity of the container apps (used to pull images from the registry)."
  type        = string
}

variable "environment_name" {
  description = "Name of the Container Apps environment that hosts both apps."
  type        = string
}

variable "initial_image_tag" {
  description = "Image tag used when the container apps are first created. Later deployments are done by GitHub Actions."
  type        = string
  default     = "latest"
}

variable "location" {
  description = "Azure region for all container app resources."
  type        = string
}

variable "min_replicas" {
  description = "Minimum replicas per app. 0 scales to zero when idle (cheapest, first request waits a few seconds); 1 keeps an instance always running."
  type        = number
  default     = 1

  validation {
    condition     = contains([0, 1], var.min_replicas)
    error_message = "min_replicas must be 0 or 1."
  }
}

variable "resource_group_name" {
  description = "Resource group that contains the container app resources."
  type        = string
}

variable "tags" {
  description = "Tags applied to all container app resources."
  type        = map(string)
  default     = {}
}
