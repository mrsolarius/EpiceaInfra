# Role: monitoring

## Description
Déploie une stack complète de monitoring incluant Prometheus, Alertmanager, Grafana, Loki et Promtail pour la centralisation des logs et des métriques.

## Variables Requises
| Variable | Description | Défaut |
|----------|-------------|--------|
| `grafana_admin_password` | Mot de passe admin Grafana | - |
| `discord_webhook_url` | URL Webhook pour alertes | - |

## Dépendances
- Role: `docker`
- Role: `proxy` (Traefik)

## Volumes
- `{{ storage.monitoring }}/prometheus` : Données Prometheus
- `{{ storage.monitoring }}/grafana` : Données Grafana
- `{{ storage.monitoring }}/loki` : Données Loki

## Dashboards inclus
Les dashboards sont situés dans `files/dashboards/` et incluent :
- Traefik
- Docker
- PostgreSQL Performance
- Redis Performance
- Node Exporter (Bare Metal)
