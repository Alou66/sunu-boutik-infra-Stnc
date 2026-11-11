# Ancien déploiement « une seule EC2 » — OBSOLÈTE

Ces fichiers décrivent l'ancienne architecture (Postgres, API et web en
conteneurs sur une seule machine, Nginx copié tel quel, images `:latest`,
migrations Alembic lancées automatiquement par la CI). Ils sont conservés
pour référence uniquement : **ne pas les utiliser en production**.

| Fichier | Remplacé par |
|---|---|
| `docker-compose.single-ec2.yml` | rôles Ansible `fastapi` (backend), `web` (frontend), `postgresql` (database, hors Docker) |
| `nginx.single-ec2.conf` | template `ansible/roles/nginx/templates/sunu-boutik.conf.j2` |
| workflows `deploy.yml` (SSH vers `EC2_HOST`) | workflows `build.yml` (build + GHCR) dans les repos api/web, déploiement Ansible (`ansible/DEPLOYMENT.md`) |

Les secrets GitHub `EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY` des trois repos ne
sont plus utilisés et peuvent être supprimés.
