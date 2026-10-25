#!/bin/bash
# ========================================
# Restauration d'un pool de srv-main depuis srv-backup
# Usage : bash scripts/restore-from-backup.sh <pool> [snapshot]
#   pool     : tank ou ssd_tank
#   snapshot : nom du snapshot à restaurer (défaut : le plus récent sur srv-backup)
# ========================================
# Prérequis : le pool a été recréé vide par Ansible (make deploy ZFS_CREATE=1 TAGS=zfs).
# Le script restaure chaque dataset (contenu + historique des snapshots) depuis
# srv-backup, sans toucher à la racine du pool (point de montage, compression...).
# Ensuite : make deploy, pour réappliquer les propriétés et redémarrer les services.
#
# Lancé depuis un poste qui a un accès SSH sudo aux deux serveurs. Les commandes
# d'accès sont modifiables (le banc de simulation les surcharge) :
#   MAIN_SSH   (défaut : ssh ansible@srv-main)
#   BACKUP_SSH (défaut : ssh ansible@srv-backup)
set -euo pipefail

POOL=${1:?Usage: restore-from-backup.sh <pool> [snapshot]}
SNAP=${2:-}
MAIN_SSH=${MAIN_SSH:-ssh ansible@srv-main}
BACKUP_SSH=${BACKUP_SSH:-ssh ansible@srv-backup}
SOURCE="vault/srv-main/$POOL"
# Un dataset plus gros que ça sur srv-main n'est pas "vide" : on refuse de l'écraser
MAX_USED_BYTES=$((100 * 1024 * 1024))

main() { $MAIN_SSH "sudo $*"; }
backup() { $BACKUP_SSH "sudo $*"; }

echo "=== Restauration de $POOL depuis srv-backup ($SOURCE) ==="

mapfile -t CHILDREN < <(backup zfs list -H -o name -r -d 1 "$SOURCE" | tail -n +2 | sed "s#^$SOURCE/##")
[[ ${#CHILDREN[@]} -gt 0 ]] || { echo "Aucun dataset sous $SOURCE"; exit 1; }
echo "Datasets : ${CHILDREN[*]}"

# Seuls les datasets enfants sont répliqués (pas la racine du pool) : on prend
# le snapshot le plus récent du premier, puis on vérifie que tous l'ont.
if [[ -z "$SNAP" ]]; then
  SNAP=$(backup zfs list -H -t snapshot -o name -s creation -d 1 "$SOURCE/${CHILDREN[0]}" | tail -1 | cut -d@ -f2)
fi
[[ -n "$SNAP" ]] || { echo "Aucun snapshot sous $SOURCE sur srv-backup"; exit 1; }
for c in "${CHILDREN[@]}"; do
  backup zfs list -H -o name "$SOURCE/$c@$SNAP" >/dev/null 2>&1     || { echo "Le snapshot $SNAP n'existe pas pour $c : en choisir un autre (2e argument)"; exit 1; }
done
echo "Snapshot restauré : $SNAP"

echo "--- Vérifications sur srv-main"
main zpool list "$POOL" >/dev/null || { echo "Pool $POOL absent : le recréer d'abord (make deploy ZFS_CREATE=1 TAGS=zfs)"; exit 1; }
for c in "${CHILDREN[@]}"; do
  used=$(main zfs get -Hp -o value used "$POOL/$c" 2>/dev/null || echo 0)
  if (( used > MAX_USED_BYTES )); then
    echo "$POOL/$c contient déjà $((used / 1024 / 1024)) Mo : refus de l'écraser."
    echo "Ce script restaure un pool recréé à vide. Pour revenir en arrière sur un pool sain : zfs rollback."
    exit 1
  fi
done

echo "--- Arrêt de Docker et des snapshots automatiques sur srv-main"
main systemctl stop docker.socket docker sanoid.timer

for c in "${CHILDREN[@]}"; do
  echo "--- $POOL/$c"
  # Le dataset recréé par Ansible est vide : on supprime ses éventuels snapshots pour pouvoir l'écraser
  main zfs destroy "$POOL/$c@%" 2>/dev/null || true
  backup zfs send -R "$SOURCE/$c@$SNAP" | main zfs receive -F "$POOL/$c"
  # Les copies de srv-backup sont en lecture seule par héritage, pas les données restaurées
  main zfs inherit readonly "$POOL/$c"
done

main zfs mount -a
# Snapshot de tout le pool : sans snapshot sur sa racine (recréée vide), syncoid
# refuserait de reprendre la réplication jusqu'au prochain snapshot horaire
main zfs snapshot -r "$POOL@restauration-$(date +%Y-%m-%d_%H%M)"
main systemctl start sanoid.timer
# Pendant que le pool manquait, systemd a relancé Docker en boucle jusqu'à sa limite
# de tentatives : sans remise à zéro, make deploy ne pourrait pas le redémarrer
main systemctl reset-failed docker.service docker.socket

echo ""
echo "Restauration terminée. Étape suivante : make deploy"
echo "(réapplique les propriétés ZFS et redémarre Docker et les services)"
