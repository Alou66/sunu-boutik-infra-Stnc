# Règles en ressources séparées (aws_vpc_security_group_*_rule) : les SG se
# référencent mutuellement (egress frontend -> backend, ingress backend <-
# frontend), ce qui créerait un cycle avec des blocs inline.
#
# Aucune règle egress "all" : Terraform supprime la règle par défaut
# d'AWS à la création, seules les règles ci-dessous existent.
#
# Descriptions en ASCII uniquement (contrainte AWS). Ne pas modifier la
# description d'un SG existant : cela force son remplacement.

locals {
  ssh_enabled = var.allowed_ssh_cidr != null
}

resource "aws_security_group" "frontend" {
  name        = "${var.project_name}-sg-frontend"
  description = "Frontend - HTTP/HTTPS depuis Internet, SSH admin restreint"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.project_name}-sg-frontend" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_security_group" "backend" {
  name        = "${var.project_name}-sg-backend"
  description = "Backend - API 8000 depuis le SG frontend uniquement"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.project_name}-sg-backend" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_security_group" "database" {
  name        = "${var.project_name}-sg-database"
  description = "Database - PostgreSQL 5432 depuis le SG backend uniquement"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.project_name}-sg-database" })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Frontend
# -----------------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "frontend_http" {
  security_group_id = aws_security_group.frontend.id
  description       = "HTTP depuis Internet (redirection + ACME HTTP-01)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "frontend_https" {
  security_group_id = aws_security_group.frontend.id
  description       = "HTTPS depuis Internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "frontend_ssh_admin" {
  count             = local.ssh_enabled ? 1 : 0
  security_group_id = aws_security_group.frontend.id
  description       = "SSH depuis le poste administrateur uniquement"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.allowed_ssh_cidr
}

# apt (HTTP), Docker/GHCR/Let's Encrypt/SSM (HTTPS)
resource "aws_vpc_security_group_egress_rule" "frontend_http_out" {
  security_group_id = aws_security_group.frontend.id
  description       = "HTTP sortant (depots apt Ubuntu)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "frontend_https_out" {
  security_group_id = aws_security_group.frontend.id
  description       = "HTTPS sortant (Docker, GHCR, ACME, SSM)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "frontend_to_backend_api" {
  security_group_id            = aws_security_group.frontend.id
  description                  = "Nginx vers API backend"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  referenced_security_group_id = aws_security_group.backend.id
}

# Rebond SSH (ProxyJump) vers les instances privées : uniquement si SSH activé
resource "aws_vpc_security_group_egress_rule" "frontend_ssh_to_backend" {
  count                        = local.ssh_enabled ? 1 : 0
  security_group_id            = aws_security_group.frontend.id
  description                  = "Rebond SSH vers backend"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.backend.id
}

resource "aws_vpc_security_group_egress_rule" "frontend_ssh_to_database" {
  count                        = local.ssh_enabled ? 1 : 0
  security_group_id            = aws_security_group.frontend.id
  description                  = "Rebond SSH vers database"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.database.id
}

# -----------------------------------------------------------------------------
# Backend
# -----------------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "backend_api_from_frontend" {
  security_group_id            = aws_security_group.backend.id
  description                  = "API depuis le SG frontend"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  referenced_security_group_id = aws_security_group.frontend.id
}

resource "aws_vpc_security_group_ingress_rule" "backend_ssh_from_frontend" {
  count                        = local.ssh_enabled ? 1 : 0
  security_group_id            = aws_security_group.backend.id
  description                  = "SSH par rebond depuis le frontend"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.frontend.id
}

resource "aws_vpc_security_group_egress_rule" "backend_http_out" {
  security_group_id = aws_security_group.backend.id
  description       = "HTTP sortant (depots apt Ubuntu, via NAT)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "backend_https_out" {
  security_group_id = aws_security_group.backend.id
  description       = "HTTPS sortant (GHCR, Docker, SSM)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_database" {
  security_group_id            = aws_security_group.backend.id
  description                  = "PostgreSQL vers le SG database"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.database.id
}

# SMTP sortant (Gmail, port 587 STARTTLS) pour les e-mails de l'API
resource "aws_vpc_security_group_egress_rule" "backend_smtp_out" {
  count             = var.backend_smtp_egress ? 1 : 0
  security_group_id = aws_security_group.backend.id
  description       = "SMTP submission 587 (envoi e-mails)"
  ip_protocol       = "tcp"
  from_port         = 587
  to_port           = 587
  cidr_ipv4         = "0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# Database
# -----------------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "database_postgres_from_backend" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL depuis le SG backend"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.backend.id
}

resource "aws_vpc_security_group_ingress_rule" "database_ssh_from_frontend" {
  count                        = local.ssh_enabled ? 1 : 0
  security_group_id            = aws_security_group.database.id
  description                  = "SSH par rebond depuis le frontend"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.frontend.id
}

resource "aws_vpc_security_group_egress_rule" "database_http_out" {
  security_group_id = aws_security_group.database.id
  description       = "HTTP sortant (depots apt Ubuntu, via NAT)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "database_https_out" {
  security_group_id = aws_security_group.database.id
  description       = "HTTPS sortant (SSM, depots apt HTTPS)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
