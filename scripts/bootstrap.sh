#!/bin/bash
set -euo pipefail

# ========================================
# Bootstrap Epicea - ULTRA MINIMALISTE
# Installe UNIQUEMENT : Ansible + Git
# TOUT LE RESTE est géré par Ansible !
# ========================================

echo "========================================"
echo "  Bootstrap Epicea Infrastructure"
echo "========================================"
echo ""

# Vérifier root/sudo
if [[ $EUID -ne 0 ]]; then
   echo "⚠️  Ce script doit être exécuté avec sudo"
   exit 1
fi

echo "📦 Mise à jour système..."
apt-get update -qq

echo "📦 Installation Python + Git..."
apt-get install -y -qq python3 python3-pip git curl

echo "📦 Installation Ansible..."
apt-get install -y -qq ansible

echo ""
echo "========================================"
echo "  ✅ Bootstrap terminé !"
echo "========================================"
echo ""
echo "Ansible version : $(ansible --version | head -n1)"
echo ""
echo "Prochaines étapes :"
echo "  1. make init"
echo "  2. make deploy"
echo ""
echo "Note : Docker, NFS, firewall, etc. seront"
echo "installés automatiquement par Ansible."
echo ""
