#!/bin/bash
# ========================================
# Migration : restauration des données rapatriées sur srv-backup vers le nouveau srv-main
# ========================================
# À lancer sur srv-main, en root, APRÈS make deploy. Voir docs/MIGRATION.md.
#
#   restore-on-srv-main.sh files       Médiathèque, photos, uploads Backpaking, données Nextcloud
#   restore-on-srv-main.sh databases   Bases PostgreSQL de Litopia et Backpaking
#   restore-on-srv-main.sh amp         Serveurs de jeu AMP et leur MySQL (après le rôle amp)
#
# Nextcloud (base MariaDB -> PostgreSQL) se termine à la main : docs/MIGRATION.md, étape 6.
# Relançable : rsync ne recopie que les différences.
set -euo pipefail

MODE="${1:-}"
BACKUP="${BACKUP:-root@192.168.1.101}"
SNAP_DIR="${SNAP_DIR:-}"   # vide : la copie courante. Sinon ex. /mnt/vault/migration/.zfs/snapshot/final-20261101-0900
SRC="${SNAP_DIR:-/mnt/vault/migration}"
NC_USER="${NC_USER:-}"     # compte Nextcloud qui reçoit l'ancien dossier Data du datastore (ex. louis)

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new"
log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "ERREUR : $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "à lancer en root sur srv-main"
[[ "$MODE" =~ ^(files|databases|amp)$ ]] || die "usage : $0 files|databases|amp"
ssh $SSH_OPTS "$BACKUP" "test -d '$SRC'" || die "$BACKUP:$SRC inaccessible"

pull() {  # pull <chemin source> <destination> <uid:gid> [options rsync]
  log "  $1 -> $2"
  mkdir -p "$2"
  rsync -aH --info=stats1 --chown="$3" "${@:4}" -e "ssh $SSH_OPTS" "$BACKUP:$SRC/$1/" "$2/"
}

compose() { docker compose --project-directory "/opt/epicea/docker/$1" "${@:2}"; }

restore_pg() {  # restore_pg <app> <conteneur db> <fichier .dump> <conteneur(s) à arrêter...>
  local app="$1" db="$2" dump="$3"; shift 3
  log "== $app : $dump"
  local user name
  user=$(docker exec "$db" printenv POSTGRES_USER)
  name=$(docker exec "$db" printenv POSTGRES_DB)
  compose "$app" stop "$@"
  # Base vidée entièrement : le nouveau backend a déjà créé ses tables au premier démarrage, et
  # --clean ne retire que les objets présents dans le dump. Au redémarrage, le backend applique ses
  # migrations sur l'ancien schéma.
  docker exec "$db" psql -q -v ON_ERROR_STOP=1 -U "$user" -d "$name" \
    -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION \"$user\";"
  ssh $SSH_OPTS "$BACKUP" "cat '$SRC/webservice/var/backups/migration/$dump'" \
    | docker exec -i "$db" pg_restore -U "$user" -d "$name" --no-owner --no-acl \
    || log "  pg_restore a signalé des avertissements (souvent sans gravité, ex. COMMENT ON SCHEMA public)"
  log "  $(docker exec "$db" psql -At -U "$user" -d "$name" -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'") tables restaurées"
  compose "$app" start "$@"
}

case "$MODE" in
  files)
    log "== Médiathèque (Jellyfin)"
    pull datastore/home/louis/Mediatheque/Films    /mnt/tank/media/movies 1000:1000
    pull datastore/home/louis/Mediatheque/Series   /mnt/tank/media/shows  1000:1000
    pull datastore/home/louis/Mediatheque/Musiques /mnt/tank/media/music  1000:1000

    log "== Photos PhotoPrism (à importer dans Immich, voir le guide)"
    pull photoprism/home/louis/Pictures /mnt/tank/photos/a-importer 1000:1000

    log "== Uploads Backpaking"
    pull webservice/opt/backpaking/uploads /mnt/tank/apps/backpaking-uploads 10001:999

    log "== Données Nextcloud"
    compose nextcloud stop nextcloud
    pull nextcloud/home/nextcloud/data /mnt/tank/cloud/data 33:33
    if [[ -n "$NC_USER" ]]; then
      pull datastore/home/louis/Data "/mnt/tank/cloud/data/$NC_USER/files/Data" 33:33
    else
      log "  NC_USER vide : l'ancien dossier Data du datastore n'est pas copié dans Nextcloud"
    fi
    log "Nextcloud reste arrêté : terminer avec l'étape 6 du guide de migration."
    ;;
  databases)
    restore_pg litopia    litopia-db    LitopiaDB.dump    litopia-back
    restore_pg backpaking backpaking-db backpackingv2.dump backpaking-back
    ;;
  amp)
    log "== AMP : instances et MySQL des plugins"
    # stopall aussi pour une instance lancée hors du service (ampinstmgr quickstart)
    systemctl stop ampinstmgr
    runuser -u amp -- bash -c 'cd ~ && ampinstmgr stopall' >/dev/null 2>&1 || true
    pull gameserver/home/amp /home/amp amp:amp --delete  # copie exacte de l'ancien serveur
    pw=$(docker exec amp-mysql printenv MYSQL_ROOT_PASSWORD)
    d="$SRC/gameserver/var/backups/migration"
    # Les serveurs joignent MySQL (Docker) par 127.0.0.1:3306 : vus depuis la passerelle Docker, plus
    # depuis localhost. Les comptes passent donc de @localhost à @% (le port n'écoute que sur 127.0.0.1).
    { ssh $SSH_OPTS "$BACKUP" "cat '$d/amp-databases.sql'" 2>/dev/null || true
      ssh $SSH_OPTS "$BACKUP" "cat '$d/amp-users.sql'" | sed 's/@`localhost`/@`%`/; s/@`127.0.0.1`/@`%`/'
      echo "FLUSH PRIVILEGES;"
    } | docker exec -i -e MYSQL_PWD="$pw" amp-mysql mysql -uroot
    systemctl restart ampinstmgr
    log "AMP redémarré : vérifier les instances sur le panneau (licence à réactiver si demandé)."
    ;;
esac
log "Terminé."
