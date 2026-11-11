variable "aws_region" {
  description = "Région AWS"
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

variable "vpc_cidr" {
  description = "CIDR du VPC dédié"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR du sous-réseau public (frontend, NAT Gateway)"
  type        = string
  default     = "10.20.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR du sous-réseau privé (backend, database)"
  type        = string
  default     = "10.20.11.0/24"
}

variable "availability_zone" {
  description = "AZ unique (celle du volume EBS PostgreSQL : ne jamais la changer après création)"
  type        = string
  default     = "eu-north-1a"
}

variable "allowed_ssh_cidr" {
  description = "IP administrateur au format /32 pour SSH sur le frontend (rebond vers les instances privées). null = pas de SSH, administration via SSM uniquement."
  type        = string
  default     = null
  validation {
    condition = var.allowed_ssh_cidr == null ? true : (
      can(regex("^(\\d{1,3}\\.){3}\\d{1,3}/32$", var.allowed_ssh_cidr)) &&
      can(cidrhost(var.allowed_ssh_cidr, 0))
    )
    error_message = "allowed_ssh_cidr doit être une adresse IPv4 unique au format /32 (ex. 198.51.100.7/32), ou null."
  }
}

variable "private_egress_mode" {
  description = "Connectivité sortante des instances privées : nat_gateway (apt + GHCR + SSM), vpc_endpoints (SSM seul, pas d'apt ni de GHCR), none (isolées). Aucun défaut : choix explicite requis (impact coût)."
  type        = string
  validation {
    condition     = contains(["nat_gateway", "vpc_endpoints", "none"], var.private_egress_mode)
    error_message = "private_egress_mode doit valoir nat_gateway, vpc_endpoints ou none."
  }
}

variable "interface_endpoint_services" {
  description = "Interface endpoints créés en mode vpc_endpoints"
  type        = list(string)
  default     = ["ssm", "ssmmessages", "ec2messages"]
}

variable "backend_smtp_egress" {
  description = "Autorise le backend à sortir en TCP 587 (SMTP Gmail)"
  type        = bool
  default     = true
}

variable "key_name" {
  description = "Nom de la clé SSH AWS existante (aussi utilisée par SSH-over-SSM)"
  type        = string
}

variable "ami_id" {
  description = "AMI Ubuntu 24.04 LTS figée (recommandé). Vide = dernière AMI Canonical au premier apply."
  type        = string
  default     = ""
}

variable "instance_type_frontend" {
  description = "Type d'instance frontend"
  type        = string
  default     = "t3.small"
}

variable "instance_type_backend" {
  description = "Type d'instance backend"
  type        = string
  default     = "t3.small"
}

variable "instance_type_database" {
  description = "Type d'instance database"
  type        = string
  default     = "t3.small"
}

variable "volume_size_frontend" {
  description = "Taille du volume racine frontend (Go)"
  type        = number
  default     = 20
}

variable "volume_size_backend" {
  description = "Taille du volume racine backend (Go)"
  type        = number
  default     = 20
}

variable "volume_size_database_root" {
  description = "Taille du volume racine database (Go)"
  type        = number
  default     = 20
}

variable "volume_size_database" {
  description = "Taille du volume EBS dédié aux données PostgreSQL (Go). Agrandissable sans remplacement, jamais réductible."
  type        = number
  default     = 30
  validation {
    condition     = var.volume_size_database >= 30
    error_message = "Le volume PostgreSQL doit faire au moins 30 Go."
  }
}

variable "volume_type" {
  description = "Type de volume EBS"
  type        = string
  default     = "gp3"
}

variable "termination_protection" {
  description = "Active disable_api_termination sur les trois instances"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags communs"
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Sauvegardes PostgreSQL (module backup, voir ansible/docs/BACKUP_RESTORE.md)
# -----------------------------------------------------------------------------
variable "backup_enabled" {
  description = "Crée le bucket S3 des sauvegardes et le rôle IAM dédié à l'instance database."
  type        = bool
  default     = false
}

variable "backup_bucket_name" {
  description = "Nom du bucket des sauvegardes. Vide = <project_name>-pg-backups-<ID du compte>."
  type        = string
  default     = ""
}

variable "backup_prefix" {
  description = "Préfixe des sauvegardes dans le bucket (= postgresql_backup_prefix côté Ansible)."
  type        = string
  default     = "postgresql/sunuboutik"
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$", var.backup_prefix))
    error_message = "backup_prefix : segments [A-Za-z0-9._-] séparés par /, sans / initial ni final."
  }
}

variable "backup_daily_retention_days" {
  description = "Durée de conservation des sauvegardes quotidiennes (jours)."
  type        = number
  default     = 7
  validation {
    condition     = var.backup_daily_retention_days >= 7
    error_message = "Au moins 7 sauvegardes quotidiennes doivent être conservées."
  }
}

variable "backup_weekly_retention_days" {
  description = "Durée de conservation des sauvegardes hebdomadaires (jours)."
  type        = number
  default     = 28
  validation {
    condition     = var.backup_weekly_retention_days >= 28
    error_message = "Au moins 4 sauvegardes hebdomadaires (28 jours) doivent être conservées."
  }
}
