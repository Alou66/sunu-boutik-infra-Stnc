# Déploiement et rollback — Sunu-Boutik (3 EC2)

Toutes les commandes Ansible se lancent depuis la racine du repo
`sunu-boutik-infra` (c'est là que se trouve `ansible.cfg`).

## Architecture

```
Internet ──80/443──▶ EC2 frontend
                     ├─ Nginx (Let's Encrypt, sunu-boutique.online / www)
                     │   ├─ /      → conteneur web   127.0.0.1:3000
                     │   └─ /api/  → EC2 backend     <backend_private_ip>:8000  (préfixe /api retiré)
                     └─ conteneur sunu-boutik-web (ghcr.io/alou66/sunu-boutik-web-stnc:sha-…)

EC2 backend  ─ conteneur sunu-boutik-api (ghcr.io/alou66/sunu-boutik-api-stnc:sha-…)
               publié sur <backend_private_ip>:8000, SG : depuis le SG frontend uniquement

EC2 database ─ PostgreSQL 16 sur l'hôte (pas de Docker), données sur EBS dédié,
               5432 ouvert au backend uniquement
```

| Rôle | Hôte | Responsabilité |
|---|---|---|
| `postgresql` | database | installation, volume EBS, base et utilisateur |
| `fastapi` | backend | fichier `.env.api` + conteneur API (via `app_release`) |
| `web` | frontend | conteneur Next.js (via `app_release`) |
| `nginx` | frontend | reverse proxy, certificat, renouvellement |
| `app_release` | — | rôle interne : pull par tag SHA, démarrage, contrôle de santé, rollback automatique, journal, nettoyage limité des images |

## Versions d'images

- Chaque push sur `main` des repos api et web publie **une** image taguée
  `sha-<SHA complet du commit>` (workflow `build.yml`). Pas de `latest`.
- Les versions déployées sont fixées dans
  `ansible/inventory/group_vars/all/release.yml`. Le playbook refuse un tag
  vide, `latest` ou tout ce qui n'est pas `sha-<40 hex>`.
- **NEXT_PUBLIC_API_URL** est inliné dans le JavaScript au build de l'image
  web. Il vaut `/api` (relatif) : le navigateur appelle l'API sur la même
  origine, sans CORS, et une même image fonctionne pour tous les domaines.
  Changer cette valeur impose de reconstruire l'image ; une variable
  d'environnement du conteneur n'a aucun effet.

## Procédure de déploiement

1. **Choisir les versions.** Récupérer le SHA du commit voulu dans chaque
   repo et vérifier que l'image existe sur GHCR (onglet *Packages* du repo,
   ou `docker manifest inspect ghcr.io/alou66/sunu-boutik-api-stnc:sha-<SHA>`).
   Pour le web, vérifier que le run `build.yml` correspondant utilisait bien
   `NEXT_PUBLIC_API_URL=/api`.
2. **Renseigner** `ansible/inventory/group_vars/all/release.yml` :
   ```yaml
   api_image_tag: "sha-<SHA api>"
   web_image_tag: "sha-<SHA web>"
   ```
   puis commiter ce fichier (son historique Git = journal des mises en prod).
3. **Contrôle à blanc** (aucune modification) :
   ```bash
   ansible-playbook ansible/playbooks/site.yml --check --diff
   ```
4. **Déployer**, un tier à la fois, dans l'ordre :
   ```bash
   # Première installation ou changement de config système :
   ansible-playbook ansible/playbooks/database.yml
   ansible-playbook ansible/playbooks/backend.yml
   ansible-playbook ansible/playbooks/frontend.yml

   # Mise à jour applicative seule (conteneurs) :
   ansible-playbook ansible/playbooks/backend.yml  --tags deploy
   ansible-playbook ansible/playbooks/frontend.yml --tags deploy
   ```
   Pour chaque conteneur, `app_release` :
   - pull l'image `sha-…` ;
   - recrée le conteneur si l'image ou le fichier `.env.api` a changé ;
   - attend `GET /health` (API) ou `GET /` (web) ;
   - **en cas d'échec, redémarre automatiquement l'image précédente** et fait
     échouer le play ;
   - ajoute une ligne `previous=… current=…` à
     `/opt/sunu-boutik/releases/<conteneur>.log` ;
   - supprime les images du même dépôt au-delà des 3 plus récentes, sans
     jamais toucher l'image courante ni la précédente.
5. **Vérifier** depuis l'extérieur :
   ```bash
   curl -fsS https://sunu-boutique.online/api/health
   curl -fsSI https://sunu-boutique.online/ | head -1
   ```

Changer de version backend ne demande pas de toucher au frontend, et
inversement (images et playbooks indépendants). Déployer l'API avant le web
quand le web dépend d'un nouvel endpoint.

## Rollback applicatif

Le rollback applicatif remplace **uniquement les conteneurs**. Il ne touche
jamais à la base de données.

**Automatique** : si le contrôle de santé échoue pendant un déploiement,
l'image précédente est redémarrée immédiatement (voir étape 4).

**Manuel** (la nouvelle version démarre mais se comporte mal) :

1. Trouver la version précédente :
   ```bash
   # Sur l'hôte concerné
   tail -n 5 /opt/sunu-boutik/releases/sunu-boutik-api.log
   tail -n 5 /opt/sunu-boutik/releases/sunu-boutik-web.log
   # Ou depuis le repo infra
   git log -p -- ansible/inventory/group_vars/all/release.yml
   ```
2. Redéployer ce tag (l'image est encore en cache local, aucun pull réseau
   nécessaire si elle fait partie des 3 dernières) :
   ```bash
   ansible-playbook ansible/playbooks/backend.yml  --tags deploy -e api_image_tag=sha-<précédent>
   ansible-playbook ansible/playbooks/frontend.yml --tags deploy -e web_image_tag=sha-<précédent>
   ```
3. Remettre la même valeur dans `release.yml` et commiter, sinon le prochain
   déploiement réinstallerait la version défaillante.

**Secours sans Ansible** (directement sur l'hôte, si besoin immédiat) :
```bash
docker image ls ghcr.io/alou66/sunu-boutik-api-stnc     # tags disponibles
docker rm -f sunu-boutik-api
docker run -d --name sunu-boutik-api --restart unless-stopped \
  --env-file /opt/sunu-boutik/.env.api \
  -p <backend_private_ip>:8000:8000 \
  ghcr.io/alou66/sunu-boutik-api-stnc:sha-<précédent>
```
Repasser ensuite par Ansible (étape 2) pour revenir à un état géré.

**Limite** : un rollback d'image n'annule pas un changement de `.env.api`
(secrets, URL de base). Si c'est la config qui est en cause, corriger le
vault et relancer `backend.yml`.

## Base de données (séparée du rollback applicatif)

### Stratégie d'initialisation actuelle

- Au démarrage, l'API exécute `Base.metadata.create_all()` (`app/main.py`) :
  sur une base vide, toutes les tables sont créées à partir des modèles, puis
  l'admin est créé (`ADMIN_EMAIL` / `ADMIN_PASSWORD`).
- `create_all` **crée les tables manquantes mais ne modifie jamais une table
  existante** (pas d'ajout de colonne, d'index ou de contrainte).
- Une base initialisée ainsi **n'a pas de table `alembic_version`**.
- **Aucune migration Alembic n'est lancée automatiquement** (ni par la CI, ni
  par Ansible, ni dans l'image). L'ancien workflow API qui lançait
  `alembic upgrade head` à chaque push a été supprimé.

### Avant d'appliquer une migration Alembic (manuel, après audit)

1. Sauvegarder la base (voir « Vérifications »), puis lire l'état réel :
   ```bash
   # Sur l'hôte backend, avec l'image qui va être déployée
   docker run --rm --env-file /opt/sunu-boutik/.env.api \
     ghcr.io/alou66/sunu-boutik-api-stnc:sha-<SHA> alembic current
   docker run --rm --env-file /opt/sunu-boutik/.env.api \
     ghcr.io/alou66/sunu-boutik-api-stnc:sha-<SHA> alembic upgrade head --sql | less
   ```
   `alembic current` vide = base `create_all` non suivie par Alembic.
   **Ne pas lancer `upgrade head` dans ce cas** : Alembic rejouerait toutes
   les migrations depuis le début sur des tables qui existent déjà. Il faut
   d'abord déterminer la révision qui correspond au schéma réel, puis
   `alembic stamp <révision>`. C'est une décision d'audit, à ne pas automatiser.
2. Relire le SQL généré (`--sql`) : suppressions ou renommages de colonnes,
   contraintes `NOT NULL` sur des tables remplies, verrous longs.
3. Appliquer `alembic upgrade <révision>` à la main, puis déployer l'image
   applicative.

### Rollback de la base

- Un rollback applicatif ne fait **jamais** de `alembic downgrade`.
- Revenir à une image plus ancienne ne pose pas de problème si la nouvelle
  version a seulement **ajouté** des tables ou colonnes nullables. Si une
  migration a supprimé, renommé ou rendu obligatoire une colonne, l'ancienne
  image est incompatible : il faut restaurer la sauvegarde prise juste avant
  la migration (`pg_restore` ou snapshot EBS), ce qui perd les écritures
  faites depuis.
- D'où la règle : migrations **rétro-compatibles** (expand puis contract en
  deux mises en production) chaque fois que c'est possible.

## Vérifications avant mise en production

**Images et CI**
- [ ] Les workflows `build.yml` des repos api et web ont publié les tags
      `sha-…` choisis (et le build web utilise `NEXT_PUBLIC_API_URL=/api`).
- [ ] Les packages GHCR sont privés et `ghcr_username` / `ghcr_token` (PAT
      `read:packages`) sont dans le vault.
- [ ] La suppression de `.github/workflows/deploy.yml` est poussée sur `main`
      dans les trois repos : tant qu'elle ne l'est pas, l'ancien workflow SSH
      reste actif sur GitHub et se déclenche au prochain push.
- [ ] Les secrets `EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY` sont supprimés des
      trois repos (plus utilisés).
- [ ] Le dossier `ansible/` et `terraform/` sont bien commités dans le repo
      infra (sinon `validate.yml` ne vérifie rien).

**Variables**
- [ ] `group_vars/all/terraform.yml` généré par `scripts/generate_inventory.sh`
      (`frontend_private_ip`, `backend_private_ip`, `database_private_ip`,
      `postgresql_data_volume_id`) ; aucune de ces clés dans `vars.yml`.
- [ ] `vars.yml` : `admin_email` renseigné (adresse réelle) ; `frontend_url`
      vaut `https://sunu-boutique.online` ; `smtp_user` renseigné pour activer
      les emails (sinon vide). Aucune de ces clés dans le vault.
- [ ] Vault : `db_user`, `db_password`, `secret_key`, `admin_password`
      (et `smtp_password` si `smtp_user` est défini) sans `CHANGE_ME`.
- [ ] `group_vars/frontend.yml` : `nginx_certbot_email` défini, DNS A des deux domaines → Elastic IP du
      frontend (`terraform output frontend_public_ip`).

**Réseau** (Terraform)
- [ ] SG backend : 8000 depuis le SG frontend uniquement ; aucun port
      applicatif public.
- [ ] SG database : 5432 depuis le SG backend uniquement.
- [ ] SG frontend : 80/443 publics, 22 uniquement depuis `allowed_ssh_cidr`
      (/32) ou fermé (administration SSM).
- [ ] Backend et database dans le sous-réseau privé, sans IP publique ;
      `private_egress_mode = "nat_gateway"` (sinon apt et GHCR échouent).
- [ ] Poste opérateur : AWS CLI v2 + `session-manager-plugin` (mode ssm).

**Base de données**
- [ ] Sauvegarde en place **avant** la mise en production : rôle
      `postgresql_backup` activé (`docs/BACKUP_RESTORE.md` §2), première
      sauvegarde réelle et test de restauration isolée (§6) réussis. En plus,
      snapshot EBS manuel du volume de données avant chaque migration.
- [ ] État de la base connu (`alembic current`) ; si des données viennent de
      l'ancienne EC2, dump/restore testé au préalable.

**Validation**
- [ ] `ansible-lint ansible/roles ansible/playbooks` et `--syntax-check` passent.
- [ ] `ansible-playbook ansible/playbooks/site.yml --check --diff` relu.
- [ ] Après déploiement : `/api/health` en HTTPS, connexion utilisateur,
      génération d'un PDF de facture, en-tête `X-Forwarded-For` bien pris en
      compte par la limitation de débit (deux clients ne se bloquent pas
      mutuellement).
