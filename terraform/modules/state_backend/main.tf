# Bucket S3 dédié EXCLUSIVEMENT au state Terraform (distinct du bucket des
# sauvegardes PostgreSQL du module backup) : privé, versionné, chiffré
# (SSE-S3), protégé contre la suppression. Le verrouillage est assuré par
# le backend lui-même (use_lockfile = true, objet <key>.tflock), sans DynamoDB.
#
# Politiques IAM proposées (créées, jamais attachées ici) :
#   - state-rw       : plan/apply/force-unlock sur le state prod ;
#   - state-ro       : lecture seule (terraform output, generate_inventory.sh) ;
#   - state-recovery : lecture des versions et restauration (break-glass).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
  bucket_arn  = "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}"
  state_arns  = [for k in var.state_keys : "${local.bucket_arn}/${k}"]
  lock_arns   = [for k in var.state_keys : "${local.bucket_arn}/${k}.tflock"]
}

resource "aws_s3_bucket" "state" {
  bucket        = local.bucket_name
  force_destroy = false

  tags = merge(var.tags, {
    Name = local.bucket_name
    Role = "terraform-state"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACL désactivées : le compte propriétaire du bucket possède tous les objets.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Chaque écriture du state crée une version : un state écrasé, corrompu ou
# supprimé se restaure depuis une version précédente (docs/STATE_BACKEND.md).
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 : aucune permission KMS à accorder aux opérateurs.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Les versions anciennes ne sont supprimées que si elles ont plus de
# noncurrent_retention_days jours ET qu'au moins noncurrent_versions_kept
# versions plus récentes existent. Nettoie aussi les versions des .tflock
# (une par plan/apply) et les marqueurs de suppression orphelins.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days           = var.noncurrent_retention_days
      newer_noncurrent_versions = var.noncurrent_versions_kept
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "delete-markers"
    status = "Enabled"
    filter {}
    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Terraform ne supprime jamais un state (hors workspace delete, non
  # utilisé) : toute suppression d'un *.tfstate est une erreur. Le .tflock,
  # lui, doit rester supprimable (libération du verrou).
  statement {
    sid       = "DenyStateDeletion"
    effect    = "Deny"
    actions   = ["s3:DeleteObject"]
    resources = ["${local.bucket_arn}/*.tfstate"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # Aucune version n'est effaçable définitivement à la main (le cycle de vie
  # n'est pas soumis à cette politique).
  statement {
    sid       = "DenyVersionDeletion"
    effect    = "Deny"
    actions   = ["s3:DeleteObjectVersion"]
    resources = ["${local.bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # Supprimer le bucket impose d'abord de retirer cette politique : action
  # délibérée, tracée dans CloudTrail.
  statement {
    sid       = "DenyBucketDeletion"
    effect    = "Deny"
    actions   = ["s3:DeleteBucket"]
    resources = [local.bucket_arn]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# -----------------------------------------------------------------------------
# Politiques IAM proposées : permissions exactes du backend S3 avec
# use_lockfile (developer.hashicorp.com/terraform/language/backend/s3).
# Le bucket étant dédié au state, ListBucket n'expose que des noms de clés.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "state_rw" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }

  statement {
    sid       = "ReadWriteState"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = local.state_arns
  }

  statement {
    sid       = "ManageLockFile"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = local.lock_arns
  }
}

data "aws_iam_policy_document" "state_ro" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }

  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = local.state_arns
  }
}

# À attacher en plus de state-rw, temporairement, pour une restauration.
data "aws_iam_policy_document" "state_recovery" {
  statement {
    sid       = "ListStateVersions"
    actions   = ["s3:ListBucketVersions"]
    resources = [local.bucket_arn]
  }

  statement {
    sid       = "ReadStateVersions"
    actions   = ["s3:GetObjectVersion"]
    resources = local.state_arns
  }
}

resource "aws_iam_policy" "state_rw" {
  count       = var.create_iam_policies ? 1 : 0
  name        = "${var.project_name}-terraform-state-rw"
  description = "Lecture/écriture du state Terraform et du verrou .tflock (${local.bucket_name})"
  policy      = data.aws_iam_policy_document.state_rw.json

  tags = var.tags
}

resource "aws_iam_policy" "state_ro" {
  count       = var.create_iam_policies ? 1 : 0
  name        = "${var.project_name}-terraform-state-ro"
  description = "Lecture seule du state Terraform (${local.bucket_name})"
  policy      = data.aws_iam_policy_document.state_ro.json

  tags = var.tags
}

resource "aws_iam_policy" "state_recovery" {
  count       = var.create_iam_policies ? 1 : 0
  name        = "${var.project_name}-terraform-state-recovery"
  description = "Lecture des versions du state Terraform pour restauration (${local.bucket_name})"
  policy      = data.aws_iam_policy_document.state_recovery.json

  tags = var.tags
}
