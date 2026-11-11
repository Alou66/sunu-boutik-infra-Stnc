variable "project_name" { type = string }
variable "public_subnet_id" { type = string }
variable "private_subnet_id" { type = string }
variable "key_name" { type = string }
variable "ami_id" { type = string }
variable "availability_zone" { type = string }
variable "instance_profile_name" { type = string }
# Profil dédié à l'instance database (sauvegardes S3). Vide = profil commun.
variable "database_instance_profile_name" {
  type     = string
  default  = ""
  nullable = false # null (module backup désactivé) = profil commun
}
variable "sg_frontend_id" { type = string }
variable "sg_backend_id" { type = string }
variable "sg_database_id" { type = string }
variable "instance_type_frontend" { type = string }
variable "instance_type_backend" { type = string }
variable "instance_type_database" { type = string }
variable "volume_size_frontend" { type = number }
variable "volume_size_backend" { type = number }
variable "volume_size_database_root" { type = number }
variable "volume_size_database" { type = number }
variable "volume_type" { type = string }
variable "termination_protection" { type = bool }
variable "tags" {
  type    = map(string)
  default = {}
}
