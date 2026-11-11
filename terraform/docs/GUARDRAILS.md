# Garde-fous permanents (Terraform Sunu-Boutik)

> Ces règles s'appliquent à toute personne ou tout outil (y compris un
> assistant) qui travaille sur `terraform/`. Elles priment sur toute
> procédure de ce dépôt. Une validation donnée pour une opération ne vaut
> que pour cette opération : elle ne s'étend ni à la suivante, ni à une
> autre session.

## Règles

1. **Aucune opération AWS réelle sans validation préalable.**
   Est « réelle » toute commande qui contacte AWS, même en lecture seule :
   `aws …` (dont `sts get-caller-identity`, `s3api get-*`,
   `list-object-versions`), `terraform init` avec backend, `plan`,
   `output`, `state list`, `state pull`, `refresh`. Seules les commandes
   hors ligne sont libres (voir plus bas).

2. **Autorisation explicite obligatoire**, commande par commande, pour :
   `terraform apply` (y compris `-refresh-only`), `terraform destroy`,
   `terraform import` (et tout bloc `import {}`), `terraform force-unlock`,
   `terraform state push`, `terraform init -migrate-state`.
   Un `terraform plan` relu ne vaut **pas** autorisation d'appliquer.

3. **Aucune suppression du state local sans vérification de la migration
   et sauvegarde préalable.** Avant de supprimer `terraform.tfstate` ou
   `terraform.tfstate.backup` :
   - une copie chiffrée (`age`) existe hors du dépôt et a été relue
     (déchiffrement testé, `serial` et `lineage` identiques) ;
   - `terraform state list` sur le backend distant donne le même nombre de
     ressources qu'avant migration ;
   - `terraform plan` affiche `No changes` ;
   - la version correspondante est visible dans `list-object-versions`.
   La suppression elle-même reste soumise à autorisation.

4. **Toute restauration du state préserve une copie de l'état courant.**
   Avant `copy-object`, `state push` ou tout remplacement, l'état courant
   est téléchargé, chiffré et conservé hors du dépôt, avec son `VersionId`
   noté. Une restauration S3 se fait **par copie** d'une version (jamais
   par suppression de versions), afin que la version remplacée reste dans
   l'historique.

5. **Les permissions IAM de récupération sont temporaires.**
   `sunu-boutik-terraform-state-recovery` n'est attachée que le temps
   d'une récupération autorisée, puis **détachée immédiatement après**, et
   le détachement est vérifié
   (`aws iam list-attached-role-policies` / `list-attached-user-policies`).
   L'attachement comme le détachement sont des opérations AWS réelles
   (règle 1) ; l'attachement exige une autorisation explicite.

6. **Le bucket du backend est indépendant du backend lui-même.**
   Le bucket `sunu-boutik-tfstate-<ID compte>` est créé et géré par
   `terraform/bootstrap`, dont le state reste **local** (`backend "local"`).
   Ne jamais migrer le state du bootstrap dans ce bucket, ni gérer ce bucket
   depuis `environments/prod`. Le bucket reste distinct de celui des
   sauvegardes PostgreSQL (`*-pg-backups-*`).

7. **Anciennes instances strictement hors périmètre.**

   | Instance | ID |
   |---|---|
   | `sunu-boutik` (historique) | `i-0a8fa28bbc839c1aa` |
   | `transfertpro` | `i-0f32b1aeb2a4ffe02` |

   Elles ne sont ni importées, ni référencées (aucune data source, aucun
   ID dans le code), ni lues, ni modifiées, ni arrêtées, ni supprimées,
   y compris lors d'une récupération de state ou d'un réimport.

## Commandes libres (hors ligne, sans AWS)

```bash
terraform fmt -recursive -check
terraform init -backend=false
terraform validate
terraform test                       # mock_provider / endpoints redirigés vers 127.0.0.1
scripts/check_state_backend.sh       # contrôles statiques, dont ces garde-fous
```

## Avant de demander une autorisation

Indiquer : la commande exacte, le répertoire, le compte et le profil AWS
visés, ce qui sera créé, modifié ou supprimé (sortie de `plan` si
applicable), la sauvegarde existante et le moyen de revenir en arrière.

Procédures détaillées : [`STATE_BACKEND.md`](STATE_BACKEND.md).
