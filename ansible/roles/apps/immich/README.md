# Role: immich

## Description
Déploie Immich (solution de sauvegarde photo/vidéo) avec ses dépendances (PostgreSQL, Redis, Typesense, Machine Learning).

## Variables Requises
| Variable | Description | Défaut |
|----------|-------------|--------|
| `immich_version` | Version d'Immich | `stable` |
| `service_domains.immich` | FQDN de l'instance | - |

## Dépendances
- Role: `docker`
- Role: `proxy`
- Role: `redis` (Optionnel si utilisé à la place du conteneur redis local)

## Volumes
- `{{ storage.ansible.compose }}/immich` : Configuration
- `{{ storage.databases.immich }}` : Données PostgreSQL
- `{{ storage.photos }}` : Stockage des médias
