#!/bin/bash
# ========================================
# Change le mot de passe du dashboard Traefik (utilisé par make traefik-pass)
# ========================================
# Usage : bash scripts/traefik-pass.sh <vault.yml en clair>
# Demande le mot de passe, le hache (htpasswd apr1) et écrit traefik_auth dans le vault.
set -euo pipefail
VAULT="$1"
USER_NAME="admin"

command -v openssl >/dev/null || { echo "❌ openssl introuvable" >&2; exit 1; }

read -rsp "Nouveau mot de passe Traefik ($USER_NAME) : " pass; echo
read -rsp "Confirmer : " confirm; echo
[[ -n "$pass" ]] || { echo "❌ Mot de passe vide" >&2; exit 1; }
[[ "$pass" == "$confirm" ]] || { echo "❌ Les mots de passe ne correspondent pas" >&2; exit 1; }

# printf plutôt qu'un argument : le mot de passe n'apparaît pas dans la liste des processus
hash=$(printf '%s' "$pass" | openssl passwd -apr1 -stdin)
line="traefik_auth: \"$USER_NAME:$hash\""

# Le hash apr1 ne contient que [./0-9A-Za-z$] : aucun caractère spécial pour sed avec « | »
if grep -q '^traefik_auth:' "$VAULT"; then
  sed -i "s|^traefik_auth:.*|$line|" "$VAULT"
else
  printf '%s\n' "$line" >> "$VAULT"
fi
echo "✅ traefik_auth mis à jour (déployer avec : make deploy TAGS=proxy)"
