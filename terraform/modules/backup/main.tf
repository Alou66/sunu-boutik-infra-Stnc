# Sauvegardes PostgreSQL : bucket S3 privé + rôle IAM dédié à l'instance
# database. Les sauvegardes sont chiffrées côté client (age) AVANT l'envoi ;
# le bucket ajoute SSE-S3, le versioning et la rétention par cycle de vie.
#
# L'instance ne peut ni supprimer ni lister hors de son préfixe : la
# rétention est appliquée par S3 (cycle de vie), jamais par le serveur.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : "${var.project_name}-pg-backups-${data.aws_caller_identity.current.account_id}"
  bucket_arn  = "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}"
  prefix      = trimsuffix(var.backup_prefix, "/")
}

resource "aws_s3_bucket" "backups" {
  bucket        = local.bucket_name
  force_destroy = false

  tags = merge(var.tags, {
    Name = local.bucket_name
    Role = "database-backups"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACL désactivées : le compte propriétaire du bucket possède tous les objets.
resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Un écrasement ou une suppression accidentels laissent une version
# récupérable pendant noncurrent_retention_days.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Rétention : une sauvegarde par jour, conservée daily_retention_days
# (soit au moins 7 sauvegardes quotidiennes), et une par semaine conservée
# weekly_retention_days (au moins 4 hebdomadaires). S3 arrondit l'expiration
# au minuit UTC suivant.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "daily"
    status = "Enabled"
    filter {
      prefix = "${local.prefix}/daily/"
    }
    expiration {
      days = var.daily_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "weekly"
    status = "Enabled"
    filter {
      prefix = "${local.prefix}/weekly/"
    }
    expiration {
      days = var.weekly_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  # Marqueurs de suppression orphelins laissés par l'expiration versionnée.
  rule {
    id     = "delete-markers"
    status = "Enabled"
    filter {
      prefix = "${local.prefix}/"
    }
    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.backups]
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

  # Écriture uniquement depuis le VPC (endpoint S3 Gateway), même avec des
  # identifiants valides utilisés ailleurs.
  statement {
    sid       = "DenyWritesOutsideVpc"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceVpce"
      values   = [var.s3_vpc_endpoint_id]
    }
  }

  # Aucune suppression manuelle (la rétention est faite par le cycle de vie,
  # non soumis à cette politique). Lever ce refus impose de modifier la
  # politique du bucket : action délibérée et tracée dans CloudTrail.
  statement {
    sid       = "DenyObjectDeletion"
    effect    = "Deny"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["${local.bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enforce_conditional_writes ? [1] : []
    content {
      sid       = "DenyOverwrite"
      effect    = "Deny"
      actions   = ["s3:PutObject"]
      resources = ["${local.bucket_arn}/*"]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = "Null"
        variable = "s3:if-none-match"
        values   = ["true"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# -----------------------------------------------------------------------------
# Rôle IAM de l'instance database : SSM (comme les autres instances) +
# sauvegardes, limité au préfixe. Frontend et backend n'ont aucun accès.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "database" {
  name               = "${var.project_name}-ec2-database"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "database_ssm_core" {
  role       = aws_iam_role.database.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "database_backup" {
  # Liste limitée au préfixe des sauvegardes (status, --latest).
  statement {
    sid       = "ListBackupPrefix"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.prefix}/*"]
    }
  }

  # Dépôt des nouvelles sauvegardes uniquement sous daily/ et weekly/.
  statement {
    sid     = "PutBackups"
    actions = ["s3:PutObject"]
    resources = [
      "${local.bucket_arn}/${local.prefix}/daily/*",
      "${local.bucket_arn}/${local.prefix}/weekly/*",
    ]
  }

  # Lecture (HeadObject après envoi, vérification, restauration). Les
  # objets étant chiffrés par age, cette lecture ne donne pas accès aux
  # données sans la clé privée, absente du serveur.
  statement {
    sid       = "ReadBackups"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/${local.prefix}/*"]
  }
}

resource "aws_iam_role_policy" "database_backup" {
  name   = "postgresql-backups"
  role   = aws_iam_role.database.id
  policy = data.aws_iam_policy_document.database_backup.json
}

resource "aws_iam_instance_profile" "database" {
  name = "${var.project_name}-ec2-database"
  role = aws_iam_role.database.name

  tags = var.tags
}
