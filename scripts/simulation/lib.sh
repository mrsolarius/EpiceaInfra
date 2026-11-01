#!/bin/bash
# ========================================
# Fonctions communes aux scripts de test de la simulation
# ========================================
export MSYS_NO_PATHCONV=1

MAIN=srv-main-sim
BACKUP=srv-backup-sim
PASS=0
FAIL=0
FAILED=()

# multipass avec délai : sous Windows (terminal Git Bash), un appel peut rester bloqué sans
# rien afficher. L'entrée standard est fermée (cause du blocage observé sur multipass exec),
# et au-delà de MP_TIMEOUT secondes (120 par défaut) l'appel est arrêté avec une erreur.
# Ex. : MP_TIMEOUT=900 mp launch ...
mp() {
  local limit="${MP_TIMEOUT:-120}" rc=0
  timeout "$limit" multipass "$@" </dev/null || rc=$?
  if [[ $rc -eq 124 ]]; then
    echo "ERREUR : « multipass $1 $2 » sans réponse après $limit s, arrêté." >&2
    echo "         Relancer la commande (les scripts sont reprenables) ; si ça se répète : multipass restart $2" >&2
  fi
  return $rc
}

# Commande transmise en base64 : sous Windows, multipass exec abîme les guillemets imbriqués
# TS (horodatage du test en cours) est transmis à la VM pour nommer les snapshots de test
on() { local vm=$1; shift; MP_TIMEOUT="${MP_TIMEOUT:-1200}" mp exec "$vm" -- bash -c "echo $(printf 'TS=%s; %s' "${TS:-}" "$*" | base64 -w0) | base64 -d | sudo bash"; }

check() {
  local desc=$1 vm=$2 cmd=$3 out
  if out=$(on "$vm" "$cmd" 2>&1); then
    PASS=$((PASS + 1)); printf '  \e[32mOK\e[0m   %s\n' "$desc"
  else
    FAIL=$((FAIL + 1)); FAILED+=("$desc"); printf '  \e[31mKO\e[0m   %s\n' "$desc"
    printf '%s\n' "$out" | tail -5 | sed 's/^/         /'
  fi
}

# Étape d'une procédure (pas un test) : affichée, et arrêt du script si elle échoue
step() {
  local desc=$1 vm=$2 cmd=$3 out
  printf '  ...  %s\n' "$desc"
  if ! out=$(on "$vm" "$cmd" 2>&1); then
    printf '  \e[31mÉCHEC\e[0m %s\n' "$desc"
    printf '%s\n' "$out" | tail -8 | sed 's/^/         /'
    summary
    exit 1
  fi
}

# Requête PromQL depuis le conteneur Prometheus, renvoie le nombre de séries
PROMQL='q() { docker exec prometheus wget -qO- "http://localhost:9090/api/v1/query?query=$(jq -rn --arg q "$1" "\$q|@uri")" | jq ".data.result | length"; }'

summary() {
  echo ""
  echo "=== Résultat : $PASS OK, $FAIL KO ==="
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  [[ $FAIL -eq 0 ]]
}
