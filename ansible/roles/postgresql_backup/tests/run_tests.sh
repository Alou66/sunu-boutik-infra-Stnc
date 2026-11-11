#!/usr/bin/env bash
# Banc de tests des scripts de sauvegarde/restauration (conteneur Ubuntu
# 24.04, --network none : aucun accès AWS possible). Données 100 % fictives.
set -uo pipefail

SRC=/src            # ansible/roles/postgresql_backup/files (lecture seule)
IN=/test            # entrées (clés, conf rendue, faux aws) et résultats (run.sh)
W=/work
LOGS=$W/logs
mkdir -p "$LOGS" "$W/s3" /etc/sunu-boutik /usr/local/lib/sunu-boutik
PASS=0 FAIL=0
RESULTS=$W/results.txt
: >"$RESULTS"

BUCKET=sunu-boutik-pg-backups-test
PREFIX=postgresql/sunuboutik
FAKE_DB_PASSWORD='FakeDbPassw0rd!Xy9'
export AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKE1234
export AWS_SECRET_ACCESS_KEY=FakeSecretAccessKey0123456789abcdefXYZ0

record() { # nom, attendu, obtenu, détail
  if [[ $2 == "$3" ]]; then
    PASS=$((PASS + 1)); printf 'PASS  %-58s rc=%s\n' "$1" "$3" | tee -a "$RESULTS"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-58s attendu=%s obtenu=%s %s\n' "$1" "$2" "$3" "${4:-}" | tee -a "$RESULTS"
  fi
}
check() { # nom, condition (commande)
  local name=$1; shift
  if "$@"; then record "$name" ok ok; else record "$name" ok ko; fi
}

PG_ENV=(PGBACKUP_AWS_BIN=/usr/local/bin/aws FAKE_S3_ROOT=$W/s3 FAKE_S3_LOG=$W/s3.log
  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
as_pg() { runuser -u postgres -- env "${PG_ENV[@]}" "$@"; }
# Lance une commande en tant que postgres, journalise, vérifie le code retour.
run_case() { # nom, rc attendu, commande…
  local name=$1 expected=$2 rc=0
  shift 2
  as_pg "$@" >"$LOGS/$name.log" 2>&1 || rc=$?
  record "$name" "$expected" "$rc" "(voir logs/$name.log)"
}
psql_pg() { runuser -u postgres -- psql -X -A -t -q "$@"; }
fingerprint() { # empreinte des données d'une base
  local db=$1 t
  for t in users shops products invoices; do
    psql_pg -d "$db" -c "SELECT '$t:' || count(*) || ':' || md5(coalesce(string_agg(x::text, '|' ORDER BY id), '')) FROM $t x"
  done
  psql_pg -d "$db" -c "SELECT 'seq:' || last_value FROM users_id_seq"
  psql_pg -d "$db" -c "SELECT 'view:' || count(*) FROM shop_stats"
}
workdir_clean() { [[ -z $(find /var/backups/sunu-boutik-pg -mindepth 1 ! -name .lock -print -quit) ]]; }
s3_obj() { echo "$W/s3/$BUCKET/objects/$1"; }
s3_meta() { echo "$W/s3/$BUCKET/meta/$1.json"; }

echo "== Installation (chemins identiques au rôle Ansible)"
install -o root -g root -m 0644 "$SRC/pg-backup-common.sh" /usr/local/lib/sunu-boutik/
install -o root -g root -m 0755 "$SRC/sunu-boutik-pg-backup" "$SRC/sunu-boutik-pg-restore" /usr/local/sbin/
install -o root -g root -m 0755 "$IN/bin/aws" /usr/local/bin/aws
install -o root -g postgres -m 0640 "$IN/rendered/pg-backup.conf" /etc/sunu-boutik/pg-backup.conf
install -d -o postgres -g postgres -m 0700 /var/backups/sunu-boutik-pg
mkdir -p "$W/s3/$BUCKET"
install -o postgres -g postgres -m 0600 /dev/null "$W/s3.log"
chown -R postgres:postgres "$W/s3"
install -d -m 0700 /root/keys
install -m 0600 "$IN/keys/backup.key" "$IN/keys/wrong.key" /root/keys/
# Procédure documentée : clé privée copiée temporairement en tmpfs, postgres seul
install -o postgres -g postgres -m 0600 /root/keys/backup.key /dev/shm/restore.key
install -o postgres -g postgres -m 0600 /root/keys/wrong.key /dev/shm/wrong.key

echo "== Cluster PostgreSQL 16 et données fictives"
pg_ctlcluster 16 main start
psql_pg -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE sunu_app LOGIN PASSWORD '$FAKE_DB_PASSWORD';
CREATE DATABASE sunuboutik OWNER sunu_app TEMPLATE template0 ENCODING 'UTF8';
SQL
psql_pg -d sunuboutik -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
SET ROLE sunu_app;
CREATE TABLE users (id serial PRIMARY KEY, email text UNIQUE NOT NULL, password_hash text NOT NULL,
  role text NOT NULL, created_at timestamptz NOT NULL DEFAULT '2026-01-01');
CREATE TABLE shops (id serial PRIMARY KEY, owner_id int NOT NULL REFERENCES users(id), name text, status text);
CREATE TABLE products (id serial PRIMARY KEY, shop_id int NOT NULL REFERENCES shops(id), name text,
  price numeric(12,2), stock int CHECK (stock >= 0));
CREATE TABLE invoices (id serial PRIMARY KEY, shop_id int NOT NULL REFERENCES shops(id),
  total numeric(12,2), payload jsonb);
INSERT INTO users (email, password_hash, role)
  SELECT 'client' || g || '@fake.invalid', '$2b$12$FAKEHASH' || md5(g::text), CASE WHEN g = 1 THEN 'admin' ELSE 'owner' END
  FROM generate_series(1, 200) g;
INSERT INTO shops (owner_id, name, status)
  SELECT 1 + g % 200, 'Boutique fictive ' || g, CASE WHEN g % 3 = 0 THEN 'pending' ELSE 'active' END
  FROM generate_series(1, 50) g;
INSERT INTO products (shop_id, name, price, stock)
  SELECT 1 + g % 50, 'Thiéboudienne n°' || g, (g % 97) * 125.5, g % 40 FROM generate_series(1, 2000) g;
INSERT INTO invoices (shop_id, total, payload)
  SELECT 1 + g % 50, g * 10.25, jsonb_build_object('lignes', g % 7, 'note', 'facture fictive ' || g)
  FROM generate_series(1, 5000) g;
CREATE INDEX products_shop_idx ON products (shop_id);
CREATE VIEW shop_stats AS SELECT s.id, count(p.id) AS nb FROM shops s LEFT JOIN products p ON p.shop_id = s.id GROUP BY s.id;
SQL
SRC_FP=$(fingerprint sunuboutik)
echo "$SRC_FP" >"$W/source.fp"

echo "== 1. Analyse statique"
rc=0; shellcheck -x -P "$SRC" "$SRC/pg-backup-common.sh" "$SRC/sunu-boutik-pg-backup" "$SRC/sunu-boutik-pg-restore" >"$LOGS/shellcheck.log" 2>&1 || rc=$?
record "shellcheck (3 scripts)" 0 "$rc"
rc=0; for f in "$SRC"/*; do bash -n "$f" || rc=1; done; record "bash -n (syntaxe)" 0 "$rc"
run_case backup_help 0 sunu-boutik-pg-backup --help
run_case restore_help 0 sunu-boutik-pg-restore --help
run_case restore_unknown_cmd 2 sunu-boutik-pg-restore drop

echo "== 2. Configuration invalide"
run_case cfg_bucket_absent 2 env PGBACKUP_BUCKET= sunu-boutik-pg-backup
run_case cfg_recipient_invalide 2 env PGBACKUP_AGE_RECIPIENT=age1invalide sunu-boutik-pg-backup
run_case cfg_prefix_traversal 2 env PGBACKUP_PREFIX=postgresql/../autre sunu-boutik-pg-backup
cp /etc/sunu-boutik/pg-backup.conf "$W/bad.conf"; chown root:postgres "$W/bad.conf"; chmod 0666 "$W/bad.conf"
run_case cfg_conf_modifiable_par_tous 2 env PGBACKUP_CONF="$W/bad.conf" sunu-boutik-pg-backup
cp /etc/sunu-boutik/pg-backup.conf "$W/inj.conf"; echo 'touch /tmp/injection' >>"$W/inj.conf"; chmod 0644 "$W/inj.conf"
run_case cfg_ligne_shell_refusee 2 env PGBACKUP_CONF="$W/inj.conf" sunu-boutik-pg-backup
check "cfg : aucune exécution de code depuis la conf" test ! -e /tmp/injection

echo "== 3. Sauvegarde nominale"
TODAY=$(date -u +%u); OTHER=$((TODAY % 7 + 1))
TS1=20261101T023000Z
run_case backup_quotidienne 0 env PGBACKUP_TIMESTAMP=$TS1 PGBACKUP_WEEKLY_DAY=$OTHER sunu-boutik-pg-backup
K1=$PREFIX/daily/sunuboutik_$TS1.dump.age
check "objet daily créé" test -f "$(s3_obj "$K1")"
check "pas d'objet weekly hors jour hebdo" test ! -e "$(s3_obj "$PREFIX/weekly/sunuboutik_$TS1.dump.age")"
check "PUT avec If-None-Match: *" grep -q '"op": "put-object".*"if-none-match": "\*"' "$W/s3.log"
check "métadonnées sha256 + SSE AES256" bash -c "jq -e '.Metadata[\"enc-sha256\"] and .Metadata[\"plain-sha256\"] and .ServerSideEncryption == \"AES256\"' '$(s3_meta "$K1")' >/dev/null"
check "objet chiffré au format age" bash -c "head -c 21 '$(s3_obj "$K1")' | grep -q 'age-encryption.org/v1'"
check "aucune donnée en clair dans l'objet S3" bash -c "! grep -aqE 'fake\.invalid|FAKEHASH|Thi|CREATE TABLE|sunu_app' '$(s3_obj "$K1")'"
check "répertoire de travail vidé" workdir_clean

TS2=$(date -u +%Y%m%dT%H%M%SZ)
run_case backup_jour_hebdomadaire 0 env PGBACKUP_TIMESTAMP=$TS2 PGBACKUP_WEEKLY_DAY=$TODAY sunu-boutik-pg-backup
check "objets daily et weekly créés" test -f "$(s3_obj "$PREFIX/daily/sunuboutik_$TS2.dump.age")" -a -f "$(s3_obj "$PREFIX/weekly/sunuboutik_$TS2.dump.age")"

echo "== 4. Protection contre l'écrasement"
SHA_BEFORE=$(sha256sum "$(s3_obj "$K1")" | cut -d' ' -f1)
run_case ecrasement_refuse 10 env PGBACKUP_TIMESTAMP=$TS1 PGBACKUP_WEEKLY_DAY=$OTHER sunu-boutik-pg-backup
check "objet existant inchangé" test "$SHA_BEFORE" = "$(sha256sum "$(s3_obj "$K1")" | cut -d' ' -f1)"
check "répertoire de travail vidé après échec" workdir_clean

echo "== 5. Échecs S3 et base"
run_case s3_acces_refuse_put 7 env FAKE_S3_DENY=put PGBACKUP_WEEKLY_DAY=$OTHER sunu-boutik-pg-backup
check "message accès refusé explicite" grep -q 'accès S3 refusé' "$LOGS/s3_acces_refuse_put.log"
check "identifiant AWS masqué dans le message" bash -c "grep -q 'Credential=\*\*\*\*' '$LOGS/s3_acces_refuse_put.log' && ! grep -q 'AKIAFAKEFAKEFAKE1234' '$LOGS/s3_acces_refuse_put.log'"
check "signature masquée" bash -c "! grep -q deadbeefcafe '$LOGS/s3_acces_refuse_put.log'"
check "aucun dump en clair laissé après refus S3" workdir_clean
run_case s3_acces_refuse_head 8 env FAKE_S3_DENY=head PGBACKUP_WEEKLY_DAY=$OTHER sunu-boutik-pg-backup
run_case s3_sans_identifiants 7 env FAKE_S3_NOCREDS=1 PGBACKUP_WEEKLY_DAY=$OTHER sunu-boutik-pg-backup
run_case s3_bucket_inexistant 7 env PGBACKUP_BUCKET=bucket-inexistant-test PGBACKUP_WEEKLY_DAY=$OTHER sunu-boutik-pg-backup
run_case base_inexistante 3 env PGBACKUP_DB=base_absente PGBACKUP_WEEKLY_DAY=$OTHER sunu-boutik-pg-backup
pg_ctlcluster 16 main stop
run_case base_indisponible 3 env PGBACKUP_WEEKLY_DAY=$OTHER sunu-boutik-pg-backup
run_case restore_base_indisponible 3 sunu-boutik-pg-restore restore --latest daily --identity /dev/shm/restore.key --target-db restore_x
pg_ctlcluster 16 main start
# Verrou : une opération à la fois
runuser -u postgres -- flock /var/backups/sunu-boutik-pg/.lock sleep 5 &
sleep 1
run_case verrou_operation_en_cours 9 env PGBACKUP_WEEKLY_DAY=$OTHER sunu-boutik-pg-backup
wait

echo "== 6. Liste, fraîcheur"
run_case list_daily 0 sunu-boutik-pg-restore list
# 3 : le cas « HeadObject refusé » a bien déposé son objet (non vérifié, code 8)
check "list affiche les 3 sauvegardes daily" test "$(grep -c '\.dump\.age' "$LOGS/list_daily.log")" = 3
run_case list_weekly 0 sunu-boutik-pg-restore list weekly
run_case status_frais 0 sunu-boutik-pg-restore status
run_case status_prefixe_vide 12 env PGBACKUP_PREFIX=postgresql/vide sunu-boutik-pg-restore status
run_case list_prefixe_vide 11 env PGBACKUP_PREFIX=postgresql/vide sunu-boutik-pg-restore list
# Préfixe ne contenant qu'une sauvegarde ancienne
mkdir -p "$W/s3/$BUCKET/objects/postgresql/ancien/daily" "$W/s3/$BUCKET/meta/postgresql/ancien/daily"
cp "$(s3_obj "$K1")" "$W/s3/$BUCKET/objects/postgresql/ancien/daily/sunuboutik_20260101T023000Z.dump.age"
cp "$(s3_meta "$K1")" "$W/s3/$BUCKET/meta/postgresql/ancien/daily/sunuboutik_20260101T023000Z.dump.age.json"
install -o postgres -g postgres -m 0600 /dev/null "$W/s3.log"
chown -R postgres:postgres "$W/s3"
run_case status_sauvegarde_perimee 12 env PGBACKUP_PREFIX=postgresql/ancien sunu-boutik-pg-restore status

echo "== 7. Vérification et restauration isolée"
run_case verify_latest 0 sunu-boutik-pg-restore verify --latest daily --identity /dev/shm/restore.key
check "vérification : répertoire de travail vidé" workdir_clean
run_case restore_latest 0 sunu-boutik-pg-restore restore --latest daily --identity /dev/shm/restore.key --target-db restore_test1
check "données restaurées identiques à la source" test "$(fingerprint restore_test1)" = "$SRC_FP"
check "propriétaire neutre par défaut (--no-owner)" test "$(psql_pg -d restore_test1 -c "SELECT tableowner FROM pg_tables WHERE tablename = 'users'")" = postgres
check "avertissement perte des écritures postérieures" grep -q 'perdre toutes les écritures' "$LOGS/restore_latest.log"
run_case restore_weekly_keep_owner 0 sunu-boutik-pg-restore restore --latest weekly --identity /dev/shm/restore.key --target-db restore_test2 --keep-owner
check "--keep-owner conserve sunu_app" test "$(psql_pg -d restore_test2 -c "SELECT tableowner FROM pg_tables WHERE tablename = 'users'")" = sunu_app
check "restauration weekly identique à la source" test "$(fingerprint restore_test2)" = "$SRC_FP"
run_case restore_par_cle 0 sunu-boutik-pg-restore restore --key "$K1" --identity /dev/shm/restore.key --target-db restore_test3
cp "$(s3_obj "$K1")" "$W/local.dump.age"; chown postgres "$W/local.dump.age"
LOCAL_SHA=$(sha256sum "$W/local.dump.age" | cut -d' ' -f1)
run_case restore_fichier_local 0 sunu-boutik-pg-restore restore --file "$W/local.dump.age" --sha256 "$LOCAL_SHA" --identity /dev/shm/restore.key --target-db restore_test4
check "restauration locale identique à la source" test "$(fingerprint restore_test4)" = "$SRC_FP"

echo "== 8. Garde-fous de la cible"
run_case cible_production_refusee 13 sunu-boutik-pg-restore restore --latest daily --identity /dev/shm/restore.key --target-db sunuboutik
run_case cible_nom_non_restore_refuse 13 sunu-boutik-pg-restore restore --latest daily --identity /dev/shm/restore.key --target-db autre_base
run_case cible_existante_refusee 13 sunu-boutik-pg-restore restore --latest daily --identity /dev/shm/restore.key --target-db restore_test1
run_case cible_postgres_refusee 13 sunu-boutik-pg-restore restore --latest daily --identity /dev/shm/restore.key --target-db postgres
run_case sources_multiples_refusees 2 sunu-boutik-pg-restore verify --latest daily --key "$K1" --identity /dev/shm/restore.key
run_case cle_hors_prefixe_refusee 2 sunu-boutik-pg-restore verify --key autre/chemin/x.dump.age --identity /dev/shm/restore.key
check "production intacte après tous les tests" test "$(fingerprint sunuboutik)" = "$SRC_FP"

echo "== 9. Sauvegarde absente"
run_case cle_inexistante 11 sunu-boutik-pg-restore verify --key "$PREFIX/daily/sunuboutik_20200101T000000Z.dump.age" --identity /dev/shm/restore.key
run_case latest_sans_sauvegarde 11 env PGBACKUP_PREFIX=postgresql/vide sunu-boutik-pg-restore restore --latest daily --identity /dev/shm/restore.key --target-db restore_x
run_case fichier_local_absent 11 sunu-boutik-pg-restore verify --file /nonexistent.dump.age --identity /dev/shm/restore.key
check "aucune base créée par les échecs" test -z "$(psql_pg -d postgres -c "SELECT datname FROM pg_database WHERE datname = 'restore_x'")"

echo "== 10. Fichiers corrompus"
corrupt_copy() { # clé source, nom ; copie la sauvegarde sous un nouvel horodatage
  local k="$PREFIX/daily/sunuboutik_$2.dump.age"
  cp "$(s3_obj "$1")" "$(s3_obj "$k")"; cp "$(s3_meta "$1")" "$(s3_meta "$k")"
  chown postgres "$(s3_obj "$k")" "$(s3_meta "$k")"; echo "$k"
}
flip_byte() { printf '\xff' | dd of="$1" bs=1 seek=$(($(stat -c %s "$1") / 2)) conv=notrunc status=none; }
# a) octet altéré, checksum S3 d'origine : détecté au téléchargement
KA=$(corrupt_copy "$K1" 20261020T000000Z); flip_byte "$(s3_obj "$KA")"
run_case corrompu_checksum_s3 5 sunu-boutik-pg-restore verify --key "$KA" --identity /dev/shm/restore.key
# b) objet remplacé (checksum S3 recalculé) : SHA-256 des métadonnées différent
KB=$(corrupt_copy "$K1" 20261021T000000Z); flip_byte "$(s3_obj "$KB")"
python3 -I -c "import json,sys,hashlib,base64; p,o=sys.argv[1:]; m=json.load(open(p)); m['ChecksumSHA256']=base64.b64encode(hashlib.sha256(open(o,'rb').read()).digest()).decode(); json.dump(m,open(p,'w'))" "$(s3_meta "$KB")" "$(s3_obj "$KB")"
run_case corrompu_metadata_sha 5 sunu-boutik-pg-restore verify --key "$KB" --identity /dev/shm/restore.key
# c) checksum S3 ET métadonnées recalculés : l'authentification age échoue
KC=$(corrupt_copy "$K1" 20261022T000000Z); flip_byte "$(s3_obj "$KC")"
python3 -I -c "import json,sys,hashlib,base64; p,o=sys.argv[1:]; d=open(o,'rb').read(); m=json.load(open(p)); m['ChecksumSHA256']=base64.b64encode(hashlib.sha256(d).digest()).decode(); m['Metadata']['enc-sha256']=hashlib.sha256(d).hexdigest(); json.dump(m,open(p,'w'))" "$(s3_meta "$KC")" "$(s3_obj "$KC")"
run_case corrompu_detecte_par_age 6 sunu-boutik-pg-restore restore --key "$KC" --identity /dev/shm/restore.key --target-db restore_corrompu
check "aucune base créée depuis un fichier corrompu" test -z "$(psql_pg -d postgres -c "SELECT datname FROM pg_database WHERE datname = 'restore_corrompu'")"
# d) fichier local tronqué
head -c 2000 "$W/local.dump.age" >"$W/tronque.dump.age"; chown postgres "$W/tronque.dump.age"
run_case fichier_tronque 6 sunu-boutik-pg-restore verify --file "$W/tronque.dump.age" --identity /dev/shm/restore.key
# e) fichier local, SHA-256 attendu différent
run_case fichier_sha_attendu_different 5 sunu-boutik-pg-restore verify --file "$W/local.dump.age" --sha256 "$(printf '0%.0s' {1..64})" --identity /dev/shm/restore.key
# f) fichier age valide mais contenu qui n'est pas un dump PostgreSQL
RECIPIENT=$(age-keygen -y /root/keys/backup.key)
head -c 50000 /dev/urandom | age -r "$RECIPIENT" -o "$W/pasundump.age"; chown postgres "$W/pasundump.age"
run_case contenu_non_pgdump 5 sunu-boutik-pg-restore verify --file "$W/pasundump.age" --identity /dev/shm/restore.key
check "répertoire de travail vidé après échecs" workdir_clean

echo "== 11. Clé de déchiffrement"
run_case mauvaise_cle_age 6 sunu-boutik-pg-restore verify --latest daily --identity /dev/shm/wrong.key
chmod 0644 /dev/shm/wrong.key
run_case cle_lisible_par_tous_refusee 2 sunu-boutik-pg-restore verify --latest daily --identity /dev/shm/wrong.key
run_case cle_absente 2 sunu-boutik-pg-restore verify --latest daily

echo "== 12. Restauration en échec : nettoyage de la cible"
psql_pg -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE ROLE role_temporaire LOGIN;
CREATE DATABASE sunuboutik_tmp OWNER role_temporaire;
SQL
psql_pg -d sunuboutik_tmp -c "SET ROLE role_temporaire; CREATE TABLE t (id int PRIMARY KEY); INSERT INTO t VALUES (1);" >/dev/null
run_case backup_base_temporaire 0 env PGBACKUP_DB=sunuboutik_tmp PGBACKUP_PREFIX=postgresql/tmp PGBACKUP_WEEKLY_DAY=$OTHER sunu-boutik-pg-backup
psql_pg -d postgres -c "DROP DATABASE sunuboutik_tmp" -c "DROP ROLE role_temporaire" >/dev/null
run_case restore_role_manquant_echoue 5 env PGBACKUP_DB=sunuboutik_tmp PGBACKUP_PREFIX=postgresql/tmp sunu-boutik-pg-restore restore --latest daily --identity /dev/shm/restore.key --target-db restore_echec --keep-owner
check "base cible supprimée après échec" test -z "$(psql_pg -d postgres -c "SELECT datname FROM pg_database WHERE datname = 'restore_echec'")"

echo "== 13. Absence de secrets dans les journaux"
SECRET_KEY_LINE=$(grep -h '^AGE-SECRET-KEY-' /root/keys/backup.key /root/keys/wrong.key)
cat "$LOGS"/*.log >"$W/all.log"
leak=0
while IFS= read -r s; do grep -qF -- "$s" "$W/all.log" && { echo "FUITE: ${s:0:12}…" >>"$RESULTS"; leak=1; }; done <<EOF
$FAKE_DB_PASSWORD
$AWS_ACCESS_KEY_ID
$AWS_SECRET_ACCESS_KEY
deadbeefcafe0123456789
$(echo "$SECRET_KEY_LINE" | head -n 1)
$(echo "$SECRET_KEY_LINE" | tail -n 1)
FAKEHASH
client42@fake.invalid
EOF
record "aucun secret ni donnée applicative dans les logs" 0 "$leak"
check "aucune ligne AGE-SECRET-KEY dans les logs" bash -c "! grep -q 'AGE-SECRET-KEY-1' '$W/all.log'"

echo
echo "RÉSULTAT : $PASS réussis, $FAIL échoués" | tee -a "$RESULTS"
mkdir -p "$IN/results"; rm -rf "$IN/results/logs"; cp -r "$LOGS" "$RESULTS" "$W/s3.log" "$IN/results/"
chown -R "${HOST_UID:-1000}:${HOST_UID:-1000}" "$IN/results"
exit $((FAIL > 0))
