#!/usr/bin/env bash
# Banc de tests HORS LIGNE des scripts de sauvegarde/restauration.
#
# Conteneur Ubuntu 24.04 lancé avec --network none : aucun accès à AWS ni à
# Internet. S3 est simulé par fake-aws (stockage local), PostgreSQL 16 tourne
# dans le conteneur avec des données fictives, les clés age sont jetables.
#
# Prérequis : docker, ansible-playbook (rendu des templates du rôle).
# Usage     : ansible/roles/postgresql_backup/tests/run.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROLE=$(dirname "$HERE")
IMAGE=sunu-boutik-backup-test:noble
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sunu-backup-test.XXXXXX")
mkdir -p "$WORK/keys" "$WORK/rendered" "$WORK/bin"

echo "Image de test ($IMAGE)…"
docker build -q -t "$IMAGE" "$HERE" >/dev/null

echo "Clés age jetables…"
docker run --rm --network none -v "$WORK/keys":/k "$IMAGE" sh -c \
  "age-keygen -o /k/backup.key 2>/dev/null && age-keygen -o /k/wrong.key 2>/dev/null && chown $(id -u):$(id -g) /k/* && chmod 600 /k/*"
RECIPIENT=$(docker run --rm --network none -v "$WORK/keys":/k:ro "$IMAGE" age-keygen -y /k/backup.key)

echo "Rendu des templates du rôle…"
ansible-playbook -i localhost, "$HERE/render.yml" \
  -e test_work_dir="$WORK" \
  -e postgresql_backup_bucket=sunu-boutik-pg-backups-test \
  -e postgresql_backup_age_recipient="$RECIPIENT" >/dev/null

install -m 0755 "$HERE/fake-aws" "$WORK/bin/aws"
install -m 0755 "$HERE/run_tests.sh" "$WORK/run_tests.sh"

echo "Exécution des tests (réseau désactivé)…"
rc=0
docker run --rm --network none -e HOST_UID="$(id -u)" \
  -v "$ROLE/files":/src:ro -v "$WORK":/test "$IMAGE" bash /test/run_tests.sh || rc=$?

rm -rf -- "$WORK/keys"
echo "Résultats et journaux : $WORK/results"
exit "$rc"
