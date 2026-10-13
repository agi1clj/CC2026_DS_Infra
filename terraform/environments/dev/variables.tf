variable "acr_sku" {
  description = "Azure Container Registry SKU."
  type        = string
  default     = "Basic"
}

variable "app_service_sku" {
  description = "SKU of the shared Linux App Service Plan (B1 is the cheapest SKU that supports Always On)."
  type        = string
  default     = "B1"
}

variable "create_web_apps" {
  description = "Create the App Service Plan and Web Apps. Set to false only for the very first apply, before the first images exist in ACR."
  type        = bool
  default     = true
  nullable    = false
}

variable "environment" {
  description = "Environment name used in resource names and tags."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev"], var.environment)
    error_message = "Only the dev environment exists; add a new environments/<name> folder for others."
  }
}

variable "location" {
  description = "Azure region. Azure for Students subscriptions only allow a few regions (bootstrap.sh checks the policy)."
  type        = string
  default     = "germanywestcentral"
}

variable "project_name" {
  description = "Short project name used as a prefix in resource names."
  type        = string
  default     = "cc2026"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.project_name))
    error_message = "Project name must be 2-10 lowercase letters/digits, starting with a letter."
  }
}

variable "student_initials" {
  description = "Student initials used in every resource name, e.g. agi."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2,5}$", var.student_initials))
    error_message = "Student initials must be 2-5 lowercase letters, e.g. agi."
  }
}

variable "subscription_id" {
  description = "Azure subscription ID to deploy into (not a secret; set by bootstrap.sh)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "Subscription ID must be a GUID."
  }
}
