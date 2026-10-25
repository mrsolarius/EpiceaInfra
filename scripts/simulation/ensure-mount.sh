#!/bin/bash
# ========================================
# Vérifie que le projet est monté dans srv-main-sim (/home/ubuntu/infra)
# ========================================
# Multipass sous Windows perd parfois ce montage, par exemple après un
# redémarrage de la VM : on le recrée si besoin.
set -euo pipefail
export MSYS_NO_PATHCONV=1

VM=srv-main-sim
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
  PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd -W)"
else
  PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi

if ! multipass exec "$VM" -- test -f /home/ubuntu/infra/Makefile 2>/dev/null; then
  echo "Montage du projet absent dans $VM : remontage"
  multipass umount "$VM" 2>/dev/null || true
  multipass mount "$PROJECT_ROOT" "$VM:/home/ubuntu/infra"
fi
