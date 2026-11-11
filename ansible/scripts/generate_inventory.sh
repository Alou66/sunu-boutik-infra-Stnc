#!/bin/bash
# Génère, depuis les outputs Terraform (terraform output -json) :
#   - ansible/inventory/hosts.ini                    (connexion aux 3 EC2)
#   - ansible/inventory/group_vars/all/terraform.yml (IP privées, EIP, volume EBS)
# Aucune IP codée en dur : tout provient du state Terraform.
#
# Usage :
#   ./ansible/scripts/generate_inventory.sh            # mode ssm (défaut)
#   CONNECTION_MODE=bastion ./ansible/scripts/generate_inventory.sh
#   SSH_KEY=~/.ssh/ma-cle.pem ./ansible/scripts/generate_inventory.sh
#
# Modes de connexion :
#   ssm     : SSH encapsulé dans AWS Systems Manager (AWS-StartSSHSession).
#             Aucun port 22 ouvert nécessaire. Prérequis poste opérateur :
#             AWS CLI v2 + session-manager-plugin + droit ssm:StartSession.
#   bastion : SSH direct sur le frontend (allowed_ssh_cidr /32), rebond
#             vers backend et database par leur IP privée.
#
# Prérequis : Terraform appliqué dans terraform/environments/prod, jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/environments/prod"
INVENTORY_FILE="$REPO_ROOT/ansible/inventory/hosts.ini"
TF_VARS_FILE="$REPO_ROOT/ansible/inventory/group_vars/all/terraform.yml"
CONNECTION_MODE="${CONNECTION_MODE:-ssm}"
SSH_KEY="${SSH_KEY:-~/.ssh/your-key.pem}"

case "$CONNECTION_MODE" in
  ssm|bastion) ;;
  *) echo "ERREUR : CONNECTION_MODE doit valoir ssm ou bastion." >&2; exit 1 ;;
esac

cd "$TF_DIR"

TF_OUTPUTS="$(terraform output -json 2>/dev/null || true)"
if [ -z "$TF_OUTPUTS" ] || [ "$TF_OUTPUTS" = "{}" ]; then
  echo "ERREUR : aucun output Terraform dans $TF_DIR (apply non effectué ?)." >&2
  exit 1
fi

out() { echo "$TF_OUTPUTS" | jq -r --arg k "$1" '.[$k].value // empty'; }

AWS_REGION="$(out aws_region)"
FRONTEND_PUBLIC="$(out frontend_public_ip)"
FRONTEND_PRIVATE="$(out frontend_private_ip)"
BACKEND_PRIVATE="$(out backend_private_ip)"
DATABASE_PRIVATE="$(out database_private_ip)"
FRONTEND_ID="$(out frontend_instance_id)"
BACKEND_ID="$(out backend_instance_id)"
DATABASE_ID="$(out database_instance_id)"
PG_VOLUME_ID="$(out postgres_data_volume_id)"
# Vide si backup_enabled = false côté Terraform
PG_BACKUP_BUCKET="$(out postgres_backup_bucket)"
AWS_REGION_OUT="$(out aws_region)"
SSH_ENABLED="$(out ssh_enabled)"

missing=0
for name in AWS_REGION FRONTEND_PUBLIC FRONTEND_PRIVATE BACKEND_PRIVATE DATABASE_PRIVATE \
            FRONTEND_ID BACKEND_ID DATABASE_ID PG_VOLUME_ID; do
  if [ -z "${!name}" ]; then
    echo "ERREUR : output Terraform manquant pour $name" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

if [ "$CONNECTION_MODE" = "bastion" ] && [ "$SSH_ENABLED" != "true" ]; then
  echo "ERREUR : mode bastion impossible, allowed_ssh_cidr n'est pas défini dans Terraform." >&2
  exit 1
fi

if [ "$CONNECTION_MODE" = "ssm" ]; then
  command -v aws >/dev/null || echo "ATTENTION : AWS CLI introuvable (requis en mode ssm)." >&2
  command -v session-manager-plugin >/dev/null \
    || echo "ATTENTION : session-manager-plugin introuvable (requis en mode ssm)." >&2

  # %h = ID d'instance (ansible_host), %p = port SSH
  PROXY="-o ProxyCommand=\"aws ssm start-session --region $AWS_REGION --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p\""
  FRONTEND_LINE="sunu-boutik-frontend ansible_host=$FRONTEND_ID ansible_ssh_common_args='$PROXY'"
  BACKEND_LINE="sunu-boutik-backend ansible_host=$BACKEND_ID ansible_ssh_common_args='$PROXY'"
  DATABASE_LINE="sunu-boutik-database ansible_host=$DATABASE_ID ansible_ssh_common_args='$PROXY'"
else
  # ProxyCommand plutôt que ProxyJump : la clé doit aussi servir au rebond
  PROXY="-o ProxyCommand=\"ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new -W %h:%p -q ubuntu@$FRONTEND_PUBLIC\""
  FRONTEND_LINE="sunu-boutik-frontend ansible_host=$FRONTEND_PUBLIC"
  BACKEND_LINE="sunu-boutik-backend ansible_host=$BACKEND_PRIVATE ansible_ssh_common_args='$PROXY'"
  DATABASE_LINE="sunu-boutik-database ansible_host=$DATABASE_PRIVATE ansible_ssh_common_args='$PROXY'"
fi

GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "$INVENTORY_FILE" <<EOF
# Inventaire généré automatiquement depuis Terraform outputs ($CONNECTION_MODE)
# Généré le $GENERATED_AT
# Ne pas modifier à la main : relancer generate_inventory.sh après un terraform apply

[frontend]
$FRONTEND_LINE
# EC2 ID : $FRONTEND_ID

[backend]
$BACKEND_LINE
# EC2 ID : $BACKEND_ID

[database]
$DATABASE_LINE
# EC2 ID : $DATABASE_ID

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=$SSH_KEY
ansible_python_interpreter=/usr/bin/python3
EOF

cat > "$TF_VARS_FILE" <<EOF
---
# Généré par scripts/generate_inventory.sh le $GENERATED_AT
# depuis les outputs Terraform. Ne pas modifier à la main.
frontend_public_ip: "$FRONTEND_PUBLIC"
frontend_private_ip: "$FRONTEND_PRIVATE"
backend_private_ip: "$BACKEND_PRIVATE"
database_private_ip: "$DATABASE_PRIVATE"
# Nitro : le disque est retrouvé via /dev/disk/by-id grâce à son ID
postgresql_data_volume_id: "$PG_VOLUME_ID"
# Sauvegardes PostgreSQL (rôle postgresql_backup) ; vide = bucket non créé
postgresql_backup_bucket: "$PG_BACKUP_BUCKET"
postgresql_backup_region: "${AWS_REGION_OUT:-eu-north-1}"
EOF

echo "Inventaire écrit dans $INVENTORY_FILE (mode $CONNECTION_MODE)"
echo "Variables écrites dans $TF_VARS_FILE"
echo "  frontend : $FRONTEND_PUBLIC (privé : $FRONTEND_PRIVATE, $FRONTEND_ID)"
echo "  backend  : $BACKEND_PRIVATE ($BACKEND_ID)"
echo "  database : $DATABASE_PRIVATE ($DATABASE_ID, volume $PG_VOLUME_ID)"
