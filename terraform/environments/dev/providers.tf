provider "azurerm" {
  features {}

  subscription_id = var.subscription_id

  # Register only what this project needs instead of the provider's default set.
  # (Locally Terraform authenticates with `az login`; in CI with GitHub OIDC via ARM_* variables.)
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.ContainerRegistry",
    "Microsoft.ManagedIdentity",
    "Microsoft.Web",
  ]
}
