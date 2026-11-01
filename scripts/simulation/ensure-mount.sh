#!/bin/bash
# ========================================
# Vérifie que le projet est monté dans srv-main-sim (/home/ubuntu/infra)
# ========================================
# Multipass sous Windows perd parfois ce montage, par exemple après un
# redémarrage de la VM : on le recrée si besoin.
set -euo pipefail
source "$(dirname "$0")/lib.sh"  # mp : multipass avec délai

VM=srv-main-sim
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
  PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd -W)"
else
  PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi

# test -f renvoie 1 si le fichier manque : seul un délai dépassé (124) est une vraie erreur
rc=0
mp exec "$VM" -- test -f /home/ubuntu/infra/Makefile || rc=$?
if [[ $rc -eq 124 ]]; then exit 1; fi
if [[ $rc -ne 0 ]]; then
  echo "Montage du projet absent dans $VM : remontage"
  mp umount "$VM" 2>/dev/null || true
  mp mount "$PROJECT_ROOT" "$VM:/home/ubuntu/infra"
fi
