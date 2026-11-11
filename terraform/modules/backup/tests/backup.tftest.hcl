# Tests hors ligne du module backup : provider AWS simulé (mock_provider),
# aucun identifiant ni appel à AWS. Lancer : terraform init && terraform test
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
}

variables {
  project_name       = "sunu-boutik"
  backup_prefix      = "postgresql/sunuboutik"
  s3_vpc_endpoint_id = "vpce-0123456789abcdef0"
}

run "bucket_prive_versionne_chiffre" {
  command = plan

  assert {
    condition     = aws_s3_bucket.backups.bucket == "sunu-boutik-pg-backups-111122223333"
    error_message = "Nom de bucket par défaut inattendu."
  }
  assert {
    condition     = aws_s3_bucket.backups.force_destroy == false
    error_message = "force_destroy doit rester désactivé."
  }
  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.backups.block_public_acls,
      aws_s3_bucket_public_access_block.backups.block_public_policy,
      aws_s3_bucket_public_access_block.backups.ignore_public_acls,
      aws_s3_bucket_public_access_block.backups.restrict_public_buckets,
    ])
    error_message = "Tout accès public doit être bloqué."
  }
  assert {
    condition     = aws_s3_bucket_versioning.backups.versioning_configuration[0].status == "Enabled"
    error_message = "Le versioning doit être activé."
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.backups.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "SSE-S3 attendu."
  }
}

run "retention_7_quotidiennes_4_hebdomadaires" {
  command = plan

  assert {
    condition = {
      for r in aws_s3_bucket_lifecycle_configuration.backups.rule :
      r.id => r.expiration[0].days if r.id != "delete-markers"
      } == {
      daily  = 7
      weekly = 28
    }
    error_message = "Rétention attendue : daily 7 jours, weekly 28 jours."
  }
  assert {
    condition = [
      for r in aws_s3_bucket_lifecycle_configuration.backups.rule : r.filter[0].prefix
    ] == ["postgresql/sunuboutik/daily/", "postgresql/sunuboutik/weekly/", "postgresql/sunuboutik/"]
    error_message = "Les règles doivent être limitées au préfixe des sauvegardes."
  }
}

run "iam_moindre_privilege" {
  command = plan

  assert {
    condition = sort(flatten([
      for s in data.aws_iam_policy_document.database_backup.statement : s.actions
    ])) == sort(["s3:GetObject", "s3:ListBucket", "s3:PutObject"])
    error_message = "Seules ListBucket, PutObject et GetObject sont autorisées (aucune suppression)."
  }
  assert {
    condition = sort(flatten([
      for s in data.aws_iam_policy_document.database_backup.statement : s.resources if s.sid == "PutBackups"
      ])) == sort([
      "arn:aws:s3:::sunu-boutik-pg-backups-111122223333/postgresql/sunuboutik/daily/*",
      "arn:aws:s3:::sunu-boutik-pg-backups-111122223333/postgresql/sunuboutik/weekly/*",
    ])
    error_message = "PutObject doit être limité à daily/ et weekly/."
  }
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.database_backup.statement :
      alltrue([for r in s.resources : startswith(r, "arn:aws:s3:::sunu-boutik-pg-backups-111122223333")])
    ])
    error_message = "Aucune permission hors du bucket de sauvegarde."
  }
}

run "politique_bucket_refus" {
  command = plan

  assert {
    condition = toset([
      for s in data.aws_iam_policy_document.bucket.statement : s.sid if s.effect == "Deny"
    ]) == toset(["DenyInsecureTransport", "DenyWritesOutsideVpc", "DenyObjectDeletion", "DenyOverwrite"])
    error_message = "Refus attendus : HTTP, écriture hors VPC, suppression, écrasement."
  }
}

run "ecriture_conditionnelle_desactivable" {
  command = plan
  variables {
    enforce_conditional_writes = false
  }
  assert {
    condition     = !contains([for s in data.aws_iam_policy_document.bucket.statement : s.sid], "DenyOverwrite")
    error_message = "DenyOverwrite doit disparaître si enforce_conditional_writes = false."
  }
}
