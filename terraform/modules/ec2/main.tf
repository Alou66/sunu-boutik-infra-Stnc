# Protections contre le remplacement accidentel :
# - prevent_destroy : tout plan qui détruirait l'instance échoue ;
# - ignore_changes = [ami] : la data source "most_recent" renverrait une
#   nouvelle AMI à chaque publication Canonical, ce qui forcerait un
#   remplacement (bloqué par prevent_destroy, donc plan en erreur) ;
# - disable_api_termination : protection côté AWS (console/CLI).
# Attributs qui forcent un remplacement s'ils changent après création :
# subnet_id, key_name, availability_zone, associate_public_ip_address,
# root_block_device.encrypted, ebs encrypted/availability_zone.

resource "aws_instance" "frontend" {
  ami                         = var.ami_id
  instance_type               = var.instance_type_frontend
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [var.sg_frontend_id]
  key_name                    = var.key_name
  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = false # IP publique = Elastic IP ci-dessous
  disable_api_termination     = var.termination_protection

  metadata_options {
    http_tokens   = "required" # IMDSv2 uniquement
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = var.volume_size_frontend
    volume_type           = var.volume_type
    encrypted             = true
    delete_on_termination = false
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-frontend"
    Role = "frontend"
  })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami]
  }
}

# IP publique stable : l'enregistrement DNS sunu-boutique.online ne change
# pas en cas d'arrêt/redémarrage de l'instance.
resource "aws_eip" "frontend" {
  domain   = "vpc"
  instance = aws_instance.frontend.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-frontend-eip"
    Role = "frontend"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "backend" {
  ami                         = var.ami_id
  instance_type               = var.instance_type_backend
  subnet_id                   = var.private_subnet_id
  vpc_security_group_ids      = [var.sg_backend_id]
  key_name                    = var.key_name
  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = false
  disable_api_termination     = var.termination_protection

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = var.volume_size_backend
    volume_type           = var.volume_type
    encrypted             = true
    delete_on_termination = false
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-backend"
    Role = "backend"
  })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami]
  }
}

resource "aws_instance" "database" {
  ami                         = var.ami_id
  instance_type               = var.instance_type_database
  subnet_id                   = var.private_subnet_id
  vpc_security_group_ids      = [var.sg_database_id]
  key_name                    = var.key_name
  iam_instance_profile        = var.database_instance_profile_name != "" ? var.database_instance_profile_name : var.instance_profile_name
  associate_public_ip_address = false
  disable_api_termination     = var.termination_protection

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = var.volume_size_database_root
    volume_type           = var.volume_type
    encrypted             = true
    delete_on_termination = false
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-database"
    Role = "database"
  })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami]
  }
}

# Volume de données PostgreSQL, indépendant du cycle de vie de l'instance.
# Son AZ est celle du sous-réseau privé : ne jamais la changer (remplacement).
resource "aws_ebs_volume" "postgres_data" {
  availability_zone = var.availability_zone
  size              = var.volume_size_database
  type              = var.volume_type
  encrypted         = true
  final_snapshot    = true # snapshot automatique si le volume est un jour supprimé

  tags = merge(var.tags, {
    Name = "${var.project_name}-postgres-data"
    Role = "database"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "postgres_data" {
  device_name = "/dev/xvdf" # vu comme /dev/nvme1n1 sur Nitro (t3) : Ansible utilise l'ID du volume
  volume_id   = aws_ebs_volume.postgres_data.id
  instance_id = aws_instance.database.id

  # Arrêt propre de l'instance avant tout détachement (évite un démontage à
  # chaud de PostgreSQL)
  stop_instance_before_detaching = true

  lifecycle {
    prevent_destroy = true
  }
}
