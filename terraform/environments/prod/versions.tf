terraform {
  # use_lockfile (verrou natif S3, sans DynamoDB) : Terraform >= 1.11
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # State distant : bucket dédié créé au préalable par terraform/bootstrap
  # (versionné, SSE-S3, accès public bloqué, suppression refusée). Le nom du
  # bucket (contient l'ID du compte) est fourni à l'init, jamais versionné :
  #   terraform init -backend-config=backend.s3.tfbackend
  # Aucun identifiant ici : chaîne standard AWS (AWS_PROFILE, SSO...).
  # Procédures : terraform/docs/STATE_BACKEND.md
  backend "s3" {
    key          = "sunu-boutik/prod/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}
