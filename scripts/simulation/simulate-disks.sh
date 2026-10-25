#!/bin/bash
# ========================================
# Simulation des disques physiques dans une VM
# Usage : sudo simulate-disks.sh srv-main|srv-backup
# ========================================
# Chaque disque réel devient un fichier creux attaché en loop device.
# Une règle udev lui donne le même nom /dev/disk/by-id que le vrai disque
# (et les liens -partN des partitions créées par ZFS), si bien que les
# variables zfs_pools de production s'appliquent telles quelles.
# Tailles réduites, proportions conservées : 4 To -> 5 Go, 26 To -> 33 Go (vault >= tank).
set -euo pipefail

PROFILE=${1:?Usage: simulate-disks.sh srv-main|srv-backup}
DIR=/var/lib/sim-disks
RULES=/etc/udev/rules.d/99-sim-disks.rules

case "$PROFILE" in
  srv-main)
    DISKS=(
      "ata-ST4000NM000A-2HZ100_WJG18L6P:5G"
      "ata-ST4000NM000A-2HZ100_WJG10EM1:5G"
      "ata-ST4000NM000A-2HZ100_WJG18KLM:5G"
      "ata-ST4000NM000A-2HZ100_WJG17J2C:5G"
      "ata-ST4000NM000A-2HZ100_WJG17WFW:5G"
      "ata-ST4000NM000A-2HZ100_WJG193FZ:5G"
      "ata-ST4000NM000A-2HZ100_WJG193LM:5G"
      "ata-ST4000NM000A-2HZ100_WJG18KM9:5G"
      "ata-CT1000MX500SSD1_2019E2A1579C:2G"
      "ata-Samsung_SSD_850_PRO_256GB_S251NSAG902861D:4G"  # Jellyfin exige 2 Gio libres pour son cache
    )
    ;;
  srv-backup)
    DISKS=(
      "ata-ST26000NM000C-3WE103_ZXA24BZ3:33G"
      "ata-ST26000NM000C-3WE103_K1N00A6V:33G"
    )
    ;;
  *)
    echo "Profil inconnu : $PROFILE" >&2
    exit 1
    ;;
esac

mkdir -p "$DIR"
tmp=$(mktemp)
for disk in "${DISKS[@]}"; do
  id=${disk%%:*}
  size=${disk##*:}
  img="$DIR/$id.img"
  [[ -f "$img" ]] || truncate -s "$size" "$img"
  cat >> "$tmp" <<EOF
KERNEL=="loop*", ENV{DEVTYPE}=="disk", ATTR{loop/backing_file}=="$img", SYMLINK+="disk/by-id/$id"
KERNEL=="loop*", ENV{DEVTYPE}=="partition", ATTRS{loop/backing_file}=="$img", SYMLINK+="disk/by-id/$id-part%n"
EOF
done
install -m 0644 "$tmp" "$RULES"
rm -f "$tmp"
udevadm control --reload

# Script d'attachement rejoué à chaque démarrage, avant l'import des pools ZFS
cat > /usr/local/sbin/sim-disks-attach <<EOF
#!/bin/bash
for img in $DIR/*.img; do
  losetup -j "\$img" | grep -q . || losetup -f -P "\$img"
done
udevadm trigger --subsystem-match=block
udevadm settle
EOF
chmod 0755 /usr/local/sbin/sim-disks-attach

cat > /etc/systemd/system/sim-disks.service <<'EOF'
[Unit]
Description=Disques physiques simulés (loop + liens by-id)
DefaultDependencies=no
# Pas de After=local-fs.target : zfs-mount fait partie de local-fs, ce serait un cycle
After=systemd-udevd.service
RequiresMountsFor=/var/lib/sim-disks
Before=zfs-import-cache.service zfs-import-scan.service zfs-import.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/sim-disks-attach

[Install]
WantedBy=sysinit.target
EOF
systemctl daemon-reload
systemctl enable sim-disks.service
# Appel direct : le service déjà actif ne se relance pas si on rejoue le script
/usr/local/sbin/sim-disks-attach

echo "Disques simulés pour $PROFILE :"
for disk in "${DISKS[@]}"; do
  id=${disk%%:*}
  printf '  %-55s -> %s\n' "/dev/disk/by-id/$id" "$(readlink -f "/dev/disk/by-id/$id")"
done
