# Guide : comment tout ça fonctionne

Le guide à lire en premier. Le détail technique est dans [DOC_TECHNIQUE.md](../DOC_TECHNIQUE.md).

---

## 1. L'idée en une minute

- On n'installe **rien à la main** sur les serveurs. Tout est décrit dans ce dépôt, et **Ansible** l'applique.
- On peut relancer un déploiement autant de fois qu'on veut : Ansible ne modifie que ce qui a changé.
- Chaque service (Nextcloud, Immich…) tourne dans des **conteneurs Docker**, décrits par un fichier `docker-compose.yml` généré par Ansible.
- **Traefik** reçoit tout le trafic web (ports 80/443), et envoie chaque domaine vers le bon conteneur.
- Il y a deux machines :

| Machine | Rôle |
|---|---|
| **srv-main** | Fait tourner tous les services et garde toutes les données |
| **srv-backup** | Ne fait que recevoir une copie des données chaque nuit |

---

## 2. Où sont les données ?

srv-main a 4 types de disques, chacun avec un usage précis :

| Disque | Monté sur | Contient | Sauvegardé ? |
|---|---|---|---|
| NVMe 1 To | `/` et `/opt/epicea` | Le système, Docker, les configs des services, le monitoring | ⚠️ Seulement `/opt/epicea`, copié chaque nuit (voir §4) |
| SSD 1 To → pool `ssd_tank` | `/mnt/ssd_tank` | Les **bases de données** (PostgreSQL, Redis) | ✅ Oui |
| SSD 256 Go → pool `scratch` | `/mnt/scratch` | Des **caches** (transcodage Jellyfin, modèles IA d'Immich) | ❌ Non, ils se reconstruisent tout seuls |
| 8 HDD 4 To → pool `tank` | `/mnt/tank` | Les **gros fichiers** : films, photos, fichiers Nextcloud | ✅ Oui |

`tank` est en **RAIDZ2** : 2 disques sur 8 peuvent tomber en panne sans perte. Une alerte Discord prévient dès qu'un disque lâche.

### Remplacer un disque (pas de hotswap)
1. L'alerte `ZFSPoolDegraded` arrive sur Discord. Repérer le disque en cause :
   ```bash
   zpool status -v
   ```
2. Éteindre le serveur, remplacer le disque, rallumer.
3. Au démarrage, un **rapport arrive sur Discord**, avec l'état de chaque pool et des services :
   - ✅ **RÉTABLI** : tout est revenu, rien à faire ;
   - ⚠️ **WARNING** : le pool est encore dégradé ou en reconstruction (avec sa progression) ;
   - 🚨 **CRITIQUE** : un pool est absent, donc Docker et le monitoring sont arrêtés. Vérifier les branchements, puis redémarrer : un pool qui réapparaît est réimporté automatiquement au démarrage. Si le disque est vraiment mort, suivre la restauration (§5, cas 3).
4. Un disque **neuf** doit être ajouté au pool à la place de l'ancien. Mettre ensuite son identifiant dans `production.yml` :
   ```bash
   sudo zpool replace tank <ancien-disque> /dev/disk/by-id/<nouveau-disque>
   ```
5. La reconstruction (*resilver*) dure plusieurs heures. Quand elle est terminée, le « ✅ RÉTABLI » de l'alerte arrive sur Discord.

Le rapport de démarrage part directement sur Discord, sans passer par le monitoring : on est prévenu même quand un pool manque et que Docker ne peut pas démarrer.

Les chemins sont centralisés dans [`ansible/inventory/group_vars/all/common.yml`](../ansible/inventory/group_vars/all/common.yml), dans l'objet `storage`. Les services n'écrivent jamais un chemin en dur : ils utilisent par exemple `{{ storage.databases.immich }}`.

---

## 3. Comment marche un déploiement

```bash
make deploy          # srv-main
```
```bash
make deploy-backup   # srv-backup
```

`make deploy` lance [`ansible/playbooks/site.yml`](../ansible/playbooks/site.yml), qui applique des **rôles** dans cet ordre :

```
common   → paquets, pare-feu, fail2ban
docker   → installe Docker
zfs      → crée les pools/datasets, snapshots automatiques
storage  → crée les dossiers, copie nocturne des configs
proxy    → Traefik
monitoring → Prometheus, Grafana, Loki, Alertmanager (alertes Discord)
redis    → Redis partagé
apps/*   → Nextcloud, Immich, Jellyfin, Litopia, Backpaking
```

Pour chaque application, le rôle fait toujours la même chose :
1. crée le dossier `/opt/epicea/docker/<app>/` ;
2. y génère le `.env` (mots de passe, chemins) et le `docker-compose.yml` à partir des templates `.j2` ;
3. lance `docker compose up` ;
4. attend que le conteneur soit en bonne santé.

**Ce qui pilote le déploiement :**

| Fichier | Contenu |
|---|---|
| `ansible/inventory/hosts.yml` | Les IPs des serveurs |
| `ansible/inventory/group_vars/all/common.yml` | Ce qui est commun (chemins de stockage) |
| `ansible/inventory/group_vars/all/versions.yml` | Les versions des images Docker |
| `ansible/inventory/group_vars/production.yml` | srv-main : disques ZFS, domaines, **liste des services activés** (`enabled_services`) |
| `ansible/inventory/group_vars/backup.yml` + `all/replication.yml` | srv-backup et la réplication |
| `ansible/secrets/vault.yml` | Les mots de passe (chiffré) |

Ansible charge ces fichiers seul, selon le groupe de chaque serveur dans l'inventaire : `all/` pour tous, puis `production.yml` ou `backup.yml`.

> **Depuis Windows :** Ansible ne fonctionne pas sous Windows. Les commandes `make` qui l'utilisent (`deploy`, `secrets`, `vault-*`, `validate`, `lint`) le lancent donc dans **WSL**, via `scripts/ansible.sh`. Pour préparer WSL une fois :
> - installer Ansible et ses collections : `sudo bash scripts/bootstrap.sh` ;
> - pour `make lint` : `pipx install ansible-lint` ;
> - pour déployer : copier sa clé SSH dans `~/.ssh` de WSL.
>
> Pour ne pas retaper le mot de passe du vault, l'écrire dans `ansible/.vault_pass` (non versionné). Les commandes `sim-*`, elles, tournent dans la VM.

> **Avant de déployer en vrai**, toujours tester sur le banc de simulation : `make sim-all` (voir [scripts/simulation/README.md](../scripts/simulation/README.md)).

---

## 4. Les sauvegardes, simplement

Chaque nuit, trois choses se passent :

```
toutes les heures   srv-main prend un "snapshot" de tank et ssd_tank (photo instantanée, quasi gratuite)
3h00                srv-main copie /opt/epicea (configs) dans tank/backups/epicea-configs
4h30                srv-backup se connecte à srv-main et récupère les nouveaux snapshots
```

C'est **srv-backup qui vient chercher** les données. srv-main ne peut que les lui donner : il n'a aucun droit sur les sauvegardes. Un pirate qui prendrait srv-main ne pourrait donc pas effacer les backups.

### Ce qui EST sauvegardé
- Tout `tank` : films/séries, photos Immich, fichiers Nextcloud, uploads Backpaking (`tank/apps`), `tank/backups`.
- Tout `ssd_tank` : **toutes les bases de données** et Redis.
- `/opt/epicea` (configs des services, données Grafana…), grâce à la copie de 3h.

### Ce qui N'EST PAS sauvegardé
- `scratch` : caches, reconstruits automatiquement.
- Les données Prometheus et Loki (métriques et logs) : trop volumineuses, et on peut les perdre.
- Le système et les images Docker : `make deploy` reconstruit tout.

### Combien de temps on garde
| | srv-main | srv-backup |
|---|---|---|
| Snapshots horaires | 24 h | 48 h |
| Quotidiens | 30 jours | 90 jours |
| Mensuels | 6 mois | 12 mois |

### Si une sauvegarde ne passe pas
Une alerte Discord arrive :
- `BackupReplicationFailed` : le dernier passage a échoué ;
- `BackupReplicationStale` : aucune réplication réussie depuis plus de 36 h.

Pour voir ce qui s'est passé, sur srv-backup :
```bash
journalctl -u syncoid-pull
```

---

## 5. Restaurer une sauvegarde

Trois situations, de la plus courante à la plus grave. Chacune est testée sur le banc de simulation par `make sim-test-restore`.

**Choisir le bon snapshot.** Les snapshots portent leur date dans leur nom (`autosnap_2026-10-25_03:00:00_hourly`). Pour les lister :
```bash
zfs list -t snapshot -o name,creation tank/photos
```

### Cas 1 : un fichier supprimé ou abîmé
Rien à arrêter. Chaque dataset a un dossier caché `.zfs/snapshot/` où chaque snapshot est consultable comme un dossier normal, en lecture seule.

```bash
ls /mnt/tank/photos/.zfs/snapshot/
```
```bash
cp -a /mnt/tank/photos/.zfs/snapshot/<snapshot>/chemin/du/fichier /mnt/tank/photos/chemin/du/fichier
```

Plus vieux que les snapshots de srv-main (plus de 30 jours) ? Le même fichier se trouve sur srv-backup, dans `/mnt/vault/srv-main/tank/photos/.zfs/snapshot/`. Le récupérer avec `scp`.

### Cas 2 : une application est cassée (mise à jour ratée, mauvaise manip)
On remet **la base et les fichiers** de l'application dans l'état d'un snapshot. Exemple avec Nextcloud :

1. Arrêter l'application :
   ```bash
   cd /opt/epicea/docker/nextcloud && sudo docker compose stop
   ```
2. Revenir au snapshot, pour la base **et** les fichiers, au même instant :
   ```bash
   sudo zfs rollback -r ssd_tank/nextcloud-db@<snapshot>
   ```
   ```bash
   sudo zfs rollback -r tank/cloud@<snapshot>
   ```
3. Redémarrer :
   ```bash
   sudo docker compose start
   ```

⚠️ `rollback -r` **efface tout ce qui a été écrit depuis**, y compris les snapshots plus récents. En cas de doute, copier d'abord ce qu'on veut garder (cas 1).

Quels datasets pour quelle application :

| Application | Base | Fichiers |
|---|---|---|
| Nextcloud | `ssd_tank/nextcloud-db` | `tank/cloud` |
| Immich | `ssd_tank/immich-db` | `tank/photos` |
| Litopia | `ssd_tank/litopia-db` | — |
| Backpaking | `ssd_tank/backpaking-db` | `tank/apps` (photos envoyées) |
| Serveurs de jeu (AMP) | `ssd_tank/amp-db` (MySQL) | `ssd_tank/amp` (instances et mondes, `/home/amp`) |
| Jellyfin | — | `tank/media` (sa config est dans `/opt/epicea`, voir cas 1 avec `tank/backups/epicea-configs`) |

### Cas 3 : un disque ou un pool entier est perdu
Exemple : le SSD des bases de données (`ssd_tank`, un seul disque) meurt. Les données sont sur srv-backup.

1. **Remplacer le disque**, puis mettre son nouvel identifiant dans `zfs_pools` de [`production.yml`](../ansible/inventory/group_vars/production.yml). L'identifiant s'obtient avec :
   ```bash
   ls -l /dev/disk/by-id/
   ```
   Docker ne redémarre pas tant que le pool manque, et c'est voulu.
2. **Recréer le pool vide**, sans lancer les applications :
   ```bash
   make deploy ZFS_CREATE=1 TAGS=zfs
   ```
3. **Restaurer depuis srv-backup**, depuis ton PC (il faut un accès SSH aux deux serveurs). Par défaut, le script prend le snapshot le plus récent ; on peut lui en donner un autre en deuxième argument.
   ```bash
   bash scripts/restore-from-backup.sh ssd_tank
   ```
4. **Tout redémarrer**, ce qui réapplique les réglages ZFS et relance les services :
   ```bash
   make deploy
   ```
5. **Rétablir les droits de réplication.** Ils étaient attachés à l'ancien pool, et un pool recréé ne les a plus :
   ```bash
   make deploy-backup
   ```
6. **Vérifier que la sauvegarde reprend**, sur srv-backup :
   ```bash
   sudo systemctl start syncoid-pull
   ```
   ```bash
   journalctl -u syncoid-pull
   ```

Même procédure pour `tank`, en remplaçant `ssd_tank` par `tank`. Prévoir des heures pour plusieurs To.

Le script prend aussi un snapshot du pool restauré, pour que la réplication reprenne tout de suite. Il remet à zéro le compteur d'échecs de Docker, qui a tenté de démarrer en boucle pendant que le pool manquait.

Le script refuse d'écraser un dataset qui contient déjà des données. Il est fait pour remplir un pool **recréé à vide**, jamais pour écraser un pool en service.

### Cas 4 : srv-main est complètement détruit
1. Réinstaller Ubuntu sur le nouveau serveur.
2. Mettre à jour `hosts.yml` et `production.yml` (IP, identifiants des disques).
3. Recréer les pools vides :
   ```bash
   make deploy ZFS_CREATE=1 TAGS=zfs
   ```
4. Restaurer les deux pools :
   ```bash
   bash scripts/restore-from-backup.sh ssd_tank
   ```
   ```bash
   bash scripts/restore-from-backup.sh tank
   ```
5. Tout redéployer, y compris la configuration de la réplication :
   ```bash
   make deploy
   ```
   ```bash
   make deploy-backup
   ```

Les configs de `/opt/epicea` sont restaurées avec `tank`, dans `tank/backups/epicea-configs`. `make deploy` régénère presque tout. Pour le reste (données Grafana…), recopier depuis ce dossier.

---

## 6. Ajouter un nouveau service

Exemple : on ajoute un service `monapp`, joignable sur `monapp.louisvolat.fr`, avec sa propre base PostgreSQL. Le plus simple est de **copier un rôle existant qui ressemble** (`apps/litopia` est un bon modèle : un front, un back et une base).

### Étape 1 : le rôle
Créer `ansible/roles/apps/monapp/` avec :
```
tasks/main.yml                    # déclare ses fichiers, le rôle partagé app_stack fait le reste
templates/docker-compose.yml.j2   # les conteneurs
templates/monapp.env.j2           # variables d'environnement (mots de passe via le vault)
```

`tasks/main.yml` tient en quelques lignes. Le rôle partagé `app_stack` crée le dossier et la base, génère les fichiers et lance `docker compose` en attendant que tout soit en bonne santé :
```yaml
- name: Déployer Monapp
  ansible.builtin.import_role:
    name: app_stack
  vars:
    app_name: monapp
    app_database: true          # base PostgreSQL dans storage.databases.monapp
    app_files:
      - {src: monapp.env.j2, dest: .env, mode: '0600'}
      - {src: docker-compose.yml.j2, dest: docker-compose.yml}
```

Dans le `docker-compose.yml.j2`, la base et son exporter Prometheus s'écrivent en deux lignes. Le `.env` doit définir `POSTGRES_USER`, `POSTGRES_PASSWORD` et `POSTGRES_DB` :
```jinja
{% import 'postgres.j2' as pg with context %}
services:
  monapp: ...
{{ pg.database('monapp') }}
{{ pg.exporter('monapp') }}
```

Dans le `docker-compose.yml.j2`, trois règles :
- **Les données vont sur le bon disque :**
  - la base → `{{ storage.databases.monapp }}` ;
  - les gros fichiers → un chemin sous `{{ drive_bulk_path }}` ;
  - les caches → sous `{{ drive_scratch_path }}`.
- **Le conteneur web est exposé via Traefik :** réseau `proxy` + labels `traefik.*`, à copier depuis un autre service.
- **La base ne va que sur le réseau `default`**, jamais sur `proxy`. Elle ne doit pas être joignable depuis Internet.

### Étape 2 : déclarer le service
| Fichier | À ajouter |
|---|---|
| `inventory/group_vars/production.yml` | `monapp` dans `enabled_services`, son domaine dans `service_domains` |
| `inventory/group_vars/production.yml` | un dataset pour sa base dans `zfs_datasets` :<br>`- name: "ssd_tank/monapp-db"`<br>`  properties: {recordsize: "16K", logbias: "latency"}` |
| `inventory/group_vars/all/common.yml` | le chemin de la base : `storage.databases.monapp: "{{ drive_ssd_path }}/monapp-db"` |
| `inventory/group_vars/all/versions.yml` | la version de l'image Docker |
| `secrets/vault.yml` (+ `vault.yml.example`) | ses mots de passe |
| `playbooks/site.yml` | le rôle, sur le modèle des autres : `when: "'monapp' in enabled_services"` |

### Étape 3 : tester puis déployer
```bash
make sim-deploy
```
```bash
make sim-test
```
Puis :
```bash
make deploy
```

### Et la sauvegarde ?
**Rien à faire**, si on a respecté l'étape 1 : tout ce qui est sur `tank` ou `ssd_tank` est sauvegardé automatiquement, nouveaux datasets compris.

Le seul piège : un service qui écrit ses données ailleurs, par exemple dans un volume Docker anonyme (`volumes:` sans chemin). Ces données ne sont **pas** sauvegardées. Toujours monter un chemin issu de `storage`.

---

## 7. Les commandes à connaître

| Je veux… | Commande |
|---|---|
| Tout tester sans risque | `make sim-all` |
| Déployer srv-main | `make deploy` |
| Déployer srv-backup | `make deploy-backup` |
| Voir les conteneurs (sur srv-main) | `docker ps` |
| Éditer les mots de passe (le fichier reste chiffré) | `make secrets` |
| Lire les mots de passe | `make vault-view` |
| Chiffrer / déchiffrer `vault.yml` | `make vault-encrypt` / `make vault-decrypt` |
| Vérifier la syntaxe | `make validate` |
| Restaurer un pool depuis srv-backup | `bash scripts/restore-from-backup.sh <pool>` |
| Voir l'état des disques (sur un serveur) | `zpool status` |
| Voir les snapshots (sur un serveur) | `zfs list -t snapshot` |

---

## 8. Quand quelque chose ne va pas

| Symptôme | Explication | Quoi faire |
|---|---|---|
| Alerte `ZFSPoolDegraded` | Un disque est mort ou débranché, mais les données sont intactes | `zpool status -v`, remplacer le disque puis `zpool replace` |
| Rapport 🚨 CRITIQUE au démarrage | Un pool n'a pas été trouvé ; Docker attend exprès, pour ne pas écrire sur le mauvais disque | Vérifier le disque et ses câbles, puis redémarrer. Le pool est réimporté seul (`journalctl -u zfs-import-expected`). |
| Un site renvoie 404 | Le conteneur est « unhealthy », donc Traefik le retire | `docker ps`, puis `docker logs <conteneur>` |
| Pas de sauvegarde depuis 36 h | srv-backup n'arrive plus à joindre srv-main | `journalctl -u syncoid-pull` sur srv-backup |

> Une alerte n'est envoyée sur Discord que si le problème dure assez longtemps : environ 1 à 2 minutes pour une panne de disque. Un problème qui disparaît en quelques secondes ne génère pas de message.
>
> Si un problème se règle pendant un redémarrage, c'est le rapport de démarrage qui le confirme (✅ RÉTABLI). Alertmanager repart de zéro à chaque redémarrage, si bien qu'une panne encore présente au démarrage est notifiée à nouveau.
