#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}⚠️  Destruction des VMs Multipass Epicea${NC}\n"

STORAGE_VM="storage-test"
EPICEA_VM="epicea-test"

# Demande confirmation
read -p "Êtes-vous sûr de vouloir détruire les VMs ? (yes/no) : " confirm

if [[ "$confirm" != "yes" ]]; then
    echo -e "${GREEN}Annulé.${NC}"
    exit 0
fi

echo ""
echo -e "${RED}🗑️  Suppression de $EPICEA_VM...${NC}"
if multipass list | grep -q "^$EPICEA_VM"; then
    multipass stop "$EPICEA_VM" 2>/dev/null || true
    multipass delete "$EPICEA_VM"
    echo -e "${GREEN}✅ $EPICEA_VM supprimée${NC}"
else
    echo -e "${YELLOW}⚠️  $EPICEA_VM n'existe pas${NC}"
fi

echo ""
echo -e "${RED}🗑️  Suppression de $STORAGE_VM...${NC}"
if multipass list | grep -q "^$STORAGE_VM"; then
    multipass stop "$STORAGE_VM" 2>/dev/null || true
    multipass delete "$STORAGE_VM"
    echo -e "${GREEN}✅ $STORAGE_VM supprimée${NC}"
else
    echo -e "${YELLOW}⚠️  $STORAGE_VM n'existe pas${NC}"
fi

echo ""
echo -e "${RED}🗑️  Purge des VMs supprimées...${NC}"
multipass purge

echo ""
echo -e "${GREEN}✅ Toutes les VMs Epicea ont été supprimées${NC}"
echo -e "Pour recréer : ${YELLOW}bash scripts/multipass/setup-vms.sh${NC}\n"
