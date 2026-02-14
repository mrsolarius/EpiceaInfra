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
│   ├── roles/                  # Rôles Ansible
│   │   ├── apps/               # Rôles applicatifs
│   │   │   ├── immich/
│   │   │   ├── jellyfin/
│   │   │   ├── litopia/
│   │   │   └── nextcloud/
│   │   ├── common/             # Base system
│   │   ├── docker/             # Docker engine
│   │   ├── monitoring/         # Stack monitoring
│   │   ├── proxy/              # Traefik
│   │   ├── redis/              # Cache Redis
│   │   └── storage/            # Montages NFS
│   └── secrets/vault.yml.example # Template des secrets
├── scripts/                    # Scripts utilitaires
│   ├── bootstrap.sh            # Bootstrap initial
│   ├── test-traefik.sh         # Tests Traefik
│   └── multipass/              # Environnement de test local
│       ├── setup-vms.sh        # Création des VMs
│       ├── destroy-vms.sh      # Destruction des VMs
│       ├── init-epicea-vm.sh   # Init VM applicative
│       └── init-storage-vm.sh  # Init VM stockage
├── .gitignore                  # Fichiers ignorés par Git
├── LICENSE                     # Licence AGPL-3.0
├── Makefile                    # Point d'entrée principal
└── README.md                   # Présentation du projet

```


---

## 🏗️ Architecture Technique

### Diagramme d'Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                       │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ :80/:443
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TRAEFIK v3.6.6                                      │
│              (Reverse Proxy + Let's Encrypt + Middlewares)                  │
│                                                                             │
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
│  (Dédié/App)  │       │  (Mutualisé)  │       │               │
│  :5432        │       │  :6379        │       │  /mnt/media   │
│               │       │               │       │  /mnt/photos  │
│ - Nextcloud   │       │ - Sessions    │       │  /mnt/cloud   │
│ - Immich      │       │ - Cache       │       │  /mnt/backups │
└───────────────┘       └───────────────┘       └───────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                         MONITORING STACK                                    │
│                                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │ PROMETHEUS   │  │ ALERTMANAGER │  │   GRAFANA    │  │    LOKI      │     │
│  │ :9090        │  │ :9093        │  │   :3000      │  │    :3100     │     │
│  └──────┬───────┘  └──────────────┘  └──────────────┘  └──────┬───────┘     │
│         │                                                     │             │
│  ┌──────┴───────┐  ┌──────────────┐  ┌──────────────┐  ┌──────┴───────┐     │
│  │   cADVISOR   │  │POSTGRES-EXP. │  │ REDIS-EXP.   │  │  PROMTAIL    │     │
│  │   :8080      │  │   :9187      │  │   :9121      │  │              │     │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘     │
└─────────────────────────────────────────────────────────────────────────────┘
```


---

### 📂 Organisation du Stockage

L'infrastructure utilise une distinction claire entre les types de stockage physique pour optimiser les performances et la durabilité.

#### 1. Racines Physiques (Hôte)

| Variable | Chemin par défaut | Usage |
|----------|-------------------|-------|
| `drive_nvme_path` | `/opt/epicea` | OS, Fichiers de configuration, Logs, Monitoring (Vitesse) |
| `drive_ssd_path` | `/mnt/ssd_tank` | Bases de données PostgreSQL, Redis (IOPS, Endurance) |
| `drive_nfs_root` | `/mnt/nas` | Stockage de masse (Photos, Vidéos, Données Cloud) |

#### 2. Chemins Logiques (Objets Ansible)

Les chemins sont centralisés dans l'objet `storage` dans `group_vars/common.yml` :

```yaml
storage:
  configs: "{{ drive_nvme_path }}/config"
  monitoring: "{{ drive_nvme_path }}/monitoring"
  databases:
    immich: "{{ drive_ssd_path }}/immich-db"
    nextcloud: "{{ drive_ssd_path }}/nextcloud-db"
    redis: "{{ drive_ssd_path }}/redis"
    litopia: "{{ drive_ssd_path }}/litopia-db"
  media:
    immich_photos: "{{ drive_nfs_root }}/photos/immich"
    nextcloud_data: "{{ drive_nfs_root }}/cloud/data"
    jellyfin_movies: "{{ drive_nfs_root }}/media/movies"
```

### 👤 Gestion des Permissions

Tous les services sont standardisés sur un utilisateur système unique (PUID/PGID) pour éviter les problèmes de droits sur les volumes partagés.

- **Utilisateur global** : `1000:1000` (défini par `common_system_user` et `common_system_group`).
- **Standardisation** : Les variables `PUID` et `PGID` sont injectées dans les fichiers `.env` et utilisées par les conteneurs.
- **Provisioning** : Ansible gère les `chown` lors de la création des répertoires sur l'hôte.

---

### 🛡️ Sécurisation du Socket Docker

Pour éviter l'exposition directe de `/var/run/docker.sock` aux conteneurs exposés sur Internet (Traefik), un proxy de socket (`tecnativa/docker-socket-proxy`) est utilisé.

- **Traefik** : Communique avec le proxy via le réseau interne `docker-socket`. Le proxy est configuré pour n'autoriser que les accès nécessaires à l'auto-discovery (Containers, Services, Networks, etc.).
- **Monitoring** : Chaque application inclut ses propres exportateurs de métriques (ex: `postgres-exporter`) en tant que sidecar, connectés à la fois au réseau interne de l'application et au réseau global `monitoring`.
- **Isolation** : Les bases de données ne sont jamais exposées sur le réseau `proxy`. Seuls les services "Front" y ont accès. Le socket Unix n'est monté que dans les conteneurs proxies, qui ne sont pas exposés sur Internet.

---

## 🔧 Rôles Ansible

### 1. `common` - Configuration système de base

**Fichiers :**
- `tasks/main.yml` - Tâches principales
- `handlers/main.yml` - Handler reboot système
- `requirements.yml` - Collections Ansible requises

**Fonctionnalités :**

| Fonction | Description |
|----------|-------------|
| Mise à jour système | `apt upgrade dist` avec cache |
| Paquets de base | curl, wget, git, vim, htop, ncdu, tree, jq, unzip, ca-certificates, gnupg, lsb-release, ufw, fail2ban, nfs-common, prometheus-node-exporter, smartmontools |
| Timezone | Configurable via `timezone` (défaut: Europe/Paris) |
| Node Exporter | Activé et exposé sur le port 9100 (accès LAN uniquement) |
| UFW Firewall | SSH (22), HTTP (80), HTTPS (443) autorisés ; PostgreSQL (5432), Redis (6379) et Node Exporter (9100) bloqués en externe |
| Fail2ban | Protection brute-force activée |
| DNS local | Entrées `/etc/hosts` pour domaines `.local` (test uniquement) |
| NVIDIA Drivers | Installation conditionnelle (production + GPU) |
| Collections Ansible | Installation de `community.general`, `community.docker`, `ansible.posix` |

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
docker_daemon_log_max_size: "50m"
docker_daemon_log_max_file: "5"
proxy_network_name: "traefik-proxy"
system_enable_gpu: false
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

### 5. `redis` - Redis Mutualisé

**Fichiers :**
- `tasks/main.yml` - Déploiement de Redis Stack
- `templates/redis.env.j2` - Variables Redis
- `templates/redis.conf.j2` - Configuration Redis

**Note importante :** Les instances PostgreSQL sont désormais gérées directement par les rôles applicatifs (`apps/immich`, `apps/nextcloud`, `apps/litopia`) pour une meilleure isolation et compatibilité (ex: extensions spécifiques comme VectorChord).

**Redis :**

| Caractéristique | Valeur |
|-----------------|--------|
| Image | `redis:8-alpine` |
| Port | 6379 (localhost uniquement) |
| Persistence | RDB + AOF |
| Config | slowlog, latency-monitor, maxmemory-policy allkeys-lru |
| Rôle | Cache et Sessions mutualisés |


---

### 6. `monitoring` - Stack Prometheus + Grafana + Loki

**Fichiers :**
- `tasks/main.yml` - Déploiement monitoring
- `handlers/main.yml` - Restart monitoring
- `templates/*.j2` - Configurations
- `files/dashboards/*.json` - Dashboards Grafana
- `files/*-alerts.yml` - Règles d'alerting

**Composants déployés :**

| Service | Image | Port | Rôle |
|---------|-------|------|------|
| Prometheus | `prom/prometheus:v3.9.1` | 9090 | Métriques |
| Alertmanager | `prom/alertmanager:v0.26.0` | 9093 | Alertes |
| Grafana | `grafana/grafana:12.3.1` | 3000 | Visualisation |
| Loki | `grafana/loki:3.3.2` | 3100 | Logs |
| Promtail | `grafana/promtail:3.3.2` | - | Collecte logs |
| Node Exporter | `apt:prometheus-node-exporter` | 9100 | Métriques Host |
| cAdvisor | `gcr.io/cadvisor/cadvisor:v0.55.1` | 8080 | Métriques Docker |
| postgres-nextcloud-exporter | `prometheuscommunity/postgres-exporter:v0.15.0` | 9187 | Métriques PostgreSQL (Nextcloud) |
| postgres-immich-exporter | `prometheuscommunity/postgres-exporter:v0.15.0` | 9187 | Métriques PostgreSQL (Immich) |
| redis-exporter | `oliver006/redis_exporter:v1.55.0` | 9121 | Métriques Redis |

**Dashboards Grafana pré-configurés :**
1. **Traefik Dashboard** - Monitoring reverse proxy
2. **Docker Dashboard** - Containers (CPU, RAM, réseau)
3. **PostgreSQL Performance** - Queries, locks, cache, I/O, pgvector
4. **Redis Performance** - Cache hit rate, mémoire, latence
5. **Node Exporter Full** - Monitoring hardware, CPU, RAM, Disk, Network, NFS

## 📊 Règles d'Alerting Complètes

### PostgreSQL (14 règles)

| Alerte | Sévérité | Expression | Durée | Description |
|--------|----------|------------|-------|-------------|
| **PostgreSQLDown** | 🔴 critical | `pg_up{service="postgresql"} == 0` | 5m | Instance PostgreSQL indisponible depuis plus de 5 minutes |
| **PostgreSQLTooManyConnections** | 🟡 warning | Connexions > 80% max | 5m | Utilisation excessive des connexions disponibles |
| **PostgreSQLLowCacheHitRatio** | 🟡 warning | Cache hit < 90% | 10m | Taux de cache insuffisant - envisager augmenter `shared_buffers` |
| **PostgreSQLDeadlocks** | 🟡 warning | `rate(deadlocks) > 0` | 5m | Deadlocks détectés dans la base de données |
| **PostgreSQLLongRunningTransactions** | 🟡 warning | Transaction > 1800s | 5m | Transaction en cours depuis plus de 30 minutes |
| **PostgreSQLIdleInTransaction** | 🟡 warning | Sessions idle > 5 | 10m | Plus de 5 sessions inactives en transaction |
| **PostgreSQLHighIOWait** | 🟡 warning | I/O wait > 1000ms | 10m | Temps d'attente E/S élevé - vérifier performance disque |
| **PostgreSQLExcessiveTempFiles** | 🟡 warning | Temp files > 100MB/s | 10m | Écriture excessive dans fichiers temporaires - optimiser `work_mem` |
| **PostgreSQLTableBloat** | 🟡 warning | Dead tuples > 20% | 1h | Table gonflée avec trop de tuples morts - lancer VACUUM |
| **PostgreSQLReplicationLag** | 🟡 warning | Lag > 30s | 5m | Retard de réplication détecté |
| **PostgreSQLVectorTableSeqScans** | 🔵 info | Seq scans > Index scans | 15m | Tables vectorielles avec trop de scans séquentiels (HNSW/IVFFlat) |
| **PostgreSQLVectorIndexUnused** | 🔵 info | Index > 10MB, scans < 10 | 1h | Grand index vectoriel inutilisé |
| **PostgreSQLHighLockWaitCount** | 🟡 warning | Locks waiting > 10 | 5m | Nombre élevé de verrous en attente |

---

### Redis (17 règles)

| Alerte | Sévérité | Expression | Durée | Description |
|--------|----------|------------|-------|-------------|
| **RedisDown** | 🔴 critical | `redis_up{job="redis"} == 0` | 1m | Instance Redis indisponible depuis plus d'une minute |
| **RedisLowCacheHitRate** | 🟡 warning | Hit rate < 80% | 10m | Taux de cache insuffisant - vérifier patterns d'utilisation |
| **RedisHighMemoryUsage** | 🟡 warning | Mémoire > 90% max | 5m | Mémoire presque pleine - risque d'éviction de clés |
| **RedisHighMemoryFragmentation** | 🟡 warning | Fragmentation > 2 | 10m | Fragmentation mémoire élevée (ratio > 2) |
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

### 7. `apps/immich` - Gestion de Photos

**Fichiers :**
- `tasks/main.yml` - Déploiement Immich
- `templates/.env.j2` - Variables d'environnement
- `templates/init-db.sql.j2` - Initialisation BDD dédiée

**Composants :**

| Service | Image | Description |
|---------|-------|-------------|
| immich-server | `ghcr.io/immich-app/immich-server:v2.4.1-ig441` | API + Web |
| immich-machine-learning | `ghcr.io/immich-app/immich-machine-learning:v1.130.2` | ML/IA |
| immich-postgres | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` | BDD dédiée avec VectorChord |

**Volumes :**
- `/mnt/photos` → `/usr/src/app/upload` (photos)
- `${DATA_PATH}/immich/model-cache` → `/cache` (modèles ML)
- `${DATA_PATH}/immich/postgres` → données PostgreSQL

**Particularités :**
- **BDD Dédiée** : Utilise une image PostgreSQL optimisée par Immich avec support VectorChord et pgvector.
- **Monitoring** : Un exporteur PostgreSQL dédié (`immich-postgres-exporter`) est déployé par le rôle monitoring pour surveiller cette instance.
- **Réseau** : Connecté au réseau `proxy` pour Traefik et `default` pour la communication interne.

**Labels Traefik :**
- Routes HTTP/HTTPS sur `photos.${base_domain}`
- Port interne : 2283

---

### 8. `apps/jellyfin` - Streaming Média

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

### 9. `apps/nextcloud` - Cloud Personnel

**Fichiers :**
- `tasks/main.yml` - Déploiement Nextcloud
- `templates/.env.j2` - Variables d'environnement
- `templates/init-db.sql.j2` - Initialisation BDD dédiée

**Configuration :**

| Paramètre | Valeur |
|-----------|--------|
| Image | `nextcloud:32.0.5` |
| Port | 80 (interne) |
| Stockage app | `${DATA_PATH}/nextcloud` |
| Stockage data | `/mnt/cloud` |
| BDD | PostgreSQL dédiée (`nextcloud-db`) |
| Cache | Redis mutualisé |

**Particularités :**
- **BDD Dédiée** : Bien que mutualisée au début, Nextcloud utilise maintenant sa propre instance PostgreSQL (`nextcloud-db`) définie dans son `docker-compose.yml`.
- **Auto-configuration** : Le rôle Ansible utilise l'utilitaire `occ` pour configurer automatiquement les domaines de confiance, Redis, et les paramètres de sécurité après le premier démarrage.
- **Monitoring** : Un exporteur PostgreSQL dédié (`nextcloud-postgres-exporter`) surveille l'instance.

**Middlewares Traefik spécifiques :**
- Redirect CalDAV/CardDAV vers `/remote.php/dav/`

---

### 10. `apps/litopia` - Portail communautaire

**Fichiers :**
- `tasks/main.yml` - Deploiement Litopia
- `templates/litopia-back.env.j2` - Variables d'environnement backend + DB
- `templates/litopia-front.env.j2` - Variables d'environnement frontend
- `templates/docker-compose.yml.j2` - Stack Litopia

**Composants :**

| Service | Image | Description |
|---------|-------|-------------|
| litopia-front | `ghcr.io/litopiacommunity/litopia-front:v1.1.0` | Front web |
| litopia-back | `ghcr.io/litopiacommunity/litopia-back:v1.1.0` | API NestJS |
| litopia-db | `postgres:16-alpine` | BDD PostgreSQL |
| litopia-postgres-exporter | `prometheuscommunity/postgres-exporter:v0.15.0` | Metriques PostgreSQL |

**Reseaux :**
- `proxy` pour le front/back expose via Traefik
- `monitoring` pour l'exporter
- `default` pour la base

**Particularites :**
- **Domaines** : Host `{{ service_domains.litopia }}`, front sur `/` et API sur `/api`.
- **DB dediee** : Donnees sur `storage.databases.litopia`.
- **Secrets** : Discord, AMP, et `API_LOCAL_KEY` via `vault.yml`.

**Healthchecks :**
- Front : `http://localhost:4000`
- Back : `http://localhost:3000/api`
- DB : `pg_isready`

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

# Litopia
litopia_db_user: "litopia"
litopia_db_password: "..."
litopia_db_database: "litopia"
litopia_discord_client_id: "..."
litopia_discord_client_secret: "..."
litopia_discord_client_token: "..."
litopia_discord_callback_url: "/api/auth/redirect"
litopia_discord_candidature_channel_id: "..."
litopia_discord_guild_id: "..."
litopia_discord_role_ghost: "..."
litopia_discord_role_candidate: "..."
litopia_discord_role_pre_accepted: "..."
litopia_discord_role_pretopien: "..."
litopia_discord_role_litopien: "..."
litopia_discord_role_active_litopien: "..."
litopia_discord_role_inactive_litopien: "..."
litopia_discord_role_refused: "..."
litopia_discord_role_litogod: "..."
litopia_discord_role_unique_god: "..."
litopia_amp_host: "..."
litopia_amp_instance: "..."
litopia_amp_login: "..."
litopia_api_local_key: "..."

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
| `system_enable_gpu` | `false` |
| `proxy_enable_letsencrypt` | `false` |
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
| `system_enable_gpu` | `true` |
| `proxy_enable_letsencrypt` | `true` |
| `storage_enable_zfs_snapshots` | `true` |
| `base_domain` | `louisvolat.fr` |
| `monitoring_prometheus_retention` | `90d` |
| `traefik_log_level` | `INFO` |

**Services activés :**
- shared-services (PostgreSQL + Redis)
- traefik
- immich
- jellyfin
- nextcloud
- litopia
- monitoring
- games (AMP)

---

## 🐳 Images Docker

### Versions (Production)

| Service | Image | Version | Limite CPU | Limite RAM |
|---------|-------|---------|------------|------------|
| Traefik | `traefik` | v3.6.6 | 0.5 | 512M |
| PostgreSQL (Apps) | `postgres` | 16-alpine | 0.5 | 512M |
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
| Litopia Front | `ghcr.io/litopiacommunity/litopia-front` | v1.1.0 | 0.25 | 256M |
| Litopia Back | `ghcr.io/litopiacommunity/litopia-back` | v1.1.0 | 0.5 | 512M |
| Socket Proxy | `docker-socket-proxy` | latest | 0.1 | 64M |

---

## 🚀 Commandes Make

```shell script
# === AIDE ===
make help

# === TESTS MULTIPASS ===
make vm-up              # Créer les VMs de test (setup-vms.sh)
make vm-down            # Détruire les VMs (destroy-vms.sh)
make test-init          # Initialiser secrets test (copie vault.yml.example)
make test-deploy        # Déployer sur VM test (via multipass exec)
make test-status         # Afficher status des containers sur VM test
make test-logs           # Suivre les logs Traefik sur VM test

# === PRODUCTION ===
make init                # Initialiser + chiffrer vault.yml
make secrets             # Éditer le vault chiffré
make deploy              # Déployer en production (demande vault password)
make status              # Status des services (docker ps local)
make validate            # Valider syntaxe Ansible (syntax-check)

# === MAINTENANCE ===
make clean               # Purger Docker (docker system prune -af)
```


---

## 📊 Monitoring & Alerting

### Scrape Prometheus

| Job | Target | Interval | Métriques |
|-----|--------|----------|-----------|
| prometheus | localhost:9090 | 15s | Self-monitoring |
| traefik | traefik:8080 | 15s | Requêtes, latence, status |
| cadvisor | cadvisor:8080 | 15s | CPU, RAM, réseau, I/O containers |
| postgres-nextcloud | nextcloud-postgres-exporter:9187 | 30s | Connexions, queries, cache, locks |
| postgres-immich | immich-postgres-exporter:9187 | 30s | Connexions, queries, cache, locks |
| postgres-litopia | litopia-postgres-exporter:9187 | 30s | Connexions, queries, cache, locks |
| redis | redis-exporter:9121 | 30s | Hit rate, mémoire, commandes |

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
    - `ansible/group_vars/all.yml` : variables communes et versions par défaut.
    - `ansible/group_vars/production.yml` : domaines, IPs NFS, etc. (surcharges).
    - `ansible/inventory/hosts.yml` : IP du serveur production

4. **Déployer**
```shell script
# Test
   make vm-up
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

# Logs Applicatifs (ex: Nextcloud)
docker logs nextcloud -f

# Logs Ansible (verbose)
ansible-playbook -vvv playbooks/site.yml
```

### Commandes Utiles

```shell script
# Forcer la réinitialisation de Nextcloud (via occ)
docker exec -u 33 nextcloud php occ status

# Vérifier la base de données Immich
docker exec -it immich-db psql -U immich
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
