# Sunu Boutik — Infra Docker

Orchestration Docker Compose pour la stack complète de Sunu Boutik :

- **db** — PostgreSQL 16
- **api** — backend FastAPI ([`../sunu-boutik-api`](../sunu-boutik-api))
- **web** — frontend Next.js ([`../sunu-boutik-web`](../sunu-boutik-web))

Structure attendue sur disque (les trois dossiers doivent être frères) :

```
soutenance/
├── sunu-boutik-api/
├── sunu-boutik-web/
└── sunu-boutik-infra/   <- vous êtes ici
```

## Démarrage rapide

```bash
cp .env.example .env
# éditer .env : au minimum SECRET_KEY, POSTGRES_PASSWORD, ADMIN_PASSWORD

docker compose up -d --build
docker compose logs -f api
```

- Frontend : http://localhost:3000
- API : http://localhost:8000 (docs interactives sur http://localhost:8000/docs)
- Health check API : http://localhost:8000/health

> **Conflit de ports** : si vous avez déjà un Postgres (service système ou
> autre conteneur), un `uvicorn` ou un `next dev` qui tournent en local sur
> ces mêmes ports (5432 / 8000 / 3000), `docker compose up` échouera avec
> `address already in use`. Le cas le plus courant est un PostgreSQL
> installé nativement (`systemctl status postgresql*`) qui tourne en
> permanence : pas besoin de l'arrêter, changez simplement `POSTGRES_PORT`
> dans `.env` (ex. `5433`) — le conteneur `db` reste indépendant de ce
> Postgres système.

Au premier démarrage, l'API crée automatiquement tout le schéma de base de
données (`Base.metadata.create_all`) puis le compte admin plateforme défini
par `ADMIN_EMAIL` / `ADMIN_PASSWORD` (voir `on_startup` / `_seed_admin` dans
`app/main.py`). Sur une base **neuve**, ce schéma est déjà à jour : il n'y a
rien de plus à faire.

Les migrations Alembic (`alembic/versions/`) ne servent qu'à faire évoluer
une base **existante** (ex. si vous restaurez un dump de la base de prod
dans le conteneur `db`) — dans ce cas, lancez-les manuellement :

```bash
docker compose exec api alembic upgrade head
```

## Variables d'environnement

Tout est centralisé dans `.env` (voir `.env.example` pour le détail de chaque
variable). Points importants :

- `DATABASE_URL` n'existe **pas** dans `.env` : elle est reconstruite par
  `docker-compose.yml` à partir de `POSTGRES_USER` / `POSTGRES_PASSWORD` /
  `POSTGRES_DB`, pour n'avoir qu'une seule source de vérité sur les
  identifiants Postgres.
- `NEXT_PUBLIC_API_URL` est **inlinée dans le bundle JS au moment du build**
  du frontend (limitation Next.js). Si vous la changez, il faut rebuilder :
  ```bash
  docker compose up -d --build web
  ```
  Elle doit pointer vers une URL joignable depuis le **navigateur** de
  l'utilisateur (donc `http://localhost:8000` en local), pas vers le nom du
  service Docker interne (`api`).

## Commandes utiles

```bash
# Démarrer / reconstruire
docker compose up -d --build

# Logs
docker compose logs -f            # tous les services
docker compose logs -f api        # un seul service

# État des conteneurs
docker compose ps

# Arrêter (les volumes/données persistent)
docker compose down

# Tout supprimer, y compris les données Postgres et les uploads
docker compose down -v

# Ouvrir un shell dans un conteneur
docker compose exec api sh
docker compose exec db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"

# Rejouer les migrations manuellement
docker compose exec api alembic upgrade head

# Générer une nouvelle migration après modification des modèles SQLAlchemy
docker compose exec api alembic revision --autogenerate -m "message"
```

## Persistance des données

Deux volumes Docker nommés sont créés :

- `sunu-boutik-postgres-data` — données PostgreSQL
- `sunu-boutik-api-uploads` — fichiers uploadés par l'API (logos boutiques, etc.)

Ils survivent à `docker compose down` ; seul `docker compose down -v` les supprime.

## Développement vs production

Cette stack est pensée pour un environnement type "démo / soutenance" (une
seule machine, tout en local). Pour un vrai déploiement production, pensez
à minima à :

- ne pas exposer le port Postgres (`POSTGRES_PORT`) publiquement,
- utiliser des secrets gérés (Vault, secrets Docker/Kubernetes...) plutôt
  qu'un fichier `.env` en clair,
- mettre `web` derrière un reverse proxy TLS (Nginx, Traefik, Caddy...),
- limiter les ressources (`deploy.resources` ou équivalent) et ajouter de la
  supervision (logs centralisés, monitoring).
