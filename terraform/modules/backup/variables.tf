variable "project_name" { type = string }

variable "bucket_name" {
  description = "Nom du bucket. Vide = <project_name>-pg-backups-<ID du compte> (unicité globale S3)."
  type        = string
  default     = ""
}

variable "backup_prefix" {
  description = "Préfixe des sauvegardes (= postgresql_backup_prefix côté Ansible)."
  type        = string
}

variable "daily_retention_days" {
  type    = number
  default = 7
}

variable "weekly_retention_days" {
  type    = number
  default = 28
}

variable "noncurrent_retention_days" {
  description = "Conservation des versions écrasées ou supprimées (récupération après erreur)."
  type        = number
  default     = 7
}

variable "s3_vpc_endpoint_id" {
  description = "Endpoint S3 Gateway du VPC : seule origine autorisée pour l'écriture des sauvegardes."
  type        = string
}

variable "enforce_conditional_writes" {
  description = "Refuse tout PutObject sans If-None-Match (clé de condition s3:if-none-match)."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
