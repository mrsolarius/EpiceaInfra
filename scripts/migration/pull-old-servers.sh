#!/bin/bash
# ========================================
# Migration Proxmox -> srv-main : rapatriement des données sur srv-backup
# ========================================
# À lancer sur srv-backup, en root. Voir docs/MIGRATION.md.
#
#   pull-old-servers.sh sync     Copie à chaud, sans coupure. Relançable autant de fois que voulu :
#                                seules les différences sont recopiées.
#   pull-old-servers.sh final    Arrête les services, exporte les bases, dernière copie, snapshot.
#   pull-old-servers.sh verify   Compare source et copie (contenu des fichiers, sauf médiathèque :
#                                taille + date). Ne modifie rien.
#
# Prérequis sur chaque VM (voir le guide) : la clé SSH root de srv-backup dans
# ~louis/.ssh/authorized_keys et sudo sans mot de passe pour louis.
#
# Variables : ONLY="gameserver nextcloud" limite aux machines citées,
#             IP_<machine>=… remplace une adresse (banc de simulation),
#             EXCLUDE_EXTRA="motifs rsync" ajoute des exclusions.
set -euo pipefail

MODE="${1:-}"
DEST_DS="${DEST_DS:-vault/migration}"
SSH_USER="${SSH_USER:-louis}"

# machine -> IP
declare -A HOSTS=(
  [datastore]=192.168.1.220
  [nextcloud]=192.168.1.230
  [photoprism]=192.168.1.225
  [webservice]=192.168.1.250
  [gameserver]=192.168.1.200
  [reverseproxy]=192.168.1.254
)
for m in "${!HOSTS[@]}"; do
  ip_var="IP_$m"
  if [[ -n "${!ip_var:-}" ]]; then HOSTS[$m]="${!ip_var}"; fi
done
ORDER=()
for m in reverseproxy webservice gameserver photoprism nextcloud datastore; do
  if [[ -z "${ONLY:-}" || " $ONLY " == *" $m "* ]]; then ORDER+=("$m"); fi
done

# Chemins copiés par machine. /etc et les crontabs sont copiés partout (référence des anciennes configs).
COMMON_PATHS="/etc /var/spool/cron"
declare -A PATHS=(
  [datastore]="/home/louis/Mediatheque /home/louis/Data /home/louis/Downloads /home/louis/torent /home/louis/.config /var/lib/jellyfin"
  [nextcloud]="/home/nextcloud/data /var/www/nextcloud /home/louis/export_maps"
  [photoprism]="/home/louis/Pictures /home/louis/Import /photoprism"
  [webservice]="/opt/backpaking /opt/remina-survey /home/louis /var/www /var/lib/docker/volumes"
  [gameserver]="/home/amp /opt/cubecoders"
  [reverseproxy]="/etc/letsencrypt"
)
EXCLUDES=(
  --exclude=node_modules/ --exclude=.npm/ --exclude=.gradle/ --exclude=.nvm/ --exclude=.cache/
  --exclude=/photoprism/storage/cache/
  --exclude=/amp/.ampdata/instances/AMPCache-*.zip  # motifs en « / » : relatifs au dossier copié (ici amp/)
)
# EXCLUDE_EXTRA="motif1 motif2" : exclusions supplémentaires (ex. copie partielle sur le banc)
for e in ${EXCLUDE_EXTRA:-}; do EXCLUDES+=("--exclude=$e"); done
# Gros volumes remplaçables : vérifiés sur taille + date plutôt que sur contenu
QUICK_VERIFY="/home/louis/Mediatheque"  # (datastore)

log()  { echo "[$(date '+%F %T')] $*"; }
die()  { echo "ERREUR : $*" >&2; exit 1; }
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
# shellcheck disable=SC2086
rsh()  { ssh $SSH_OPTS "$SSH_USER@${HOSTS[$1]}" "${@:2}"; }

[[ $EUID -eq 0 ]] || die "à lancer en root sur srv-backup"
[[ "$MODE" =~ ^(sync|final|verify)$ ]] || die "usage : $0 sync|final|verify"

# ---------- Vérifications ----------
zfs list "${DEST_DS%%/*}" >/dev/null 2>&1 || die "pool ${DEST_DS%%/*} absent : installer srv-backup d'abord (make deploy-backup)"
for m in "${ORDER[@]}"; do
  rsh "$m" 'sudo -n true' 2>/dev/null || die "$m (${HOSTS[$m]}) : accès SSH ou sudo sans mot de passe manquant"
done

if ! zfs list "$DEST_DS" >/dev/null 2>&1; then
  zfs create -p -o compression=lz4 -o recordsize=1M -o atime=off "$DEST_DS"
fi
for m in "${ORDER[@]}"; do
  zfs list "$DEST_DS/$m" >/dev/null 2>&1 || zfs create "$DEST_DS/$m"
done
ROOT="$(zfs get -H -o value mountpoint "$DEST_DS")"

copy() {  # copy <machine> <chemin> [options rsync]
  local m="$1" p="$2"; shift 2
  rsh "$m" "sudo test -e '$p'" || { log "  $m:$p absent, ignoré"; return 0; }
  mkdir -p "$ROOT/$m$(dirname "$p")"
  local rc=0
  rsync -aHAX --numeric-ids --delete --info=stats1 "${EXCLUDES[@]}" "$@" \
    -e "ssh $SSH_OPTS" --rsync-path="sudo rsync" \
    "$SSH_USER@${HOSTS[$m]}:$p" "$ROOT/$m$(dirname "$p")/" || rc=$?
  # 24 : fichiers supprimés pendant la copie (temporaires des services en marche), normal à chaud
  if [[ $rc -eq 24 ]]; then log "  fichiers disparus pendant la copie (normal à chaud)"; rc=0; fi
  return $rc
}

# ---------- Arrêt des services et exports des bases (final), par machine ----------
D=/var/backups/migration

stop_nextcloud() {  # mode maintenance puis export MariaDB
  rsh nextcloud "sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on"
  rsh nextcloud "sudo mysqldump --single-transaction --default-character-set=utf8mb4 nextcloud | sudo tee $D/nextcloud.sql >/dev/null"
}

stop_webservice() {  # PostgreSQL 12 natif (Litopia, Backpaking) + base Docker de remina-survey
  rsh webservice "sudo systemctl stop backpaking pm2-louis"
  rsh webservice "sudo -u postgres pg_dumpall --globals-only | sudo tee $D/globals.sql >/dev/null"
  for db in $(rsh webservice "sudo -u postgres psql -Atc \"SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'\""); do
    rsh webservice "sudo -u postgres pg_dump -Fc '$db' | sudo tee '$D/$db.dump' >/dev/null"
  done
  rsh webservice "sudo docker exec remina-postgres pg_dumpall -U postgres | sudo tee $D/remina.sql >/dev/null" || log "  remina-postgres non exporté"
}

stop_photoprism() {  # MariaDB dans Docker (albums, favoris, métadonnées)
  rsh photoprism "cd /photoprism && sudo docker compose stop photoprism && sudo docker compose exec -T mariadb mariadb-dump -uroot -pinsecure --all-databases | sudo tee $D/photoprism.sql >/dev/null"
}

stop_datastore() {  # Jellyfin arrêté pour copier une base cohérente
  rsh datastore "sudo systemctl stop jellyfin"
}

stop_reverseproxy() { :; }

stop_gameserver() {  # arrêt des instances AMP (mondes cohérents) puis export MySQL
  # KEEP_RUNNING=1 : exports sans arrêter les serveurs de jeu (répétition sur la prod, mondes copiés à chaud)
  if [[ -n "${KEEP_RUNNING:-}" ]]; then
    log "  KEEP_RUNNING : AMP laissé en marche"
  else
    rsh gameserver "sudo -u amp -H bash -c 'cd ~ && ampinstmgr stopall'" \
      || log "  ampinstmgr stopall a échoué : vérifier que les serveurs de jeu sont arrêtés"
  fi
  # Bases des plugins et leurs comptes, sans les tables système : le nouveau MySQL (Docker) garde son root
  # AMP_SKIP_DBS="base1 base2" : bases non exportées (ex. DynmapLitopia, 104 Go de tuiles régénérables)
  local d=$D skip="'mysql','sys','performance_schema','information_schema'" db
  for db in ${AMP_SKIP_DBS:-}; do skip+=",'$db'"; log "  base $db non exportée (AMP_SKIP_DBS)"; done
  rsh gameserver "sudo bash -s" <<EOF
set -e
# root MySQL a un mot de passe : on passe par le compte de maintenance Debian
mysql()     { command mysql --defaults-file=/etc/mysql/debian.cnf "\$@"; }
mysqldump() { command mysqldump --defaults-file=/etc/mysql/debian.cnf "\$@"; }
dbs=\$(mysql -NBe "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ($skip)")
if [ -n "\$dbs" ]; then mysqldump --single-transaction --databases \$dbs > $d/amp-databases.sql; fi
# Hash des mots de passe en hexadécimal : sous forme brute, il peut contenir des apostrophes
{ echo "SET print_identified_with_as_hex = ON;"
  mysql -NBe "SELECT CONCAT('SHOW CREATE USER \\\`',user,'\\\`@\\\`',host,'\\\`; SHOW GRANTS FOR \\\`',user,'\\\`@\\\`',host,'\\\`;') FROM mysql.user WHERE user NOT IN ('root','debian-sys-maint') AND user NOT LIKE 'mysql.%'"
} | mysql -NB | sed 's/\$/;/' > $d/amp-users.sql
EOF
}

dump_databases() {
  log "Arrêt des services et exports des bases"
  for m in "${ORDER[@]}"; do
    rsh "$m" "sudo mkdir -p $D && sudo chmod 700 $D"
    "stop_$m"
  done
}

# ---------- Copie ----------
run_copy() {
  for m in "${ORDER[@]}"; do
    log "== $m (${HOSTS[$m]})"
    for p in $COMMON_PATHS ${PATHS[$m]}; do log "  $p"; copy "$m" "$p"; done
    if [[ "$MODE" == final ]]; then copy "$m" "$D"; fi
  done
}

# ---------- Vérification ----------
run_verify() {
  local total=0
  for m in "${ORDER[@]}"; do
    for p in $COMMON_PATHS ${PATHS[$m]}; do
      rsh "$m" "sudo test -e '$p'" || continue
      local opt=(--checksum)
      if [[ "$m" == datastore && "$p" == "$QUICK_VERIFY" ]]; then opt=(); fi
      local n
      n=$(rsync -aHAX --numeric-ids --delete --dry-run --itemize-changes "${opt[@]}" "${EXCLUDES[@]}" \
            -e "ssh $SSH_OPTS" --rsync-path="sudo rsync" \
            "$SSH_USER@${HOSTS[$m]}:$p" "$ROOT/$m$(dirname "$p")/" | grep -vc '^\.d' || true)
      printf '  %-12s %-40s %s différence(s)\n' "$m" "$p" "$n"
      total=$((total + n))
    done
  done
  log "Total : $total différence(s) (des fichiers modifiés depuis la dernière copie sont normaux tant que les services tournent)"
}

manifest() {
  local f="$ROOT/MANIFEST.txt"
  {
    echo "Migration - $(date '+%F %T') - mode $MODE"
    zfs list -r -o name,used,refer "$DEST_DS"
    echo
    for m in "${ORDER[@]}"; do
      echo "$m : $(find "$ROOT/$m" -type f | wc -l) fichiers"
    done
  } > "$f"
  cat "$f"
}

case "$MODE" in
  sync)
    run_copy
    manifest
    log "Copie à chaud terminée. Relancer 'sync' réduit la durée de la passe finale."
    ;;
  final)
    dump_databases
    run_copy
    manifest
    snap="$DEST_DS@final-$(date +%Y%m%d-%H%M)"
    zfs snapshot -r "$snap"
    log "Passe finale terminée, snapshot $snap"
    if [[ -z "${KEEP_RUNNING:-}" ]]; then
      log "Les services des anciennes VMs sont ARRÊTÉS (Nextcloud en maintenance). Étape suivante : verify."
    fi
    ;;
  verify)
    run_verify
    ;;
esac
