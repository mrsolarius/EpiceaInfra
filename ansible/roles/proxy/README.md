# 🔀 Rôle Ansible : proxy (Traefik)

## Description

Déploie et configure **Traefik v3** comme reverse proxy pour tous les services Epicea.

## Fonctionnalités

### ✅ Mode Test
- Certificats auto-signés (pas de Let's Encrypt)
- Domaines `.local` (ex: `traefik.epicea-test.local`)
- Log level DEBUG
- Dashboard accessible sans restrictions

### ✅ Mode Production
- Let's Encrypt automatique (HTTP ou DNS challenge)
- Domaines réels (ex: `traefik.votre-domaine.fr`)
- Renouvellement automatique certificats
- Rate limiting et sécurité renforcée
- Log level INFO

## Structure

```
proxy/
├── tasks/
│   └── main.yml                    # Tâches de déploiement
├── templates/
│   ├── traefik.yml.j2              # Configuration statique
│   ├── dynamic-middlewares.yml.j2  # Middlewares (auth, CORS, etc.)
│   └── env.j2                      # Variables d'environnement
├── handlers/
│   └── main.yml                    # Restart/reload handlers
├── defaults/
│   └── main.yml                    # Variables par défaut
├── vars/
│   └── main.yml                    # Variables du rôle
└── files/
    └── test-traefik.sh             # Script de test
```

## Variables

### Variables requises (group_vars)

```yaml
# Test
proxy_enable_letsencrypt: false
base_domain: "epicea-test.local"
service_domains:
  traefik: "traefik.epicea-test.local"

# Production
# proxy_enable_letsencrypt: true (déjà défini)
# base_domain: "votre-domaine.fr" (déjà défini)
traefik_acme_email: "admin@votre-domaine.fr"
```

### Variables optionnelles (defaults)

```yaml
traefik_dashboard_enabled: true
traefik_log_level: "INFO"
traefik_acme_staging: false
traefik_auth: "admin:$apr1$..."  # htpasswd hash
```

## Utilisation

### Déployer Traefik

```bash
# Test
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --tags proxy --limit test

# Production
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --tags proxy --limit production
```

### Tester la configuration

```bash
# Depuis le serveur
bash /opt/epicea/docker/traefik/test-traefik.sh

# Ou via Ansible
ansible test -m script -a "scripts/test-traefik.sh"
```

### Accéder au dashboard

**Test** :
```bash
# SSH tunnel depuis ton PC
ssh -L 8080:localhost:8080 ubuntu@<IP_VM_EPICEA>

# Navigateur
http://localhost:8080
# User: admin / Pass: admin
```

**Production** :
```
https://traefik.votre-domaine.fr
```

## Middlewares disponibles

Tous les services peuvent utiliser ces middlewares via labels Docker :

### `redirect-to-https`
Redirige HTTP → HTTPS
```yaml
- "traefik.http.routers.myapp-http.middlewares=redirect-to-https@file"
```

### `security-headers`
Headers de sécurité (HSTS, XSS, etc.)
```yaml
- "traefik.http.routers.myapp.middlewares=security-headers@file"
```

### `rate-limit`
Protection DDoS (100 req/min)
```yaml
- "traefik.http.routers.myapp.middlewares=rate-limit@file"
```

### `compression`
Compression gzip/brotli
```yaml
- "traefik.http.routers.myapp.middlewares=compression@file"
```

### `cors-headers`
CORS pour APIs
```yaml
- "traefik.http.routers.api.middlewares=cors-headers@file"
```

### `traefik-auth`
Authentification Basic Auth (dashboard)
```yaml
- "traefik.http.routers.admin.middlewares=traefik-auth@file"
```

## Labels Docker pour nouveaux services

Pour qu'un service soit exposé via Traefik, ajouter ces labels :

```yaml
services:
  mon-app:
    labels:
      - "traefik.enable=true"

      # HTTP router (redirect vers HTTPS)
      - "traefik.http.routers.monapp-http.entrypoints=web"
      - "traefik.http.routers.monapp-http.rule=Host(`monapp.${BASE_DOMAIN}`)"
      - "traefik.http.routers.monapp-http.middlewares=redirect-to-https@file"

      # HTTPS router
      - "traefik.http.routers.monapp.entrypoints=websecure"
      - "traefik.http.routers.monapp.rule=Host(`monapp.${BASE_DOMAIN}`)"
      - "traefik.http.routers.monapp.tls=${TRAEFIK_TLS_ENABLED}"
      - "traefik.http.routers.monapp.tls.certresolver=${TRAEFIK_CERT_RESOLVER}"
      - "traefik.http.routers.monapp.middlewares=security-headers@file,compression@file"

      # Service (si port != 80)
      - "traefik.http.services.monapp.loadbalancer.server.port=3000"

    networks:
      - traefik-proxy
```

## Monitoring

### Prometheus metrics

```bash
curl http://localhost:8082/metrics
```

Métriques disponibles :
- `traefik_entrypoint_requests_total`
- `traefik_router_requests_total`
- `traefik_service_requests_total`
- `traefik_entrypoint_request_duration_seconds`

### Logs

```bash
# Logs conteneur
docker logs traefik -f

# Logs fichiers
tail -f /opt/epicea/docker/traefik/logs/traefik.log
tail -f /opt/epicea/docker/traefik/logs/access.log
```

## Troubleshooting

### Dashboard inaccessible

```bash
# Vérifier que le port 8080 est ouvert
sudo ufw allow 8080/tcp

# Vérifier le container
docker ps | grep traefik
docker logs traefik
```

### Let's Encrypt échoue

```bash
# Vérifier config
docker exec traefik cat /etc/traefik/traefik.yml

# Mode staging pour tests
# Dans group_vars/production.yml :
traefik_acme_staging: true

# Supprimer acme.json et recommencer
rm /opt/epicea/docker/traefik/letsencrypt/acme.json
docker compose -f /opt/epicea/docker/traefik/docker-compose.yml restart
```

### Service non routé

```bash
# Vérifier les labels du service
docker inspect <container> | jq '.[0].Config.Labels'

# Vérifier que le service est dans le réseau traefik-proxy
docker network inspect traefik-proxy

# Voir les routers actifs
curl http://localhost:8080/api/http/routers | jq
```

## Handlers

### `restart traefik`
Redémarre complètement Traefik (changements config statique)

### `reload traefik config`
Recharge config dynamique sans redémarrage (changements middlewares)

## Dépendances

- Docker + Docker Compose
- Network `traefik-proxy` créé
- Port 80, 443, 8080, 8082 disponibles

## Tags Ansible

```bash
# Déployer seulement Traefik
ansible-playbook site.yml --tags proxy

# Skip Traefik
ansible-playbook site.yml --skip-tags proxy
```

## Références

- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Let's Encrypt](https://letsencrypt.org/)
- [Traefik + Docker](https://doc.traefik.io/traefik/providers/docker/)
