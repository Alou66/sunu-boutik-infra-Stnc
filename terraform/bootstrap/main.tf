# Création préalable du bucket du state Terraform (une seule fois, avant
# le premier `terraform init` de environments/prod). Aucune instance EC2
# n'est créée, lue ni référencée ici.
module "state_backend" {
  source = "../modules/state_backend"

  project_name              = var.project_name
  bucket_name               = var.state_bucket_name
  state_keys                = var.state_keys
  noncurrent_retention_days = var.noncurrent_retention_days
  noncurrent_versions_kept  = var.noncurrent_versions_kept
  create_iam_policies       = var.create_iam_policies
  tags                      = var.tags
}
