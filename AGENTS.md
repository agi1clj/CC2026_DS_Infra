# AGENTS.md

Teaching project (UTCN Cloud Computing). Azure infra for the companion `*_Apps` repository. Keep it simple: no AKS, VNets, Key Vault or extra tooling unless asked.

## Layout
- `terraform/environments/dev/` the only root module (remote state key `dev.tfstate`). Names and tags live in `locals.tf`.
- `terraform/modules/<service>/` one small module per service (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`).
- `bootstrap/bootstrap.sh` one-time state storage, Entra app + OIDC, roles, GitHub variables. `scripts/cleanup.sh` deliberate teardown.
- How to add services: `docs/extending.md`.

## Verify before finishing (no Azure needed)
- `terraform fmt -check -recursive terraform`
- `cd terraform/environments/dev && terraform init -backend=false && terraform validate && terraform test`
- `shellcheck bootstrap/*.sh scripts/*.sh` and `actionlint .github/workflows/*.yml`

## Rules
- Never run `terraform apply`/`destroy`, `bootstrap.sh` or `cleanup.sh` against Azure without explicit user approval. Destroy only after showing `plan -destroy`.
- Follow the HashiCorp style guide: every variable has `type` + `description`, every output a `description`; no provisioners; no hard-coded IDs or secrets.
- Do not commit `terraform.tfvars`, `backend.hcl` or state. Do commit `.terraform.lock.hcl` (lock for linux_amd64, darwin_arm64, darwin_amd64, windows_amd64).
- `ignore_changes` covers only `docker_image_name` (Apps CI owns image tags). Never widen it.
- `CREATE_WEB_APPS` must never go back to `false` once Web Apps exist (it would delete them).
- New roles Terraform assigns must be added to `ASSIGNABLE_ROLE_IDS` in `bootstrap.sh`; new resource providers to both `bootstrap.sh` and `providers.tf`.
