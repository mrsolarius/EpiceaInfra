# 📊 Role Ansible : Monitoring Stack (PostgreSQL + Redis)

Ce role Ansible déploie une stack complète de monitoring incluant :
- **Prometheus** avec exporters pour PostgreSQL et Redis
- **Alertmanager** pour les notifications Discord
- **Grafana** avec dashboards pré-configurés
- **Alerting** automatique via règles Prometheus

## 🎯 Dashboards inclus

1. **Traefik Dashboard** - Monitoring du reverse proxy
2. **Docker Dashboard** - Monitoring des containers
3. **PostgreSQL Performance & pgvector** - Monitoring complet de PostgreSQL incluant :
   - Analyse I/O vs CPU
   - Top requêtes (query offenders)
   - Sessions et locks
   - Monitoring spécifique pgvector (index HNSW/IVFFlat)
   - Table bloat
4. **Redis Performance** - Monitoring complet de Redis incluant :
   - Cache hit rate
   - Analyse mémoire et fragmentation
   - Latence par commande
   - Performance et persistence

## 📁 Fichiers déployés

```
monitoring/
├── prometheus/
│   ├── prometheus.yml                    # Config Prometheus (template)
│   └── rules/
│       ├── postgres-alerts.yml           # 15+ règles PostgreSQL
│       └── redis-alerts.yml              # 16+ règles Redis
├── postgres-exporter/
│   └── queries.yaml                      # Métriques custom pgvector
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── prometheus.yml            # Datasource auto-provisionné
│       └── dashboards/
│           ├── dashboards.yml            # Config provisioning
│           ├── traefik.json             # Dashboard Traefik
│           ├── docker.json              # Dashboard Docker
│           ├── postgresql.json          # Dashboard PostgreSQL
│           └── redis.json               # Dashboard Redis
└── docker-compose.yml                    # Stack complète
```

## 🚀 Utilisation

### Prérequis dans l'inventaire

Assurez-vous que les variables suivantes sont définies dans votre inventaire ou vault :

```yaml
# Variables requises
grafana_admin_user: admin
grafana_admin_password: "votre_mot_de_passe_securise"

# Variables PostgreSQL (pour postgres_exporter)
postgres_user: postgres
postgres_password: "votre_mot_de_passe_postgres"
postgres_database: postgres

# Variables Redis (pour redis_exporter)
redis_password: "votre_mot_de_passe_redis"

# Notifications (Discord)
discord_webhook_url: "https://discord.com/api/webhooks/..." # (Variable Vault recommandée)

# Optionnel
prometheus_scrape_interval: "15s"
prometheus_evaluation_interval: "15s"
deploy_environment: "production"
```

### Exécution du playbook

```bash
cd ansible
ansible-playbook -i inventory/production playbooks/deploy_monitoring.yml
```

Ou si vous déployez toute l'infrastructure :

```bash
ansible-playbook -i inventory/production playbooks/deploy_all.yml
```

## ✅ Vérification du déploiement

### 1. Vérifier que les containers sont actifs

```bash
ssh user@server
cd /opt/docker/monitoring
docker compose ps
```

**Attendu :**
- prometheus (healthy)
- postgres-exporter (healthy)
- redis-exporter (healthy)
- cadvisor (healthy)
- grafana (healthy)

### 2. Vérifier les targets Prometheus

Accéder à : `http://prometheus:9090/targets` (via port-forward ou réseau interne)

**Tous les targets doivent être UP :**
- prometheus
- postgres (postgres-exporter:9187)
- redis (redis-exporter:9121)
- cadvisor
- grafana

### 3. Accéder à Grafana

URL : Défini dans `service_domains.grafana` de votre inventaire

**Credentials :**
- User : `{{ grafana_admin_user }}`
- Password : `{{ grafana_admin_password }}`

### 4. Vérifier les dashboards

Dans Grafana, aller à **Dashboards → Browse → Epicea**

Vous devriez voir :
- ✅ Traefik Dashboard
- ✅ Docker Dashboard
- ✅ PostgreSQL Performance & pgvector Monitoring
- ✅ Redis Performance Monitoring

## 🔧 Configuration PostgreSQL

Pour que le monitoring PostgreSQL fonctionne correctement, PostgreSQL doit être configuré avec :

```sql
-- Extensions requises
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS vectors;

-- Configuration (dans postgresql.conf ou via ALTER SYSTEM)
ALTER SYSTEM SET pg_stat_statements.track = 'all';
ALTER SYSTEM SET pg_stat_statements.max = 10000;
ALTER SYSTEM SET track_io_timing = on;
ALTER SYSTEM SET track_activities = on;
ALTER SYSTEM SET track_counts = on;

-- Redémarrer PostgreSQL
SELECT pg_reload_conf();  -- ou redémarrer le service
```

Le role `postgres` de cette infrastructure devrait déjà configurer cela via `init.sql`.

## 🔧 Configuration Redis

Pour que le monitoring Redis fonctionne correctement, Redis doit être configuré avec :

```bash
# Dans redis.conf
slowlog-log-slower-than 10000
slowlog-max-len 128
latency-monitor-threshold 100
activedefrag yes
appendonly yes
```

Le role `redis` de cette infrastructure devrait déjà configurer cela.

## 🔔 Alertes disponibles

### PostgreSQL (15+ alertes)
- Instance down
- Trop de connexions
- Cache hit ratio faible
- Deadlocks
- Transactions longues
- I/O wait élevé
- Spillage disque excessif
- Table bloat
- Sequential scans sur tables vectorielles
- Locks en attente

### Redis (16+ alertes)
- Instance down
- Cache hit rate faible
- Utilisation mémoire élevée
- Fragmentation mémoire
- Évictions de clés
- Clients bloqués
- Connexions rejetées
- Commandes lentes
- CPU élevé

## 📚 Documentation complète

Pour plus de détails sur le troubleshooting et les optimisations, consulter :
- `docker/monitoring/README.md` - Documentation complète du monitoring
- `docker/monitoring/DEPLOYMENT.md` - Checklist de déploiement détaillée

## 🛠️ Troubleshooting

### Les dashboards n'apparaissent pas dans Grafana

1. Vérifier que les fichiers JSON sont présents sur le serveur :
   ```bash
   ls -la /opt/docker/monitoring/grafana/provisioning/dashboards/
   ```

2. Vérifier les logs Grafana :
   ```bash
   docker compose logs grafana | grep -i dashboard
   ```

3. Redémarrer Grafana :
   ```bash
   docker compose restart grafana
   ```

### Aucune métrique PostgreSQL/Redis

1. Vérifier que les exporters sont UP :
   ```bash
   curl http://localhost:9187/metrics  # postgres-exporter
   curl http://localhost:9121/metrics  # redis-exporter
   ```

2. Vérifier les logs des exporters :
   ```bash
   docker compose logs postgres-exporter
   docker compose logs redis-exporter
   ```

3. Vérifier la connectivité réseau :
   ```bash
   docker compose exec postgres-exporter ping postgres
   docker compose exec redis-exporter ping redis
   ```

### Les alertes ne se déclenchent pas

1. Vérifier que les règles sont chargées dans Prometheus :
   ```
   http://prometheus:9090/rules
   ```

2. Vérifier les logs Prometheus :
   ```bash
   docker compose logs prometheus | grep -i rules
   ```

## 🔄 Mise à jour

Pour mettre à jour les dashboards ou la configuration :

```bash
# Mettre à jour les fichiers localement
git pull

# Re-déployer via Ansible
ansible-playbook -i inventory/production playbooks/deploy_monitoring.yml

# Ou manuellement sur le serveur
cd /opt/docker/monitoring
docker compose down
docker compose up -d
```

---

**Maintenu par** : Équipe SRE Epicea
**Dernière mise à jour** : 2026-01-12
