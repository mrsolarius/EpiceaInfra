#!/bin/bash
set -euo pipefail

# ========================================
# Init Epicea VM - Wrapper ultra-minimaliste
# Installe juste Ansible via bootstrap
# TOUT LE RESTE est fait par Ansible !
# ========================================

STORAGE_IP=${1:-}

echo "========================================"
echo "  Init Epicea VM"
echo "========================================"
echo ""

# Lancer bootstrap (installe Ansible uniquement)
echo "🚀 Lancement du bootstrap..."
sudo bash /home/ubuntu/infra/scripts/bootstrap.sh

echo ""
echo "========================================"
echo "  ✅ Epicea VM prête !"
echo "========================================"
echo ""
echo "Depuis ton PC, lance :"
echo "  make test-init"
echo "  make test-deploy"
echo ""
echo "Note : Docker, NFS, firewall, etc. seront"
echo "installés automatiquement par Ansible."
echo ""
