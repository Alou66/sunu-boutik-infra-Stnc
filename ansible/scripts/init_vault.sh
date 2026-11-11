#!/bin/bash
# Script pour créer le vault chiffré Ansible (non commité).
# À exécuter une seule fois, localement, avec un mot de passe fort.
#
# Usage :
#   ./ansible/scripts/init_vault.sh
#   # Saisir un mot de passe fort, le conserver dans ansible/.vault_pass
#
# Le vault contient UNIQUEMENT des variables sensibles :
#   ghcr_username, ghcr_token, db_user, db_password, secret_key,
#   admin_password, smtp_password
# La configuration non sensible (admin_email, frontend_url, cors_origins,
# smtp_user, nginx_certbot_email) est dans group_vars/all/vars.yml et
# group_vars/frontend.yml (voir VAULT_STRUCTURE.md).
#
# Aucun secret réel n'est inscrit : les valeurs sont vides ou placeholder.
# L'utilisateur doit déchiffrer, renseigner ses vrais secrets, et rechiffrer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VAULT_FILE="$REPO_ROOT/ansible/inventory/group_vars/all/vault.yml"
VAULT_PASS="$REPO_ROOT/ansible/.vault_pass"

if ! command -v ansible-vault >/dev/null 2>&1; then
  echo "ERREUR : ansible-vault est requis (installer Ansible >= 2.9)." >&2
  echo "  sudo apt install ansible" >&2
  exit 1
fi

if [ -f "$VAULT_FILE" ]; then
  echo "ATTENTION : $VAULT_FILE existe déjà. Annulation pour éviter l'écrasement." >&2
  exit 1
fi

# Créer le mot de passe (généré aléatoirement)
head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 > "$VAULT_PASS"
chmod 600 "$VAULT_PASS"
echo "Mot de passe vault créé dans $VAULT_PASS (non commité)."

# Créer le vault avec des variables vides (à compléter)
ansible-vault create --vault-password-file "$VAULT_PASS" "$VAULT_FILE" <<'VAULT_EOF'
# Variables sensibles - À RENSEIGNER avec vos vrais secrets
# Ce fichier est chiffré. Ne jamais le déchiffrer en clair dans un contexte non sécurisé.
# Pour modifier : ansible-vault edit --vault-password-file ansible/.vault_pass ansible/inventory/group_vars/all/vault.yml

# Authentification GitHub Container Registry (ghcr.io)
ghcr_username: "CHANGE_ME"
ghcr_token: "CHANGE_ME"

# Base de données PostgreSQL (DATABASE_URL est construite par le rôle fastapi)
db_user: "CHANGE_ME"
db_password: "CHANGE_ME"

# Clé secrète API, 32 caractères minimum
# (python3 -c "import secrets; print(secrets.token_urlsafe(48))")
secret_key: "CHANGE_ME_GENERATE_RANDOM"

# Mot de passe du compte admin_email (vars.yml)
admin_password: "CHANGE_ME"

# SMTP (optionnel - vide si smtp_user est vide dans vars.yml)
smtp_password: ""
VAULT_EOF

echo "Vault créé : $VAULT_FILE"
echo "Pour vérifier : ansible-vault view --vault-password-file ansible/.vault_pass ansible/inventory/group_vars/all/vault.yml"