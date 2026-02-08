#!/bin/bash
set -euo pipefail

# Couleurs pour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Désactiver la conversion de chemin MSYS/Git Bash pour les commandes envoyées aux VMs
export MSYS_NO_PATHCONV=1

echo -e "${GREEN}=== Configuration VMs Multipass pour tests Epicea ===${NC}\n"

# Récupère le chemin du projet (depuis scripts/multipass/)
# Support Windows (Git Bash / WSL) avec conversion de chemin
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    # Windows Git Bash : convertir /c/Users/... en C:/Users/...
    PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd -W 2>/dev/null || pwd)"
else
    PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi

echo -e "Chemin projet : ${YELLOW}${PROJECT_ROOT}${NC}\n"

# Configuration VMs
STORAGE_VM="storage-test"
EPICEA_VM="epicea-test"

STORAGE_CPUS=2
STORAGE_MEM="4G"
STORAGE_DISK="20G"

EPICEA_CPUS=4
EPICEA_MEM="8G"
EPICEA_DISK="100G"

# Vérifier si multipass est installé
if ! command -v multipass &> /dev/null; then
    echo -e "${RED}❌ Multipass n'est pas installé${NC}"
    echo "Télécharger : https://multipass.run/install"
    exit 1
fi

# Fonction pour vérifier si une VM existe
vm_exists() {
    multipass list | grep -q "^$1"
}

# 1. Créer VM Storage (NAS simulé)
echo -e "${GREEN}📦 Création VM Storage (NAS simulé)...${NC}"
if vm_exists "$STORAGE_VM"; then
    echo -e "${YELLOW}⚠️  VM $STORAGE_VM existe déjà. Suppression...${NC}"
    multipass delete "$STORAGE_VM" || true
    multipass purge || true
fi

multipass launch \
    --name "$STORAGE_VM" \
    --cpus "$STORAGE_CPUS" \
    --memory "$STORAGE_MEM" \
    --disk "$STORAGE_DISK" \
    24.04

echo -e "${GREEN}✅ VM Storage créée${NC}\n"

# 2. Créer VM Epicea (serveur applicatif)
echo -e "${GREEN}🖥️  Création VM Epicea (serveur applicatif)...${NC}"
if vm_exists "$EPICEA_VM"; then
    echo -e "${YELLOW}⚠️  VM $EPICEA_VM existe déjà. Suppression...${NC}"
    multipass delete "$EPICEA_VM" || true
    multipass purge || true
fi

multipass launch \
    --name "$EPICEA_VM" \
    --cpus "$EPICEA_CPUS" \
    --memory "$EPICEA_MEM" \
    --disk "$EPICEA_DISK" \
    --mount "$PROJECT_ROOT:/home/ubuntu/infra" \
    24.04

echo -e "${GREEN}✅ VM Epicea créée avec mount projet${NC}\n"

# 3. Récupérer IPs
echo -e "${GREEN}🔍 Récupération des IPs...${NC}"
STORAGE_IP=$(multipass info "$STORAGE_VM" | grep IPv4 | awk '{print $2}')
EPICEA_IP=$(multipass info "$EPICEA_VM" | grep IPv4 | awk '{print $2}')

echo -e "  Storage VM : ${YELLOW}${STORAGE_IP}${NC}"
echo -e "  Epicea VM  : ${YELLOW}${EPICEA_IP}${NC}\n"

# 4. Monter temporairement le projet sur Storage VM pour accéder aux scripts
echo -e "${GREEN}📋 Montage temporaire du projet sur Storage VM...${NC}"
# Utiliser un chemin relatif simple pour éviter les problèmes de drive letter Windows dans le mount
multipass mount . "$STORAGE_VM:/tmp/infra-scripts"

# 5. Initialiser VM Storage (NFS server)
echo -e "${GREEN}🔧 Configuration NFS sur Storage VM...${NC}"
multipass exec "$STORAGE_VM" -- sudo bash /tmp/infra-scripts/scripts/multipass/init-storage-vm.sh

# Démonter après utilisation
echo -e "${GREEN}📋 Démontage du projet sur Storage VM...${NC}"
multipass umount "$STORAGE_VM:/tmp/infra-scripts"

# 6. Initialiser VM Epicea (Docker + Ansible)
# Le projet est déjà monté dans /home/ubuntu/infra
echo -e "${GREEN}🔧 Configuration Epicea VM...${NC}"
multipass exec "$EPICEA_VM" -- sudo bash /home/ubuntu/infra/scripts/multipass/init-epicea-vm.sh "$STORAGE_IP"

# 7. Mettre à jour l'inventory Ansible avec les bonnes IPs
echo -e "${GREEN}📝 Mise à jour inventory Ansible...${NC}"
INVENTORY_FILE="$PROJECT_ROOT/ansible/inventory/hosts.yml"
GROUP_VARS_FILE="$PROJECT_ROOT/ansible/group_vars/test.yml"

# Sur Windows avec Git Bash, utiliser sed compatible
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    sed -i "s/ansible_host: .* # IP_EPICEA_TEST/ansible_host: $EPICEA_IP # IP_EPICEA_TEST/" "$INVENTORY_FILE"
    sed -i "s/nfs_server: \".*\" # IP_STORAGE_TEST/nfs_server: \"$STORAGE_IP\" # IP_STORAGE_TEST/" "$GROUP_VARS_FILE"
else
    sed -i.bak "s/ansible_host: .* # IP_EPICEA_TEST/ansible_host: $EPICEA_IP # IP_EPICEA_TEST/" "$INVENTORY_FILE"
    sed -i.bak "s/nfs_server: \".*\" # IP_STORAGE_TEST/nfs_server: \"$STORAGE_IP\" # IP_STORAGE_TEST/" "$GROUP_VARS_FILE"
    rm -f "${INVENTORY_FILE}.bak" "${GROUP_VARS_FILE}.bak"
fi

echo -e "${GREEN}✅ Inventory et group_vars mis à jour${NC}\n"

# 7. Afficher résumé
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           VMs Multipass créées avec succès ! 🎉          ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}\n"

echo -e "📦 ${YELLOW}Storage VM${NC}   : $STORAGE_VM ($STORAGE_IP)"
echo -e "🖥️  ${YELLOW}Epicea VM${NC}    : $EPICEA_VM ($EPICEA_IP)"
echo -e "📁 ${YELLOW}Projet monté${NC} : /home/ubuntu/infra\n"

echo -e "${GREEN}Prochaines étapes :${NC}"
echo -e "  1. ${YELLOW}make test-init${NC}     # Initialiser secrets test"
echo -e "  2. ${YELLOW}make test-deploy${NC}   # Déployer sur VM test"
echo -e "  3. ${YELLOW}make test-status${NC}   # Vérifier statut services\n"

echo -e "${YELLOW}Accès SSH :${NC}"
echo -e "  multipass shell $EPICEA_VM\n"

echo -e "${YELLOW}Détruire les VMs :${NC}"
echo -e "  bash scripts/multipass/destroy-vms.sh\n"
