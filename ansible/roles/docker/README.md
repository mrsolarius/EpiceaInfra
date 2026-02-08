# Role: docker

## Description
Installation du moteur Docker et de Docker Compose, configuration du daemon et création des réseaux virtuels partagés.

## Variables
| Variable | Description | Défaut |
|----------|-------------|--------|
| `docker_proxy_network_name` | Nom du réseau pour le proxy | `traefik-proxy` |
| `docker_monitoring_network_name` | Nom du réseau de monitoring | `monitoring` |

## Dépendances
- Role: `common`
