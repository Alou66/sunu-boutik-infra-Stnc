# Ansible - Sunu-Boutik

## Sécurité
- Utiliser Ansible Vault pour tous les secrets
- Créer `.vault_pass` localement (non commité)
- Ne jamais commiter de mots de passe en clair

## Déploiement
1. `scripts/generate_inventory.sh` : inventaire et IP privées depuis Terraform
2. Créer le vault (identifiants GHCR, secrets applicatifs)
3. Fixer les images à déployer dans `inventory/group_vars/all/release.yml`
   (tags `sha-<commit>`, jamais `latest`)
4. Depuis la racine du repo : `ansible-playbook ansible/playbooks/site.yml`

Procédure complète, rollback et vérifications avant mise en production :
[DEPLOYMENT.md](DEPLOYMENT.md).

## Playbooks par serveur
| Playbook | Groupe | Rôles |
|---|---|---|
| `playbooks/database.yml` | database | common, postgresql, postgresql_backup (si `postgresql_backup_enabled`) |
| `playbooks/backend.yml` | backend | common, docker, fastapi (→ app_release) |
| `playbooks/frontend.yml` | frontend | common, docker, web (→ app_release), nginx |

`site.yml` les importe dans l'ordre database → backend → frontend.
Redéployer uniquement les conteneurs applicatifs : `ansible-playbook ansible/playbooks/site.yml --tags deploy`.

## Notes
- PostgreSQL utilise volume persistant monté sur l'instance DB
- Sauvegarde quotidienne chiffrée vers S3 et restauration isolée :
  [docs/BACKUP_RESTORE.md](docs/BACKUP_RESTORE.md)
- API utilise `create_all()` au démarrage (pas d'alembic upgrade automatique)
- Nginx proxifie `/api/` vers backend privé:8000
