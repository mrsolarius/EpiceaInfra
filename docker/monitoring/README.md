# 📊 Monitoring Stack Epicea Infrastructure

Stack complet de monitoring pour PostgreSQL (avec pgvector) et Redis basé sur Prometheus et Grafana.

## 🏗️ Architecture

```
┌─────────────────┐      ┌──────────────────┐      ┌─────────────┐
│   PostgreSQL    │─────▶│ postgres_exporter │─────▶│             │
│   (pgvecto-rs)  │      │   (port 9187)     │      │             │
└─────────────────┘      └──────────────────┘      │             │
                                                     │ Prometheus  │
┌─────────────────┐      ┌──────────────────┐      │ (port 9090) │
│      Redis      │─────▶│  redis_exporter   │─────▶│             │
│    (Alpine)     │      │   (port 9121)     │      │             │
└─────────────────┘      └──────────────────┘      └──────┬──────┘
                                                           │
                         ┌──────────────────┐             │
                         │    cAdvisor      │─────────────┤
                         │  (port 8080)     │             │
                         └──────────────────┘             │
                                                           │
                                                           ▼
                                                    ┌─────────────┐
                                                    │   Grafana   │
                                                    │ (port 3000) │
                                                    └─────────────┘
```

## 📁 Structure des fichiers

```
monitoring/
├── docker-compose.yml                              # Stack complet
├── prometheus/
│   ├── prometheus.yml                              # Configuration Prometheus
│   ├── rules/
│   │   ├── postgres-alerts.yml                     # Alertes PostgreSQL
│   │   └── redis-alerts.yml                        # Alertes Redis
│   └── data/                                       # Données Prometheus (volume)
├── postgres-exporter/
│   └── queries.yaml                                # Métriques custom PostgreSQL
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/
│   │   │   └── prometheus.yml                      # Datasource Prometheus
│   │   └── dashboards/
│   │       └── default.yml                         # Provisioning dashboards
│   └── dashboards/
│       ├── postgresql/
│       │   └── postgresql-performance.json         # Dashboard PostgreSQL
│       └── redis/
│           └── redis-performance.json              # Dashboard Redis
└── README.md                                       # Ce fichier
```

## 🚀 Démarrage rapide

### 1. Prérequis

- Docker et Docker Compose
- PostgreSQL avec `pg_stat_statements` activé
- Redis avec configuration de monitoring

### 2. Configuration

Créer un fichier `.env` dans le répertoire `monitoring/` :

```bash
# Prometheus
PROMETHEUS_RETENTION=15d

# Grafana
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<mot_de_passe_securise>
GRAFANA_DOMAIN=monitoring.epicea-test.local
GRAFANA_PLUGINS=

# PostgreSQL credentials (pour postgres_exporter)
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<mot_de_passe_postgres>
POSTGRES_DB=postgres

# Redis credentials (pour redis_exporter)
REDIS_PASSWORD=<mot_de_passe_redis>

# Environment
ENVIRONMENT=production
```

### 3. Initialisation de PostgreSQL

Le fichier `docker/stateful/postgres/init.sql` active automatiquement :
- Extension `pg_stat_statements`
- Extension `vectors` (pgvector)
- Tracking I/O (`track_io_timing`)
- Logging des requêtes lentes

**⚠️ Important** : PostgreSQL doit être redémarré après l'initialisation pour que certains paramètres prennent effet.

```bash
cd docker/stateful/postgres
docker-compose down
docker-compose up -d
```

### 4. Configuration Redis

Le fichier `redis.conf` active :
- Slowlog pour détecter les commandes lentes
- Latency monitoring
- AOF persistence
- Active defragmentation

Redémarrer Redis pour appliquer la configuration :

```bash
cd docker/stateful/redis
docker-compose down
docker-compose up -d
```

### 5. Lancer le stack de monitoring

```bash
cd docker/monitoring
docker-compose up -d
```

### 6. Accéder aux interfaces

- **Grafana** : http://monitoring.epicea-test.local (ou configuré dans `.env`)
- **Prometheus** : http://localhost:9090 (non exposé par défaut)

Les dashboards sont automatiquement provisionnés dans Grafana sous le dossier **"Database Monitoring"**.

## 📊 Dashboards Grafana

### Dashboard PostgreSQL Performance & pgvector

**Sections principales :**

1. **Overview**
   - Uptime, connexions actives
   - TPS (Transactions Per Second)
   - Cache Hit Ratio
   - Deadlocks

2. **Resource Analysis - I/O vs CPU**
   - I/O Wait Time (lecture/écriture disque)
   - Pourcentage de temps passé en I/O
   - Identification des goulots d'étranglement

3. **Top Query Offenders (pg_stat_statements)**
   - Top 10 requêtes par temps total d'exécution
   - Top 10 requêtes les plus appelées
   - Top 10 requêtes avec spillage disque (temp files)

4. **Sessions & Locks**
   - États des sessions (active, idle, idle in transaction)
   - Wait Events (Lock, LWLock, IO)
   - Transactions longues (> 5 min)
   - Statut des locks en cours

5. **pgvector Monitoring**
   - Index vectoriels (HNSW/IVFFlat/vectors) avec taille et usage
   - Ratio Sequential Scan vs Index Scan sur tables vectorielles
   - Évolution de la taille des index vectoriels

6. **Table & Index Health**
   - Table bloat (dead tuples)
   - Nécessité de VACUUM

### Dashboard Redis Performance

**Sections principales :**

1. **Overview**
   - Uptime, clients connectés
   - Commands/sec
   - Cache Hit Rate
   - Blocked clients

2. **Memory Analysis**
   - Usage mémoire (Used vs Max vs RSS)
   - Fragmentation ratio
   - Évictions et expirations de clés
   - Distribution mémoire (Dataset/Overhead/Startup)
   - Clés par base de données

3. **Cache Efficiency**
   - Hits vs Misses
   - Taux de hit rate dans le temps

4. **Performance & Latency**
   - Latence moyenne par commande
   - Commandes par seconde par type
   - Statistiques détaillées par commande

5. **Persistence & Operations**
   - Opérations RDB/AOF
   - Network I/O
   - CPU usage
   - Activité des connexions

## 🎯 Métriques clés à surveiller

### PostgreSQL

| Métrique | Valeur cible | Action si déviation |
|----------|--------------|---------------------|
| **Cache Hit Ratio** | > 95% | Augmenter `shared_buffers` |
| **Connections actives** | < 80% max | Vérifier connection pooling |
| **I/O Wait Time** | < 20% du temps total | Optimiser requêtes ou disque |
| **Deadlocks** | 0 | Revoir logique applicative |
| **Temp files** | Minimal | Augmenter `work_mem` |
| **Idle in transaction** | 0 | Corriger code application |
| **Table bloat** | < 10% dead tuples | Lancer VACUUM |
| **Sequential scans (vectors)** | < Index scans | Créer/rebuild index HNSW |

### Redis

| Métrique | Valeur cible | Action si déviation |
|----------|--------------|---------------------|
| **Cache Hit Rate** | > 90% | Revoir stratégie de cache |
| **Memory usage** | < 80% maxmemory | Augmenter maxmemory ou revoir TTL |
| **Fragmentation Ratio** | 1.0 - 1.5 | Redémarrer ou activer defrag |
| **Evicted Keys** | 0 | Augmenter mémoire |
| **Blocked Clients** | 0 | Optimiser commandes bloquantes |
| **Command Latency** | < 1ms (µs) | Identifier commandes lentes |
| **Slowlog entries** | 0 | Optimiser commandes |

## 🔔 Alerting Prometheus

Les règles d'alerting sont configurées dans :
- `prometheus/rules/postgres-alerts.yml`
- `prometheus/rules/redis-alerts.yml`

### Alertes PostgreSQL principales

| Alerte | Sévérité | Seuil | Description |
|--------|----------|-------|-------------|
| PostgreSQLDown | Critical | 1 min | Instance PostgreSQL inaccessible |
| PostgreSQLTooManyConnections | Warning | > 80% | Trop de connexions |
| PostgreSQLLowCacheHitRatio | Warning | < 90% | Cache inefficace |
| PostgreSQLDeadlocks | Warning | > 0/s | Deadlocks détectés |
| PostgreSQLLongRunningTransactions | Warning | > 30 min | Transaction bloquante |
| PostgreSQLHighIOWait | Warning | > 1000ms/s | I/O lent |
| PostgreSQLTableBloat | Warning | > 20% | Nécessite VACUUM |
| PostgreSQLVectorTableSeqScans | Info | seq > idx | Index vectoriel non utilisé |

### Alertes Redis principales

| Alerte | Sévérité | Seuil | Description |
|--------|----------|-------|-------------|
| RedisDown | Critical | 1 min | Instance Redis inaccessible |
| RedisLowCacheHitRate | Warning | < 80% | Cache inefficace |
| RedisHighMemoryUsage | Warning | > 90% | Mémoire saturée |
| RedisHighMemoryFragmentation | Warning | > 2.0 | Fragmentation excessive |
| RedisKeysEvicted | Warning | > 100/s | Éviction de clés |
| RedisBlockedClients | Warning | > 5 | Clients bloqués |
| RedisHighCommandLatency | Warning | > 10ms | Commandes lentes |

## 🛠️ Troubleshooting

### PostgreSQL : Requêtes lentes

1. Identifier les top offenders dans le dashboard "Top Query Offenders"
2. Récupérer la requête complète :
   ```sql
   SELECT query, calls, total_exec_time, mean_exec_time
   FROM pg_stat_statements
   WHERE queryid = '<query_id>'
   ORDER BY total_exec_time DESC;
   ```
3. Analyser le plan d'exécution :
   ```sql
   EXPLAIN ANALYZE <votre_requete>;
   ```
4. Actions possibles :
   - Créer des index manquants
   - Augmenter `work_mem` si spillage disque
   - Optimiser les JOINs
   - Utiliser HNSW/IVFFlat pour recherches vectorielles

### PostgreSQL : Cache Hit Ratio bas

1. Vérifier `shared_buffers` actuel :
   ```sql
   SHOW shared_buffers;
   ```
2. Recommandation : 25% de la RAM disponible
3. Modifier dans `postgresql.conf` :
   ```
   shared_buffers = 4GB
   ```
4. Redémarrer PostgreSQL

### PostgreSQL : Table Bloat

1. Identifier les tables dans le dashboard "Table Bloat"
2. Exécuter VACUUM :
   ```sql
   VACUUM VERBOSE ANALYZE <table_name>;
   ```
3. Si bloat persiste, utiliser VACUUM FULL (requiert lock) :
   ```sql
   VACUUM FULL <table_name>;
   ```

### Redis : Low Cache Hit Rate

1. Analyser les patterns d'accès dans Grafana
2. Vérifier les clés expirées vs évincées
3. Si évictions élevées → augmenter `maxmemory`
4. Si expirations élevées → revoir les TTL
5. Vérifier la distribution des clés (hotkeys) :
   ```bash
   redis-cli --bigkeys
   redis-cli --hotkeys
   ```

### Redis : High Memory Fragmentation

1. Si ratio > 1.5 et stable, considérer :
   ```bash
   redis-cli CONFIG SET activedefrag yes
   ```
2. Si ratio > 2.0, redémarrer Redis (en dehors des heures de pic)

### Redis : Slowlog

1. Consulter le slowlog :
   ```bash
   redis-cli SLOWLOG GET 10
   ```
2. Identifier les commandes problématiques
3. Actions possibles :
   - Utiliser pipelines pour batch operations
   - Éviter `KEYS *` (utiliser `SCAN` à la place)
   - Fragmenter les grandes structures (lists, sets)

## 📈 Optimisations recommandées

### PostgreSQL

**Configuration de base (postgresql.conf) :**

```ini
# Métriques et monitoring
shared_preload_libraries = 'pg_stat_statements,vectors'
pg_stat_statements.track = all
pg_stat_statements.max = 10000
track_io_timing = on
track_functions = all

# Performance
shared_buffers = 4GB                    # 25% RAM
effective_cache_size = 12GB             # 75% RAM
work_mem = 64MB                         # Ajuster selon spillage
maintenance_work_mem = 1GB
max_connections = 100

# WAL et checkpoints
wal_buffers = 16MB
checkpoint_completion_target = 0.9
max_wal_size = 4GB
min_wal_size = 1GB

# Vacuum
autovacuum = on
autovacuum_max_workers = 4
autovacuum_naptime = 10s
```

**Index vectoriels (pgvector) :**

```sql
-- Index HNSW (recommandé pour haute précision)
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- Index IVFFlat (recommandé pour large dataset)
CREATE INDEX ON items USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);
```

### Redis

**Configuration de base (redis.conf) :**

```ini
# Mémoire
maxmemory 8gb
maxmemory-policy allkeys-lru

# Persistence
save 900 1
save 300 10
save 60 10000
appendonly yes
appendfsync everysec

# Performance
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes

# Monitoring
slowlog-log-slower-than 10000          # 10ms
slowlog-max-len 128
latency-monitor-threshold 100

# Defragmentation
activedefrag yes
active-defrag-threshold-lower 10
```

## 🔒 Sécurité

### Recommandations

1. **Grafana** : Changer le mot de passe admin par défaut
2. **Prometheus** : Ne pas exposer publiquement (pas de routes Traefik par défaut)
3. **Exporters** : Accès limité aux réseaux Docker internes
4. **PostgreSQL/Redis** : Utiliser des mots de passe forts dans `.env`

### Rotation des credentials

```bash
# PostgreSQL
docker exec postgres psql -U postgres -c "ALTER USER postgres PASSWORD 'new_password';"

# Redis
docker exec redis redis-cli CONFIG SET requirepass "new_password"
docker exec redis redis-cli CONFIG REWRITE

# Redémarrer les exporters
docker-compose -f docker/monitoring/docker-compose.yml restart postgres-exporter redis-exporter
```

## 📚 Ressources

### Documentation officielle

- [Prometheus](https://prometheus.io/docs/)
- [Grafana](https://grafana.com/docs/)
- [PostgreSQL Performance](https://www.postgresql.org/docs/current/performance-tips.html)
- [pgvector](https://github.com/pgvector/pgvector)
- [Redis Performance](https://redis.io/docs/management/optimization/)

### Exporters

- [postgres_exporter](https://github.com/prometheus-community/postgres_exporter)
- [redis_exporter](https://github.com/oliver006/redis_exporter)

### Requêtes utiles

**PostgreSQL - Voir les index vectoriels :**
```sql
SELECT
    schemaname, tablename, indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
JOIN pg_index ON indexrelid = pg_stat_user_indexes.indexrelid
JOIN pg_class ON pg_index.indrelid = pg_class.oid
JOIN pg_am ON pg_class.relam = pg_am.oid
WHERE pg_am.amname IN ('hnsw', 'ivfflat', 'vectors');
```

**PostgreSQL - Reset pg_stat_statements :**
```sql
SELECT pg_stat_statements_reset();
```

**Redis - Info complète :**
```bash
redis-cli INFO ALL
```

## 🤝 Support

Pour toute question ou problème :
1. Consulter les logs : `docker-compose logs -f <service>`
2. Vérifier les métriques Prometheus : http://localhost:9090
3. Consulter les dashboards Grafana pour identifier les anomalies

---

**Version** : 1.0.0
**Dernière mise à jour** : 2026-01-12
**Auteur** : Équipe SRE Epicea
