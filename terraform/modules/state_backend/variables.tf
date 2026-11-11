variable "project_name" { type = string }

variable "bucket_name" {
  description = "Nom du bucket du state. Vide = <project_name>-tfstate-<ID du compte> (unicité globale S3)."
  type        = string
  default     = ""
  validation {
    condition     = !strcontains(var.bucket_name, "pg-backups")
    error_message = "Le bucket du state doit être distinct du bucket des sauvegardes PostgreSQL."
  }
}

variable "state_keys" {
  description = "Clés des states autorisés par les politiques IAM (= key du backend s3)."
  type        = list(string)
  validation {
    condition = length(var.state_keys) > 0 && alltrue([
      for k in var.state_keys : can(regex("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\\.tfstate$", k))
    ])
    error_message = "state_keys : chemins sans / initial, terminés par .tfstate, sans joker."
  }
}

variable "noncurrent_retention_days" {
  description = "Âge minimal (jours) d'une version ancienne avant suppression par le cycle de vie."
  type        = number
  default     = 90
  validation {
    condition     = var.noncurrent_retention_days >= 30
    error_message = "Conserver les anciennes versions du state au moins 30 jours."
  }
}

variable "noncurrent_versions_kept" {
  description = "Nombre de versions anciennes toujours conservées, quel que soit leur âge."
  type        = number
  default     = 50
  validation {
    condition     = var.noncurrent_versions_kept >= 10 && var.noncurrent_versions_kept <= 100
    error_message = "noncurrent_versions_kept doit être compris entre 10 et 100 (limite S3)."
  }
}

variable "create_iam_policies" {
  description = "Crée les politiques IAM state-rw, state-ro et state-recovery (non attachées)."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
