# 📚 Documentation Complète - EpiceaInfra

## 🌲 Vue d'ensemble

**EpiceaInfra** est une infrastructure self-hosted complète, automatisée par Ansible, permettant de déployer une stack de services personnels (photos, cloud, média, monitoring) sur un serveur bare-metal ou dans des VMs de test.

### Licence
GNU Affero General Public License v3 (AGPL-3.0)

---

## 📁 Architecture du Projet

```
EpiceaInfra/
├── .github/                    # CI/CD GitHub
│   ├── workflows/ci.yml        # Pipeline de validation Ansible
│   └── dependabot.yml          # Mise à jour automatique des dépendances
├── ansible/                    # Configuration Ansible
│   ├── ansible.cfg             # Configuration globale Ansible
│   ├── requirements.yml        # Collections Ansible requises
│   ├── group_vars/             # Variables par environnement
│   │   ├── production.yml      # Variables production
│   │   └── test.yml            # Variables environnement test
│   ├── inventory/hosts.yml     # Inventaire des hôtes
│   ├── playbooks/site.yml      # Playbook principal
│   ├── roles/                  # Rôles Ansible (voir détail ci-dessous)
│   └── secrets/vault.yml.example # Template des secrets
├── docker/                     # Configurations Docker Compose
│   ├── app/                    # Applications métier
│   │   ├── immich/             # Gestion photos
│   │   ├── jellyfin/           # Média streaming
│   │   └── nextcloud/          # Cloud personnel
│   ├── monitoring/             # Stack monitoring
│   ├── stateful/               # Services avec état
│   │   ├── postgres/           # Base de données
│   │   └── redis/              # Cache
│   └── traefik/                # Reverse proxy
├── scripts/                    # Scripts utilitaires
│   ├── bootstrap.sh            # Bootstrap initial
│   ├── test-traefik.sh         # Tests Traefik
│   └── multipass/              # Environnement de test local
├── docs/                       # Documentation (vide - ce fichier)
├── Makefile                    # Point d'entrée principal
└── Infra.md                    # Description infrastructure
```


---

## 🏗️ Architecture Technique

### Diagramme d'Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                        │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ :80/:443
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TRAEFIK v3.6.6                                       │
│              (Reverse Proxy + Let's Encrypt + Middlewares)                   │
│                                                                              │
│   ┌──────────────┬──────────────┬──────────────┬──────────────┐             │
│   │ HTTP (:80)   │ HTTPS (:443) │ API (:8080)  │ Metrics      │             │
│   │ → redirect   │ → services   │ → dashboard  │ → Prometheus │             │
│   └──────────────┴──────────────┴──────────────┴──────────────┘             │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ traefik-proxy network
        ┌────────────────────────┼────────────────────────┐
        ▼                        ▼                        ▼
┌───────────────┐       ┌───────────────┐       ┌───────────────┐
│    IMMICH     │       │   NEXTCLOUD   │       │   JELLYFIN    │
│  (Photos)     │       │   (Cloud)     │       │   (Média)     │
│  :2283        │       │   :80         │       │   :8096       │
└───────┬───────┘       └───────┬───────┘       └───────────────┘
        │                       │                       │
        └───────────────────────┼───────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
┌───────────────┐       ┌───────────────┐       ┌───────────────┐
│  POSTGRESQL   │       │    REDIS      │       │   NFS MOUNTS  │
│  (pgvecto.rs) │       │  (Cache)      │       │               │
│  :5432        │       │  :6379        │       │  /mnt/media   │
│               │       │               │       │  /mnt/photos  │
│ - Nextcloud   │       │ - Sessions    │       │  /mnt/cloud   │
│ - Immich      │       │ - Cache       │       │  /mnt/backups │
└───────────────┘       └───────────────┘       └───────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                         MONITORING STACK                                     │
│                                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │ PROMETHEUS   │  │ ALERTMANAGER │  │   GRAFANA    │  │    LOKI      │    │
│  │ :9090        │  │ :9093        │  │   :3000      │  │    :3100     │    │
│  └──────┬───────┘  └──────────────┘  └──────────────┘  └──────┬───────┘    │
│         │                                                      │            │
│  ┌──────┴───────┐  ┌──────────────┐  ┌──────────────┐  ┌──────┴───────┐    │
│  │   cADVISOR   │  │POSTGRES-EXP. │  │ REDIS-EXP.   │  │  PROMTAIL    │    │
│  │   :8080      │  │   :9187      │  │   :9121      │  │              │    │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```


---

### 🛡️ Sécurisation du Socket Docker

Pour éviter l'exposition directe de `/var/run/docker.sock` aux conteneurs exposés sur Internet (Traefik), un proxy de socket (`tecnativa/docker-socket-proxy`) est utilisé.

- **Traefik** : Communique avec le proxy via le réseau interne `docker-socket`. Le proxy est configuré pour n'autoriser que les accès nécessaires à l'auto-discovery (Containers, Services, Networks, etc.).
- **Monitoring (cAdvisor & Promtail)** : Utilisent également un proxy de socket filtré pour collecter les métriques et logs.
- **Isolation** : Le socket Unix n'est monté que dans les conteneurs proxies, qui ne sont pas exposés sur Internet.

---

## 🔧 Rôles Ansible

### 1. `common` - Configuration système de base

**Fichiers :**
- `tasks/main.yml` - Tâches principales
- `handlers/main.yml` - Handler reboot système

**Fonctionnalités :**

| Fonction | Description |
|----------|-------------|
| Mise à jour système | `apt upgrade dist` avec cache |
| Paquets de base | curl, wget, git, vim, htop, ncdu, tree, jq, unzip, ufw, fail2ban, nfs-common |
| Timezone | Configurable via `timezone` (défaut: Europe/Paris) |
| UFW Firewall | SSH (22), HTTP (80), HTTPS (443) autorisés ; PostgreSQL (5432) et Redis (6379) bloqués en externe |
| Fail2ban | Protection brute-force activée |
| DNS local | Entrées `/etc/hosts` pour domaines `.local` (test uniquement) |
| NVIDIA Drivers | Installation conditionnelle (production + GPU) |

**Variables :**
```yaml
timezone: "Europe/Paris"
fail2ban_enabled: true
enable_gpu: false  # true en production avec GPU
gpu_driver_version: "550"
```


---

### 2. `docker` - Installation Docker Engine

**Fichiers :**
- `tasks/main.yml` - Installation Docker
- `handlers/main.yml` - Restart Docker
- `defaults/main.yml` - Variables par défaut

**Fonctionnalités :**

| Fonction | Description |
|----------|-------------|
| Installation | Docker CE depuis repository officiel (dernière version) |
| Docker Compose | Plugin v2 intégré |
| Log rotation | json-file avec max-size/max-file configurables |
| NVIDIA Runtime | Configuration automatique si GPU activé |
| Réseau proxy | Création du réseau `traefik-proxy` |

**Variables par défaut :**
```yaml
docker_log_max_size: "50m"
docker_log_max_file: "5"
proxy_network_name: "traefik-proxy"
enable_gpu: false
docker_min_api_version: "1.44"  # Requis pour Traefik v3.3+
```


---

### 3. `storage` - Montages NFS

**Fichiers :**
- `tasks/main.yml` - Configuration NFS

**Fonctionnalités :**
- Création des points de montage
- Montage automatique des partages NFS
- Configuration des permissions post-montage
- Vérification des montages

**Variables (exemple test) :**
```yaml
nfs_server: "172.17.41.245"
nfs_mounts:
  - src: "{{ nfs_server }}:/exports/media"
    path: "/mnt/media"
    opts: "rw,hard,intr,nfsvers=4"
  - src: "{{ nfs_server }}:/exports/photos"
    path: "/mnt/photos"
    opts: "rw,hard,intr,nfsvers=4"
  - src: "{{ nfs_server }}:/exports/cloud"
    path: "/mnt/cloud"
    opts: "rw,hard,intr,nfsvers=4"
    owner: "33"  # www-data
    group: "33"
```


---

### 4. `proxy` - Traefik v3 Reverse Proxy

**Fichiers :**
- `tasks/main.yml` - Déploiement Traefik
- `handlers/main.yml` - Restart/reload Traefik
- `defaults/main.yml` - Variables par défaut
- `vars/main.yml` - Variables du rôle
- `templates/traefik.yml.j2` - Configuration statique
- `templates/dynamic-middlewares.yml.j2` - Middlewares
- `templates/env.j2` - Variables d'environnement
- `files/test-traefik.sh` - Script de test

**Fonctionnalités :**

| Fonctionnalité | Test | Production |
|----------------|------|------------|
| Certificats | Auto-signés | Let's Encrypt (HTTP ou DNS challenge) |
| Dashboard | Accessible sans auth sur :8080 | Protégé par auth + middleware |
| Log level | DEBUG | INFO |
| HTTPS redirect | Configurable | Forcé |
| Métriques Prometheus | Activées | Activées |

**Middlewares disponibles :**
```yaml
traefik_middlewares:
  - redirect-to-https      # Redirection HTTP → HTTPS
  - security-headers       # Headers de sécurité (HSTS, XSS, etc.)
  - rate-limit             # Limitation 100 req/min, burst 50
  - compression            # Gzip compression
  - cors-headers           # CORS headers
  - traefik-auth           # Basic auth dashboard
```


**Ports exposés :**
```yaml
traefik_ports:
  http: 80
  https: 443
  dashboard: 8080
  metrics: 8082
```


**Variables par défaut :**
```yaml
traefik_image_version: "v3.0"
traefik_dashboard_enabled: true
traefik_log_level: "INFO"
traefik_acme_email: "admin@{{ base_domain }}"
traefik_auth: "admin:$apr1$..."  # htpasswd hash
traefik_network_name: "traefik-proxy"
```


---

### 5. `database` - PostgreSQL + Redis

**Fichiers :**
- `tasks/main.yml` - Déploiement des BDD
- `templates/init.sql.j2` - Script d'initialisation PostgreSQL
- `templates/postgres.env.j2` - Variables PostgreSQL
- `templates/redis.env.j2` - Variables Redis

**PostgreSQL :**

| Caractéristique | Valeur |
|-----------------|--------|
| Image | `tensorchord/pgvecto-rs:pg16-v0.4.0` |
| Extensions | pg_stat_statements, cube, earthdistance, vectors (pgvector) |
| Port | 5432 (localhost uniquement) |
| Bases créées | nextcloud, immich |
| Monitoring | track_io_timing, track_activities, log_autovacuum |

**Redis :**

| Caractéristique | Valeur |
|-----------------|--------|
| Image | `redis:8-alpine` |
| Port | 6379 (localhost uniquement) |
| Persistence | RDB + AOF |
| Config | slowlog, latency-monitor, maxmemory-policy allkeys-lru |

**Script init.sql :**
```sql
-- Création utilisateurs et bases
CREATE USER nextcloud WITH PASSWORD '...';
CREATE DATABASE nextcloud OWNER nextcloud;

CREATE USER immich WITH PASSWORD '...';
CREATE DATABASE immich OWNER immich;

-- Extensions Immich
\c immich
ALTER SCHEMA public OWNER TO immich;
```


---

### 6. `monitoring` - Stack Prometheus + Grafana + Loki

**Fichiers :**
- `tasks/main.yml` - Déploiement monitoring
- `handlers/main.yml` - Restart monitoring
- `templates/*.j2` - Configurations
- `files/*.json` - Dashboards Grafana
- `files/*-alerts.yml` - Règles d'alerting

**Composants déployés :**

| Service | Image | Port | Rôle |
|---------|-------|------|------|
| Prometheus | `prom/prometheus:v3.9.1` | 9090 | Métriques |
| Alertmanager | `prom/alertmanager:v0.26.0` | 9093 | Alertes |
| Grafana | `grafana/grafana:12.3.1` | 3000 | Visualisation |
| Loki | `grafana/loki:3.3.2` | 3100 | Logs |
| Promtail | `grafana/promtail:3.3.2` | - | Collecte logs |
| cAdvisor | `gcr.io/cadvisor/cadvisor:v0.55.1` | 8080 | Métriques Docker |
| postgres-exporter | `prometheuscommunity/postgres-exporter:v0.15.0` | 9187 | Métriques PostgreSQL |
| redis-exporter | `oliver006/redis_exporter:v1.55.0` | 9121 | Métriques Redis |

**Dashboards Grafana pré-configurés :**
1. **Traefik Dashboard** - Monitoring reverse proxy
2. **Docker Dashboard** - Containers (CPU, RAM, réseau)
3. **PostgreSQL Performance** - Queries, locks, cache, I/O, pgvector
4. **Redis Performance** - Cache hit rate, mémoire, latence

## 📊 Règles d'Alerting Complètes

### PostgreSQL (14 règles)

| Alerte | Sévérité | Expression | Durée | Description |
|--------|----------|------------|-------|-------------|
| **PostgreSQLDown** | 🔴 critical | `pg_up == 0` | 1m | Instance PostgreSQL indisponible depuis plus d'une minute |
| **PostgreSQLTooManyConnections** | 🟡 warning | Connexions > 80% max | 5m | Utilisation excessive des connexions disponibles |
| **PostgreSQLLowCacheHitRatio** | 🟡 warning | Cache hit < 90% | 10m | Taux de cache insuffisant - envisager augmenter `shared_buffers` |
| **PostgreSQLDeadlocks** | 🟡 warning | `rate(deadlocks) > 0` | 5m | Deadlocks détectés dans la base de données |
| **PostgreSQLLongRunningTransactions** | 🟡 warning | Transaction > 1800s | 5m | Transaction en cours depuis plus de 30 minutes |
| **PostgreSQLIdleInTransaction** | 🟡 warning | Sessions idle > 5 | 10m | Plus de 5 sessions inactives en transaction |
| **PostgreSQLHighIOWait** | 🟡 warning | I/O wait > 1000ms | 10m | Temps d'attente E/S élevé - vérifier performance disque |
| **PostgreSQLExcessiveTempFiles** | 🟡 warning | Temp files > 100MB/s | 10m | Écriture excessive dans fichiers temporaires - optimiser `work_mem` |
| **PostgreSQLTableBloat** | 🟡 warning | Dead tuples > 20% | 1h | Table gonflée avec trop de tuples morts - lancer VACUUM |
| **PostgreSQLReplicationLag** | 🟡 warning | Lag > 30s | 5m | Retard de réplication détecté |
| **PostgreSQLVectorTableSeqScans** | 🔵 info | Seq scans > Index scans | 15m | Tables vectorielles avec trop de scans séquentiels - créer index HNSW/IVFFlat |
| **PostgreSQLVectorIndexUnused** | 🔵 info | Index > 10MB, scans < 10 | 1h | Grand index vectoriel inutilisé |
| **PostgreSQLHighLockWaitCount** | 🟡 warning | Locks waiting > 10 | 5m | Nombre élevé de verrous en attente |

---

### Redis (17 règles)

| Alerte | Sévérité | Expression | Durée | Description |
|--------|----------|------------|-------|-------------|
| **RedisDown** | 🔴 critical | `redis_up == 0` | 1m | Instance Redis indisponible depuis plus d'une minute |
| **RedisLowCacheHitRate** | 🟡 warning | Hit rate < 80% | 10m | Taux de cache insuffisant - vérifier patterns d'utilisation |
| **RedisHighMemoryUsage** | 🟡 warning | Mémoire > 90% max | 5m | Mémoire presque pleine - risque d'éviction de clés |
| **RedisHighMemoryFragmentation** | 🟡 warning | Fragmentation > 2 | 10m | Fragmentation mémoire élevée - envisager restart ou défragmentation |
| **RedisLowMemoryFragmentation** | 🔵 info | Fragmentation < 0.7 | 10m | Fragmentation faible - possible swap sur disque |
| **RedisKeysEvicted** | 🟡 warning | Éviction > 100/s | 5m | Clés évincées - augmenter `maxmemory` ou revoir TTL |
| **RedisTooManyConnectedClients** | 🟡 warning | Clients > 100 | 5m | Trop de clients connectés - vérifier fuites de connexion |
| **RedisBlockedClients** | 🟡 warning | Bloqués > 5 | 5m | Clients bloqués sur opérations lentes |
| **RedisRejectedConnections** | 🟡 warning | Rejets > 0/s | 5m | Connexions refusées - augmenter `maxclients` |
| **RedisSlowCommands** | 🔵 info | Slowlog > 10 | 5m | Commandes lentes détectées - optimiser opérations |
| **RedisRDBSaveFailure** | 🟡 warning | Dernière sauvegarde > 1h + changements | 10m | Sauvegarde RDB en retard avec données non sauvegardées |
| **RedisAOFRewriteTooLong** | 🟡 warning | Réécriture AOF en cours | 30m | Réécriture AOF prend trop de temps |
| **RedisHighCommandLatency** | 🟡 warning | Latence > 10ms | 10m | Latence moyenne des commandes trop élevée |
| **RedisHighCPUUsage** | 🟡 warning | CPU > 80% | 10m | Utilisation CPU excessive - enquêter opérations coûteuses |
| **RedisNoKeys** | 🔵 info | Total clés = 0 | 10m | Aucune clé dans Redis - normal ou problème |
| **RedisMasterLinkDown** | 🔴 critical | Master link down | 2m | Réplica a perdu connexion au maître |
| **RedisHighNetworkTraffic** | 🔵 info | Trafic > 100MB/s | 10m | Trafic réseau élevé - surveiller goulots d'étranglement |

---

### Récapitulatif par Sévérité

| Sévérité | PostgreSQL | Redis | Total |
|----------|------------|-------|-------|
| 🔴 **Critical** | 1 | 2 | **3** |
| 🟡 **Warning** | 10 | 12 | **22** |
| 🔵 **Info** | 2 | 3 | **5** |
| **Total** | **13** | **17** | **30** |

---

### Format des Notifications Discord

Les alertes sont envoyées sur Discord avec ce format :

```
🚨 CRITIQUE : PostgreSQLDown          (si firing + critical)
⚠️ WARNING : RedisHighMemoryUsage     (si firing + warning)
✅ RÉTABLI : PostgreSQLDown           (si resolved)

### État du Système
> 📝 **Statut :** `FIRING`
> ⚙️ **Service :** `postgresql`
> ⚡ **Sévérité :** `CRITICAL`

**Informations**
• **Résumé :** _Instance PostgreSQL indisponible 🔴_
• **Description :** L'instance PostgreSQL postgres:5432 est indisponible depuis plus d'une minute.
• **Instance :** `postgres:5432`

---
*Envoyé avec* ❤️ *par Owl Alert* 🦉
```


---

### Configuration Alertmanager

```yaml
# Groupement des alertes
route:
  group_by: ['alertname', 'service', 'severity']
  group_wait: 10s        # Attente avant premier envoi
  group_interval: 1m     # Intervalle entre groupes
  repeat_interval: 12h   # Ré-notification si non résolu
  receiver: 'discord-notifications'
```


**Notifications Alertmanager :**
- Canal : Discord (webhook configurable)
- Format : Messages enrichis avec émojis et contexte
- Groupement : Par alertname, service, severity

---

### 7. `immich` - Gestion de Photos

**Fichiers :**
- `tasks/main.yml` - Déploiement Immich
- `templates/.env.j2` - Variables d'environnement

**Composants :**

| Service | Image | Description |
|---------|-------|-------------|
| immich-server | `ghcr.io/immich-app/immich-server:v2.4.1` | API + Web |
| immich-machine-learning | `ghcr.io/immich-app/immich-machine-learning:v1.130.2` | ML/IA |
| immich-postgres | `ghcr.io/immich-app/postgres:16-vectorchord0.3.0-pgvectors0.3.0` | BDD dédiée avec VectorChord |

**Volumes :**
- `/mnt/photos` → `/usr/src/app/upload` (photos)
- `${DATA_PATH}/immich/model-cache` → `/cache` (modèles ML)
- `${DATA_PATH}/immich/postgres` → données PostgreSQL

**Labels Traefik :**
- Routes HTTP/HTTPS sur `photos.${base_domain}`
- Port interne : 2283

---

### 8. `jellyfin` - Streaming Média

**Fichiers :**
- `tasks/main.yml` - Déploiement Jellyfin
- `templates/.env.j2` - Variables d'environnement

**Configuration :**

| Paramètre | Valeur |
|-----------|--------|
| Image | `jellyfin/jellyfin:10.11.6` |
| Port web | 8096 |
| Port discovery | 7359/udp |
| Stockage config | `${DATA_PATH}/jellyfin/config` |
| Stockage cache | `${DATA_PATH}/jellyfin/cache` |
| Médias | `/mnt/media` (read-only) |

---

### 9. `nextcloud` - Cloud Personnel

**Fichiers :**
- `tasks/main.yml` - Déploiement Nextcloud
- `templates/.env.j2` - Variables d'environnement

**Configuration :**

| Paramètre | Valeur |
|-----------|--------|
| Image | `nextcloud:32.0.5` |
| Port | 80 (interne) |
| Stockage app | `${DATA_PATH}/nextcloud` |
| Stockage data | `/mnt/cloud` |
| BDD | PostgreSQL mutualisé |
| Cache | Redis mutualisé |

**Middlewares Traefik spécifiques :**
- Redirect CalDAV/CardDAV vers `/remote.php/dav/`

---

## 🔐 Gestion des Secrets

### Fichier `vault.yml`

Le fichier `ansible/secrets/vault.yml` contient tous les secrets sensibles. En production, il **DOIT** être chiffré avec Ansible Vault.

**Structure des secrets :**

```yaml
# Traefik
traefik_auth: "admin:$apr1$..."  # htpasswd -nb admin password
traefik_acme_email: "admin@domain.fr"

# PostgreSQL
postgres_root_password: "..."
postgres_databases:
  nextcloud:
    user: "nextcloud"
    password: "..."
  immich:
    user: "immich"
    password: "..."
  grafana:
    user: "grafana"
    password: "..."

# Redis
redis_password: "..."

# Nextcloud
nextcloud_admin_user: "admin"
nextcloud_admin_password: "..."

# Grafana
grafana_admin_user: "admin"
grafana_admin_password: "..."
grafana_secret_key: "..."

# Notifications
discord_webhook_url: "https://discord.com/api/webhooks/..."

# Backup
backup_encryption_password: "..."
```


**Commandes utiles :**
```shell script
# Créer et chiffrer le vault
ansible-vault encrypt ansible/secrets/vault.yml

# Éditer le vault
ansible-vault edit ansible/secrets/vault.yml

# Déployer avec vault
ansible-playbook --ask-vault-pass playbooks/site.yml
```


---

## 🌍 Environnements

### Test (Multipass)

| Variable | Valeur |
|----------|--------|
| `deploy_environment` | `test` |
| `enable_gpu` | `false` |
| `enable_letsencrypt` | `false` |
| `base_domain` | `epicea-test.local` |
| `nfs_server` | IP de la VM storage-test |
| `prometheus_retention` | `15d` |
| `traefik_log_level` | `DEBUG` |

**VMs Multipass :**
1. **storage-test** : 2 CPU, 4GB RAM, 20GB - Serveur NFS
2. **epicea-test** : 4 CPU, 8GB RAM, 100GB - Serveur applicatif

### Production

| Variable | Valeur |
|----------|--------|
| `deploy_environment` | `production` |
| `enable_gpu` | `true` |
| `enable_letsencrypt` | `true` |
| `enable_zfs_snapshots` | `true` |
| `base_domain` | `louisvolat.fr` |
| `prometheus_retention` | `90d` |
| `traefik_log_level` | `INFO` |

**Services activés :**
- shared-services (PostgreSQL + Redis)
- traefik
- immich
- jellyfin
- nextcloud
- monitoring
- games (AMP)

---

## 🐳 Images Docker

### Versions (Production)

| Service | Image | Version | Limite CPU | Limite RAM |
|---------|-------|---------|------------|------------|
| Traefik | `traefik` | v3.6.6 | 0.5 | 512M |
| PostgreSQL | `tensorchord/pgvecto-rs` | pg16-v0.4.0 | 1.0 | 2G |
| Redis | `redis` | 8-alpine | 0.5 | 512M |
| Prometheus | `prom/prometheus` | v3.9.1 | 1.0 | 2G |
| Alertmanager | `prom/alertmanager` | v0.26.0 | 0.2 | 256M |
| Grafana | `grafana/grafana` | 12.3.1 | 0.5 | 1G |
| Loki | `grafana/loki` | 3.3.2 | 0.5 | 1G |
| Promtail | `grafana/promtail` | 3.3.2 | 0.2 | 512M |
| cAdvisor | `gcr.io/cadvisor/cadvisor` | v0.55.1 | 0.2 | 512M |
| postgres-exporter | `prometheuscommunity/postgres-exporter` | v0.15.0 | 0.1 | 256M |
| redis-exporter | `oliver006/redis_exporter` | v1.55.0 | 0.1 | 128M |
| Immich Server | `ghcr.io/immich-app/immich-server` | v2.4.1-ig441 | 1.0 | 2G |
| Immich ML | `ghcr.io/immich-app/immich-machine-learning` | v1.130.2 | 2.0 | 4G |
| Immich PostgreSQL | `ghcr.io/immich-app/postgres` | 14-vectorchord0.4.3-pgvectors0.2.0 | 0.5 | 1G |
| Jellyfin | `jellyfin/jellyfin` | 10.11.6 | 2.0 | 4G |
| Nextcloud | `nextcloud` | 32.0.5 | 1.0 | 1G |
| Socket Proxy | `docker-socket-proxy` | - | 0.1 | 64M |

---

## 🚀 Commandes Make

```shell script
# === AIDE ===
make help

# === TESTS MULTIPASS ===
make multipass-setup     # Créer les VMs de test
make multipass-destroy   # Détruire les VMs
make test-init           # Initialiser secrets test (copie vault.yml.example)
make test-deploy         # Déployer sur VM test
make test-status         # Afficher status des containers
make test-logs           # Suivre les logs

# === PRODUCTION ===
make init                # Initialiser + chiffrer vault.yml
make secrets             # Éditer le vault chiffré
make deploy              # Déployer en production (demande vault password)
make status              # Status des services
make validate            # Valider syntaxe Ansible

# === MAINTENANCE ===
make clean               # Purger Docker (containers, images, volumes)
```


---

## 📊 Monitoring & Alerting

### Scrape Prometheus

| Job | Target | Interval | Métriques |
|-----|--------|----------|-----------|
| prometheus | localhost:9090 | 15s | Self-monitoring |
| traefik | traefik:8080 | 15s | Requêtes, latence, status |
| cadvisor | cadvisor:8080 | 15s | CPU, RAM, réseau, I/O containers |
| postgres | postgres-exporter:9187 | 30s | Connexions, queries, cache, locks |
| redis | redis-exporter:9121 | 15s | Hit rate, mémoire, commandes |

### Flux d'alerting

```
Prometheus → Alertmanager → Discord Webhook
     │
     └── Règles d'alerting (postgres-alerts.yml, redis-alerts.yml)
```


---

## 🔒 Sécurité

### Firewall (UFW)

| Port | Protocole | Action | Description |
|------|-----------|--------|-------------|
| 22 | TCP | ALLOW | SSH |
| 80 | TCP | ALLOW | HTTP |
| 443 | TCP | ALLOW | HTTPS |
| 5432 | TCP | DENY | PostgreSQL (accès interne uniquement) |
| 6379 | TCP | DENY | Redis (accès interne uniquement) |
| 8080 | TCP | ALLOW (prod) | Traefik dashboard |
| 9090 | TCP | ALLOW (prod) | Prometheus (interne) |

### Fail2ban

- Protection SSH activée par défaut
- Bantime : 1h (production)
- Max retry : 5 tentatives

### Traefik Middlewares de sécurité

```yaml
security-headers:
  frameDeny: true
  browserXssFilter: true
  contentTypeNosniff: true
  forceSTSHeader: true
  stsIncludeSubdomains: true
  stsPreload: true
  stsSeconds: 31536000

rate-limit:
  average: 100
  burst: 50
  period: 1m
```


---

## 🔄 CI/CD

### GitHub Actions (`.github/workflows/ci.yml`)

**Triggers :**
- Push sur `main`
- Pull requests vers `main`

**Jobs :**
```yaml
validate:
  - Checkout
  - Setup Python 3.11
  - Install Ansible + ansible-lint
  - Syntax check playbooks
```


### Dependabot

Mise à jour automatique hebdomadaire pour :
- GitHub Actions
- Docker Compose (traefik, monitoring, postgres, redis, immich, nextcloud)

---

## 📋 Checklist de Déploiement

### Prérequis

- [ ] Ubuntu 22.04+ sur le serveur cible
- [ ] Accès SSH avec privilèges sudo
- [ ] NAS NFS configuré et accessible
- [ ] DNS configuré (production) ou `/etc/hosts` (test)

### Étapes

1. **Cloner le projet**
```shell script
git clone https://github.com/user/EpiceaInfra.git
   cd EpiceaInfra
```


2. **Configurer les secrets**
```shell script
# Test
   make test-init
   vi ansible/secrets/vault.yml  # Modifier les mots de passe
   
   # Production
   make init
   make secrets  # Éditer le vault chiffré
```


3. **Adapter les variables d'environnement**
    - `ansible/group_vars/production.yml` : domaines, IPs NFS, etc.
    - `ansible/inventory/hosts.yml` : IP du serveur production

4. **Déployer**
```shell script
# Test
   make multipass-setup
   make test-deploy
   
   # Production
   make deploy
```


5. **Vérifier**
```shell script
make status
   # Accéder aux URLs des services
```


---

## 🆘 Dépannage

### Logs

```shell script
# Tous les containers
docker ps -a
docker logs <container_name>

# Logs Traefik
docker logs traefik -f --tail=100

# Logs Ansible (verbose)
ansible-playbook -vvv playbooks/site.yml
```


### Problèmes courants

| Problème | Cause probable | Solution |
|----------|----------------|----------|
| Traefik ne démarre pas | Port 80/443 déjà utilisé | `sudo lsof -i :80` |
| PostgreSQL erreur permissions | UID/GID incorrect | Vérifier `owner: 1000` |
| NFS timeout | IP incorrecte | Vérifier `nfs_server` |
| Grafana 502 | Datasource down | Vérifier Prometheus |
| Let's Encrypt échec | DNS non propagé | Attendre propagation DNS |

### Tests Traefik

```shell script
bash scripts/test-traefik.sh
```


---

## 📚 Ressources

- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Ansible Documentation](https://docs.ansible.com/)
- [Immich Documentation](https://immich.app/docs/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)

---

*Documentation générée le 2026-01-23 pour EpiceaInfra*