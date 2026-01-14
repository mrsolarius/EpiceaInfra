# 🚀 Checklist de Déploiement - Stack Monitoring

## ✅ Étape 1 : Prérequis

- [ ] Docker et Docker Compose installés
- [ ] PostgreSQL et Redis déjà déployés
- [ ] Accès réseau entre les services (réseau Docker `traefik-proxy`)
- [ ] Credentials PostgreSQL et Redis disponibles

## ✅ Étape 2 : Configuration PostgreSQL

### 2.1 Activer pg_stat_statements

- [ ] Copier `docker/stateful/postgres/init.sql` si absent
- [ ] Vérifier que le fichier est monté dans docker-compose :
  ```yaml
  volumes:
    - ./init.sql:/docker-entrypoint-initdb.d/init.sql
  ```

### 2.2 Redémarrer PostgreSQL

```bash
cd docker/stateful/postgres
docker-compose down
docker-compose up -d
docker-compose logs -f postgres  # Attendre démarrage complet
```

### 2.3 Vérifier l'activation

```bash
docker exec postgres psql -U postgres -c "SELECT * FROM pg_extension WHERE extname IN ('pg_stat_statements', 'vectors');"
docker exec postgres psql -U postgres -c "SHOW pg_stat_statements.track;"
docker exec postgres psql -U postgres -c "SHOW track_io_timing;"
```

**✅ Attendu :**
- `pg_stat_statements` et `vectors` dans la liste
- `pg_stat_statements.track = all`
- `track_io_timing = on`

## ✅ Étape 3 : Configuration Redis

### 3.1 Appliquer redis.conf

- [ ] Copier `docker/stateful/redis/redis.conf` si absent
- [ ] Vérifier le montage dans docker-compose :
  ```yaml
  volumes:
    - ./redis.conf:/usr/local/etc/redis/redis.conf:ro
  command: redis-server /usr/local/etc/redis/redis.conf --requirepass ${REDIS_PASSWORD}
  ```

### 3.2 Redémarrer Redis

```bash
cd docker/stateful/redis
docker-compose down
docker-compose up -d
docker-compose logs -f redis  # Attendre démarrage complet
```

### 3.3 Vérifier la configuration

```bash
docker exec redis redis-cli -a "${REDIS_PASSWORD}" CONFIG GET slowlog-log-slower-than
docker exec redis redis-cli -a "${REDIS_PASSWORD}" CONFIG GET activedefrag
docker exec redis redis-cli -a "${REDIS_PASSWORD}" CONFIG GET appendonly
```

**✅ Attendu :**
- `slowlog-log-slower-than = 10000`
- `activedefrag = yes`
- `appendonly = yes`

## ✅ Étape 4 : Configuration du Monitoring

### 4.1 Créer le fichier .env

```bash
cd docker/monitoring
cp .env.example .env
```

### 4.2 Modifier les credentials

```bash
nano .env  # ou vim/vi selon préférence
```

**Modifier obligatoirement :**
- `GRAFANA_ADMIN_PASSWORD`
- `POSTGRES_PASSWORD`
- `REDIS_PASSWORD`
- `GRAFANA_DOMAIN` (si différent)

### 4.3 Vérifier la structure des fichiers

```bash
tree docker/monitoring/
```

**✅ Attendu :**
```
monitoring/
├── .env
├── .env.example
├── docker-compose.yml
├── DEPLOYMENT.md
├── README.md
├── prometheus/
│   ├── prometheus.yml
│   └── rules/
│       ├── postgres-alerts.yml
│       └── redis-alerts.yml
├── postgres-exporter/
│   └── queries.yaml
└── grafana/
    ├── provisioning/
    │   ├── datasources/
    │   │   └── prometheus.yml
    │   └── dashboards/
    │       └── default.yml
    └── dashboards/
        ├── postgresql/
        │   └── postgresql-performance.json
        └── redis/
            └── redis-performance.json
```

## ✅ Étape 5 : Déploiement du Stack

### 5.1 Vérifier la configuration Docker Compose

```bash
cd docker/monitoring
docker-compose config  # Vérifie la syntaxe
```

**⚠️ Corriger les erreurs éventuelles avant de continuer**

### 5.2 Créer le réseau Traefik (si nécessaire)

```bash
docker network ls | grep traefik-proxy || docker network create traefik-proxy
```

### 5.3 Lancer le stack

```bash
docker-compose up -d
```

### 5.4 Vérifier les logs

```bash
# Tous les services
docker-compose logs -f

# Ou individuellement
docker-compose logs -f prometheus
docker-compose logs -f postgres-exporter
docker-compose logs -f redis-exporter
docker-compose logs -f grafana
```

**✅ Attendu (sans erreurs) :**
- Prometheus : "Server is ready to receive web requests"
- postgres-exporter : "Listening on :9187"
- redis-exporter : "Redis Metrics Exporter v..."
- Grafana : "HTTP Server Listen"

### 5.5 Vérifier le status des containers

```bash
docker-compose ps
```

**✅ Tous les containers doivent être "Up" et "healthy"**

## ✅ Étape 6 : Validation des Exporters

### 6.1 Tester postgres_exporter

```bash
# Vérifier les métriques exposées
curl -s http://localhost:9187/metrics | grep "pg_up"
curl -s http://localhost:9187/metrics | grep "pg_stat_statements"
```

**✅ Attendu :**
- `pg_up 1`
- Présence de métriques `pg_stat_statements_*`

### 6.2 Tester redis_exporter

```bash
# Vérifier les métriques exposées
curl -s http://localhost:9121/metrics | grep "redis_up"
curl -s http://localhost:9121/metrics | grep "redis_memory_used_bytes"
```

**✅ Attendu :**
- `redis_up 1`
- Présence de `redis_memory_used_bytes`

## ✅ Étape 7 : Validation Prometheus

### 7.1 Accéder à l'interface Prometheus

Ouvrir : http://localhost:9090

### 7.2 Vérifier les targets

Aller dans **Status → Targets**

**✅ Tous les targets doivent être "UP" :**
- prometheus (9090)
- cadvisor (8080)
- postgres-exporter (9187)
- redis-exporter (9121)
- grafana (3000)

### 7.3 Tester des requêtes PromQL

Dans **Graph**, tester :

```promql
# PostgreSQL connecté
pg_up

# Redis connecté
redis_up

# Nombre de connexions PostgreSQL
pg_stat_database_numbackends

# Cache hit rate Redis
rate(redis_keyspace_hits_total[5m])
```

**✅ Toutes les requêtes doivent retourner des valeurs**

## ✅ Étape 8 : Validation Grafana

### 8.1 Accéder à Grafana

Ouvrir : http://monitoring.epicea-test.local (ou selon votre `GRAFANA_DOMAIN`)

**Credentials :**
- User : `admin`
- Password : (celui défini dans `.env`)

### 8.2 Vérifier la datasource Prometheus

Aller dans **Configuration → Data Sources**

**✅ "Prometheus" doit être présent et fonctionnel (point vert)**

### 8.3 Vérifier les dashboards

Aller dans **Dashboards → Browse**

**✅ Attendu dans le dossier "Database Monitoring" :**
- PostgreSQL Performance & pgvector Monitoring
- Redis Performance Monitoring

### 8.4 Tester les dashboards

Ouvrir chaque dashboard :

**Dashboard PostgreSQL :**
- [ ] Overview : Uptime, Connexions, TPS, Cache Hit Ratio visible
- [ ] I/O vs CPU : Graphiques avec données
- [ ] Top Queries : Tables avec query_id (peut être vide si peu d'activité)
- [ ] Sessions & Locks : Au moins quelques sessions actives
- [ ] pgvector : Tables/graphiques (peut être vide si pas d'index vectoriels)
- [ ] Table Bloat : Tables avec dead tuples (peut être vide)

**Dashboard Redis :**
- [ ] Overview : Uptime, Clients, Commands/sec, Hit Rate visible
- [ ] Memory Analysis : Usage mémoire et fragmentation
- [ ] Cache Efficiency : Hits vs Misses
- [ ] Performance : Latence par commande
- [ ] Persistence : Network I/O, RDB/AOF

**⚠️ Si aucune donnée n'apparaît :**
1. Vérifier que les targets sont UP dans Prometheus
2. Vérifier les logs des exporters
3. Vérifier la connectivité réseau (Docker networks)

## ✅ Étape 9 : Test des Alertes (Optionnel)

### 9.1 Vérifier les règles d'alerting dans Prometheus

Aller dans Prometheus → **Alerts**

**✅ Toutes les alertes doivent être listées (état "Inactive" si tout va bien)**

### 9.2 Tester une alerte (optionnel)

Exemple : Simuler une charge élevée sur PostgreSQL

```bash
# Créer des connexions simultanées
for i in {1..50}; do
  docker exec -d postgres psql -U postgres -c "SELECT pg_sleep(60);"
done
```

**✅ L'alerte "PostgreSQLTooManyConnections" devrait se déclencher dans Prometheus**

## ✅ Étape 10 : Configuration finale

### 10.1 Configurer la rétention Prometheus

Si besoin d'ajuster la rétention :

```bash
# Dans .env
PROMETHEUS_RETENTION=30d  # Exemple : 30 jours
docker-compose up -d prometheus
```

### 10.2 Sécuriser Grafana

- [ ] Changer le mot de passe admin
- [ ] Désactiver l'inscription : `GF_USERS_ALLOW_SIGN_UP=false` (déjà fait)
- [ ] Configurer HTTPS via Traefik (si souhaité)

### 10.3 Planifier les backups

```bash
# Backup Prometheus data
tar -czf prometheus-backup-$(date +%Y%m%d).tar.gz docker/monitoring/prometheus/data/

# Backup Grafana data
tar -czf grafana-backup-$(date +%Y%m%d).tar.gz docker/monitoring/grafana-data/
```

## ✅ Étape 11 : Monitoring en Production

### 11.1 Créer un dashboard d'alertes

Dans Grafana, créer un tableau récapitulatif des alertes actives.

### 11.2 Configurer Alertmanager (optionnel)

Pour recevoir des notifications (email, Slack, etc.), configurer Alertmanager :

```yaml
# docker-compose.yml (ajouter)
alertmanager:
  image: prom/alertmanager:v0.26.0
  container_name: alertmanager
  restart: unless-stopped
  volumes:
    - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml
  networks:
    - monitoring
  ports:
    - "9093:9093"
```

### 11.3 Vérifier les métriques quotidiennement

- [ ] Cache Hit Ratio PostgreSQL > 95%
- [ ] Cache Hit Rate Redis > 90%
- [ ] Pas de deadlocks PostgreSQL
- [ ] Pas d'évictions Redis
- [ ] Pas de transactions longues (> 5 min)

## 🎉 Déploiement terminé !

Votre stack de monitoring est maintenant opérationnel.

### 📚 Prochaines étapes

1. Consulter le [README.md](README.md) pour le troubleshooting
2. Configurer les alertes selon vos besoins
3. Créer des dashboards personnalisés si nécessaire
4. Mettre en place une routine de backup

### 📞 Support

En cas de problème :
1. Consulter les logs : `docker-compose logs -f <service>`
2. Vérifier les targets Prometheus
3. Tester les queries PromQL manuellement
4. Consulter la documentation officielle

---

**Checklist complétée le** : _______________
**Par** : _______________
