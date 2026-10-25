#!/bin/bash
# ========================================
# Banc de simulation de l'infrastructure de production
# Usage : bash scripts/simulation/setup-sim.sh   (ou make sim-up)
# ========================================
# Crée deux VMs Multipass qui reproduisent srv-main et srv-backup :
#   - mêmes disques que la production (noms /dev/disk/by-id identiques, tailles réduites)
#   - Ansible installé sur srv-main-sim, qui sert de contrôleur pour les deux VMs
#   - inventaire et variables réseau générés avec les IPs des VMs
set -euo pipefail
export MSYS_NO_PATHCONV=1

MAIN_VM="srv-main-sim"
BACKUP_VM="srv-backup-sim"
# Tailles surchargeables, ex. pour un test avec de vraies données :
#   MAIN_DISK=200G BACKUP_DISK=320G SSD_SIZE=180G VAULT_SIZE=180G make sim-up
MAIN_CPUS=4; MAIN_MEM="6G"; MAIN_DISK="${MAIN_DISK:-40G}"
BACKUP_CPUS=2; BACKUP_MEM="${BACKUP_MEM:-2G}"; BACKUP_DISK="${BACKUP_DISK:-15G}"
UBUNTU="24.04"

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
  PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd -W)"
else
  PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi
SIM_DIR="$PROJECT_ROOT/scripts/simulation"
ANSIBLE_DIR="$PROJECT_ROOT/ansible"

command -v multipass >/dev/null || { echo "Multipass n'est pas installé : https://multipass.run/install"; exit 1; }

vm_exists() { multipass info "$1" >/dev/null 2>&1; }
# IP lue dans la VM : multipass info peut afficher une ancienne IP en cache
vm_ip() { multipass exec "$1" -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1; }
step() { echo ""; echo "[$(date +%H:%M:%S)] === $* ==="; }

# Le script est reprenable : les VMs déjà créées sont conservées (make sim-down pour repartir de zéro)
step "Création des VMs"
vm_exists "$MAIN_VM" || multipass launch "$UBUNTU" --name "$MAIN_VM" --cpus "$MAIN_CPUS" \
  --memory "$MAIN_MEM" --disk "$MAIN_DISK" --mount "$PROJECT_ROOT:/home/ubuntu/infra"
vm_exists "$BACKUP_VM" || multipass launch "$UBUNTU" --name "$BACKUP_VM" --cpus "$BACKUP_CPUS" \
  --memory "$BACKUP_MEM" --disk "$BACKUP_DISK"

bash "$SIM_DIR/ensure-mount.sh"

step "Simulation des disques"
# Copie en base64 puis exécution locale : sous Windows, multipass transfer, l'entrée standard
# de multipass exec et la lecture d'un script sur le dossier monté sont peu fiables
run_sim_disks() {
  multipass exec "$1" -- bash -c "echo $(base64 -w0 "$SIM_DIR/simulate-disks.sh") | base64 -d > /tmp/simulate-disks.sh"
  multipass exec "$1" -- sudo SSD_SIZE="${SSD_SIZE:-2G}" VAULT_SIZE="${VAULT_SIZE:-33G}" bash /tmp/simulate-disks.sh "$2"
}
run_sim_disks "$MAIN_VM" srv-main
run_sim_disks "$BACKUP_VM" srv-backup

step "Installation d'Ansible sur $MAIN_VM (contrôleur)"
multipass exec "$MAIN_VM" -- sudo bash /home/ubuntu/infra/scripts/bootstrap.sh

step "IPs fixes (le DHCP de Hyper-V change l'IP au redémarrage)"
# Fige l'IP actuelle de la VM en configuration statique (script envoyé en base64)
PIN_IP_SCRIPT=$(cat <<'EOF'
test -f /etc/netplan/60-sim-static.yaml && exit 0
addr=$(ip -4 -o addr show eth0 | awk '{print $4}' | head -1)
gw=$(ip route | awk '/^default/ {print $3; exit}')
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
rm -f /etc/netplan/50-cloud-init.yaml
cat > /etc/netplan/60-sim-static.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses: [$addr]
      routes: [{to: default, via: $gw}]
      nameservers: {addresses: [$gw]}
NETPLAN
chmod 600 /etc/netplan/60-sim-static.yaml
netplan apply
EOF
)
pin_ip() {
  multipass exec "$1" -- bash -c "echo $(printf '%s' "$PIN_IP_SCRIPT" | base64 -w0) | base64 -d | sudo bash"
}
pin_ip "$MAIN_VM"
pin_ip "$BACKUP_VM"

step "Accès SSH $MAIN_VM -> $BACKUP_VM"
multipass exec "$MAIN_VM" -- bash -c 'test -f ~/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519'
PUBKEY=$(multipass exec "$MAIN_VM" -- cat /home/ubuntu/.ssh/id_ed25519.pub)
multipass exec "$BACKUP_VM" -- bash -c "grep -qF '$PUBKEY' ~/.ssh/authorized_keys || echo '$PUBKEY' >> ~/.ssh/authorized_keys"

MAIN_IP=$(vm_ip "$MAIN_VM")
BACKUP_IP=$(vm_ip "$BACKUP_VM")
# Seul srv-main doit lire le node exporter de srv-backup
SCRAPER="$MAIN_IP/32"

step "Génération de l'inventaire de simulation"
cat > "$ANSIBLE_DIR/inventory/simulation.yml" <<EOF
---
# Généré par scripts/simulation/setup-sim.sh - ne pas versionner
all:
  vars:
    ansible_become: true
    ansible_python_interpreter: /usr/bin/python3
  children:
    production:
      hosts:
        srv-main:
          ansible_host: $MAIN_IP
          ansible_connection: local
          ansible_user: ubuntu
    backup:
      hosts:
        srv-backup:
          ansible_host: $BACKUP_IP
          ansible_user: ubuntu
          ansible_ssh_common_args: "-o StrictHostKeyChecking=accept-new"
EOF

cat > "$ANSIBLE_DIR/group_vars/simulation-network.yml" <<EOF
---
# Généré par scripts/simulation/setup-sim.sh - ne pas versionner
monitoring_extra_node_targets:
  - {target: "$BACKUP_IP:9100", instance: "srv-backup"}
backup_lan_cidr: "$SCRAPER"
EOF

if [[ ! -f "$ANSIBLE_DIR/secrets/vault.yml" ]]; then
  cp "$ANSIBLE_DIR/secrets/vault.yml.example" "$ANSIBLE_DIR/secrets/vault.yml"
  echo "vault.yml créé depuis l'exemple (non chiffré, pour la simulation)"
fi

echo ""
echo "Banc prêt : $MAIN_VM ($MAIN_IP), $BACKUP_VM ($BACKUP_IP)"
echo "Étapes suivantes : make sim-deploy && make sim-deploy-backup && make sim-test"
