# Câblage du module backup, hors ligne (provider AWS simulé, aucun appel
# AWS). Lancer : terraform init -backend=false && terraform test
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
}

variables {
  key_name            = "test-key"
  private_egress_mode = "nat_gateway"
}

run "sauvegardes_desactivees_par_defaut" {
  command = plan

  assert {
    condition     = length(module.backup) == 0
    error_message = "Le module backup ne doit rien créer par défaut."
  }
  assert {
    condition     = output.postgres_backup_bucket == null
    error_message = "Aucun bucket attendu quand backup_enabled = false."
  }
}

run "sauvegardes_activees" {
  command = plan
  variables {
    backup_enabled = true
  }

  assert {
    condition     = output.postgres_backup_bucket == "sunu-boutik-pg-backups-111122223333"
    error_message = "Bucket de sauvegarde attendu."
  }
}

run "retention_minimale_imposee" {
  command = plan
  variables {
    backup_enabled              = true
    backup_daily_retention_days = 3
  }
  expect_failures = [var.backup_daily_retention_days]
}
