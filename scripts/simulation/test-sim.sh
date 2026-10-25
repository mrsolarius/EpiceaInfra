#!/bin/bash
# ========================================
# Tests de bout en bout du banc de simulation
# Usage : bash scripts/simulation/test-sim.sh   (ou make sim-test)
# ========================================
# Vérifie stockage ZFS, services, routage Traefik, monitoring, snapshots,
# réplication vers srv-backup, droits de l'utilisateur syncoid et alerte
# sur panne de disque.
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/simulation/lib.sh

echo "=== 1. Disques et pools ZFS (srv-main) ==="
check "8 HDD + 2 SSD visibles sous leur nom by-id de production" $MAIN \
  'test $(ls /dev/disk/by-id/ | grep -cE "^ata-(ST4000NM000A-2HZ100|CT1000MX500SSD1|Samsung_SSD_850_PRO_256GB)_[A-Z0-9]+$") -eq 10'
check "Pools tank, ssd_tank et scratch ONLINE" $MAIN \
  'test "$(zpool list -H -o name,health | sort | tr "\t\n" ":,")" = "scratch:ONLINE,ssd_tank:ONLINE,tank:ONLINE,"'
check "tank est un RAIDZ2 de 8 disques référencés par by-id" $MAIN \
  'zpool status -P tank | grep -q raidz2-0 && test $(zpool status -P tank | grep -cE "/dev/disk/by-id/ata-ST4000NM000A-2HZ100_[A-Z0-9]+(-part1)? ") -eq 8'
check "ashift=12 sur les pools" $MAIN \
  'test "$(zpool get -H -o value ashift tank ssd_tank scratch | sort -u)" = 12'
check "Datasets montés aux chemins attendus" $MAIN \
  'for d in tank/media:/mnt/tank/media tank/photos:/mnt/tank/photos tank/cloud:/mnt/tank/cloud ssd_tank/immich-db:/mnt/ssd_tank/immich-db scratch/jellyfin-cache:/mnt/scratch/jellyfin-cache; do test "$(zfs get -H -o value mountpoint,mounted ${d%%:*} | tr "\n" " ")" = "${d##*:} yes " || exit 1; done'
check "Propriétés : recordsize 1M (médias), 16K (BDD), sync=disabled (cache)" $MAIN \
  'test "$(zfs get -H -o value recordsize tank/media)" = 1M && test "$(zfs get -H -o value recordsize ssd_tank/nextcloud-db)" = 16K && test "$(zfs get -H -o value sync scratch/immich-ml-cache)" = disabled'
check "Limite ARC appliquée" $MAIN \
  'grep -q zfs_arc_max /etc/modprobe.d/zfs.conf && test "$(cat /sys/module/zfs/parameters/zfs_arc_max)" = 1073741824'
check "Nextcloud data appartient à www-data" $MAIN 'test "$(stat -c %u /mnt/tank/cloud)" = 33'

echo "=== 2. Conteneurs (srv-main) ==="
check "Tous les conteneurs attendus tournent" $MAIN \
  'for c in traefik prometheus grafana alertmanager loki nextcloud nextcloud-db immich-server immich-db immich-machine-learning redis jellyfin litopia-db litopia-back litopia-front backpaking-db backpaking-back backpaking-front; do docker ps --filter "name=^${c}$" --filter status=running -q | grep -q . || { echo "absent: $c"; exit 1; }; done'
check "Aucun conteneur unhealthy ou en redémarrage" $MAIN \
  'test -z "$(docker ps -a --format "{{.Names}} {{.Status}}" | grep -E "unhealthy|Restarting|Exited")"'
check "Bases PostgreSQL sur ssd_tank (ZFS)" $MAIN \
  'for c in immich-db nextcloud-db litopia-db backpaking-db; do docker inspect $c --format "{{range .Mounts}}{{.Source}} {{end}}" | grep -q /mnt/ssd_tank/ || { echo $c; exit 1; }; done'
check "Caches Jellyfin et Immich ML sur scratch" $MAIN \
  'docker inspect jellyfin --format "{{range .Mounts}}{{.Source}} {{end}}" | grep -q /mnt/scratch/jellyfin-cache && docker inspect immich-machine-learning --format "{{range .Mounts}}{{.Source}} {{end}}" | grep -q /mnt/scratch/immich-ml-cache'
check "Médias Jellyfin et photos Immich sur tank" $MAIN \
  'docker inspect jellyfin --format "{{range .Mounts}}{{.Source}} {{end}}" | grep -q /mnt/tank/media && docker inspect immich-server --format "{{range .Mounts}}{{.Source}} {{end}}" | grep -q /mnt/tank/photos/immich'
check "Quick Sync absent en VM : Jellyfin démarre sans /dev/dri" $MAIN \
  'test -z "$(docker inspect jellyfin --format "{{.HostConfig.Devices}}" | tr -d "[]")"'

echo "=== 3. Routage HTTPS via Traefik ==="
for site in photos.epicea-sim.local cloud.epicea-sim.local jellyfin.epicea-sim.local monitoring.epicea-sim.local litopia-sim.local backpaking.epicea-sim.local; do
  check "https://$site répond" $MAIN \
    "code=\$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve $site:443:127.0.0.1 https://$site/); echo \$code; [[ \$code =~ ^(200|301|302|303|307|308)$ ]]"
done

echo "=== 4. Monitoring ==="
check "Toutes les cibles Prometheus sont UP" $MAIN \
  'docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets | jq -e "[.data.activeTargets[] | select(.health != \"up\")] | length == 0" || docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets | jq -r ".data.activeTargets[] | select(.health != \"up\") | .labels.job + \" \" + .lastError"'
check "srv-backup est scrapé (node-exporter-lan)" $MAIN \
  "$PROMQL; test \$(q 'up{job=\"node-exporter-lan\"} == 1') -eq 1"
check "Métriques ZFS des pools remontées" $MAIN \
  "$PROMQL; test \$(q 'node_zfs_zpool_state{state=\"online\"} == 1') -ge 3"
check "Règles d'alerte ZFS et sauvegarde chargées" $MAIN \
  'docker exec prometheus wget -qO- http://localhost:9090/api/v1/rules | jq -e "[.data.groups[].name] | index(\"zfs_alerts\") and index(\"backup_alerts\")"'

echo "=== 5. Snapshots et copie des configs (srv-main) ==="
check "Timer sanoid actif" $MAIN 'systemctl is-active -q sanoid.timer'
# Snapshot explicite : sanoid ne snapshote que si un snapshot est dû
on $MAIN 'echo "fichier-test-$(date +%s)" > /mnt/tank/photos/sim-marker.txt; sanoid --take-snapshots; zfs snapshot -r tank@simtest-$(date +%s)' >/dev/null 2>&1
check "Snapshots sanoid créés sur tank et ssd_tank" $MAIN \
  'zfs list -H -t snapshot -o name | grep -q "^tank/photos@autosnap_" && zfs list -H -t snapshot -o name | grep -q "^ssd_tank/immich-db@autosnap_"'
check "scratch n'est pas snapshoté" $MAIN 'test -z "$(zfs list -H -t snapshot -o name -r scratch)"'
check "Copie des configs /opt/epicea vers tank/backups" $MAIN \
  'bash -c "$(grep -o "rsync.*" /etc/cron.d/epicea-configs-backup)" && test -f /mnt/tank/backups/epicea-configs/docker/traefik/docker-compose.yml && test ! -d /mnt/tank/backups/epicea-configs/monitoring/prometheus'

echo "=== 6. Serveur de sauvegarde ==="
check "Disques 26 To visibles sous leur nom by-id" $BACKUP \
  'test -L /dev/disk/by-id/ata-ST26000NM000C-3WE103_ZXA24BZ3 && test -L /dev/disk/by-id/ata-ST26000NM000C-3WE103_K1N00A6V'
check "Pool vault en miroir ONLINE" $BACKUP 'zpool status vault | grep -q mirror-0 && test "$(zpool list -H -o health vault)" = ONLINE'
check "Timer de réplication actif" $BACKUP 'systemctl is-active -q syncoid-pull.timer'
check "Réplication complète (1er passage)" $BACKUP 'systemctl start syncoid-pull.service'
check "Le fichier témoin est présent sur srv-backup" $BACKUP \
  "test \"\$(cat /mnt/vault/srv-main/tank/photos/sim-marker.txt)\" = \"$(on $MAIN 'cat /mnt/tank/photos/sim-marker.txt')\""
check "Bases de données répliquées" $BACKUP 'zfs list vault/srv-main/ssd_tank/immich-db vault/srv-main/ssd_tank/nextcloud-db'
check "Copies en lecture seule" $BACKUP 'test "$(zfs get -H -o value readonly vault/srv-main/tank/photos)" = on'
on $MAIN 'echo modifie >> /mnt/tank/photos/sim-marker.txt; zfs snapshot -r tank@simtest-$(date +%s)' >/dev/null 2>&1
check "Réplication incrémentale (2e passage)" $BACKUP 'systemctl start syncoid-pull.service && grep -q modifie /mnt/vault/srv-main/tank/photos/sim-marker.txt'
check "Métriques syncoid écrites" $BACKUP \
  'grep -q "syncoid_last_run_status 0" /var/lib/prometheus/node-exporter/syncoid.prom && test $(grep -c syncoid_last_success_timestamp_seconds /var/lib/prometheus/node-exporter/syncoid.prom) -eq 2'
check "Prometheus voit la date de dernière sauvegarde" $MAIN \
  "$(printf '%s' "$PROMQL"); for i in \$(seq 1 12); do test \$(q 'syncoid_last_success_timestamp_seconds') -eq 2 && exit 0; sleep 10; done; exit 1"

echo "=== 7. Sécurité de la réplication ==="
check "L'utilisateur syncoid ne peut pas détruire de snapshot" $MAIN \
  'snap=$(zfs list -H -t snapshot -o name tank/photos | head -1); ! sudo -u syncoid zfs destroy "$snap" 2>/dev/null && zfs list "$snap" >/dev/null'
check "L'utilisateur syncoid ne peut pas écrire dans les données" $MAIN '! sudo -u syncoid touch /mnt/tank/photos/intrus 2>/dev/null'
check "Sa clé n'est acceptée que depuis srv-backup" $MAIN 'grep -q "^from=\"" /var/lib/syncoid/.ssh/authorized_keys'

echo "=== 8. Panne d'un disque ==="
DISK=/dev/disk/by-id/ata-ST4000NM000A-2HZ100_WJG17WFW
# Nombre de notifications déjà envoyées par Alertmanager (toutes intégrations confondues)
NOTIFS='n() { docker exec alertmanager wget -qO- http://127.0.0.1:9093/metrics | awk "/^alertmanager_notifications_total/ {s+=\$2} END {print s+0}"; }'
NOTIFS_AVANT=$(on $MAIN "$NOTIFS; n" 2>/dev/null)
on $MAIN "zpool offline tank $DISK" >/dev/null 2>&1
check "tank passe DEGRADED mais reste lisible" $MAIN \
  'test "$(zpool list -H -o health tank)" = DEGRADED && cat /mnt/tank/photos/sim-marker.txt >/dev/null'
echo "  ...  attente de l'alerte ZFSPoolDegraded (jusqu'à 4 min)"
check "Alerte ZFSPoolDegraded déclenchée" $MAIN \
  "for i in \$(seq 1 24); do docker exec prometheus wget -qO- http://localhost:9090/api/v1/alerts | jq -e '.data.alerts[] | select(.labels.alertname==\"ZFSPoolDegraded\" and .state==\"firing\")' >/dev/null && exit 0; sleep 10; done; exit 1"
# Le disque ne revient qu'après l'envoi : sinon Alertmanager reçoit le rétablissement
# avant d'avoir notifié la panne, et n'envoie rien
check "Notification envoyée par Alertmanager (Discord)" $MAIN \
  "$NOTIFS; for i in \$(seq 1 12); do [ \"\$(n)\" -gt ${NOTIFS_AVANT:-0} ] && exit 0; sleep 5; done; exit 1"
NOTIFS_PANNE=$(on $MAIN "$NOTIFS; n" 2>/dev/null)
on $MAIN "zpool online tank $DISK && zpool clear tank" >/dev/null 2>&1
check "tank redevient ONLINE après remise en ligne" $MAIN \
  'for i in $(seq 1 12); do test "$(zpool list -H -o health tank)" = ONLINE && exit 0; sleep 5; done; exit 1'
echo "  ...  attente de la notification de rétablissement (jusqu'à 4 min)"
check "Notification de rétablissement envoyée (Discord)" $MAIN \
  "$NOTIFS; for i in \$(seq 1 24); do [ \"\$(n)\" -gt ${NOTIFS_PANNE:-0} ] && exit 0; sleep 10; done; exit 1"

echo "=== 9. Panne réparée par un redémarrage (pas de hotswap) ==="
check "Docker attend le montage des pools (garde-fou actif)" $MAIN \
  'systemctl cat docker.service | grep -q zfs-check-mounts && /usr/local/sbin/zfs-check-mounts'
check "Rapport de démarrage installé et activé" $MAIN 'systemctl is-enabled -q boot-report.service'
check "Alertmanager repart de zéro à chaque redémarrage (tmpfs)" $MAIN \
  'docker inspect alertmanager --format "{{json .HostConfig.Tmpfs}}" | grep -q /alertmanager'
# Panne temporaire (-t) : le disque revient de lui-même au redémarrage, comme un
# disque remplacé ou rebranché pendant l'arrêt
NOTIFS_AVANT=$(on $MAIN "$NOTIFS; n" 2>/dev/null)
on $MAIN "zpool offline -t tank $DISK" >/dev/null 2>&1
echo "  ...  disque en panne, attente de la notification (jusqu'à 4 min)"
check "Panne notifiée avant l'arrêt" $MAIN \
  "$NOTIFS; for i in \$(seq 1 24); do [ \"\$(n)\" -gt ${NOTIFS_AVANT:-0} ] && exit 0; sleep 10; done; exit 1"
# Le pool scratch disparaît du cache ZFS, comme après un démarrage où son disque
# était débranché : il doit être réimporté seul au démarrage suivant
on $MAIN "systemctl stop docker.socket docker && zpool export scratch" >/dev/null 2>&1
check "scratch n'est plus dans le cache ZFS" $MAIN '! zpool list scratch 2>/dev/null && ! strings /etc/zfs/zpool.cache | grep -qx scratch'
echo "  ...  arrêt, « réparation », redémarrage de la VM"
multipass restart "$MAIN" >/dev/null 2>&1
# Attendre que la VM réponde à nouveau (jusqu'à 3 min)
for i in $(seq 1 36); do multipass exec "$MAIN" -- true >/dev/null 2>&1 && break; sleep 5; done
bash scripts/simulation/ensure-mount.sh
check "Pools réimportés et datasets montés après redémarrage" $MAIN \
  'for i in $(seq 1 30); do /usr/local/sbin/zfs-check-mounts 2>/dev/null && exit 0; sleep 5; done; exit 1'
check "Tous les conteneurs redémarrés et sains" $MAIN \
  'for i in $(seq 1 36); do n=$(docker ps -q | wc -l); bad=$(docker ps --format "{{.Status}}" | grep -cE "unhealthy|starting|Restarting"); [ "$n" -ge 20 ] && [ "$bad" -eq 0 ] && exit 0; sleep 10; done; docker ps --format "{{.Names}} {{.Status}}" | grep -vE "\(healthy\)|Up [0-9a-z ]+$"; exit 1'
check "Le pool tank est revenu ONLINE" $MAIN 'test "$(zpool list -H -o health tank)" = ONLINE'
check "Le pool scratch, absent du cache, a été réimporté seul" $MAIN \
  'test "$(zpool list -H -o health scratch)" = ONLINE && journalctl -b -u zfs-import-expected --no-pager | grep -q "Pool scratch importé"'
check "Rapport de démarrage « RÉTABLI » envoyé sur Discord" $MAIN \
  'for i in $(seq 1 60); do journalctl -b -u boot-report --no-pager | grep "Rapport envoyé" | grep -q "RÉTABLI" && exit 0; sleep 10; done; journalctl -b -u boot-report --no-pager | tail -3; exit 1'
check "Aucun fichier écrit sur le disque système sous les points de montage" $MAIN \
  'mkdir -p /tmp/rootfs && mount --bind / /tmp/rootfs && for d in tank ssd_tank scratch; do test -z "$(ls -A /tmp/rootfs/mnt/$d 2>/dev/null)" || { echo "/mnt/$d non vide sur /"; umount /tmp/rootfs; exit 1; }; done; umount /tmp/rootfs'

summary
