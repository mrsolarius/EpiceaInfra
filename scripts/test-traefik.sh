#!/bin/bash
set -euo pipefail

# ========================================
# Script de test Traefik
# ========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Tests Traefik - Epicea Infrastructure${NC}"
echo -e "${BLUE}========================================${NC}\n"

TRAEFIK_CONTAINER="traefik"
TESTS_PASSED=0
TESTS_FAILED=0

# Fonction de test
test_check() {
    local test_name="$1"
    local test_command="$2"

    echo -ne "${YELLOW}[TEST]${NC} $test_name ... "

    if eval "$test_command" &>/dev/null; then
        echo -e "${GREEN}✅ PASS${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}❌ FAIL${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
}

# ========================================
# Tests Docker
# ========================================
echo -e "${BLUE}## Tests Docker${NC}\n"

test_check "Container Traefik existe" \
    "docker ps -a | grep -q $TRAEFIK_CONTAINER"

test_check "Container Traefik est running" \
    "docker ps | grep -q $TRAEFIK_CONTAINER"

test_check "Health check container OK" \
    "docker inspect $TRAEFIK_CONTAINER | jq -r '.[0].State.Health.Status' | grep -q healthy"

test_check "Network traefik-proxy existe" \
    "docker network ls | grep -q traefik-proxy"

# ========================================
# Tests Ports
# ========================================
echo -e "\n${BLUE}## Tests Ports${NC}\n"

test_check "Port 80 (HTTP) ouvert" \
    "ss -tuln | grep -q ':80 '"

test_check "Port 443 (HTTPS) ouvert" \
    "ss -tuln | grep -q ':443 '"

test_check "Port 8080 (Dashboard) ouvert" \
    "ss -tuln | grep -q ':8080 '"

test_check "Port 8082 (Metrics) ouvert" \
    "ss -tuln | grep -q ':8082 '"

# ========================================
# Tests Endpoints HTTP
# ========================================
echo -e "\n${BLUE}## Tests Endpoints HTTP${NC}\n"

test_check "Endpoint /ping répond 200" \
    "curl -sf http://localhost/ping -o /dev/null"

test_check "Dashboard accessible (HTTP 200/401)" \
    "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080 | grep -E '200|401'"

test_check "Metrics Prometheus accessibles" \
    "curl -sf http://localhost:8082/metrics | grep -q 'traefik_'"

# ========================================
# Tests Configuration
# ========================================
echo -e "\n${BLUE}## Tests Configuration${NC}\n"

test_check "Fichier traefik.yml présent" \
    "docker exec $TRAEFIK_CONTAINER test -f /etc/traefik/traefik.yml"

test_check "Middlewares dynamiques présents" \
    "docker exec $TRAEFIK_CONTAINER test -f /etc/traefik/dynamic/middlewares.yml"

test_check "Configuration Traefik valide" \
    "docker exec $TRAEFIK_CONTAINER traefik version"

# ========================================
# Tests Logs
# ========================================
echo -e "\n${BLUE}## Tests Logs${NC}\n"

test_check "Pas d'erreurs critiques dans les logs" \
    "! docker logs $TRAEFIK_CONTAINER 2>&1 | grep -i 'level=error'"

test_check "Traefik a bien démarré" \
    "docker logs $TRAEFIK_CONTAINER 2>&1 | grep -q 'Configuration loaded'"

# ========================================
# Tests Sécurité
# ========================================
echo -e "\n${BLUE}## Tests Sécurité${NC}\n"

test_check "Dashboard protégé par auth" \
    "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080 | grep -q 401"

test_check "Socket Proxy est utilisé (pas de socket direct)" \
    "! docker inspect $TRAEFIK_CONTAINER | jq -r '.[0].HostConfig.Binds[]' | grep -q 'docker.sock'"

test_check "Socket Proxy est running" \
    "docker ps | grep -q docker-socket-proxy"

# ========================================
# Tests Let's Encrypt (si activé)
# ========================================
if docker exec $TRAEFIK_CONTAINER test -f /letsencrypt/acme.json 2>/dev/null; then
    echo -e "\n${BLUE}## Tests Let's Encrypt${NC}\n"

    test_check "Fichier acme.json existe" \
        "docker exec $TRAEFIK_CONTAINER test -f /letsencrypt/acme.json"

    test_check "Permissions acme.json correctes (600)" \
        "docker exec $TRAEFIK_CONTAINER stat -c '%a' /letsencrypt/acme.json | grep -q 600"
fi

# ========================================
# Résumé
# ========================================
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}  Résumé des tests${NC}"
echo -e "${BLUE}========================================${NC}\n"

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))

echo -e "Total tests    : ${BLUE}$TOTAL_TESTS${NC}"
echo -e "Tests réussis  : ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests échoués  : ${RED}$TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "\n${GREEN}✅ Tous les tests sont passés !${NC}\n"
    exit 0
else
    echo -e "\n${RED}❌ Certains tests ont échoué${NC}\n"
    echo -e "${YELLOW}Commandes de debug :${NC}"
    echo -e "  docker logs $TRAEFIK_CONTAINER"
    echo -e "  docker exec $TRAEFIK_CONTAINER cat /etc/traefik/traefik.yml"
    echo -e "  curl -v http://localhost/ping"
    echo ""
    exit 1
fi
