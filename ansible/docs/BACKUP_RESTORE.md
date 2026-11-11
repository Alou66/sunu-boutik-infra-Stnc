# Sauvegarde et restauration PostgreSQL

Sauvegarde quotidienne de la base `sunuboutik` (instance **database**) vers un
bucket S3 privé, chiffrée sur le serveur avant tout envoi, et procédure de
restauration dans une base **isolée**.

> La nouvelle base est initialisée vide (rôle `postgresql`, puis
> `create_all()` au démarrage de l'API). Aucune donnée de l'ancienne
> application n'est importée : la première sauvegarde contient donc un
> schéma vide ou presque, c'est normal.

| Élément | Emplacement |
|---|---|
| Scripts | `ansible/roles/postgresql_backup/files/` |
| Rôle Ansible | `ansible/roles/postgresql_backup/` (playbook `database.yml`, tag `backup`) |
| Bucket S3 + IAM | `terraform/modules/backup/` (`backup_enabled`, désactivé par défaut) |
| Banc de tests hors ligne | `ansible/roles/postgresql_backup/tests/run.sh` |

## 1. Fonctionnement

```
timer systemd (02:30 UTC, Persistent)
  └─ sunu-boutik-pg-backup   (utilisateur postgres, socket local : aucun mot de passe)
       1. pg_isready + accès à la base            → sinon code 3
       2. espace disque ≥ taille de la base       → sinon code 9
       3. pg_dump --format=custom --compress=6    → sinon code 4
       4. pg_restore --list (archive lisible)     → sinon code 5
       5. age --encrypt (clé PUBLIQUE)            → sinon code 6
       6. PUT S3 --if-none-match '*' + SHA-256    → refus d'écraser : code 10
       7. HEAD S3 : taille + SHA-256 identiques   → sinon code 8
       8. le dimanche (configurable) : copie sous weekly/
```

Clés S3 : `postgresql/sunuboutik/{daily|weekly}/sunuboutik_AAAAMMJJTHHMMSSZ.dump.age`.
Métadonnées de chaque objet : base, date, version PostgreSQL, SHA-256 du dump
en clair (`plain-sha256`) et du fichier chiffré (`enc-sha256`).

### Exigences et mise en œuvre

| Exigence | Mise en œuvre |
|---|---|
| Sauvegarde quotidienne `pg_dump` | `sunu-boutik-pg-backup.timer` → service oneshot |
| Compression | format custom de `pg_dump`, niveau 6 |
| Bucket S3 privé | Block Public Access complet, ACL désactivées, refus hors TLS |
| Chiffrement | **côté client** avec `age` (X25519 + ChaCha20-Poly1305) avant l'envoi ; **SSE-S3** en plus côté bucket. La clé privée n'est jamais sur le serveur |
| Rétention 7 quotidiennes + 4 hebdomadaires | cycle de vie S3 : `daily/` expire à 7 jours, `weekly/` à 28 jours ; l'instance n'a **aucun** droit de suppression |
| IAM limité | rôle dédié à database : `ListBucket` (préfixe), `PutObject` (`daily/`, `weekly/`), `GetObject` (préfixe). Frontend et backend : aucun accès |
| Restauration documentée | §5 ; script `sunu-boutik-pg-restore` |
| Intégrité | `pg_restore --list` avant envoi ; SHA-256 vérifié par S3 à l'envoi, relu après l'envoi, revérifié au téléchargement ; authentification `age` au déchiffrement ; `plain-sha256` après déchiffrement |
| Journaux sans secret | journald ; aucun secret manipulé (auth peer, rôle IAM, clé publique) ; filtre `redact` sur toute sortie d'outil (clés AWS, signatures, clé age, mots de passe d'URL) |
| Anti-écrasement | nom horodaté unique ; `If-None-Match: *` (S3 refuse si la clé existe) ; politique de bucket qui refuse tout PUT sans cette condition ; versioning ; refus de toute suppression manuelle |

## 2. Mise en service

Rien de ceci n'a été exécuté : chaque étape est à lancer par l'opérateur,
après relecture.

1. **Clé de chiffrement, hors du serveur** (poste de l'opérateur) :
   ```bash
   age-keygen -o sunu-boutik-backup.key      # clé PRIVÉE
   age-keygen -y sunu-boutik-backup.key      # clé publique age1…
   ```
   Ranger la clé privée dans un coffre (gestionnaire de mots de passe), avec
   au moins une seconde copie hors ligne. **Sans elle, aucune sauvegarde ne
   peut être restaurée.** Ne jamais la copier dans le dépôt ni sur une EC2,
   sauf temporairement pour une restauration (§5).
2. **Terraform** (`terraform/environments/prod/terraform.tfvars`) :
   `backup_enabled = true`, puis `terraform plan` et relecture. Le plan doit
   montrer la création du bucket, de sa configuration, du rôle et du profil
   `sunu-boutik-ec2-database`, et une **modification en place** de
   `aws_instance.database` (`iam_instance_profile` seul ; ni remplacement ni
   redémarrage). Puis `terraform apply`.
3. `ansible/scripts/generate_inventory.sh` : renseigne
   `postgresql_backup_bucket` dans `group_vars/all/terraform.yml`.
4. `ansible/inventory/group_vars/database.yml` :
   `postgresql_backup_enabled: true` et
   `postgresql_backup_age_recipient: "age1…"` (clé publique).
5. `ansible-playbook playbooks/database.yml --tags backup --check --diff`,
   puis sans `--check`.
6. Première sauvegarde et contrôle, sur l'instance database :
   ```bash
   sudo systemctl start sunu-boutik-pg-backup.service
   sudo journalctl -u sunu-boutik-pg-backup.service -n 20
   sudo -u postgres sunu-boutik-pg-restore status
   ```
7. Faire un premier test de restauration (§6).

## 3. Configuration IAM proposée

Créée par `terraform/modules/backup` ; reproduite ici pour relecture
(`<BUCKET>` = `sunu-boutik-pg-backups-<ID du compte>`).

**Rôle de l'instance database** (`sunu-boutik-ec2-database`) :
`AmazonSSMManagedInstanceCore` (comme les autres instances) + la politique
ci-dessous. Aucune action `Delete*`, aucune action sur la configuration du
bucket.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBackupPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<BUCKET>",
      "Condition": { "StringLike": { "s3:prefix": "postgresql/sunuboutik/*" } }
    },
    {
      "Sid": "PutBackups",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": [
        "arn:aws:s3:::<BUCKET>/postgresql/sunuboutik/daily/*",
        "arn:aws:s3:::<BUCKET>/postgresql/sunuboutik/weekly/*"
      ]
    },
    {
      "Sid": "ReadBackups",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::<BUCKET>/postgresql/sunuboutik/*"
    }
  ]
}
```

`GetObject` est nécessaire au contrôle après envoi (HeadObject) et à la
restauration. Il ne donne pas accès aux données : les objets sont chiffrés
par `age` et la clé privée n'est pas sur le serveur.

**Politique du bucket** (refus pour tous les principaux) :

| Sid | Refuse |
|---|---|
| `DenyInsecureTransport` | toute requête hors HTTPS |
| `DenyWritesOutsideVpc` | `PutObject` qui ne passe pas par l'endpoint S3 Gateway du VPC |
| `DenyObjectDeletion` | `DeleteObject` et `DeleteObjectVersion` (le cycle de vie S3 n'est pas concerné) |
| `DenyOverwrite` | `PutObject` sans en-tête `If-None-Match` (`enforce_conditional_writes`) |

Les permissions des administrateurs ne sont pas gérées ici. Lever un refus
impose de modifier la politique du bucket : c'est une action délibérée,
tracée dans CloudTrail.

## 4. Exploitation

```bash
systemctl list-timers sunu-boutik-pg-backup.timer        # prochaine exécution
journalctl -u sunu-boutik-pg-backup.service --since -2d  # journaux
sudo -u postgres sunu-boutik-pg-restore status           # fraîcheur (code 12 si > 26 h)
sudo -u postgres sunu-boutik-pg-restore list [weekly]    # sauvegardes disponibles
```

### Codes de sortie

| Code | Signification | Action |
|---|---|---|
| 0 | succès | – |
| 2 | configuration invalide, clé age absente ou trop ouverte, option inconnue | corriger `/etc/sunu-boutik/pg-backup.conf` ou la commande |
| 3 | PostgreSQL indisponible, base inaccessible | `pg_lsclusters`, `systemctl status postgresql@16-main` |
| 4 | échec de `pg_dump` | journaux (verrous, droits) |
| 5 | intégrité : archive illisible ou SHA-256 non conforme | **ne pas utiliser** cette sauvegarde ; en prendre une autre |
| 6 | chiffrement ou déchiffrement impossible (mauvaise clé, fichier altéré) | vérifier la clé privée |
| 7 | S3 : accès refusé, bucket absent, pas d'identifiants | rôle IAM, profil d'instance, endpoint S3 |
| 8 | objet envoyé mais contrôle après envoi en échec | relancer ; vérifier l'objet avec `verify` |
| 9 | verrou (opération déjà en cours) ou espace disque insuffisant | attendre, ou libérer `/var/backups` |
| 10 | l'objet existe déjà : écrasement refusé | normal en cas de double lancement dans la même seconde |
| 11 | sauvegarde introuvable | `list` |
| 12 | dernière sauvegarde quotidienne trop ancienne, ou aucune | analyser les échecs du timer |
| 13 | cible de restauration refusée (production, nom invalide, base existante) | choisir `restore_<nom>` inexistant |

La rétention est faite par S3 : **si les sauvegardes s'arrêtent, les
quotidiennes disparaissent au bout de 7 jours et les hebdomadaires au bout de
28.** Surveiller `status` (§8).

## 5. Restauration

> ⚠️ **Perte de données.** Une sauvegarde reflète la base à sa date
> (horodatage UTC dans le nom). Toute écriture postérieure (inscriptions,
> boutiques, produits, factures) est **absente** de la sauvegarde. Si la
> production est remplacée par une sauvegarde, ces écritures sont
> **définitivement perdues** pour l'application. Avec une sauvegarde
> quotidienne, jusqu'à 24 h de données peuvent être perdues (RPO).

Le script **ne restaure jamais dans la production**. La cible doit être une
nouvelle base `restore_*` qui n'existe pas encore. La production
(`sunuboutik`) n'est ni arrêtée, ni modifiée, ni lue.

### 5.1 Restauration isolée (standard)

Sur l'instance database :

```bash
# 1. Clé privée en mémoire (tmpfs), lisible par postgres seul
sudo install -o postgres -g postgres -m 0600 /dev/null /dev/shm/restore.key
sudo -u postgres tee /dev/shm/restore.key >/dev/null   # coller la clé, puis Ctrl-D

# 2. Choisir une sauvegarde
sudo -u postgres sunu-boutik-pg-restore list

# 3. Vérifier (téléchargement, SHA-256, déchiffrement, pg_restore --list),
#    sans rien créer
sudo -u postgres sunu-boutik-pg-restore verify --latest daily --identity /dev/shm/restore.key

# 4. Restaurer dans une base isolée
sudo -u postgres sunu-boutik-pg-restore restore \
  --key postgresql/sunuboutik/daily/sunuboutik_20261105T023012Z.dump.age \
  --identity /dev/shm/restore.key --target-db restore_20261105

# 5. Supprimer la clé
sudo shred -u /dev/shm/restore.key
```

- **Restauration atomique.** Elle se fait dans une transaction unique : en
  cas d'erreur, la base cible est supprimée et rien n'est laissé à moitié.
- **Propriétaires.** Par défaut, les objets appartiennent à `postgres`
  (`--no-owner`), ce qui suffit pour consulter ou extraire des données.
  `--keep-owner` conserve les propriétaires d'origine : les rôles doivent
  alors exister (le rôle Ansible `postgresql` crée `db_user`).
- **Source locale.** `--file chemin.dump.age --sha256 <hex>` restaure depuis
  un fichier local, par exemple une copie hors S3.
- **Nettoyage.** Une fois l'analyse terminée :
  `sudo -u postgres dropdb restore_20261105`.

### 5.2 Bascule de la production vers une sauvegarde (exceptionnelle)

Manuelle uniquement, après décision explicite de perdre les écritures
postérieures à la sauvegarde. L'ancienne base est **renommée, jamais
supprimée**.

1. Restaurer avec `--keep-owner` dans `restore_<date>` (§5.1), puis vérifier
   le contenu.
2. Si la production est encore lisible, sauvegarder son état actuel :
   `sudo systemctl start sunu-boutik-pg-backup.service`.
3. Arrêter l'API (hôte backend) : `sudo docker stop sunu-boutik-api`.
4. Sur database, en tant que postgres :
   ```sql
   SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'sunuboutik';
   ALTER DATABASE sunuboutik RENAME TO sunuboutik_avant_restauration_20261105;
   ALTER DATABASE restore_20261105 RENAME TO sunuboutik;
   ALTER DATABASE sunuboutik OWNER TO <db_user>;
   ```
5. Redémarrer l'API (`sudo docker start sunu-boutik-api`) et vérifier
   `/health`, la connexion et les données.
6. Conserver `sunuboutik_avant_restauration_*` jusqu'à validation complète.

## 6. Procédure de test de restauration

À faire après la mise en service, puis **chaque mois** et après toute
modification du rôle ou de PostgreSQL. Le test ne touche pas à la
production.

1. `sudo -u postgres sunu-boutik-pg-restore status` → code 0.
2. Restaurer la dernière quotidienne dans `restore_test_<date>` (§5.1).
3. Comparer le nombre de lignes avec la production (lecture seule) :
   ```bash
   for db in sunuboutik restore_test_<date>; do
     sudo -u postgres psql -XAtq -d "$db" -c \
       "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname"
   done
   ```
   Les écarts doivent correspondre aux écritures faites depuis la sauvegarde.
4. Restaurer aussi la dernière hebdomadaire (`--latest weekly`).
5. Mesurer la durée (RTO) et la consigner avec la date, la clé restaurée et
   le résultat.
6. `dropdb` des bases de test, puis `shred` de la clé.

## 7. Banc de tests hors ligne

```bash
ansible/roles/postgresql_backup/tests/run.sh
```

Le banc s'exécute dans un conteneur Ubuntu 24.04 lancé avec
`--network none`, donc **sans aucun accès à AWS**. Il contient un vrai
PostgreSQL 16 avec des données fictives, un S3 simulé (`fake-aws`) et des
clés age jetables. Il utilise les templates réels du rôle. Les 82
vérifications couvrent :

- shellcheck ;
- les configurations invalides ;
- la sauvegarde nominale et hebdomadaire ;
- le refus d'écrasement ;
- un accès S3 refusé, l'absence d'identifiants, un bucket absent ;
- une base indisponible ;
- le verrou ;
- `list` et `status` ;
- la restauration, avec comparaison des empreintes de données ;
- les garde-fous de la cible ;
- une sauvegarde absente ;
- 6 types de corruption ;
- une mauvaise clé ;
- le nettoyage après un échec ;
- l'absence de secrets dans les journaux.

## 8. Limites et risques

- **Pas d'alerte automatique.** Un échec n'est visible que dans journald et
  via `status`. Il faut brancher `status` sur une supervision (par exemple
  CloudWatch Agent ou un `OnFailure=` vers une notification). Sans cela, une
  panne prolongée (plus de 7 jours) laisse expirer les quotidiennes.
- **RPO de 24 h.** `pg_dump` est un instantané logique quotidien. Pour un
  RPO plus court, il faudrait de l'archivage WAL (pgBackRest ou WAL-G),
  non implémenté.
- **Rôles PostgreSQL non sauvegardés** (`pg_dumpall --globals-only`). Ils
  sont recréés par le rôle Ansible `postgresql` à partir du Vault.
- **Taille limitée à 5 Gio chiffrés** (PUT S3 unique, conditionnel). Au-delà,
  le script échoue explicitement (code 9) : il faudra passer à l'envoi
  multipart conditionnel.
- **Clé privée age.** Sa perte rend toutes les sauvegardes inutilisables ;
  sa fuite ne suffit pas à les lire sans accès au bucket. Prévoir deux
  copies, dont une hors ligne.
- **Non testé contre AWS réel.** Le comportement S3 (`If-None-Match`,
  checksums, endpoint VPC, cycle de vie, clé de condition `s3:if-none-match`
  de `DenyOverwrite`) est simulé. Les éléments à valider lors de la première
  mise en service sont :
  - le plan Terraform ;
  - une première sauvegarde réelle ;
  - un `PutObject` manuel sans `If-None-Match`, qui doit être refusé.

  Si la clé de condition n'est pas acceptée, passer
  `enforce_conditional_writes = false` : la protection reste assurée par le
  script, le versioning et le refus des suppressions.
- **AWS CLI en snap.** Elle n'a pas pu être exécutée dans le banc (pas de
  snapd en conteneur). Le service systemd évite `NoNewPrivileges`, que
  snap-confine ne supporte pas. Vérifier l'exécution réelle du timer à la
  mise en service.
- **Fichiers temporaires.** Le dump en clair existe brièvement, en mode
  0600, sur le volume racine chiffré (`/var/backups/sunu-boutik-pg`). Il est
  supprimé dès le chiffrement et dans tous les cas d'échec.
