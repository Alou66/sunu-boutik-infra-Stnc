variable "project_name" { type = string }
variable "aws_region" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidr" { type = string }
variable "private_subnet_cidr" { type = string }
variable "availability_zone" { type = string }

variable "private_egress_mode" {
  type = string
  validation {
    condition     = contains(["nat_gateway", "vpc_endpoints", "none"], var.private_egress_mode)
    error_message = "private_egress_mode doit valoir nat_gateway, vpc_endpoints ou none."
  }
}

variable "interface_endpoint_services" {
  type    = list(string)
  default = ["ssm", "ssmmessages", "ec2messages"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
