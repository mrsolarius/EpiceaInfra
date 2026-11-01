#!/bin/bash
# ========================================
# Domaines de la simulation dans le fichier hosts de Windows
# Usage : bash scripts/simulation/sim-hosts.sh   (ou make sim-host)
# ========================================
# Les domaines sont rendus par Ansible dans srv-main-sim (service_domains et amp_web_routes,
# avec les surcharges du groupe simulation) et pointés sur l'IP de srv-main de l'inventaire
# généré par setup-sim.sh. Le bloc est remplacé à chaque appel ; la fenêtre UAC est attendue.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/simulation/lib.sh

INVENTORY=ansible/inventory/simulation.yml
[[ -f "$INVENTORY" ]] || { echo "ERREUR : $INVENTORY absent, lancer d'abord make sim-up" >&2; exit 1; }

# Premier ansible_host de l'inventaire : srv-main
MAIN_IP=$(awk '/ansible_host:/ {print $2; exit}' "$INVENTORY")
[[ -n "$MAIN_IP" ]] || { echo "ERREUR : IP de srv-main introuvable dans $INVENTORY" >&2; exit 1; }

DOMAINS_CMD='cd /home/ubuntu/infra && ANSIBLE_CONFIG=/home/ubuntu/infra/ansible.cfg ansible srv-main -i ansible/inventory/simulation.yml -o -m debug -a "msg={{ (service_domains.values() | list + amp_web_routes | map(attribute=\"domain\") | list) | unique | join(\" \") }}"'
DOMAINS=$(mp exec "$MAIN" -- bash -c "echo $(printf '%s' "$DOMAINS_CMD" | base64 -w0) | base64 -d | bash" \
  | sed -n 's/.*"msg": "\([^"]*\)".*/\1/p')
[[ -n "$DOMAINS" ]] || { echo "ERREUR : aucun domaine renvoyé par Ansible" >&2; exit 1; }

# Fichiers dans le Temp Windows (et non le /tmp de Git Bash) : lus et écrits par le PowerShell élevé
WIN_TEMP=$(cygpath -u "$LOCALAPPDATA")/Temp
BLOCK_FILE="$WIN_TEMP/epicea-sim-hosts.txt"
LOG_FILE="$WIN_TEMP/epicea-sim-hosts.log"
HOSTS_FILE="${HOSTS_FILE:-$(cygpath -u "$SYSTEMROOT")/System32/drivers/etc/hosts}"  # surchargeable pour un test
rm -f "$LOG_FILE"
for d in $DOMAINS; do printf '%s %s\r\n' "$MAIN_IP" "$d"; done > "$BLOCK_FILE"
cat "$BLOCK_FILE"

# Arguments passés en base64 (-EncodedCommand) : pas de guillemets à faire traverser
# Git Bash, puis PowerShell, puis Start-Process. Chemins absolus (-a) : le PowerShell élevé
# démarre dans C:\Windows\System32, pas dans le projet.
PS_ARGS="& '$(cygpath -aw scripts/simulation/set-hosts.ps1)' -BlockFile '$(cygpath -aw "$BLOCK_FILE")' -LogFile '$(cygpath -aw "$LOG_FILE")' -HostsFile '$(cygpath -aw "$HOSTS_FILE")'"
PS_ENCODED=$(printf '%s' "$PS_ARGS" | iconv -t UTF-16LE | base64 -w0)
# SIM_HOST_NO_ELEVATION=1 : sans UAC, pour un test sur une copie (HOSTS_FILE=...)
VERB="-Verb RunAs"
[[ -z "${SIM_HOST_NO_ELEVATION:-}" ]] || VERB=""

echo ""
echo "Mise à jour du fichier hosts (accepter la demande d'élévation)..."
powershell.exe -NoProfile -Command "Start-Process powershell.exe $VERB -Wait -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -EncodedCommand $PS_ENCODED'" \
  || { echo "ERREUR : élévation refusée" >&2; exit 1; }

[[ -f "$LOG_FILE" ]] || { echo "ERREUR : le script élevé ne s'est pas exécuté" >&2; exit 1; }
RESULT=$(tr -d '\r\357\273\277' < "$LOG_FILE")
[[ "$RESULT" == OK* ]] || { echo "ERREUR : $RESULT" >&2; exit 1; }
echo "Fichier hosts à jour : $(wc -l < "$BLOCK_FILE") domaines -> $MAIN_IP"
