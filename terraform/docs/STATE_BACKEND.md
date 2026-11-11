# State Terraform distant (S3 + verrou natif `use_lockfile`)

> Garde-fous permanents : [`GUARDRAILS.md`](GUARDRAILS.md). Toute commande
> qui contacte AWS (même en lecture : `aws …`, `init` avec backend, `plan`,
> `output`, `state pull`) exige une validation préalable. Les commandes
> marquées **[AUTORISATION]** exigent en plus une autorisation explicite,
> commande par commande. Les instances existantes `i-0a8fa28bbc839c1aa`
> (sunu-boutik historique) et `i-0f32b1aeb2a4ffe02` (transfertpro) sont
> strictement hors périmètre : ni importées, ni lues, ni référencées, ni
> par `bootstrap/`, ni par `environments/prod/`.

## Architecture

```
terraform/bootstrap/            (state LOCAL, exécuté une seule fois)
└── module state_backend
    ├── S3 sunu-boutik-tfstate-<ID compte>    ← dédié au state, rien d'autre
    │     versioning, SSE-S3 (AES256), Block Public Access, ACL désactivées,
    │     prevent_destroy, force_destroy = false, politique de refus,
    │     cycle de vie des anciennes versions
    └── IAM (créées, NON attachées) : *-terraform-state-rw / -ro / -recovery

terraform/environments/prod/    backend "s3"
    key          = sunu-boutik/prod/terraform.tfstate
    verrou       = sunu-boutik/prod/terraform.tfstate.tflock  (use_lockfile)
    bucket       = fourni par backend.s3.tfbackend (non versionné)
```

Le bucket des sauvegardes PostgreSQL (`sunu-boutik-pg-backups-<ID>`, module
`backup`, C2) reste **distinct** : la variable `bucket_name` du module
refuse tout nom contenant `pg-backups`, et aucune politique ne donne accès
d'un bucket à l'autre.

| Protection | Mise en œuvre |
|---|---|
| Versioning | `aws_s3_bucket_versioning` = `Enabled` : chaque écriture crée une version |
| Chiffrement | SSE-S3 par défaut sur le bucket + `encrypt = true` côté backend ; TLS imposé (`DenyInsecureTransport`) |
| Accès public | Block Public Access (4 options) + `BucketOwnerEnforced` |
| Verrouillage | `use_lockfile = true` (objet `.tflock` écrit avec `If-None-Match`), sans DynamoDB |
| Suppression accidentelle | `prevent_destroy`, `force_destroy = false`, refus `s3:DeleteObject` sur `*.tfstate`, refus `s3:DeleteObjectVersion` et `s3:DeleteBucket` pour tous |
| Historique | anciennes versions supprimées seulement si **> 90 jours ET > 50 versions plus récentes** ; la version courante n'expire jamais |
| Identifiants | aucun dans le code : chaîne standard AWS (`AWS_PROFILE`, SSO) |

Versions : Terraform `>= 1.11.0` imposé (`use_lockfile` GA ; testé en
1.17.1), provider `hashicorp/aws ~> 6.0` (verrouillé en 6.71.0).

## Permissions IAM proposées

Créées par le bootstrap (`create_iam_policies = true`), **jamais attachées
automatiquement**. Le JSON exact est visible avant création :
`terraform -chdir=terraform/bootstrap output -json iam_policy_documents`
(après plan/apply) et il est vérifié par `tests/policies_json.tftest.hcl`.

| Politique | À attacher à | Actions | Ressources |
|---|---|---|---|
| `sunu-boutik-terraform-state-rw` | opérateur Terraform (plan/apply) | `s3:ListBucket` | bucket |
| | | `s3:GetObject`, `s3:PutObject` | `…/sunu-boutik/prod/terraform.tfstate` |
| | | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` | `…/sunu-boutik/prod/terraform.tfstate.tflock` |
| `sunu-boutik-terraform-state-ro` | `terraform output` (`generate_inventory.sh`) | `s3:ListBucket` ; `s3:GetObject` | bucket ; clé du state |
| `sunu-boutik-terraform-state-recovery` | admin, **temporairement**, en plus de rw | `s3:ListBucketVersions` ; `s3:GetObjectVersion` | bucket ; clé du state |

Notes :
- Ce sont exactement les permissions documentées pour le backend S3 avec
  `use_lockfile`. Aucun joker d'action, aucune `DeleteObjectVersion`.
- `s3:ListBucket` n'est pas restreint par préfixe : le bucket étant dédié,
  il n'expose que des noms de clés, et cela évite des erreurs d'init
  (listing des workspaces).
- SSE-S3 : aucune permission KMS requise. En cas de passage à SSE-KMS,
  ajouter `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey` sur la clé.
- Le state peut contenir des valeurs sensibles : `state-ro` est une lecture
  complète du state, à n'accorder qu'aux postes d'administration.
- Les permissions de **création** du bootstrap (`s3:CreateBucket`,
  `s3:PutBucket*`, `iam:CreatePolicy`…) relèvent d'un profil administrateur
  et ne font pas partie de ces politiques.

## 1. Création préalable du bucket (bootstrap)

Terraform ne peut pas initialiser un backend dont le bucket n'existe pas :
le bucket est donc créé par une configuration séparée, `terraform/bootstrap`,
dont le state reste local. Ce state ne doit **jamais** être migré dans le
bucket qu'il crée (dépendance circulaire : perdre le bucket ferait perdre
le moyen de le recréer).

```bash
cd terraform/bootstrap
export AWS_PROFILE=<profil-admin>          # jamais de clé en clair
aws sts get-caller-identity --query Account --output text   # vérifier le compte
cp terraform.tfvars.example terraform.tfvars                 # relire
terraform init
terraform test                              # hors ligne
terraform plan -out=bootstrap.tfplan        # relire : 1 bucket + config + 3 politiques IAM
terraform apply bootstrap.tfplan            # [AUTORISATION]
terraform output -raw backend_config > ../environments/prod/backend.s3.tfbackend
```

Ressources attendues dans le plan : `aws_s3_bucket`,
`_public_access_block`, `_ownership_controls`, `_versioning`,
`_server_side_encryption_configuration`, `_lifecycle_configuration`,
`_policy`, et 3 `aws_iam_policy`. **Aucune** `aws_instance`, aucun
`import`, aucune suppression.

Vérifications post-création (lecture seule) :

```bash
B=$(terraform output -raw state_bucket_name)
aws s3api get-bucket-versioning --bucket "$B"                   # Status: Enabled
aws s3api get-bucket-encryption --bucket "$B"                   # AES256
aws s3api get-public-access-block --bucket "$B"                 # 4 × true
aws s3api get-bucket-policy --bucket "$B" --query Policy --output text | jq '.Statement[].Sid'
```

Attacher ensuite la politique `state-rw` au rôle/utilisateur opérateur
(console IAM ou `aws iam attach-role-policy`) **[AUTORISATION]**.

**State du bootstrap** : `bootstrap/terraform.tfstate` (non versionné, ignoré
par git) ne contient que le bucket et les politiques. Le sauvegarder chiffré
hors du dépôt (`age -r <clé publique> terraform.tfstate > bootstrap.tfstate.age`).
S'il est perdu, le bucket reste protégé (politique de refus) ; on le
réimporte dans le bootstrap uniquement (`terraform import
module.state_backend.aws_s3_bucket.state <bucket>`, etc.) **[AUTORISATION]**.

## 2. Mise en service / migration du state de prod

### État constaté (2026-11-05)

Aucun `terraform.tfstate` local n'existe (recherche sur tout le poste) et
`environments/prod/.terraform` a été initialisé avec `-backend=false` :
**il n'y a rien à migrer**. Le backend `s3` est déjà déclaré dans
`environments/prod/versions.tf`, ce qui empêche un premier `apply` vers un
state local non protégé.

### Cas A — aucun state local (cas actuel)

```bash
cd terraform/environments/prod
ls terraform.tfstate 2>/dev/null && echo "STOP : state local présent, voir cas B"
terraform init -backend-config=backend.s3.tfbackend
terraform plan                       # lit/verrouille le state distant (vide)
```

### Cas B — un state local existe (poste ayant appliqué avec l'ancien backend local)

Uniquement documenté, **[AUTORISATION]** requise avant l'étape 3.

1. Geler les opérations : personne d'autre ne lance Terraform.
2. Sauvegarder l'état actuel hors du dépôt, sans l'afficher :
   ```bash
   cd terraform/environments/prod
   umask 077
   cp terraform.tfstate ~/tfstate-prod-avant-migration-$(date +%F).tfstate
   jq '{serial, lineage, terraform_version}' terraform.tfstate
   jq '[.resources[].instances[]] | length' terraform.tfstate   # = nb de lignes de `terraform state list`
   ```
3. Migrer (Terraform détecte le passage `local` → `s3` et propose la copie ;
   répondre `yes`) :
   ```bash
   terraform init -migrate-state -backend-config=backend.s3.tfbackend   # [AUTORISATION]
   ```
   **Ne jamais utiliser `-reconfigure`** dans ce cas : il ignore le state
   local et repart d'un state distant vide (toutes les protections
   `prevent_destroy` seraient perdues, un apply recréerait tout).
4. Vérifier :
   ```bash
   terraform state list | wc -l         # même nombre qu'avant
   terraform plan                       # attendu : No changes
   aws s3api list-object-versions --bucket "$B" \
     --prefix sunu-boutik/prod/terraform.tfstate \
     --query 'Versions[].{v:VersionId,d:LastModified,s:Size}'
   ```
5. Après vérification seulement (même nombre de ressources, `No changes`,
   version visible dans S3, sauvegarde chiffrée relue : déchiffrement
   testé, `serial` et `lineage` identiques), retirer le state local du
   répertoire de travail **[AUTORISATION]** :
   ```bash
   age -r <clé publique> ~/tfstate-prod-avant-migration-<date>.tfstate > ~/tfstate-prod-avant-migration-<date>.tfstate.age
   shred -u ~/tfstate-prod-avant-migration-<date>.tfstate terraform.tfstate terraform.tfstate.backup
   ```

### Après mise en service

- Chaque poste : `terraform init -backend-config=backend.s3.tfbackend`.
- `ansible/scripts/generate_inventory.sh` appelle `terraform output -json`
  dans `environments/prod` : le poste qui l'exécute doit être initialisé
  avec le backend S3 et disposer au minimum de `state-ro`.
- Tests hors ligne inchangés : `terraform init -backend=false && terraform test`.

## 3. Récupération du state

Variables communes :

```bash
B=sunu-boutik-tfstate-<ID compte>
K=sunu-boutik/prod/terraform.tfstate
```

Prérequis : politiques `state-rw` + `state-recovery`. `state-recovery`
est attachée **temporairement**, pour une récupération autorisée
**[AUTORISATION]**, puis détachée dès la fin et le détachement vérifié
(`aws iam list-attached-role-policies --role-name <rôle>`).

### 3.1 Lister les versions

```bash
aws s3api list-object-versions --bucket "$B" --prefix "$K" \
  --query '{versions: Versions[?Key==`'"$K"'`].{id:VersionId,date:LastModified,taille:Size,courante:IsLatest}, marqueurs: DeleteMarkers[?Key==`'"$K"'`]}'
```

### 3.2 Examiner une version sans en afficher le contenu

```bash
umask 077
aws s3api get-object --bucket "$B" --key "$K" --version-id <VERSION_ID> /tmp/state-candidat.json
jq -e '.version == 4' /tmp/state-candidat.json >/dev/null && echo "JSON valide"
jq '{serial, lineage, terraform_version, ressources: (.resources|length)}' /tmp/state-candidat.json
```

Choisir **la version valide la plus récente** (même `lineage`, `serial` le
plus élevé) pour limiter l'écart avec l'infrastructure réelle.

### 3.3 Restaurer **[AUTORISATION]**

1. Geler Terraform et poser un verrou manuel (échoue si un verrou existe :
   ne pas forcer, identifier d'abord le détenteur ; `--if-none-match`
   exige une AWS CLI v2 récente) :
   ```bash
   printf '{"ID":"manual-restore","Operation":"manual-restore","Who":"%s","Created":"%s"}' \
     "$USER" "$(date -u +%FT%TZ)" > /tmp/lock.json
   aws s3api put-object --bucket "$B" --key "$K.tflock" --body /tmp/lock.json --if-none-match '*'
   ```
2. Préserver l'état courant (obligatoire, même s'il est jugé corrompu) :
   noter son `VersionId` et en garder une copie chiffrée hors du dépôt.
   ```bash
   aws s3api head-object --bucket "$B" --key "$K" --query VersionId --output text
   aws s3api get-object --bucket "$B" --key "$K" /tmp/state-courant.json
   age -r <clé publique> /tmp/state-courant.json > ~/sauvegardes/prod-avant-restauration-$(date +%F-%H%M).tfstate.age
   ```
3. Restaurer **par copie** : la version choisie devient une nouvelle version
   courante ; l'historique (y compris la version fautive) est conservé.
   ```bash
   aws s3api copy-object --bucket "$B" --key "$K" \
     --copy-source "$B/$K?versionId=<VERSION_ID>" \
     --server-side-encryption AES256
   ```
4. Retirer le verrou manuel : `aws s3api delete-object --bucket "$B" --key "$K.tflock"`.
5. Contrôler : `terraform plan`. Si des ressources créées après cette version
   apparaissent « à créer », **ne pas appliquer** : choisir une version plus
   récente, ou réimporter uniquement des ressources de ce projet dont l'ID est
   connu **[AUTORISATION]** — jamais `i-0a8fa28bbc839c1aa` ni
   `i-0f32b1aeb2a4ffe02`.
6. `shred -u /tmp/state-candidat.json /tmp/state-courant.json; rm -f /tmp/lock.json`,
   puis détacher `state-recovery` et vérifier le détachement.

`terraform state push` **[AUTORISATION]** est une alternative, mais il
refuse un `serial` inférieur sans `-force` ; la copie S3 est plus traçable.
L'étape 2 (copie de l'état courant) s'applique aussi.

### 3.4 Cas particuliers

| Situation | Action |
|---|---|
| State supprimé (marqueur de suppression) | Bloqué par `DenyStateDeletion`. Si la politique a été levée : restaurer par copie (3.3) la dernière version réelle, ce qui la replace au-dessus du marqueur. |
| State corrompu (JSON invalide, ressources manquantes) | 3.2 pour trouver la dernière version valide, puis 3.3. |
| Verrou resté en place (crash, coupure) | Vérifier qu'aucun Terraform ne tourne, puis `terraform force-unlock <LOCK_ID>` (ID affiché dans l'erreur) **[AUTORISATION]**. |
| Écart state / réalité | `terraform plan -refresh-only`, relire, puis `terraform apply -refresh-only` **[AUTORISATION]**. |
| Bucket inaccessible / perdu | Recréer via bootstrap, puis `terraform state push` d'une sauvegarde hors ligne (ci-dessous) **[AUTORISATION]**, après avoir conservé tout state encore lisible. |

### 3.5 Sauvegarde hors ligne (recommandée après chaque apply)

```bash
terraform state pull | age -r <clé publique> > ~/sauvegardes/prod-$(date +%F-%H%M).tfstate.age
```

Jamais en clair, jamais dans le dépôt : le state peut contenir des données
sensibles.

## Vérifications hors ligne

```bash
cd terraform
terraform fmt -recursive -check
scripts/check_state_backend.sh           # contrôles statiques (backend, IAM, secrets, docs)
for d in modules/state_backend bootstrap environments/prod modules/backup; do
  (cd "$d" && terraform init -backend=false && terraform validate && terraform test)
done
```

Aucun de ces tests ne contacte AWS : `mock_provider`, ou provider réel aux
endpoints redirigés vers `127.0.0.1:9` avec de faux identifiants
(`modules/state_backend/tests/policies_json.tftest.hcl`).
