# Terraform - Sunu-Boutik (nouvelle infrastructure)

> **Hors périmètre absolu** : les instances `i-0a8fa28bbc839c1aa`
> (sunu-boutik historique) et `i-0f32b1aeb2a4ffe02` (transfertpro) ne sont
> ni importées, ni référencées (aucune data source), ni modifiées. Le code
> crée un VPC dédié distinct.
>
> **Garde-fous permanents** : [`docs/GUARDRAILS.md`](docs/GUARDRAILS.md)
> (aucune opération AWS sans validation, autorisation explicite pour
> `apply`, `destroy`, `import`, `force-unlock`, `state push`,
> `init -migrate-state`).

## Architecture

```
eu-north-1a — VPC 10.20.0.0/16
├── public  10.20.1.0/24   rt: 0.0.0.0/0 → IGW
│   ├── frontend   Elastic IP, SG: 80/443 depuis Internet, 22 depuis /32 admin (option)
│   └── NAT Gateway (si private_egress_mode = nat_gateway)
└── private 10.20.11.0/24  rt: 0.0.0.0/0 → NAT (seulement en mode nat_gateway)
    ├── backend    sans IP publique, SG: 8000 depuis SG frontend
    └── database   sans IP publique, SG: 5432 depuis SG backend
                   + EBS gp3 30 Go chiffré dédié à PostgreSQL (/dev/xvdf)
VPC endpoint Gateway S3 (gratuit) sur les deux tables de routage.
```

| SG | Entrant | Sortant |
|---|---|---|
| frontend | 80, 443 ← 0.0.0.0/0 ; 22 ← `allowed_ssh_cidr` | 80, 443 → 0.0.0.0/0 ; 8000 → SG backend ; 22 → SG backend/database (si SSH) |
| backend | 8000 ← SG frontend ; 22 ← SG frontend (si SSH) | 80, 443, 587 → 0.0.0.0/0 ; 5432 → SG database |
| database | 5432 ← SG backend ; 22 ← SG frontend (si SSH) | 80, 443 → 0.0.0.0/0 |

Plus aucun egress « all traffic ». DNS (résolveur VPC) et NTP (Amazon Time
Sync) ne sont pas filtrés par les SG.

**Administration** : rôle IAM `AmazonSSMManagedInstanceCore` + instance
profile sur les trois instances (agent SSM préinstallé sur l'AMI Ubuntu
Canonical). Ansible passe par SSH-over-SSM (`AWS-StartSSHSession`) : aucun
port 22 nécessaire. `allowed_ssh_cidr` (strictement une IPv4 `/32`, ou `null`)
n'ouvre que le frontend, qui sert de rebond vers les instances privées.

## Besoins sortants des instances privées

| Besoin | Destination | backend | database | Couvert par VPC endpoint ? |
|---|---|---|---|---|
| Mises à jour / paquets Ubuntu | `*.archive.ubuntu.com`, `security.ubuntu.com` (HTTP 80) | ✔ | ✔ | **Non** |
| Installation Docker | `download.docker.com` (443) | ✔ | — | **Non** |
| Images applicatives | `ghcr.io`, `pkg-containers.githubusercontent.com` (443) | ✔ | — | **Non** (sauf migration vers ECR) |
| PostgreSQL 16 | dépôt apt Ubuntu (24.04) | — | ✔ | **Non** |
| SMTP Gmail | `smtp.gmail.com:587` | ✔ | — | **Non** |
| Systems Manager | `ssm`, `ssmmessages`, `ec2messages` (443) | ✔ | ✔ | Oui (interface endpoints) |

Conséquence : avec les rôles Ansible actuels, **le backend et la base ont
besoin d'un accès Internet sortant**. Des VPC endpoints seuls ne suffisent pas.

## Options d'egress (`private_egress_mode`, aucune valeur par défaut)

### `nat_gateway`, recommandé pour ce projet
- Tout fonctionne sans modifier Ansible (apt, Docker, GHCR, SMTP, SSM par Internet).
- Egress « contrôlé » au niveau des **ports** par les SG (80/443/587), pas au
  niveau des **domaines**.
- Une seule NAT dans une seule AZ : acceptable ici (tout est déjà mono-AZ).
- IP de sortie fixe (`nat_gateway_public_ip`), utile pour une allowlist externe.

### `vpc_endpoints`
- Interface endpoints SSM + Gateway S3 : administration SSM sans Internet.
- **Limitations bloquantes** : pas d'apt, pas de Docker CE, pas de GHCR, pas de
  SMTP. Rendre ce mode exploitable demanderait :
  - une AMI préparée (Packer) avec Docker, PostgreSQL et les mises à jour ;
  - le passage des images vers ECR (pull-through cache ECR vers ghcr.io, ou
    publication directe), plus les endpoints `ecr.api`, `ecr.dkr` et S3 ;
  - un relais SMTP joignable sans Internet (ex. Amazon SES via endpoint `email-smtp`).
- Il n'est pas moins cher ici (voir les coûts).

### `none`
- Instances privées totalement isolées (SSM indisponible). Réservé aux tests.

### Variantes d'egress contrôlé, non implémentées (à arbitrer)
- **NAT instance** (ex. t4g.nano dans le sous-réseau public) : bien moins cher
  qu'une NAT Gateway, mais point de défaillance unique et maintenance à prévoir.
  Un proxy Squid avec allowlist de domaines peut y être ajouté.
- **Route 53 Resolver DNS Firewall** : allowlist de domaines, coût faible.
  Ne bloque pas une connexion directe vers une adresse IP.
- **AWS Network Firewall** : filtrage par domaine (SNI) réel, mais coût horaire
  élevé par endpoint. Disproportionné pour ce projet.

## Coûts à vérifier (AWS Pricing Calculator, eu-north-1)

Ordres de grandeur **indicatifs, non contractuels** : à confirmer avant tout apply.

| Poste | Hypothèse | Ordre de grandeur |
|---|---|---|
| 3 × EC2 t3.small | 730 h/mois | ~15 à 17 $/mois chacune |
| EBS gp3 | 3 × 20 Go racine + 30 Go données | ~0,08 $/Go-mois, soit ~7 $/mois |
| IPv4 publiques | EIP frontend (+ EIP NAT) | ~0,005 $/h chacune, soit ~3,6 $/mois |
| NAT Gateway | mode `nat_gateway` | ~0,045 à 0,05 $/h (~33 à 37 $/mois) **+ ~0,045 $/Go traité** |
| Interface endpoints | mode `vpc_endpoints`, 3 endpoints × 1 AZ | ~0,01 $/h chacun (~22 à 25 $/mois) + ~0,01 $/Go |
| (+ ECR) | 2 endpoints de plus si migration ECR | ~+15 $/mois + stockage ECR |
| Gateway S3 | toujours | gratuit |
| Snapshots EBS | `final_snapshot`, snapshots manuels | ~0,05 $/Go-mois |
| Transfert sortant Internet | trafic utilisateurs | au-delà du palier gratuit, ~0,09 $/Go |

Points de vigilance : les `docker pull` répétés passent par la NAT et sont
facturés au Go traité. La NAT Gateway reste facturée même à l'arrêt des
instances : supprimez-la (`private_egress_mode = "none"`) entre deux sessions
de travail si besoin.

## Protection des ressources

- `prevent_destroy` : VPC, IGW, sous-réseaux, tables de routage, SG, instances,
  EIP frontend, volume EBS PostgreSQL et son attachement. NAT, EIP NAT et
  endpoints n'en ont pas, pour pouvoir changer de mode.
- `ignore_changes = [ami]` : une nouvelle AMI Canonical ne déclenche pas de
  remplacement. Mieux encore, figez `ami_id`.
- `disable_api_termination` (variable `termination_protection`, par défaut true).
- EBS PostgreSQL : chiffré, `final_snapshot = true`,
  `stop_instance_before_detaching = true`, AZ figée sur `availability_zone`.
  Agrandissable sans remplacement, jamais réductible.
- Attributs qui forcent un **remplacement** s'ils changent après création :
  `availability_zone`, `*_subnet_cidr`, `key_name`, chiffrement des volumes,
  description des SG. Ne pas les modifier une fois l'infrastructure créée.
- `prevent_destroy` n'agit que si le state existe : **un state perdu
  supprime toute protection**. D'où le backend S3 distant ci-dessous.

## State Terraform distant (backend S3)

`environments/prod` utilise `backend "s3"` (`key =
sunu-boutik/prod/terraform.tfstate`, `encrypt = true`, `use_lockfile = true`,
verrou natif `.tflock` sans DynamoDB, Terraform >= 1.11). Le bucket
`sunu-boutik-tfstate-<ID compte>` est **dédié au state**, distinct du bucket
des sauvegardes PostgreSQL, et créé au préalable par `terraform/bootstrap`
(module `modules/state_backend`) : versioning, SSE-S3, Block Public Access,
`prevent_destroy`, refus de supprimer state, versions et bucket, plus trois
politiques IAM minimales proposées (`state-rw`, `state-ro`,
`state-recovery`), non attachées.

Son nom n'est pas versionné : il est passé à l'init.

```bash
terraform init -backend-config=backend.s3.tfbackend   # voir backend.s3.tfbackend.example
```

Création du bucket, migration, permissions et restauration d'une version
précédente : [`docs/STATE_BACKEND.md`](docs/STATE_BACKEND.md). Contrôles
statiques hors ligne : `scripts/check_state_backend.sh`.

## Lien avec Ansible

`ansible/scripts/generate_inventory.sh` lit `terraform output -json` et écrit :
- `ansible/inventory/hosts.ini` : `CONNECTION_MODE=ssm` (ID d'instance +
  ProxyCommand SSM, par défaut) ou `bastion` (rebond SSH via l'EIP frontend) ;
- `ansible/inventory/group_vars/all/terraform.yml` : `frontend_public_ip`,
  `*_private_ip` (pour `env.api.j2`, `nginx`, `pg_hba`) et
  `postgresql_data_volume_id` (disque NVMe sur Nitro).

Outputs consommés : `aws_region`, `frontend_public_ip`, `*_private_ip`,
`*_instance_id`, `postgres_data_volume_id`, `postgres_backup_bucket`,
`ssh_enabled`.

## Sauvegardes PostgreSQL (`backup_enabled`, désactivé par défaut)

Module `modules/backup` : bucket S3 privé (Block Public Access, versioning,
SSE-S3, rétention par cycle de vie 7 j `daily/` et 28 j `weekly/`, politique
refusant HTTP, l'écriture hors endpoint VPC, les suppressions et les PUT
sans `If-None-Match`) et rôle IAM **dédié à l'instance database**
(SSM + `ListBucket`/`PutObject`/`GetObject` limités au préfixe).

L'activer **modifie en place** `aws_instance.database` (profil IAM seul,
sans remplacement) : à relire dans le plan. Tests hors ligne, provider
simulé : `terraform init -backend=false && terraform test` dans
`modules/backup` et `environments/prod`.
Exploitation : `ansible/docs/BACKUP_RESTORE.md`.

## À valider avant toute création réelle

1. Compte et profil AWS ciblés, droits IAM (création de rôle et `iam:PassRole`).
2. Choix explicite de `private_egress_mode` et coût mensuel accepté.
3. Quota d'Elastic IP en eu-north-1 (5 par défaut, déjà partagé avec les
   instances existantes).
4. Key pair `key_name` existante dans eu-north-1. AMI figée (`ami_id`).
5. Bucket du state créé (`terraform/bootstrap`), politique `state-rw`
   attachée à l'opérateur, `terraform init -backend-config=backend.s3.tfbackend`.
6. Poste opérateur : AWS CLI v2, `session-manager-plugin`, droit `ssm:StartSession`.
   Vérifier si `ec2messages` est encore requis par la version de l'agent SSM.
7. Plan de bascule DNS : le certificat Let's Encrypt (HTTP-01) exige que
   `sunu-boutique.online` pointe vers la nouvelle EIP. Les anciennes instances
   continuent de servir jusqu'à la bascule.
8. Aucune migration de données : la nouvelle base démarre vide. Sauvegardes
   à activer (`backup_enabled`) avant la mise en production.

`terraform plan` sert à relire les changements et ne vaut **pas**
autorisation de déploiement. Aucun `apply`, `destroy`, `import`,
`force-unlock`, `state push` ni `init -migrate-state` sans autorisation
explicite : voir [`docs/GUARDRAILS.md`](docs/GUARDRAILS.md).
