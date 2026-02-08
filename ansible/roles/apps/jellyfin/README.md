# Role: jellyfin

## Description
Déploie Jellyfin (serveur média) avec support de l'accélération matérielle.

## Variables
| Variable | Description | Défaut |
|----------|-------------|--------|
| `service_domains.jellyfin` | FQDN de l'instance | - |

## Dépendances
- Role: `docker`
- Role: `proxy`
- Role: `storage` (pour les accès aux médias)

## Volumes
- `{{ storage.ansible.compose }}/jellyfin` : Configuration
- `{{ storage.movies }}` : Bibliothèque films
- `{{ storage.tv_shows }}` : Bibliothèque séries
