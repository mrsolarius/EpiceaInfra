#!/bin/bash
# ========================================
# Migration : reprise de l'ancien Nextcloud (MariaDB) dans le nouveau (PostgreSQL)
# ========================================
# À lancer sur srv-main, en root, après restore-on-srv-main.sh files. Voir docs/MIGRATION.md, étape 6.
#
#   nextcloud-convert.sh <nextcloud.sql> <ancien config.php>
#
# 1. charge l'ancienne base dans un MariaDB temporaire ;
# 2. fait pointer Nextcloud dessus en reprenant instanceid/passwordsalt/secret de l'ancienne config ;
# 3. convertit la base vers le PostgreSQL du nouveau serveur (occ db:convert-type).
set -euo pipefail

DUMP="${1:-}"
OLD_CONFIG="${2:-}"
[[ $EUID -eq 0 ]] || { echo "à lancer en root" >&2; exit 1; }
[[ -s "$DUMP" && -s "$OLD_CONFIG" ]] || { echo "usage : $0 <nextcloud.sql> <ancien config.php>" >&2; exit 1; }

log() { echo "[$(date '+%T')] $*"; }
occ() { docker exec -u www-data nextcloud php occ --no-interaction "$@"; }
pg()  { docker exec nextcloud-db printenv "$1"; }

NET=$(docker inspect nextcloud-db -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | grep -m1 default)

log "MariaDB temporaire et import de l'ancienne base"
docker rm -f nc-mariadb >/dev/null 2>&1 || true
docker run -d --name nc-mariadb --network "$NET" \
  -e MARIADB_ROOT_PASSWORD=migration -e MARIADB_DATABASE=nextcloud mariadb:10.6 >/dev/null
until docker exec nc-mariadb mariadb -uroot -pmigration -e 'SELECT 1' nextcloud >/dev/null 2>&1; do sleep 2; done
docker exec -i nc-mariadb mariadb -uroot -pmigration nextcloud < "$DUMP"

log "Configuration : identité de l'ancienne instance, base MariaDB temporaire"
docker compose --project-directory /opt/epicea/docker/nextcloud start nextcloud
until docker exec nextcloud test -f /var/www/html/config/config.php; do sleep 2; done
docker cp "$OLD_CONFIG" nextcloud:/tmp/old-config.php
docker exec nextcloud chown www-data /tmp/old-config.php
docker exec -u www-data nextcloud php -r '
  $old = (function () { include "/tmp/old-config.php"; return $CONFIG ?? null; })();
  if (empty($old["instanceid"]) || empty($old["secret"])) { fwrite(STDERR, "ancienne config illisible\n"); exit(1); }
  include "/var/www/html/config/config.php";
  foreach (["instanceid", "passwordsalt", "secret"] as $k) { $CONFIG[$k] = $old[$k]; }
  $CONFIG = array_merge($CONFIG, ["dbtype" => "mysql", "dbhost" => "nc-mariadb", "dbname" => "nextcloud",
    "dbuser" => "root", "dbpassword" => "migration", "dbtableprefix" => $old["dbtableprefix"] ?? "oc_"]);
  file_put_contents("/var/www/html/config/config.php", "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n");'
docker exec nextcloud rm -f /tmp/old-config.php

if occ status --output=json | grep -q '"needsDbUpgrade":true'; then
  log "Mise à niveau de la base"
  occ upgrade
fi

log "Conversion MariaDB -> PostgreSQL"
# Base cible vidée ici : --clear-schema de Nextcloud 35 échoue sur les clés étrangères (tables oc_sharing_*)
docker exec nextcloud-db psql -q -U "$(pg POSTGRES_USER)" -d "$(pg POSTGRES_DB)" -c \
  "DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION \"$(pg POSTGRES_USER)\"; CREATE EXTENSION pg_stat_statements;"
if ! occ db:convert-type --all-apps --password "$(pg POSTGRES_PASSWORD)" \
     pgsql "$(pg POSTGRES_USER)" nextcloud-db "$(pg POSTGRES_DB)" > /tmp/nc-convert.log 2>&1; then
  # Nextcloud 35 : les données sont copiées, mais le recalage final des séquences plante (il cherche
  # les séquences via column_default, vide pour les colonnes IDENTITY). On termine ses deux dernières étapes ici.
  grep -q "(SELECT MAX() FROM ))" /tmp/nc-convert.log \
    || { tail -30 /tmp/nc-convert.log; echo "ERREUR : conversion échouée (journal : /tmp/nc-convert.log)" >&2; exit 1; }
  log "Recalage des séquences (contournement du bug Nextcloud 35)"
  docker exec nextcloud-db psql -q -v ON_ERROR_STOP=1 -U "$(pg POSTGRES_USER)" -d "$(pg POSTGRES_DB)" -c "
    DO \$\$ DECLARE r record; m bigint; BEGIN
      -- séquence -> colonne propriétaire (SERIAL : deptype a, IDENTITY : deptype i)
      -- (les tables à identifiants « snowflake » gardent une séquence inutilisée, trop petite : ignorée)
      FOR r IN SELECT seq.oid AS seq, ps.seqmax, tbl.relname AS tbl, att.attname AS col FROM pg_class seq
               JOIN pg_sequence ps ON ps.seqrelid = seq.oid
               JOIN pg_depend d ON d.objid = seq.oid AND d.deptype IN ('a', 'i')
               JOIN pg_class tbl ON tbl.oid = d.refobjid
               JOIN pg_attribute att ON att.attrelid = tbl.oid AND att.attnum = d.refobjsubid
               WHERE seq.relkind = 'S' LOOP
        EXECUTE format('SELECT MAX(%I) FROM %I', r.col, r.tbl) INTO m;
        IF m IS NOT NULL AND m <= r.seqmax THEN PERFORM setval(r.seq, m); END IF;
      END LOOP;
    END \$\$;"
  # En une fois et sans occ : occ a besoin de la base, qui n'est cohérente qu'avec les 5 valeurs
  docker exec -u www-data -e DBN="$(pg POSTGRES_DB)" -e DBU="$(pg POSTGRES_USER)" -e DBP="$(pg POSTGRES_PASSWORD)" nextcloud php -r '
    include "/var/www/html/config/config.php";
    $CONFIG = array_merge($CONFIG, ["dbtype" => "pgsql", "dbhost" => "nextcloud-db",
      "dbname" => getenv("DBN"), "dbuser" => getenv("DBU"), "dbpassword" => getenv("DBP")]);
    file_put_contents("/var/www/html/config/config.php", "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n");'
fi

log "Finalisation"
occ maintenance:mode --off
occ files:scan --all
occ maintenance:repair --include-expensive
docker rm -f nc-mariadb >/dev/null
log "Terminé : vérifier la connexion sur Nextcloud avec un ancien compte."
