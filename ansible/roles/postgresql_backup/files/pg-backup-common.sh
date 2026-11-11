# shellcheck shell=bash
# Fonctions communes à sunu-boutik-pg-backup et sunu-boutik-pg-restore.
# Installé par Ansible dans /usr/local/lib/sunu-boutik/ (rôle postgresql_backup).
#
# Configuration : /etc/sunu-boutik/pg-backup.conf (lignes PGBACKUP_*=valeur).
# Une variable déjà présente dans l'environnement est prioritaire sur le
# fichier (utilisé par les tests). Aucun secret n'est stocké dans ce fichier :
# PostgreSQL est joint par socket local (authentification peer), AWS par le
# rôle IAM de l'instance, et seule la clé PUBLIQUE age y figure.

# Codes de sortie (documentés dans docs/BACKUP_RESTORE.md), utilisés par les
# scripts qui sourcent ce fichier.
# shellcheck disable=SC2034
readonly EXIT_CONFIG=2 EXIT_DB_UNAVAILABLE=3 EXIT_DUMP=4 EXIT_INTEGRITY=5 \
  EXIT_CRYPTO=6 EXIT_S3=7 EXIT_S3_VERIFY=8 EXIT_LOCAL=9 \
  EXIT_ALREADY_EXISTS=10 EXIT_NOT_FOUND=11 EXIT_STALE=12 EXIT_TARGET=13

PGBACKUP_CONF="${PGBACKUP_CONF:-/etc/sunu-boutik/pg-backup.conf}"

# Masque tout ce qui ressemble à un secret avant journalisation : clés AWS,
# jetons de session, signatures, clé privée age, mot de passe d'URL.
redact() {
  sed -E \
    -e 's/(AKIA|ASIA)[A-Z0-9]{16}/\1****/g' \
    -e 's/AGE-SECRET-KEY-1[0-9A-Z]+/AGE-SECRET-KEY-****/g' \
    -e 's/((X-Amz-)?(Signature|Security-Token|Credential)=)[^&[:space:]]+/\1****/Ig' \
    -e 's/((password|passwd|secret|token)[[:space:]]*[=:][[:space:]]*)[^[:space:]&]+/\1****/Ig' \
    -e 's#(postgres(ql)?://[^:/@[:space:]]+:)[^@[:space:]]+@#\1****@#g'
}

log() {
  local level=$1
  shift
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" | redact >&2
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
error() { log ERROR "$@"; }
die() {
  local code=$1
  shift
  error "$*"
  exit "$code"
}

# Journalise au plus 5 lignes d'erreur d'un outil (masquées par redact).
log_tool_error() {
  local tool=$1 file=$2
  [[ -s $file ]] || return 0
  grep -v '^[[:space:]]*$' -- "$file" | head -n 5 | while IFS= read -r line; do
    error "$tool: $line"
  done
}

# Lecture stricte du fichier de configuration : uniquement des affectations
# PGBACKUP_*, jamais exécuté comme du shell.
load_config() {
  local line key value
  if [[ ! -e $PGBACKUP_CONF ]]; then
    info "configuration $PGBACKUP_CONF absente : variables d'environnement seules"
    return 0
  fi
  [[ -r $PGBACKUP_CONF ]] || die "$EXIT_CONFIG" "configuration $PGBACKUP_CONF illisible"
  if [[ -n $(find "$PGBACKUP_CONF" -maxdepth 0 -perm /022) ]]; then
    die "$EXIT_CONFIG" "configuration $PGBACKUP_CONF modifiable par le groupe ou les autres : refusée"
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ $line =~ ^(PGBACKUP_[A-Z0-9_]+)=(.*)$ ]]; then
      key=${BASH_REMATCH[1]}
      value=${BASH_REMATCH[2]}
      value=${value%\"}
      value=${value#\"}
      if [[ -z ${!key+x} ]]; then
        printf -v "$key" '%s' "$value"
      fi
    else
      die "$EXIT_CONFIG" "ligne de configuration invalide dans $PGBACKUP_CONF"
    fi
  done <"$PGBACKUP_CONF"
}

# Valeurs par défaut et validation des paramètres communs.
validate_common() {
  PGBACKUP_DB=${PGBACKUP_DB:-sunuboutik}
  PGBACKUP_PORT=${PGBACKUP_PORT:-5432}
  PGBACKUP_PREFIX=${PGBACKUP_PREFIX:-postgresql/$PGBACKUP_DB}
  PGBACKUP_REGION=${PGBACKUP_REGION:-eu-north-1}
  PGBACKUP_WORK_DIR=${PGBACKUP_WORK_DIR:-/var/backups/sunu-boutik-pg}
  PGBACKUP_AWS_BIN=${PGBACKUP_AWS_BIN:-aws}
  PGBACKUP_PG_BIN_DIR=${PGBACKUP_PG_BIN_DIR:-/usr/lib/postgresql/16/bin}
  PGBACKUP_BUCKET=${PGBACKUP_BUCKET:-}

  [[ $PGBACKUP_DB =~ ^[a-z_][a-z0-9_]{0,62}$ ]] ||
    die "$EXIT_CONFIG" "PGBACKUP_DB invalide"
  [[ $PGBACKUP_PORT =~ ^[0-9]{1,5}$ ]] ||
    die "$EXIT_CONFIG" "PGBACKUP_PORT invalide"
  [[ $PGBACKUP_BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
    die "$EXIT_CONFIG" "PGBACKUP_BUCKET absent ou invalide"
  [[ $PGBACKUP_PREFIX =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && $PGBACKUP_PREFIX != *..* ]] ||
    die "$EXIT_CONFIG" "PGBACKUP_PREFIX invalide (ni / initial ou final, ni ..)"
  [[ $PGBACKUP_REGION =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] ||
    die "$EXIT_CONFIG" "PGBACKUP_REGION invalide"
  [[ $PGBACKUP_WORK_DIR == /* ]] ||
    die "$EXIT_CONFIG" "PGBACKUP_WORK_DIR doit être un chemin absolu"

  if [[ -d $PGBACKUP_PG_BIN_DIR ]]; then
    PATH="$PGBACKUP_PG_BIN_DIR:$PATH"
  fi
  export PATH
  # Jamais de mot de passe PostgreSQL : socket local, authentification peer.
  unset PGPASSWORD
  export PGCONNECT_TIMEOUT=10
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "$EXIT_CONFIG" "commande requise introuvable : $cmd"
  done
}

prepare_work_dir() {
  if [[ ! -d $PGBACKUP_WORK_DIR ]]; then
    mkdir -p -- "$PGBACKUP_WORK_DIR" ||
      die "$EXIT_LOCAL" "impossible de créer $PGBACKUP_WORK_DIR"
  fi
  [[ -w $PGBACKUP_WORK_DIR ]] || die "$EXIT_LOCAL" "$PGBACKUP_WORK_DIR non accessible en écriture"
  chmod 0700 -- "$PGBACKUP_WORK_DIR" 2>/dev/null || true
}

# Verrou : une seule opération (sauvegarde ou restauration) à la fois.
acquire_lock() {
  exec 9>"$PGBACKUP_WORK_DIR/.lock"
  flock -n 9 || die "$EXIT_LOCAL" "une autre sauvegarde ou restauration est en cours (verrou $PGBACKUP_WORK_DIR/.lock)"
}

# Clés S3 : <prefix>/<daily|weekly>/<db>_<AAAAMMJJTHHMMSSZ>.dump.age
backup_key() { printf '%s/%s/%s_%s.dump.age' "$PGBACKUP_PREFIX" "$1" "$PGBACKUP_DB" "$2"; }
backup_key_regex() { printf '^%s/(daily|weekly)/%s_[0-9]{8}T[0-9]{6}Z\\.dump\\.age$' "$PGBACKUP_PREFIX" "$PGBACKUP_DB"; }

# Appel AWS CLI : sortie JSON sur stdout, erreurs dans $S3_ERR (journalisées
# masquées). Souvent appelé dans $(…) : l'erreur est donc classée plus tard
# par s3_fail depuis $S3_ERR, et non via une variable perdue dans le
# sous-shell.
s3api() {
  local rc=0
  : >"$S3_ERR"
  "$PGBACKUP_AWS_BIN" --region "$PGBACKUP_REGION" --no-cli-pager --output json \
    s3api "$@" 2>"$S3_ERR" || rc=$?
  ((rc == 0)) || log_tool_error aws "$S3_ERR"
  return "$rc"
}

s3_error_kind() {
  if grep -qiE 'checksum.*(did not match|mismatch)|BadDigest' "$S3_ERR"; then
    echo checksum
  elif grep -qE 'PreconditionFailed|\(412\)' "$S3_ERR"; then
    echo already_exists
  elif grep -qE 'AccessDenied|Forbidden|\(403\)' "$S3_ERR"; then
    echo access_denied
  elif grep -qE 'NoSuchBucket' "$S3_ERR"; then
    echo no_bucket
  elif grep -qE 'NoSuchKey|Not Found|\(404\)' "$S3_ERR"; then
    echo not_found
  elif grep -qE 'Unable to locate credentials|NoCredentialProviders' "$S3_ERR"; then
    echo no_credentials
  else
    echo other
  fi
}

s3_fail() {
  local code=$1 action=$2
  case $(s3_error_kind) in
    checksum) die "$EXIT_INTEGRITY" "$action : fichier corrompu (checksum S3 non conforme)" ;;
    access_denied) die "$code" "$action : accès S3 refusé (rôle IAM de l'instance ou politique du bucket)" ;;
    no_credentials) die "$code" "$action : aucun identifiant AWS (profil d'instance absent ?)" ;;
    no_bucket) die "$code" "$action : bucket $PGBACKUP_BUCKET introuvable" ;;
    not_found) die "$EXIT_NOT_FOUND" "$action : sauvegarde introuvable" ;;
    already_exists) die "$EXIT_ALREADY_EXISTS" "$action : l'objet existe déjà, écrasement refusé" ;;
    *) die "$code" "$action : échec S3" ;;
  esac
}

sha256_hex() { sha256sum -- "$1" | cut -d' ' -f1; }
sha256_b64() { openssl dgst -sha256 -binary -- "$1" | base64; }
file_size() { stat -c %s -- "$1"; }

# Exécute une requête SQL d'une ligne (socket local, sans mot de passe).
psql_value() {
  local db=$1 sql=$2
  psql -X -A -t -q --no-password -p "$PGBACKUP_PORT" -d "$db" -c "$sql"
}
