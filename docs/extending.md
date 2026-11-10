# Extending the platform (P2, P3 and beyond)

The platform is built so that later project parts **add** services without restructuring what already works. This page lists the extension points. P2 is implemented (modules `storage`, `data-factory`, `notification`). P3 is not.

| Later part | Likely Azure services (from the course architecture) |
|---|---|
| P2 – data pipeline (**implemented**) | Data lake (modules `storage`, `data-factory`, `notification`), walkthrough: [p2/student-walkthrough.md](p2/student-walkthrough.md), diagram: [architecture.md](architecture.md) |
| P3 – identity | Microsoft Entra ID sign-in for the frontend and backend |

## Extension points

| Layer | Where | How to extend |
|---|---|---|
| Terraform modules | `terraform/modules/<service>/` | One folder per service: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`. Same conventions as the existing modules (typed/described variables, described outputs, `tags` input) |
| Composition | `terraform/environments/dev/main.tf` | Add a `module "<service>"` block; wire outputs into other modules |
| Names and tags | `terraform/environments/dev/locals.tf` | Add one local per resource name, based on `local.name_base` (and `local.unique_suffix` for globally unique names). Always pass `local.tags` |
| App configuration | `module "app_service"` inputs `backend_app_settings` / `frontend_app_settings` | Pass new environment variables (e.g. a storage URL). Required settings (ports, CORS, API URL) cannot be overridden by accident |
| Access between services | `module.container_apps[0].identity_principal_id` | Grant the container apps' managed identity a role on the new resource with `azurerm_role_assignment`. No keys or connection strings |
| Roles Terraform may assign | `ASSIGNABLE_ROLE_IDS` in `bootstrap/bootstrap.sh` | Add the role's GUID and re-run bootstrap. The RBAC condition is updated in place |
| Resource providers | `RESOURCE_PROVIDERS` in `bootstrap.sh` and `resource_providers_to_register` in `providers.tf` | Add the namespace, e.g. `Microsoft.DataFactory` |
| Backend data | `backend/app/data.py` (Apps repo) | Implement `MeasurementSource` (e.g. reading Blob Storage) and return it from `get_measurement_source()`. Endpoints and tests stay unchanged |
| Backend settings | `backend/app/config.py` (Apps repo) | Add a field to `Settings` read from an environment variable |
| Frontend config | `RuntimeConfig` in `frontend/src/types.ts` + `docker/40-runtime-config.sh` | Add public runtime values (e.g. a P3 sign-in client ID). Never secrets |
| New deployable app | `.github/workflows/<app>.yml` (Apps repo) | Copy `backend.yml`: test job + deploy job using the same OIDC variables |
| Tests | `terraform/environments/dev/tests/*.tftest.hcl` | Add a `run` block asserting names/wiring with the mocked provider |

## Rules that keep the project simple

- One root module and one state for the whole project (`dev.tfstate`). Rename the key only if a later part really needs a separate lifecycle.
- Managed identities and RBAC for service-to-service access. Add Key Vault only if a service truly requires a secret.
- Keep `create_web_apps` and the image-ownership rules unchanged (README §11).
