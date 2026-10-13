# Extending the platform (P2, P3 and beyond)

The platform is built so that later project parts **add** services without restructuring what already works. This page lists the extension points and walks through one example. Nothing here is implemented in P1.

| Later part | Likely Azure services (from the course architecture) |
|---|---|
| P2 – data pipeline | Blob Storage (raw + processed data), Data Factory, Azure Functions / Logic Apps, Teams notification |
| P3 – identity | Microsoft Entra ID sign-in for the frontend and backend |

## Extension points

| Layer | Where | How to extend |
|---|---|---|
| Terraform modules | `terraform/modules/<service>/` | One folder per service: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`. Same conventions as the existing modules (typed/described variables, described outputs, `tags` input) |
| Composition | `terraform/environments/dev/main.tf` | Add a `module "<service>"` block; wire outputs into other modules |
| Names and tags | `terraform/environments/dev/locals.tf` | Add one local per resource name, based on `local.name_base` (and `local.unique_suffix` for globally unique names). Always pass `local.tags` |
| App configuration | `module "app_service"` inputs `backend_app_settings` / `frontend_app_settings` | Pass new environment variables (e.g. a storage URL). Required settings (ports, CORS, API URL) cannot be overridden by accident |
| Access between services | `module.app_service[0].identity_principal_id` | Grant the Web Apps' managed identity a role on the new resource with `azurerm_role_assignment`. No keys or connection strings |
| Roles Terraform may assign | `ASSIGNABLE_ROLE_IDS` in `bootstrap/bootstrap.sh` | Add the role's GUID and re-run bootstrap. The RBAC condition is updated in place |
| Resource providers | `RESOURCE_PROVIDERS` in `bootstrap.sh` and `resource_providers_to_register` in `providers.tf` | Add the namespace, e.g. `Microsoft.DataFactory` |
| Backend data | `backend/app/data.py` (Apps repo) | Implement `MeasurementSource` (e.g. reading Blob Storage) and return it from `get_measurement_source()`. Endpoints and tests stay unchanged |
| Backend settings | `backend/app/config.py` (Apps repo) | Add a field to `Settings` read from an environment variable |
| Frontend config | `RuntimeConfig` in `frontend/src/types.ts` + `docker/40-runtime-config.sh` | Add public runtime values (e.g. a P3 sign-in client ID). Never secrets |
| New deployable app | `.github/workflows/<app>.yml` (Apps repo) | Copy `backend.yml`: test job + deploy job using the same OIDC variables |
| Tests | `terraform/environments/dev/tests/*.tftest.hcl` | Add a `run` block asserting names/wiring with the mocked provider |

## Worked example: Blob Storage for P2 (sketch)

1. **Module** `terraform/modules/storage/main.tf`:

   ```hcl
   resource "azurerm_storage_account" "main" {
     name                            = var.name
     resource_group_name             = var.resource_group_name
     location                        = var.location
     account_tier                    = "Standard"
     account_replication_type        = "LRS"
     min_tls_version                 = "TLS1_2"
     shared_access_key_enabled       = false
     allow_nested_items_to_be_public = false

     tags = var.tags
   }

   resource "azurerm_storage_container" "processed" {
     name               = "processed"
     storage_account_id = azurerm_storage_account.main.id
   }
   ```

   Outputs: `id`, `primary_blob_endpoint`. Check the attribute names against the azurerm version in `.terraform.lock.hcl` before you use them.

2. **Name** in `locals.tf`: `storage_account_name = "st${replace(local.name_base, "-", "")}${local.unique_suffix}"` (3–24 lowercase letters and digits).

3. **Compose** in `main.tf`:

   ```hcl
   module "storage" {
     source = "../../modules/storage"

     name                = local.storage_account_name
     resource_group_name = azurerm_resource_group.main.name
     location            = azurerm_resource_group.main.location
     tags                = local.tags
   }
   ```

   and add to the existing `module "app_service"` block:

   ```hcl
   backend_app_settings = {
     STORAGE_ACCOUNT_URL = module.storage.primary_blob_endpoint
   }
   ```

   The backend already receives `AZURE_CLIENT_ID` (its managed identity), so `DefaultAzureCredential` in the Azure SDK authenticates without further configuration.

4. **Access**: allow-list *Storage Blob Data Reader* (`2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`) in `bootstrap.sh`, re-run bootstrap, then:

   ```hcl
   resource "azurerm_role_assignment" "backend_reads_blobs" {
     count = var.create_web_apps ? 1 : 0

     scope                = module.storage.id
     role_definition_name = "Storage Blob Data Reader"
     principal_id         = module.app_service[0].identity_principal_id
     principal_type       = "ServicePrincipal"
   }
   ```

5. **Backend**: add `storage_account_url` to `Settings`, implement a `BlobMeasurementSource` with `azure-identity` + `azure-storage-blob`, and select it in `get_measurement_source()` when the URL is set. Locally the in-memory source keeps working.

6. **Validate**: `terraform fmt -recursive`, `terraform validate`, `terraform test`, then the *terraform* workflow (plan first).

## Rules that keep the project simple

- One root module and one state for the whole project (`dev.tfstate`). Rename the key only if a later part really needs a separate lifecycle.
- Managed identities and RBAC for service-to-service access. Add Key Vault only if a service truly requires a secret.
- Keep `create_web_apps` and the image-ownership rules unchanged (README §11).
