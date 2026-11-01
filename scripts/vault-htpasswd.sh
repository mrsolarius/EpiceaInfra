#!/bin/bash
# ========================================
# Écrit un mot de passe htpasswd dans le vault (make traefik-pass, make seedbox-pass)
# ========================================
# Usage : bash scripts/vault-htpasswd.sh <vault.yml en clair> <clé du vault> <tags à redéployer>
# Demande le mot de passe, le hache (htpasswd apr1) et écrit la clé dans le vault.
# Les clés sont lues par les middlewares basicAuth de Traefik (rôle proxy).
set -euo pipefail
[[ $# -eq 3 ]] || { echo "Usage : $0 <vault.yml> <clé du vault> <tags à redéployer>" >&2; exit 1; }
VAULT="$1"
KEY="$2"
TAGS="$3"
USER_NAME="admin"

command -v openssl >/dev/null || { echo "❌ openssl introuvable" >&2; exit 1; }

read -rsp "Nouveau mot de passe ($KEY, utilisateur $USER_NAME) : " pass; echo
read -rsp "Confirmer : " confirm; echo
[[ -n "$pass" ]] || { echo "❌ Mot de passe vide" >&2; exit 1; }
[[ "$pass" == "$confirm" ]] || { echo "❌ Les mots de passe ne correspondent pas" >&2; exit 1; }

# printf plutôt qu'un argument : le mot de passe n'apparaît pas dans la liste des processus
hash=$(printf '%s' "$pass" | openssl passwd -apr1 -stdin)
line="$KEY: \"$USER_NAME:$hash\""

# Le hash apr1 ne contient que [./0-9A-Za-z$] : aucun caractère spécial pour sed avec « | »
if grep -q "^$KEY:" "$VAULT"; then
  sed -i "s|^$KEY:.*|$line|" "$VAULT"
else
  printf '%s\n' "$line" >> "$VAULT"
fi
echo "✅ $KEY mis à jour (déployer avec : make deploy TAGS=$TAGS)"
