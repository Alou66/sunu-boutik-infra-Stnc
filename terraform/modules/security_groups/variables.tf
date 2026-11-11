variable "project_name" { type = string }
variable "vpc_id" { type = string }

# null = aucune règle SSH (administration via SSM uniquement)
variable "allowed_ssh_cidr" {
  type    = string
  default = null
}

variable "backend_smtp_egress" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
