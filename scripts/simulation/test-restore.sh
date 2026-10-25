#!/bin/bash
# ========================================
# Tests des procédures de restauration (docs/GUIDE.md §5)
# Usage : bash scripts/simulation/test-restore.sh   (ou make sim-test-restore)
# ========================================
# 1. Fichier supprimé       : copie depuis /.zfs/snapshot sur srv-main
# 2. Mise à jour ratée      : zfs rollback de Nextcloud (base + fichiers)
# 3. SSD des bases mort     : disque remplacé, pool recréé, restauration depuis srv-backup
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/simulation/lib.sh

TS=$(date +%s)
BACKUP_IP=$(grep -A1 "srv-backup:" ansible/inventory/simulation.yml | grep -o "[0-9.]*$")

# Lecture/écriture dans la base Nextcloud
SQL=$(cat <<'EOF'
sql() { docker exec -e Q="$1" nextcloud-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$Q"'; }
EOF
)

echo "=== 1. Fichier supprimé par erreur ==="
step "Créer un fichier et prendre un snapshot" $MAIN \
  'echo "photo-importante" > /mnt/tank/photos/vacances.jpg && zfs snapshot -r tank@avant-suppression-$TS'
step "Supprimer le fichier" $MAIN 'rm /mnt/tank/photos/vacances.jpg'
check "Le snapshot est visible dans .zfs/snapshot" $MAIN 'ls /mnt/tank/photos/.zfs/snapshot/ | grep -q avant-suppression-$TS'
step "Restaurer le fichier depuis le snapshot" $MAIN \
  'cp -a /mnt/tank/photos/.zfs/snapshot/avant-suppression-$TS/vacances.jpg /mnt/tank/photos/vacances.jpg'
check "Fichier restauré" $MAIN 'test "$(cat /mnt/tank/photos/vacances.jpg)" = photo-importante'

echo "=== 2. Mise à jour ratée : retour arrière de Nextcloud ==="
step "Écrire un état « avant » dans la base et les fichiers" $MAIN \
  "$SQL; sql \"CREATE TABLE IF NOT EXISTS restore_test(etat text); DELETE FROM restore_test; INSERT INTO restore_test VALUES ('avant');\" && echo avant > /mnt/tank/cloud/etat.txt"
step "Snapshot avant la mise à jour" $MAIN 'zfs snapshot -r ssd_tank@avant-maj-$TS && zfs snapshot -r tank@avant-maj-$TS'
step "La « mise à jour » abîme les données" $MAIN \
  "$SQL; sql \"UPDATE restore_test SET etat = 'casse';\" && echo casse > /mnt/tank/cloud/etat.txt"
step "Arrêter Nextcloud" $MAIN 'cd /opt/epicea/docker/nextcloud && docker compose stop'
step "Revenir au snapshot (base + fichiers)" $MAIN \
  'zfs rollback -r ssd_tank/nextcloud-db@avant-maj-$TS && zfs rollback -r tank/cloud@avant-maj-$TS'
step "Redémarrer Nextcloud" $MAIN 'cd /opt/epicea/docker/nextcloud && docker compose start'
check "La base est revenue à l'état « avant »" $MAIN \
  "$SQL; for i in \$(seq 1 12); do test \"\$(sql 'SELECT etat FROM restore_test')\" = avant && exit 0; sleep 5; done; exit 1"
check "Les fichiers sont revenus à l'état « avant »" $MAIN 'test "$(cat /mnt/tank/cloud/etat.txt)" = avant'
check "Nextcloud est sain" $MAIN \
  'for i in $(seq 1 18); do docker ps --filter name=^nextcloud$ --format "{{.Status}}" | grep -q "(healthy)" && exit 0; sleep 10; done; exit 1'

echo "=== 3. SSD des bases de données mort : restauration depuis srv-backup ==="
step "Écrire un état « sauvegarde » dans la base Nextcloud" $MAIN \
  "$SQL; sql \"UPDATE restore_test SET etat = 'sauvegarde';\""
step "Snapshot puis réplication vers srv-backup" $MAIN 'zfs snapshot -r ssd_tank@avant-panne-$TS'
step "Réplication" $BACKUP 'systemctl start syncoid-pull.service'
check "srv-backup a le snapshot avant-panne" $BACKUP 'zfs list vault/srv-main/ssd_tank/nextcloud-db@avant-panne-$TS'

step "PANNE : le SSD meurt (pool détruit, disque effacé)" $MAIN \
  'systemctl stop docker.socket docker && zpool destroy -f ssd_tank && img=/var/lib/sim-disks/ata-CT1000MX500SSD1_2019E2A1579C.img && losetup -j $img | cut -d: -f1 | xargs -r losetup -d && rm -f $img'
multipass exec "$MAIN" -- bash -c "echo $(base64 -w0 scripts/simulation/simulate-disks.sh) | base64 -d > /tmp/simulate-disks.sh"
step "Remplacement du SSD (disque neuf vierge)" $MAIN 'bash /tmp/simulate-disks.sh srv-main >/dev/null'
check "Docker refuse de démarrer sans le pool ssd_tank" $MAIN '! systemctl start docker 2>/dev/null'

echo "  ...  Recréer le pool vide : make sim-deploy TAGS=zfs (en prod : make deploy ZFS_CREATE=1 TAGS=zfs)"
make sim-deploy TAGS=zfs > /tmp/restore-zfs.log 2>&1 || { echo "  ÉCHEC, voir /tmp/restore-zfs.log"; tail -20 /tmp/restore-zfs.log; summary; exit 1; }
check "Pool ssd_tank recréé, datasets vides" $MAIN 'zpool list ssd_tank && test "$(zfs get -Hp -o value used ssd_tank/nextcloud-db)" -lt 1048576'

echo "  ...  Restaurer depuis srv-backup : scripts/restore-from-backup.sh ssd_tank"
multipass exec "$MAIN" -- bash -c "echo $(base64 -w0 scripts/restore-from-backup.sh) | base64 -d > /tmp/restore-from-backup.sh"
step "Lancer le script de restauration" $MAIN \
  "MAIN_SSH='bash -c' BACKUP_SSH='sudo -u ubuntu ssh -o StrictHostKeyChecking=accept-new ubuntu@$BACKUP_IP' bash /tmp/restore-from-backup.sh ssd_tank"

echo "  ...  Redéployer : make sim-deploy (en prod : make deploy)"
make sim-deploy > /tmp/restore-deploy.log 2>&1 || { echo "  ÉCHEC, voir /tmp/restore-deploy.log"; tail -20 /tmp/restore-deploy.log; summary; exit 1; }
echo "  ...  Rétablir les droits de réplication du pool recréé : make sim-deploy-backup (en prod : make deploy-backup)"
make sim-deploy-backup > /tmp/restore-deploy-backup.log 2>&1 || { echo "  ÉCHEC, voir /tmp/restore-deploy-backup.log"; tail -20 /tmp/restore-deploy-backup.log; summary; exit 1; }
check "Datasets restaurés montés aux bons endroits" $MAIN \
  'test "$(zfs get -H -o value mountpoint,mounted ssd_tank/nextcloud-db | tr "\n" " ")" = "/mnt/ssd_tank/nextcloud-db yes "'
check "Propriétés de production réappliquées (recordsize 16K, lecture-écriture)" $MAIN \
  'test "$(zfs get -H -o value recordsize ssd_tank/nextcloud-db)" = 16K && test "$(zfs get -H -o value readonly ssd_tank/nextcloud-db)" = off'
check "La base Nextcloud contient l'état d'avant la panne" $MAIN \
  "$SQL; test \"\$(sql 'SELECT etat FROM restore_test')\" = sauvegarde"
check "Tous les conteneurs sont sains" $MAIN \
  'for i in $(seq 1 30); do bad=$(docker ps -a --format "{{.Status}}" | grep -cE "unhealthy|starting|Restarting|Exited"); [ "$bad" -eq 0 ] && exit 0; sleep 10; done; docker ps -a --format "{{.Names}} {{.Status}}" | grep -E "unhealthy|starting|Restarting|Exited"; exit 1'
step "Nouveau snapshot après restauration" $MAIN 'zfs snapshot -r ssd_tank@apres-restauration-$TS'
check "La réplication reprend en incrémental" $BACKUP \
  'systemctl start syncoid-pull.service && zfs list vault/srv-main/ssd_tank/nextcloud-db@apres-restauration-$TS'

summary
