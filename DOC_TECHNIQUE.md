# Documentation technique - EpiceaInfra

Référence technique du dépôt. Pour l'utilisation au quotidien (déployer, restaurer, ajouter un service), voir le [guide](docs/GUIDE.md). Pour tester, voir le [banc de simulation](scripts/simulation/README.md).

---

## Matériel

| Serveur | CPU / RAM | Disques | Rôle |
|---------|-----------|---------|------|
| **srv-main** | Intel Xeon E3-1275 v6 (Quick Sync), 64 Go DDR4 | NVMe Sabrent Rocket 4.0 1 To (OS) · SSD Crucial MX500 1 To (`ssd_tank`) · SSD Samsung 850 PRO 256 Go (`scratch`) · 8 x HDD Seagate ST4000NM000A 4 To (`tank`, RAIDZ2) | Services Docker + données |
| **srv-backup** | Intel Core i7-6800K, 16 Go DDR3 | NVMe Crucial E100 480 Go (OS) · 2 x HDD Seagate ST26000NM000C 26 To (`vault`, miroir) | Réception des snapshots ZFS |

Pas de carte graphique : Jellyfin utilise Quick Sync, l'accélération vidéo intégrée au Xeon. Pas de hotswap : un disque se change serveur éteint.

---

## Organisation du dépôt

```
ansible/
├── inventory/hosts.yml        IPs de srv-main (groupe production) et srv-backup (groupe backup)
├── group_vars/
│   ├── common.yml             Chemins de stockage (objet storage), réseaux Docker
│   ├── production.yml         srv-main : domaines, services, pools ZFS, monitoring
│   ├── backup.yml             srv-backup : pool vault, rétention
│   ├── replication.yml        Réplication srv-main -> srv-backup (lu par les deux)
│   ├── versions.yml           Versions des images Docker
│   └── simulation.yml         Surcharges du banc de simulation
├── playbooks/
│   ├── site.yml               srv-main (make deploy)
│   └── backup.yml             srv-backup + droits de réplication sur srv-main (make deploy-backup)
├── roles/                     Voir « Rôles » ci-dessous
└── secrets/vault.yml.example  Liste exacte des secrets attendus
scripts/
├── bootstrap.sh               Installe Ansible sur une machine Ubuntu
├── restore-from-backup.sh     Restaure un pool de srv-main depuis srv-backup
└── simulation/                Banc de test (VMs Multipass)
```

Les variables de `production.yml` sont passées en `-e` par le Makefile : elles priment sur tout le reste.

---

## Stockage

| Variable | Chemin | Support | Contenu | Sauvegardé |
|----------|--------|---------|---------|------------|
| `drive_nvme_path` | `/opt/epicea` | NVMe (ext4, OS) | Compose, configs, monitoring | Copie quotidienne dans `tank` |
| `drive_ssd_path` | `/mnt/ssd_tank` | Pool `ssd_tank` | PostgreSQL, Redis | ✅ |
| `drive_scratch_path` | `/mnt/scratch` | Pool `scratch` | Caches Jellyfin et Immich ML | ❌ |
| `drive_bulk_path` | `/mnt/tank` | Pool `tank` (RAIDZ2) | Médias, photos, Nextcloud, `backups/` | ✅ |

Les chemins des services sont centralisés dans l'objet `storage` de `common.yml` (`storage.databases.*`, `storage.media.*`, `storage.cache.*`).

**Datasets** (`zfs_datasets` dans `production.yml`) :
- un dataset par base de données, avec `recordsize` 16K adapté aux pages PostgreSQL ;
- `recordsize` 1M pour les médias ;
- `sync=disabled` pour les caches ;
- `tank/cloud` appartient à `www-data` (UID 33).

---

## Rôles

`site.yml` les applique dans cet ordre (le rôle `zfs` passe avant `docker`, voir plus bas) :

| Rôle | Ce qu'il fait |
|------|---------------|
| `common` | Mise à jour système, paquets de base, fuseau horaire, node exporter, UFW (SSH/HTTP/HTTPS, node exporter limité au LAN et à Docker, `ufw_additional_rules`), fail2ban |
| `zfs` | Pools, datasets, limite ARC, snapshots sanoid, import des pools au démarrage, garde-fou Docker, rapport de démarrage |
| `docker` | Docker CE (dépôt officiel), rotation des logs, réseaux `traefik-proxy` et `monitoring` |
| `storage` | Arborescence des dossiers, copie quotidienne de `/opt/epicea` vers `tank/backups/epicea-configs` |
| `proxy` | Traefik : HTTP redirigé vers HTTPS, Let's Encrypt (HTTP challenge), dashboard protégé par `traefik_auth`, accès Docker via un socket proxy en lecture seule |
| `monitoring` | Prometheus, Alertmanager (Discord), Grafana (dashboards provisionnés), Loki + Promtail, cAdvisor, redis-exporter |
| `redis` | Redis partagé : AOF, `maxmemory 400mb`, `noeviction` (requis par la file de tâches d'Immich) |
| `apps/*` | Nextcloud, Immich, Jellyfin, Litopia, Backpaking, activés via `enabled_services` |
| `amp` | Serveurs de jeu AMP (CubeCoders), installés en natif (non dockerisable) : dépôt CubeCoders, Java Temurin, services systemd, `/home/amp` sur `ssd_tank/amp`. MySQL des plugins dans Docker (`127.0.0.1:3306`). Panneau et Bluemap publiés par Traefik (`amp_web_routes`). AMP ouvre lui-même les ports de jeu dans UFW. |
| `backup_server` | srv-backup : socle système, réplication syncoid en mode pull (`tasks/source.yml` s'exécute sur srv-main) |

Chaque application suit le même schéma :
1. dossier `/opt/epicea/docker/<app>/` ;
2. `.env` et `docker-compose.yml` générés depuis les templates ;
3. `docker compose up` avec attente de la bonne santé des conteneurs (`wait: true`).

Les applications avec une base de données ont leur propre PostgreSQL et un postgres-exporter.

### `zfs` en détail

| Variable | Rôle | srv-main |
|----------|------|----------|
| `zfs_pools` | Pools : `name`, `vdev_type`, `mountpoint`, `disks` (chemins `/dev/disk/by-id`) | tank, ssd_tank, scratch |
| `zfs_datasets` | Datasets : `name`, `properties`, `owner`, `group` | voir `production.yml` |
| `zfs_allow_pool_creation` | Autorise la création des pools absents (**efface les disques**). Make : `ZFS_CREATE=1` | `false` |
| `zfs_arc_max_bytes` | Limite de l'ARC | 12 Gio (RAM laissée aux serveurs de jeu) |
| `sanoid_templates` / `sanoid_datasets` | Rétention des snapshots | 24 h / 30 j / 6 mois |
| `zfs_guard_docker` | Docker ne démarre que si tous les datasets sont montés | `true` |
| `zfs_boot_report` | Rapport Discord à chaque démarrage | `true` |

Sécurités au démarrage :
- **`zfs-import-expected.service`** importe les pools attendus absents du cache ZFS : un disque débranché lors d'un démarrage précédent, ou un système réinstallé sur des disques existants. Le rôle l'utilise aussi avant de conclure qu'un pool manque.
- **Garde-fou Docker** : `ExecStartPre=/usr/local/sbin/zfs-check-mounts`. Sans lui, un pool absent ferait écrire les conteneurs sur le disque système. C'est pour cela que `zfs` passe avant `docker`.
- **`boot-report.service`** envoie directement sur le webhook Discord l'état des pools (avec la progression d'une reconstruction) et des conteneurs, en ✅ RÉTABLI, ⚠️ WARNING ou 🚨 CRITIQUE. Il ne dépend pas de Docker : il prévient même quand le monitoring est arrêté.
- Le scrub mensuel est planifié par le paquet Ubuntu (`/etc/cron.d/zfsutils-linux`).

`zpool create` est lancé sans `-f` : il refuse un disque qui porte déjà un système de fichiers ou un ancien pool.

---

## Sauvegarde et réplication

```
toutes les heures   sanoid : snapshot atomique de tank et ssd_tank (recursive = zfs)
3h00                rsync de /opt/epicea vers tank/backups/epicea-configs
4h30                srv-backup : syncoid tire les snapshots (syncoid-pull.timer)
```

- **Mode pull :** srv-backup se connecte à srv-main avec l'utilisateur `syncoid`.
  - Cet utilisateur n'a que les droits ZFS `send,hold,release`.
  - Sa clé n'est acceptée que depuis l'IP de srv-backup.
  - Un srv-main compromis ne peut donc pas atteindre les sauvegardes.
- **Seuls les datasets enfants sont répliqués** (`--skip-parent`). Les racines de pools ne contiennent pas de données, et cela permet à la réplication de reprendre après une restauration.
- **Côté srv-backup :** réception dans `vault/srv-main/<pool>/<dataset>`.
  - Les copies sont en lecture seule (`readonly` hérité).
  - Elles sont consultables dans `/mnt/vault/srv-main/`.
  - La rétention est plus longue : 48 h, 90 j, 12 mois, 1 an.
- **Métriques :** `syncoid_last_success_timestamp_seconds` et `syncoid_last_run_status`, exposées par le collecteur textfile du node exporter.
- **Capacité :** `vault` (~23,6 Tio) reçoit `tank` (~21 Tio utiles). La marge pour l'historique diminue à mesure que `tank` se remplit.

Restauration : voir le [guide, §5](docs/GUIDE.md#5-restaurer-une-sauvegarde) et `scripts/restore-from-backup.sh`.

---

## Monitoring et alertes

- **Collecte :** Prometheus scrape Traefik, cAdvisor, les postgres-exporters, redis-exporter, Grafana, le node exporter de srv-main et ceux listés dans `monitoring_extra_node_targets` (srv-backup).
- **Envoi des alertes :** Alertmanager les envoie sur Discord. Son état est en mémoire (tmpfs) : une alerte résolue pendant un redémarrage ne bloque pas la suivante.

| Fichier de règles | Règles | Dont critiques |
|-------------------|--------|----------------|
| `postgres-alerts.yml` | 13 | 1 |
| `redis-alerts.yml` | 16 | 2 |
| `container-alerts.yml` | 8 | 2 |
| `zfs-alerts.yml` (pool dégradé, réplication en retard ou en échec) | 3 | 2 |
| `amp-alerts.yml` (port de jeu fermé, instance arrêtée, supervision interrompue) | 3 | 1 |

**Serveurs de jeu (AMP) :**
- **Collecteur :** `/usr/local/sbin/amp-metrics` (rôle `amp`) relit à chaque passage `instances.json` et la configuration de chaque instance. Une nouvelle instance est donc suivie sans rien configurer.
- **Fréquence :** l'état, les ports et le CPU/RAM par processus (java, steamcmd, serveurs Steam, AMP) sont relus chaque minute ; la taille des instances et de leurs sauvegardes, toutes les 15 min.
- **Lecture :** les métriques passent par le collecteur textfile du node exporter. Tableau de bord : « Serveurs de jeu (AMP) ».
- **Alertes sur les ports :** seuls les ports de jeu en déclenchent. Les ports ajoutés à la main dans AMP (Dynmap, chat vocal) sont affichés sans alerte.
- **Arrêt volontaire :** arrêter un serveur depuis le panneau déclenche aussi `AmpGamePortDown`, car AMP n'expose pas son état sans compte d'API.
- **Tests des règles :** `amp-alerts.test.yml`, avec `promtool test rules`.

Les fichiers de règles, dans `ansible/roles/monitoring/files/`, font foi.

---

## Sécurité

- **UFW :**
  - ouvert : SSH, HTTP, HTTPS ;
  - node exporter (9100) : LAN et réseaux Docker uniquement ;
  - tout le reste est fermé, sauf depuis le LAN (`ufw_additional_rules`).
- **Ports publiés :**
  - seuls 80/443 (Traefik) et 7359/udp (découverte Jellyfin) ;
  - bases de données, Redis et API Traefik ne sont joignables que par les réseaux Docker.
- **Traefik :**
  - dashboard uniquement en HTTPS, derrière une authentification basique (`traefik_auth`) ;
  - accès à Docker via `docker-socket-proxy`, jamais au socket directement.
- **Secrets :** chiffrés dans `ansible/secrets/vault.yml` (Ansible Vault). La liste des clés attendues est dans `vault.yml.example`.

---

## CI

`.github/workflows/ci.yml` exécute `ansible-lint` puis `ansible-playbook --syntax-check` sur les deux playbooks. Dependabot met à jour les GitHub Actions ; les versions des images Docker se changent dans `ansible/group_vars/versions.yml`.

Les tests fonctionnels se font sur le banc de simulation : `make sim-all`, `make sim-test-restore` et `make sim-test-migration`.
