# Outputs consommés par ansible/scripts/generate_inventory.sh : ne pas
# renommer sans mettre le script à jour.

output "aws_region" {
  value = var.aws_region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_id" {
  value = module.vpc.public_subnet_id
}

output "private_subnet_id" {
  value = module.vpc.private_subnet_id
}

output "private_egress_mode" {
  value = var.private_egress_mode
}

# Seule IP publique de l'architecture (Elastic IP) : cible du DNS
output "frontend_public_ip" {
  value = module.ec2.frontend_public_ip
}

# IP de sortie des instances privées (null hors mode nat_gateway)
output "nat_gateway_public_ip" {
  value = module.vpc.nat_gateway_public_ip
}

output "frontend_instance_id" {
  value = module.ec2.frontend_instance_id
}

output "backend_instance_id" {
  value = module.ec2.backend_instance_id
}

output "database_instance_id" {
  value = module.ec2.database_instance_id
}

output "frontend_private_ip" {
  value = module.ec2.frontend_private_ip
}

output "backend_private_ip" {
  value = module.ec2.backend_private_ip
}

output "database_private_ip" {
  value = module.ec2.database_private_ip
}

output "postgres_data_volume_id" {
  value = module.ec2.postgres_data_volume_id
}

output "ssh_enabled" {
  value = var.allowed_ssh_cidr != null
}

output "ssm_instance_profile" {
  value = module.iam_ssm.instance_profile_name
}

output "security_groups" {
  value = {
    frontend = module.security_groups.sg_frontend_id
    backend  = module.security_groups.sg_backend_id
    database = module.security_groups.sg_database_id
  }
}

# Bucket des sauvegardes PostgreSQL (null si backup_enabled = false),
# consommé par generate_inventory.sh (postgresql_backup_bucket).
output "postgres_backup_bucket" {
  value = one(module.backup[*].bucket_name)
}
