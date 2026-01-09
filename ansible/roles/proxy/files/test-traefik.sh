#!/bin/bash
# Lien symbolique vers le script de test principal
exec "$(dirname "$0")/../../../../scripts/test-traefik.sh" "$@"
