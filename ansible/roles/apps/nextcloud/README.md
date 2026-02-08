# Role: nextcloud

## Description
Déploie Nextcloud avec une base de données PostgreSQL dédiée et utilise l'instance Redis partagée pour le cache.

## Variables Requises
| Variable | Description | Défaut |
|----------|-------------|--------|
| `nextcloud_admin_user` | Utilisateur admin Nextcloud | `admin` |
| `nextcloud_admin_password` | Mot de passe admin | `{{ vault_nextcloud_admin_password }}` |
| `service_domains.nextcloud` | FQDN de l'instance | - |

## Dépendances
- Role: `docker`
- Role: `proxy` (Traefik)
- Role: `redis` (Cache)

## Volumes
- `{{ storage.ansible.compose }}/nextcloud` : Fichiers de configuration et compose
- `{{ storage.databases.nextcloud }}` : Données PostgreSQL
