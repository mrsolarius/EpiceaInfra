#!/bin/bash
# ========================================
# Lance une commande Ansible depuis la racine du dépôt (utilisé par le Makefile)
# ========================================
# Usage : bash scripts/ansible.sh ansible-playbook|ansible-vault|ansible-lint ...
# Ansible ne fonctionne pas sous Windows : depuis Git Bash, la commande est relancée dans WSL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    command -v wsl.exe >/dev/null || { echo "Ansible ne tourne pas sous Windows : installer WSL (wsl --install)" >&2; exit 1; }
    # MSYS_NO_PATHCONV : Git Bash ne doit pas réécrire les arguments en chemins Windows
    MSYS_NO_PATHCONV=1 exec wsl.exe --cd "$(cygpath -w "$ROOT")" -e bash scripts/ansible.sh "$@"
    ;;
esac

cd "$ROOT"
# Sur un dossier accessible à tous (WSL sur /mnt/c), Ansible ignore ansible.cfg s'il n'est pas désigné
export ANSIBLE_CONFIG="$ROOT/ansible.cfg"
export ANSIBLE_ROLES_PATH="$ROOT/ansible/roles"

# Mot de passe du vault (ansible/.vault_pass, non versionné), copié en 0600 hors du dépôt :
# sur /mnt/c le fichier paraît exécutable, et Ansible le lancerait comme un script au lieu de le lire
if [[ -f ansible/.vault_pass ]]; then
  pass=$(mktemp)
  trap 'rm -f "$pass"' EXIT
  cat ansible/.vault_pass > "$pass"
  chmod 600 "$pass"
  export ANSIBLE_VAULT_PASSWORD_FILE="$pass"
fi

if ! command -v "$1" >/dev/null; then
  case "$1" in
    ansible-lint) echo "ansible-lint introuvable : pipx install ansible-lint" >&2 ;;
    *) echo "$1 introuvable : installer Ansible (sudo bash scripts/bootstrap.sh)" >&2 ;;
  esac
  exit 1
fi
"$@"
