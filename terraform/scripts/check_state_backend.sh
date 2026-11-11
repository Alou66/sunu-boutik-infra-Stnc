#!/usr/bin/env bash
# Contrôles statiques du backend de state Terraform (aucun appel AWS, aucun
# terraform init). Complète terraform fmt/validate/test.
# Usage : terraform/scripts/check_state_backend.sh
set -uo pipefail

TF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROD="$TF_ROOT/environments/prod"
BOOT="$TF_ROOT/bootstrap"
MOD="$TF_ROOT/modules/state_backend"
DOC="$TF_ROOT/docs/STATE_BACKEND.md"
GUARD="$TF_ROOT/docs/GUARDRAILS.md"
fails=0

ok() { printf '  OK   %s\n' "$1"; }
ko() { printf '  ÉCHEC %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi; }

# Fichiers .tf/.hcl/.tfbackend suivis (hors .terraform), commentaires retirés
tf_files() { find "$TF_ROOT" -path '*/.terraform' -prune -o -type f \( -name '*.tf' -o -name '*.tftest.hcl' -o -name '*.tfbackend*' -o -name '*.tfvars.example' \) -print; }
strip() { sed -E 's/[[:space:]]*#.*$//' "$1"; }

# Bloc backend de prod (lignes entre `backend "..." {` et son `}`)
backend_block="$(strip "$PROD/versions.tf" | awk '/backend "/{f=1} f{print} f&&/^[[:space:]]*}/{exit}')"
attr() { echo "$backend_block" | grep -E "^[[:space:]]*$1[[:space:]]*=" | sed -E 's/^[^=]*=[[:space:]]*//; s/"//g; s/[[:space:]]*$//'; }

echo "== Backend environments/prod"
check "un seul bloc backend" '[ "$(strip "$PROD/versions.tf" | grep -c "backend \"")" = 1 ]'
check "backend de type s3" 'echo "$backend_block" | grep -q "backend \"s3\""'
check "use_lockfile = true" '[ "$(attr use_lockfile)" = true ]'
check "encrypt = true" '[ "$(attr encrypt)" = true ]'
check "region = eu-north-1" '[ "$(attr region)" = eu-north-1 ]'
check "key fixe se terminant par .tfstate" 'attr key | grep -Eq "^[A-Za-z0-9._/-]+\.tfstate$"'
check "pas de dynamodb_table (verrou natif S3)" '! echo "$backend_block" | grep -q dynamodb'
check "pas d'identifiants/profil dans le backend" '! echo "$backend_block" | grep -Eq "^[[:space:]]*(access_key|secret_key|token|profile|shared_credentials_files?|assume_role)[[:space:]]*="'
check "bucket non codé en dur (fourni par -backend-config)" '[ -z "$(attr bucket)" ]'
check "required_version >= 1.11 (use_lockfile)" 'strip "$PROD/versions.tf" | grep -Eq "required_version[[:space:]]*=[[:space:]]*\">= 1\.(1[1-9]|[2-9][0-9])"'

echo "== Cohérence bootstrap / prod"
key="$(attr key)"
check "state_keys du bootstrap contient la key de prod ($key)" 'strip "$BOOT/variables.tf" | grep -Fq "\"$key\""'
check "exemple tfvars du bootstrap cohérent" 'grep -Fq "\"$key\"" "$BOOT/terraform.tfvars.example"'
check "bootstrap sur state local (pas de dépendance circulaire)" 'strip "$BOOT/versions.tf" | grep -q "backend \"local\""'
check "bootstrap et prod : même région" 'strip "$BOOT/variables.tf" | grep -q "default[[:space:]]*=[[:space:]]*\"$(attr region)\""'

echo "== Bucket du state distinct du bucket de sauvegarde"
check "nom par défaut *-tfstate-*" 'grep -q "tfstate-\${data.aws_caller_identity" "$MOD/main.tf"'
check "validation refusant pg-backups" 'grep -q "pg-backups" "$MOD/variables.tf"'
check "exemple tfbackend : seul l'attribut bucket" '[ "$(strip "$PROD/backend.s3.tfbackend.example" | grep -E "=" | grep -vc "^bucket[[:space:]]*=")" = 0 ]'
check "exemple tfbackend : pas le bucket pg-backups" '! grep -q "pg-backups" "$PROD/backend.s3.tfbackend.example"'
check "aucune ressource de prod ne vise le bucket du state" '! grep -rq "tfstate" "$TF_ROOT/modules/backup" "$PROD/main.tf"'

echo "== Protections du bucket"
check "prevent_destroy sur aws_s3_bucket.state" 'awk "/resource \"aws_s3_bucket\" \"state\"/,/^}/" "$MOD/main.tf" | grep -q "prevent_destroy = true"'
check "force_destroy = false" 'grep -q "force_destroy = false" "$MOD/main.tf"'
check "versioning Enabled" 'grep -q "status = \"Enabled\"" "$MOD/main.tf"'
check "SSE AES256" 'grep -q "sse_algorithm = \"AES256\"" "$MOD/main.tf"'
for o in block_public_acls block_public_policy ignore_public_acls restrict_public_buckets; do
  check "public access block : $o = true" 'grep -Eq "$o[[:space:]]*= true" "$MOD/main.tf"'
done
for sid in DenyInsecureTransport DenyStateDeletion DenyVersionDeletion DenyBucketDeletion; do
  check "politique du bucket : $sid" 'grep -q "sid[[:space:]]*= \"$sid\"" "$MOD/main.tf"'
done
# prevent_destroy existants (C1/C2) + bucket du state : aucun ne doit disparaître
for m in vpc:6 security_groups:3 ec2:6 backup:1 state_backend:1; do
  n="$(strip "$TF_ROOT/modules/${m%%:*}/main.tf" | grep -c "prevent_destroy = true")"
  check "prevent_destroy modules/${m%%:*} : $n (attendu >= ${m##*:})" '[ "$n" -ge "${m##*:}" ]'
done

echo "== Permissions IAM proposées"
iam_actions="$(awk '/data "aws_iam_policy_document" "state_(rw|ro|recovery)"/,/^}/' "$MOD/main.tf" | grep -oE '"s3:[A-Za-z*]+"' | sort -u | tr -d '"' | tr '\n' ' ')"
check "actions limitées au backend S3 ($iam_actions)" '[ "$iam_actions" = "s3:DeleteObject s3:GetObject s3:GetObjectVersion s3:ListBucket s3:ListBucketVersions s3:PutObject " ]'
check "aucun joker d'action IAM" '! awk "/data \"aws_iam_policy_document\" \"state_(rw|ro|recovery)\"/,/^}/" "$MOD/main.tf" | grep -Eq "\"(s3:\*|\*)\""'
check "DeleteObject uniquement sur le .tflock" '[ "$(awk "/sid *= \"ManageLockFile\"/,/}/" "$MOD/main.tf" | grep -c DeleteObject)" = 1 ] && [ "$(awk "/data \"aws_iam_policy_document\" \"state_(rw|ro|recovery)\"/,/^}/" "$MOD/main.tf" | grep -c DeleteObject)" = 1 ]'
check "politiques IAM jamais attachées par Terraform" '! grep -Eq "aws_iam_(role|user|group)_policy_attachment|aws_iam_policy_attachment" "$MOD/main.tf" "$BOOT/main.tf"'

echo "== Hors périmètre : anciennes instances"
check "aucune référence aux anciennes instances" '! tf_files | xargs grep -Eq "i-0a8fa28bbc839c1aa|i-0f32b1aeb2a4ffe02|transfertpro"'
check "aucune data source aws_instance(s)" '! tf_files | xargs grep -Eq "data \"aws_instances?\""'
check "aucun bloc import" '! tf_files | xargs grep -Eq "^[[:space:]]*import[[:space:]]*\{"'
check "bootstrap sans aucune ressource EC2" '! grep -rq "aws_instance\|aws_ec2\|aws_ebs" "$BOOT" "$MOD" --include=*.tf'

echo "== Secrets"
check "aucune clé d'accès AWS (AKIA/ASIA)" '! tf_files | xargs grep -Eq "(AKIA|ASIA)[0-9A-Z]{16}"'
check "aucune clé secrète AWS (40 car.)" '! tf_files | xargs grep -Eiq "secret[_a-z]*[[:space:]]*=[[:space:]]*\"[A-Za-z0-9/+]{40}\""'
check "aucun state/tfbackend réel présent dans le dépôt" '[ -z "$(find "$TF_ROOT" -path "*/.terraform" -prune -o \( -name "*.tfstate" -o -name "*.tfstate.*" -o -name "*.tfbackend" -o -name "*.tflock" \) -print)" ]'
for d in "$PROD" "$BOOT"; do
  for p in '*.tfstate' '*.tfbackend' '*.tfvars'; do
    check "gitignore $(basename "$d") : $p" 'grep -qxF "$p" "$d/.gitignore"'
  done
done

echo "== Documentation"
for s in "Création préalable du bucket" "migration du state" "Récupération du state" "Permissions IAM proposées"; do
  check "section : $s" 'grep -iq "^##.*$s" "$DOC"'
done
check "doc : key identique à versions.tf" 'grep -Fq "$key" "$DOC"'
check "doc : restauration par copy-object versionId" 'grep -q "copy-object" "$DOC" && grep -q "versionId=" "$DOC"'
check "doc : -reconfigure signalé comme interdit" 'grep -q "Ne jamais utiliser \`-reconfigure\`" "$DOC"'
check "doc : force-unlock soumis à autorisation" 'grep "force-unlock" "$DOC" | grep -q AUTORISATION'
check "doc : -migrate-state soumis à autorisation" 'grep -- "-migrate-state" "$DOC" | grep -q AUTORISATION'
check "doc : apply soumis à autorisation" 'grep "terraform apply" "$DOC" | grep -vq -- "-refresh-only" && ! grep "terraform apply" "$DOC" | grep -v AUTORISATION | grep -q .'
check "README pointe vers la doc" 'grep -q "docs/STATE_BACKEND.md" "$TF_ROOT/README.md"'
check "doc : state push soumis à autorisation" '! grep "terraform state push" "$DOC" | grep -v AUTORISATION | grep -q .'
check "doc : copie de l'état courant avant restauration" 'grep -q "Préserver l.état courant" "$DOC"'

echo "== Garde-fous permanents"
check "docs/GUARDRAILS.md présent" '[ -f "$GUARD" ]'
check "README pointe vers les garde-fous" 'grep -q "docs/GUARDRAILS.md" "$TF_ROOT/README.md"'
check "STATE_BACKEND.md pointe vers les garde-fous" 'grep -q "GUARDRAILS.md" "$DOC"'
check "règle : aucune opération AWS sans validation" 'grep -q "Aucune opération AWS réelle sans validation préalable" "$GUARD"'
for c in "terraform apply" "terraform destroy" "terraform import" "terraform force-unlock" "terraform state push" "terraform init -migrate-state"; do
  check "règle : autorisation explicite pour $c" 'grep -Fq "\`$c\`" "$GUARD"'
done
check "règle : state local supprimé après vérif. + sauvegarde" 'grep -q "Aucune suppression du state local sans vérification" "$GUARD"'
check "règle : copie de l'état courant à la restauration" 'grep -q "préserve une copie de l.état courant" "$GUARD"'
check "règle : permissions de récupération temporaires" 'grep -q "permissions IAM de récupération sont temporaires" "$GUARD"'
check "règle : bucket indépendant du backend" 'grep -q "indépendant du backend" "$GUARD"'
check "règle : anciennes instances hors périmètre" 'grep -q "i-0a8fa28bbc839c1aa" "$GUARD" && grep -q "i-0f32b1aeb2a4ffe02" "$GUARD"'

echo
if [ "$fails" -eq 0 ]; then echo "Tous les contrôles statiques passent."; else echo "$fails contrôle(s) en échec."; fi
exit $((fails > 0))
