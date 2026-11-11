resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpc"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-igw"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Sous-réseau public : frontend (+ NAT Gateway si activée)
# -----------------------------------------------------------------------------
# Pas d'IP publique automatique : seule l'Elastic IP du frontend est publique.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-${var.availability_zone}"
    Tier = "public"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-rt"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Sous-réseau privé : backend + database (même AZ que le volume EBS PostgreSQL)
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-${var.availability_zone}"
    Tier = "private"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# Aucune route vers l'IGW. La route par défaut n'existe qu'en mode
# nat_gateway (ressource aws_route séparée : changer de mode ne remplace pas
# la table).
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-rt"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# Egress des instances privées — mode "nat_gateway"
# -----------------------------------------------------------------------------
# Pas de prevent_destroy : ressources non critiques, supprimées si l'on
# change de mode.
resource "aws_eip" "nat" {
  count  = var.private_egress_mode == "nat_gateway" ? 1 : 0
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat-eip"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count         = var.private_egress_mode == "nat_gateway" ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_default_nat" {
  count                  = var.private_egress_mode == "nat_gateway" ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

# -----------------------------------------------------------------------------
# VPC Endpoints
# -----------------------------------------------------------------------------
# Gateway S3 : gratuit, toujours créé. Utile à l'agent SSM (mises à jour,
# logs de session S3) et à ECR si utilisé ; évite aussi des frais de NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpce-s3"
  })
}

# Mode "vpc_endpoints" : SSM sans Internet. Interface endpoints payants
# (par heure, par AZ, + données).
resource "aws_security_group" "vpc_endpoints" {
  count       = var.private_egress_mode == "vpc_endpoints" ? 1 : 0
  name        = "${var.project_name}-sg-vpc-endpoints"
  description = "Interface VPC endpoints - HTTPS depuis le VPC uniquement"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.project_name}-sg-vpc-endpoints" })
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  count             = var.private_egress_mode == "vpc_endpoints" ? 1 : 0
  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS depuis le VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.private_egress_mode == "vpc_endpoints" ? toset(var.interface_endpoint_services) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpce-${each.value}"
  })
}
