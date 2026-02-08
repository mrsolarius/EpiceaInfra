# Role: redis

## Description
Déploie une instance Redis Stack partagée pour les applications du cluster (Nextcloud, Immich, etc.).

## Variables Requises
| Variable | Description | Défaut |
|----------|-------------|--------|
| `storage.databases.redis` | Chemin des données Redis | - |
| `common_system_user` | Utilisateur système | `admin` |

## Dépendances
- Role: `docker`
- Role: `storage`

## Volumes
- `{{ storage.databases.redis }}/data` : Données persistantes Redis
