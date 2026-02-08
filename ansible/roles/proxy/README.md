# Role: proxy

## Description
Déploie Traefik v3 comme reverse proxy central, gérant la terminaison SSL (Let's Encrypt), le routage des services et les middlewares de sécurité.

## Variables Requises
| Variable | Description | Défaut |
|----------|-------------|--------|
| `base_domain` | Domaine de base | - |
| `traefik_acme_email` | Email pour Let's Encrypt | - |
| `traefik_network_name` | Réseau Docker proxy | `{{ docker_proxy_network_name }}` |

## Dépendances
- Role: `docker`

## Volumes
- `{{ storage.ansible.compose }}/traefik` : Configuration et certificats

## Middlewares disponibles
- `redirect-to-https@file`
- `security-headers@file`
- `rate-limit@file`
- `compression@file`
- `traefik-auth@file` (Basic Auth)
