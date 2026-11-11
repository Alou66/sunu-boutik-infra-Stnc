variable "aws_region" {
  description = "Région AWS (identique au backend de environments/prod)"
  type        = string
  default     = "eu-north-1"
  validation {
    condition     = var.aws_region == "eu-north-1"
    error_message = "Cette infrastructure est prévue pour eu-north-1 uniquement."
  }
}

variable "project_name" {
  description = "Nom du projet"
  type        = string
  default     = "sunu-boutik"
}

variable "state_bucket_name" {
  description = "Nom du bucket du state. Vide = <project_name>-tfstate-<ID du compte>."
  type        = string
  default     = ""
}

variable "state_keys" {
  description = "Clés de state autorisées par les politiques IAM (= key dans environments/prod/versions.tf)."
  type        = list(string)
  default     = ["sunu-boutik/prod/terraform.tfstate"]
}

variable "noncurrent_retention_days" {
  description = "Âge minimal (jours) d'une ancienne version du state avant suppression."
  type        = number
  default     = 90
}

variable "noncurrent_versions_kept" {
  description = "Nombre d'anciennes versions du state toujours conservées."
  type        = number
  default     = 50
}

variable "create_iam_policies" {
  description = "Crée les politiques IAM proposées (state-rw, state-ro, state-recovery), sans les attacher."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags communs"
  type        = map(string)
  default     = {}
}
