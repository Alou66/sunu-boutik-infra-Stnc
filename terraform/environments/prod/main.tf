provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project_name                = var.project_name
  aws_region                  = var.aws_region
  vpc_cidr                    = var.vpc_cidr
  public_subnet_cidr          = var.public_subnet_cidr
  private_subnet_cidr         = var.private_subnet_cidr
  availability_zone           = var.availability_zone
  private_egress_mode         = var.private_egress_mode
  interface_endpoint_services = var.interface_endpoint_services
  tags                        = var.tags
}

module "security_groups" {
  source = "../../modules/security_groups"

  project_name        = var.project_name
  vpc_id              = module.vpc.vpc_id
  allowed_ssh_cidr    = var.allowed_ssh_cidr
  backend_smtp_egress = var.backend_smtp_egress
  tags                = var.tags
}

module "iam_ssm" {
  source = "../../modules/iam_ssm"

  project_name = var.project_name
  tags         = var.tags
}

# Sauvegardes PostgreSQL (bucket S3 + rôle IAM dédié à database).
# Désactivé par défaut : l'activer remplace, sans recréer l'instance, le
# profil IAM de database par un profil SSM + sauvegardes.
module "backup" {
  source = "../../modules/backup"
  count  = var.backup_enabled ? 1 : 0

  project_name          = var.project_name
  bucket_name           = var.backup_bucket_name
  backup_prefix         = var.backup_prefix
  daily_retention_days  = var.backup_daily_retention_days
  weekly_retention_days = var.backup_weekly_retention_days
  s3_vpc_endpoint_id    = module.vpc.s3_vpc_endpoint_id
  tags                  = var.tags
}

module "ec2" {
  source = "../../modules/ec2"

  project_name          = var.project_name
  public_subnet_id      = module.vpc.public_subnet_id
  private_subnet_id     = module.vpc.private_subnet_id
  key_name              = var.key_name
  ami_id                = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu.id
  availability_zone     = var.availability_zone
  instance_profile_name = module.iam_ssm.instance_profile_name

  database_instance_profile_name = one(module.backup[*].database_instance_profile_name)

  sg_frontend_id = module.security_groups.sg_frontend_id
  sg_backend_id  = module.security_groups.sg_backend_id
  sg_database_id = module.security_groups.sg_database_id

  instance_type_frontend = var.instance_type_frontend
  instance_type_backend  = var.instance_type_backend
  instance_type_database = var.instance_type_database

  volume_size_frontend      = var.volume_size_frontend
  volume_size_backend       = var.volume_size_backend
  volume_size_database_root = var.volume_size_database_root
  volume_size_database      = var.volume_size_database
  volume_type               = var.volume_type
  termination_protection    = var.termination_protection

  tags = var.tags
}
