locals {
  # Base used in all names: <project>-<initials>-<environment>, e.g. cc2026-agi-dev.
  name_base = "${var.project_name}-${var.student_initials}-${var.environment}"

  # ACR and Web App names must be globally unique. Initials alone can collide between
  # students, so a short suffix is derived from the subscription ID. It is deterministic:
  # local runs and CI always compute the same names.
  unique_suffix = substr(sha1("${var.subscription_id}-${var.student_initials}"), 0, 4)

  resource_group_name = "rg-${local.name_base}"
  acr_name            = "acr${replace(local.name_base, "-", "")}${local.unique_suffix}"
  service_plan_name   = "asp-${local.name_base}"
  identity_name       = "id-${local.name_base}-webapps"
  backend_app_name    = "${var.project_name}-api-${var.student_initials}-${var.environment}-${local.unique_suffix}"
  frontend_app_name   = "${var.project_name}-ui-${var.student_initials}-${var.environment}-${local.unique_suffix}"

  tags = {
    project     = var.project_name
    environment = var.environment
    owner       = var.student_initials
    course      = "UTCN Cloud Computing P1"
    managed_by  = "terraform"
  }
}
