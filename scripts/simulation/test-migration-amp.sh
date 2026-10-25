#!/bin/bash
# ========================================
# Test de la migration AMP (docs/MIGRATION.md) : ancien gameserver -> srv-backup -> srv-main
# Usage : bash scripts/simulation/test-migration-amp.sh   (ou make sim-test-migration)
# ========================================
# Une VM gameserver-sim reproduit l'ancien serveur de jeu : Ubuntu 20.04, AMP depuis le dépôt
# CubeCoders, MySQL 8.0 natif avec une base de plugin. Pendant la copie à chaud, un faux serveur
# de jeu écrit dans son monde et un faux plugin écrit dans MySQL : le pull se fait en service.
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/simulation/lib.sh

GAME=gameserver-sim
AMP_PW="Sim-Amp-2026"
BACKUP_IP=$(grep -A1 "srv-backup:" ansible/inventory/simulation.yml | grep -o "[0-9.]*$")

push() {  # push <vm> <fichier local> <destination>
  multipass exec "$1" -- bash -c "echo $(tr -d '\r' < "$2" | base64 -w0) | base64 -d | sudo tee $3 >/dev/null && sudo chmod +x $3"
}
pubkey() {  # pubkey <vm> : clé SSH root de la VM (créée si besoin)
  on "$1" 'test -f /root/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519; cat /root/.ssh/id_ed25519.pub' | tr -d '\r'
}

echo "=== 0. Ancien serveur de jeu (gameserver-sim) ==="
if ! multipass info "$GAME" >/dev/null 2>&1; then
  echo "  ...  Création de la VM (Ubuntu 20.04, comme l'ancien gameserver)"
  multipass launch 20.04 --name "$GAME" --cpus 2 --memory 2G --disk 12G >/dev/null || exit 1
fi
GAME_IP=$(on "$GAME" "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1" | tr -d '\r')

step "Installer MySQL 8.0 et AMP (dépôt CubeCoders)" $GAME '
  set -e; export DEBIAN_FRONTEND=noninteractive
  command -v ampinstmgr >/dev/null && exit 0
  apt-get update -qq && apt-get install -y -qq mysql-server rsync curl gnupg lib32gcc-s1 tmux screen jq unzip >/dev/null
  curl -fsSL https://repo.cubecoders.com/archive.key -o /usr/share/keyrings/repo.cubecoders.com.gpg
  echo "deb [signed-by=/usr/share/keyrings/repo.cubecoders.com.gpg] https://repo.cubecoders.com/ debian/" > /etc/apt/sources.list.d/cubecoders.list
  apt-get update -qq && apt-get install -y -qq ampinstmgr >/dev/null
  id amp >/dev/null 2>&1 || useradd -m -d /home/amp -s /bin/bash amp'
step "Créer l'instance ADS01 et la démarrer" $GAME "
  test -f /home/amp/.ampdata/instances.json && exit 0
  # Détaché (systemd-run) : quickstart attend la fin de la configuration dans le navigateur
  # et garderait la session multipass ouverte
  systemd-run -q --unit=amp-quickstart -p User=amp -p WorkingDirectory=/home/amp ampinstmgr quickstart admin $AMP_PW 0.0.0.0 8080
  for i in \$(seq 1 60); do ss -tln | grep -q ':8080 ' && exit 0; sleep 5; done; exit 1"
step "Monde de jeu et base de plugin" $GAME '
  set -e; W=/home/amp/.ampdata/instances/Litopia/world
  mkdir -p $W/region; test -f $W/region/r.0.0.mca || head -c 150M /dev/urandom > $W/region/r.0.0.mca
  chown -R amp:amp /home/amp/.ampdata/instances/Litopia
  mysql -e "CREATE DATABASE IF NOT EXISTS luckperms; CREATE TABLE IF NOT EXISTS luckperms.actions (t DATETIME(6));
            CREATE USER IF NOT EXISTS lp@localhost IDENTIFIED BY \"LpPass-2021\"; GRANT ALL ON luckperms.* TO lp@localhost;"'
step "Démarrer le faux serveur de jeu et le faux plugin (écritures continues)" $GAME '
  systemctl stop fake-game fake-plugin 2>/dev/null; systemctl reset-failed fake-game fake-plugin 2>/dev/null
  systemd-run -q --unit=fake-game -p User=amp bash -c "while true; do date +%s%N >> /home/amp/.ampdata/instances/Litopia/world/session.log; sleep 0.2; done"
  systemd-run -q --unit=fake-plugin bash -c "while true; do mysql -e \"INSERT INTO luckperms.actions VALUES (NOW(6))\"; sleep 0.5; done"'
step "Autoriser srv-backup sur le gameserver (clé SSH ; sudo sans mot de passe déjà actif)" $GAME \
  "grep -qF '$(pubkey $BACKUP)' /home/ubuntu/.ssh/authorized_keys || echo '$(pubkey $BACKUP)' >> /home/ubuntu/.ssh/authorized_keys"

PULL="ONLY=gameserver IP_gameserver=$GAME_IP SSH_USER=ubuntu /root/migration/pull-old-servers.sh"
on $BACKUP 'mkdir -p /root/migration'
push $BACKUP scripts/migration/pull-old-servers.sh /root/migration/pull-old-servers.sh

echo "=== 1. Copie à chaud pendant que tout tourne ==="
step "pull-old-servers.sh sync" $BACKUP "$PULL sync"
check "AMP tournait encore après la copie (panneau sur 8080)" $GAME "ss -tln | grep -q ':8080 '"
check "Le serveur et le plugin écrivaient encore" $GAME 'systemctl is-active -q fake-game && systemctl is-active -q fake-plugin'
check "Les instances AMP sont copiées" $BACKUP 'test -s /mnt/vault/migration/gameserver/home/amp/.ampdata/instances.json'
check "Le monde est copié" $BACKUP 'test -s /mnt/vault/migration/gameserver/home/amp/.ampdata/instances/Litopia/world/region/r.0.0.mca'
step "Deuxième copie à chaud (seulement les différences)" $BACKUP "$PULL sync"

echo "=== 2. Jour J : passe finale ==="
# Avec de vrais serveurs, ampinstmgr stopall les arrête : ici on arrête les faux à sa place
step "Les serveurs de jeu s'arrêtent" $GAME 'systemctl stop fake-game fake-plugin'
step "pull-old-servers.sh final" $BACKUP "$PULL final"
check "AMP est arrêté sur l'ancien serveur" $GAME "! ss -tln | grep -q ':8080 '"
check "Export des bases du plugin" $BACKUP 'grep -q "INSERT INTO \`actions\`" /mnt/vault/migration/gameserver/var/backups/migration/amp-databases.sql'
check "Export des comptes MySQL (lp)" $BACKUP 'grep -q "CREATE USER \`lp\`@\`localhost\`" /mnt/vault/migration/gameserver/var/backups/migration/amp-users.sql'
check "Snapshot final" $BACKUP 'zfs list -t snapshot -o name | grep -q "^vault/migration/gameserver@final-"'
check "verify : 0 différence" $BACKUP "$PULL verify | tee /dev/stderr | grep -q 'Total : 0 différence'"

echo "=== 3. Restauration sur srv-main ==="
step "Autoriser srv-main sur srv-backup (clé SSH root)" $BACKUP \
  "grep -qF '$(pubkey $MAIN)' /root/.ssh/authorized_keys 2>/dev/null || echo '$(pubkey $MAIN)' >> /root/.ssh/authorized_keys"
on $MAIN 'mkdir -p /root/migration'
push $MAIN scripts/migration/restore-on-srv-main.sh /root/migration/restore-on-srv-main.sh
step "restore-on-srv-main.sh amp" $MAIN "BACKUP=root@$BACKUP_IP /root/migration/restore-on-srv-main.sh amp"

OLD_ID=$(on $GAME "jq -r '.[0].InstanceID' /home/amp/.ampdata/instances.json" | tr -d '\r')
OLD_ROWS=$(on $GAME "mysql -NBe 'SELECT COUNT(*) FROM luckperms.actions'" | tr -d '\r')
OLD_SUMS=$(on $GAME 'cd /home/amp/.ampdata/instances/Litopia/world && sha256sum region/r.0.0.mca session.log' | tr -d '\r')
check "Même instance AMP qu'avant (InstanceID $OLD_ID)" $MAIN "test \"\$(jq -r '.[0].InstanceID' /home/amp/.ampdata/instances.json)\" = '$OLD_ID'"
check "Monde identique, jusqu'à la dernière écriture" $MAIN \
  "cd /home/amp/.ampdata/instances/Litopia/world && test \"\$(sha256sum region/r.0.0.mca session.log)\" = '$OLD_SUMS'"
check "Fichiers à amp" $MAIN 'test -z "$(find /home/amp ! -user amp | head -1)"'
check "AMP redémarré (panneau sur 8080)" $MAIN "for i in \$(seq 1 36); do ss -tln | grep -q ':8080 ' && exit 0; sleep 5; done; exit 1"
check "Le plugin se connecte à 127.0.0.1:3306 avec son ancien compte ($OLD_ROWS lignes)" $MAIN \
  "test \"\$(docker run --rm --network host -e MYSQL_PWD=LpPass-2021 mysql:8.0 mysql -h127.0.0.1 -ulp -NBe 'SELECT COUNT(*) FROM luckperms.actions')\" = '$OLD_ROWS'"

summary
