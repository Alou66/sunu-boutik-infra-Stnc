# Tests hors ligne du module state_backend : provider AWS simulé
# (mock_provider), aucun identifiant ni appel à AWS.
# Lancer : terraform init -backend=false && terraform test
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
  project_name = "sunu-boutik"
  state_keys   = ["sunu-boutik/prod/terraform.tfstate"]
}

run "bucket_prive_versionne_chiffre" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "sunu-boutik-tfstate-111122223333"
    error_message = "Nom de bucket par défaut inattendu."
  }
  assert {
    condition     = !strcontains(aws_s3_bucket.state.bucket, "pg-backups")
    error_message = "Le bucket du state doit être distinct de celui des sauvegardes."
  }
  assert {
    condition     = aws_s3_bucket.state.force_destroy == false
    error_message = "force_destroy doit rester désactivé."
  }
  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "Tout accès public doit être bloqué."
  }
  assert {
    condition     = one(aws_s3_bucket_ownership_controls.state.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "Les ACL doivent être désactivées."
  }
  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "Le versioning doit être activé."
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "SSE-S3 attendu."
  }
}

run "versions_anciennes_conservees" {
  command = plan

  assert {
    condition = [
      for r in aws_s3_bucket_lifecycle_configuration.state.rule :
      one(r.noncurrent_version_expiration) if r.id == "noncurrent-versions"
      ] == [{
        noncurrent_days           = 90
        newer_noncurrent_versions = 50
    }]
    error_message = "Rétention attendue : 50 versions anciennes et 90 jours minimum."
  }
  assert {
    condition = [
      for r in aws_s3_bucket_lifecycle_configuration.state.rule : r.id if length(r.expiration) > 0
    ] == ["delete-markers"]
    error_message = "Seuls les marqueurs de suppression orphelins peuvent expirer."
  }
  assert {
    condition = [
      for r in aws_s3_bucket_lifecycle_configuration.state.rule :
      one(r.expiration).expired_object_delete_marker if r.id == "delete-markers"
    ] == [true]
    error_message = "La version courante du state ne doit jamais expirer."
  }
}

run "politique_bucket_refus" {
  command = plan

  assert {
    condition = toset([
      for s in data.aws_iam_policy_document.bucket.statement : s.sid if s.effect == "Deny"
    ]) == toset(["DenyInsecureTransport", "DenyStateDeletion", "DenyVersionDeletion", "DenyBucketDeletion"])
    error_message = "Refus attendus : HTTP, suppression du state, des versions et du bucket."
  }
  assert {
    condition = flatten([
      for s in data.aws_iam_policy_document.bucket.statement : s.resources if s.sid == "DenyStateDeletion"
    ]) == ["arn:aws:s3:::sunu-boutik-tfstate-111122223333/*.tfstate"]
    error_message = "Le refus de suppression ne doit pas viser le .tflock (libération du verrou)."
  }
}

run "iam_rw_moindre_privilege" {
  command = plan

  assert {
    condition = sort(flatten([
      for s in data.aws_iam_policy_document.state_rw.statement : s.actions if s.sid == "ListStateBucket"
    ])) == sort(["s3:ListBucket"])
    error_message = "ListStateBucket : actions inattendues."
  }
  assert {
    condition = flatten([
      for s in data.aws_iam_policy_document.state_rw.statement : s.resources if s.sid == "ListStateBucket"
    ]) == ["arn:aws:s3:::sunu-boutik-tfstate-111122223333"]
    error_message = "ListStateBucket : ressource inattendue."
  }
  assert {
    condition = sort(flatten([
      for s in data.aws_iam_policy_document.state_rw.statement : s.actions if s.sid == "ReadWriteState"
    ])) == sort(["s3:GetObject", "s3:PutObject"])
    error_message = "ReadWriteState : actions inattendues."
  }
  assert {
    condition = flatten([
      for s in data.aws_iam_policy_document.state_rw.statement : s.resources if s.sid == "ReadWriteState"
    ]) == ["arn:aws:s3:::sunu-boutik-tfstate-111122223333/sunu-boutik/prod/terraform.tfstate"]
    error_message = "ReadWriteState : ressource inattendue."
  }
  assert {
    condition = sort(flatten([
      for s in data.aws_iam_policy_document.state_rw.statement : s.actions if s.sid == "ManageLockFile"
    ])) == sort(["s3:GetObject", "s3:PutObject", "s3:DeleteObject"])
    error_message = "ManageLockFile : actions inattendues."
  }
  assert {
    condition = flatten([
      for s in data.aws_iam_policy_document.state_rw.statement : s.resources if s.sid == "ManageLockFile"
    ]) == ["arn:aws:s3:::sunu-boutik-tfstate-111122223333/sunu-boutik/prod/terraform.tfstate.tflock"]
    error_message = "ManageLockFile : ressource inattendue."
  }
  assert {
    condition     = length(data.aws_iam_policy_document.state_rw.statement) == 3
    error_message = "state-rw : seules les permissions du backend S3 + use_lockfile sont attendues."
  }
}

run "iam_ro_et_recovery" {
  command = plan

  assert {
    condition = sort(flatten([
      for s in data.aws_iam_policy_document.state_ro.statement : s.actions
    ])) == sort(["s3:GetObject", "s3:ListBucket"])
    error_message = "state-ro ne doit permettre aucune écriture."
  }
  assert {
    condition = sort(flatten([
      for s in data.aws_iam_policy_document.state_recovery.statement : s.actions
    ])) == sort(["s3:GetObjectVersion", "s3:ListBucketVersions"])
    error_message = "state-recovery : lecture des versions uniquement."
  }
  assert {
    condition = alltrue(flatten([
      for d in [data.aws_iam_policy_document.state_rw, data.aws_iam_policy_document.state_ro, data.aws_iam_policy_document.state_recovery] : [
        for s in d.statement : [
          for a in s.actions : !strcontains(a, "*") && a != "s3:DeleteObjectVersion"
        ]
      ]
    ]))
    error_message = "Aucun joker d'action ni suppression de version dans les politiques proposées."
  }
  assert {
    condition = alltrue(flatten([
      for d in [data.aws_iam_policy_document.state_rw, data.aws_iam_policy_document.state_ro, data.aws_iam_policy_document.state_recovery] : [
        for s in d.statement : [
          for r in s.resources : r == "arn:aws:s3:::sunu-boutik-tfstate-111122223333" || startswith(r, "arn:aws:s3:::sunu-boutik-tfstate-111122223333/sunu-boutik/prod/terraform.tfstate")
        ]
      ]
    ]))
    error_message = "Aucune permission hors du bucket et de la clé du state."
  }
  assert {
    condition     = length(aws_iam_policy.state_rw) == 1 && length(aws_iam_policy.state_ro) == 1 && length(aws_iam_policy.state_recovery) == 1
    error_message = "Les trois politiques IAM doivent être proposées."
  }
}

run "politiques_iam_optionnelles" {
  command = plan
  variables {
    create_iam_policies = false
  }
  assert {
    condition     = length(aws_iam_policy.state_rw) + length(aws_iam_policy.state_ro) + length(aws_iam_policy.state_recovery) == 0
    error_message = "Aucune politique IAM attendue si create_iam_policies = false."
  }
}

run "bucket_sauvegardes_refuse" {
  command = plan
  variables {
    bucket_name = "sunu-boutik-pg-backups-111122223333"
  }
  expect_failures = [var.bucket_name]
}

run "cle_avec_joker_refusee" {
  command = plan
  variables {
    state_keys = ["sunu-boutik/*"]
  }
  expect_failures = [var.state_keys]
}

run "retention_minimale_imposee" {
  command = plan
  variables {
    noncurrent_retention_days = 7
  }
  expect_failures = [var.noncurrent_retention_days]
}
