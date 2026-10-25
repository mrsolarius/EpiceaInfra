# Migration Proxmox → srv-main

Objectif : vider les VMs Proxmox vers **srv-backup**, réinstaller la machine en **srv-main** avec Ansible, puis y remettre les données.

> ⚠️ La réinstallation **efface tous les disques** de la machine Proxmox. Pendant la migration, la copie sur srv-backup est **la seule copie** des données. On n'efface rien tant que l'étape 3 n'est pas entièrement validée.

---

## 1. Ce qu'il y a à sauver (inventaire du 25/10/2026)

| VM | IP | Données | Taille | Où ça va sur srv-main |
|----|----|---------|--------|-----------------------|
| datastore | .220 | `Mediatheque/` Films, Séries, Musiques | 7,5 To | `tank/media` (Jellyfin) |
| | | `Data/` (fichiers perso, LitopiaS6, backups, photos d'appareil…) | 1,2 To | Nextcloud, dans le dossier `Data` de ton compte |
| | | Jellyfin natif 10.10.7 (`/var/lib/jellyfin`) | 8 Go | Gardé en archive, bibliothèque recréée |
| nextcloud | .230 | Fichiers des utilisateurs (`/home/nextcloud/data`) | 1,1 To | `tank/cloud` |
| | | Base MariaDB, Nextcloud **35.0.2** | < 1 Go | Convertie en PostgreSQL (étape 6) |
| | | `/home/louis/export_maps` | 241 Go | Archive (à trier) |
| photoprism | .225 | `Pictures/` (originaux) | 281 Go | `tank/photos/a-importer`, puis import dans Immich |
| | | Base PhotoPrism (albums, favoris) | 185 Mo | Archive (Immich ne la lit pas) |
| webservice | .250 | PostgreSQL 12 : `LitopiaDB`, `backpackingv2` | quelques Mo | Bases `litopia-db` et `backpaking-db` |
| | | Uploads Backpaking (`/opt/backpaking/uploads`) | 16 Go | `tank/apps/backpaking-uploads` |
| | | `LitopiaMapDB` : carte **BlueMap** (le serveur Litopia y écrit via `192.168.1.250`) | à mesurer | **Non restaurée** : la carte se régénère. Après la migration, changer le stockage dans la config BlueMap de l'instance Litopia (l'IP .250 n'existera plus) |
| | | remina-survey, reversi, laforge, projets dans `/home/louis` | ~5 Go | Archive |
| gameserver | .200 | AMP : 5 instances déclarées (ADS01, Litopia, LitopiaCrea, Tuturu01, ServeurDragonWild01), plus 5 dossiers d'anciennes instances | 146 Go, dont 96 Go de sauvegardes internes d'AMP | `ssd_tank/amp`, monté sur `/home/amp` (rôle `amp`) |
| | | MySQL 8.0 : `BluemapLitopia` (vide) et `DynmapLitopia` (104 Go de tuiles Dynmap) | 104 Go | Conteneur `amp-mysql` (`ssd_tank/amp-db`). Dynmap semble remplacé par BlueMap : `AMP_SKIP_DBS=DynmapLitopia` l'exclut |

> **Répétition AMP du 25/10/2026** (prod → srv-backup-sim → srv-main-sim), faite sans les dossiers `Backups` et sans `DynmapLitopia` :
> - 31 Go copiés, `verify` sans différence hors fichiers modifiés par les serveurs en marche ;
> - les 5 instances sont reconnues et les mondes sont identiques au snapshot ;
> - au premier démarrage, AMP réécrit lui-même ses fichiers de configuration (`AMPConfig.conf`, `*.kvp`) et purge ses vieux journaux.
>
> Options utilisées pour une copie sans coupure : `ONLY=gameserver KEEP_RUNNING=1` (exports MySQL à chaud, AMP non arrêté).
| reverseproxy | .254 | nginx + certificats | négligeable | Archive (Traefik refait les certificats) |

**Total : environ 11 To.**
- srv-backup (`vault`, ~23,6 Tio) les reçoit sans problème.
- `tank` (RAIDZ2, ~20 Tio utiles) sera rempli à environ 50 %.

Sur chaque VM, le script copie aussi `/etc` et les crontabs, pour garder une trace des anciennes configurations.

## 2. Ce que la nouvelle infra ne reprend pas

Ces éléments sont **sauvegardés quand même** dans `vault/migration`, rien n'est perdu. Leur avenir est à décider :

| Élément | Situation |
|---------|-----------|
| PhotoPrism | Remplacé par Immich. On réimporte les photos ; les albums et les favoris PhotoPrism ne suivent pas. |
| remina-survey (`survey.remina.fr`), reversi, laforge | Pas de rôle Ansible. |
| Partages Samba (Mediatheque, DataStore, photos) | Remplacés par Nextcloud et Jellyfin. |
| qBittorrent (datastore) | Configuration archivée. |
| OnlyOffice (.235, éteint) | Non sauvegardé (VM injoignable). |

## 3. Déroulé

### Étape 0 - Installer srv-backup

Avec notre playbook, en ciblant srv-backup seul tant que srv-main n'existe pas :

```bash
make deploy-backup ZFS_CREATE=1 LIMIT=backup
```

Puis, sur srv-backup, créer la clé SSH qui servira à tirer les données :

```bash
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
sudo cat /root/.ssh/id_ed25519.pub
```

### Étape 1 - Ouvrir les VMs à srv-backup (temporaire)

Sur **chaque VM** (.220, .230, .225, .250, .200, .254), en tant que `louis` :

```bash
echo "<clé publique de srv-backup>" >> ~/.ssh/authorized_keys
echo "louis ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/99-migration
```

Le sudo sans mot de passe est nécessaire : beaucoup de fichiers (Nextcloud, bases, AMP) ne sont lisibles qu'en root. Les VMs vont disparaître, donc ce n'est pas gênant.

Copier le dossier `scripts/migration/` sur srv-backup, par exemple avec `scp -r scripts/migration louis@192.168.1.101:`.

### Étape 2 - Copie à chaud (sans coupure)

Sur srv-backup :

```bash
sudo tmux new -s migration
sudo ./migration/pull-old-servers.sh sync
```

- La première copie prend environ **30 h** pour 11 To sur un réseau gigabit. `tmux` laisse la copie tourner si la connexion SSH coupe.
- Les services restent en ligne pendant ce temps.
- Relancer `sync` la veille du jour J : seules les différences sont recopiées.

### Étape 3 - Jour J : passe finale et vérification

```bash
sudo AMP_SKIP_DBS=DynmapLitopia ./migration/pull-old-servers.sh final    # coupe les services, exporte les bases, dernière copie, snapshot
sudo ./migration/pull-old-servers.sh verify   # doit afficher 0 différence partout
```

`AMP_SKIP_DBS=DynmapLitopia` laisse de côté les 104 Go de tuiles Dynmap. Le retirer pour les garder.

Ce que fait `final` :
- arrête les services : Nextcloud en maintenance, Backpaking, Litopia, PhotoPrism, AMP, Jellyfin ;
- exporte les bases : MariaDB Nextcloud, PostgreSQL Litopia et Backpaking, base remina, base PhotoPrism, MySQL du gameserver ;
- fait la dernière copie et un snapshot ZFS `vault/migration@final-<date>`.

`verify` compare le **contenu** de chaque fichier. Seule la médiathèque, remplaçable et énorme, est comparée sur la taille et la date.

**Checklist avant d'effacer quoi que ce soit :**
- [ ] `verify` : 0 différence.
- [ ] `/mnt/vault/migration/MANIFEST.txt` : chaque machine a un nombre de fichiers cohérent.
- [ ] Les dumps sont présents et non vides dans `/mnt/vault/migration/*/var/backups/migration/` : `nextcloud.sql`, `LitopiaDB.dump`, `backpackingv2.dump`, `amp-databases.sql`, `amp-users.sql`.
- [ ] Tu as ouvert quelques photos et documents depuis `/mnt/vault/migration/`.
- [ ] **Recommandé :** une copie des données irremplaçables sur un disque externe (photos, `Data/`, Nextcloud, AMP, soit environ 3 To). Le miroir de srv-backup protège contre une panne de disque, pas contre une erreur de manipulation.

### Étape 4 - Réinstaller la machine en srv-main

1. Éteindre Proxmox et installer Ubuntu Server 24.04 sur le NVMe Sabrent, avec l'IP 192.168.1.100.
2. Lancer `sudo bash scripts/bootstrap.sh`.
3. Vault (déjà fait le 25/10/2026) : rien ne vient d'AMP, tout se connaît à l'avance.
   - `amp_mysql_root_password` : un nouveau mot de passe, généré. C'est le root du MySQL que crée le rôle ; les comptes des plugins sont repris tels quels à l'étape 5.
   - `litopia_amp_host` reste `dashboard.litopia.fr` : Traefik publie ce domaine vers AMP sur srv-main.
   - `litopia_amp_login` et `litopia_amp_pass` restent inchangés. Le compte AMP est copié avec `/home/amp`.
4. Lancer `make deploy ZFS_CREATE=1`. Cette commande **efface les 8 HDD, le MX500 et le 850 PRO** et crée les pools. Le rôle `amp` installe AMP et Java, mais ne crée aucune instance : elles arrivent à l'étape 5.

### Étape 5 - Restaurer les fichiers et les bases

Sur srv-main, autoriser temporairement sa clé root sur srv-backup :

```bash
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
sudo cat /root/.ssh/id_ed25519.pub
```

Ajouter cette clé dans `/root/.ssh/authorized_keys` de srv-backup. Copier ensuite `scripts/migration/` sur srv-main, puis lancer :

```bash
sudo NC_USER=<ton compte nextcloud> ./migration/restore-on-srv-main.sh files
sudo ./migration/restore-on-srv-main.sh databases
sudo ./migration/restore-on-srv-main.sh amp
```

- `files` copie environ 9 To : compter **une journée**. La commande est relançable.
- `NC_USER` choisit le compte Nextcloud qui reçoit l'ancien dossier `Data` du datastore. Sans `NC_USER`, ce dossier n'est pas copié.
- `databases` restaure Litopia et Backpaking dans leurs conteneurs PostgreSQL 16, à partir des dumps de PostgreSQL 12.
- `amp` remet `/home/amp` tel quel, avec les instances, les mondes et la configuration d'AMP, puis recharge les bases et les comptes MySQL des plugins et redémarre AMP.
  - Les plugins continuent de se connecter à `127.0.0.1:3306`.
  - AMP rouvre lui-même dans UFW les ports de jeu de ses instances (`ampfirewall`).
  - Il peut demander de réactiver la licence, puisque le matériel a changé : la clé se trouve dans ton espace CubeCoders.
  - Vérifier la RAM allouée à chaque serveur. Les instances sont réglées jusqu'à 32 Go (Fabric) et 20 Go : leur total doit rester sous ~40 Go, sur les 64 Go de srv-main.

### Étape 6 - Nextcloud : MariaDB → PostgreSQL

L'ancien Nextcloud tourne sur MariaDB, le nouveau sur PostgreSQL. Le script `nextcloud-convert.sh` fait la reprise :
1. il remonte l'ancienne base dans un MariaDB temporaire ;
2. il reprend l'identité de l'ancienne instance (`instanceid`, `passwordsalt`, `secret`, indispensables pour les données) ;
3. il laisse Nextcloud convertir la base (`occ db:convert-type`) ;
4. il termine par un scan des fichiers et une réparation.

Sur srv-main, après l'étape 5 :

```bash
scp root@192.168.1.101:/mnt/vault/migration/nextcloud/var/backups/migration/nextcloud.sql /root/
scp root@192.168.1.101:/mnt/vault/migration/nextcloud/var/www/nextcloud/config/config.php /root/old-config.php
sudo ./migration/nextcloud-convert.sh /root/nextcloud.sql /root/old-config.php
```

Les applications installées depuis le store et absentes de l'image se réinstallent : `occ app:list`, puis `occ app:install <app>`.

### Étape 7 - Jellyfin et Immich

- **Jellyfin :** l'assistant de premier démarrage s'ouvre. Créer les bibliothèques `/media/movies`, `/media/shows` et `/media/music`. L'ancienne configuration (utilisateurs, historique de lecture) est archivée dans `vault/migration/datastore/var/lib/jellyfin`. Les chemins ont changé, donc on ne la réutilise pas telle quelle.
- **Immich :** créer ton compte, générer une clé d'API, puis importer `/mnt/tank/photos/a-importer` avec l'outil en ligne de commande d'Immich (`immich upload --recursive`) ou avec `immich-go`. Supprimer le dossier une fois l'import vérifié. Les photos d'appareil qui étaient dans `Data/` peuvent être importées de la même façon.

### AMP : le parcours complet

Les étapes ci-dessus migrent AMP avec le reste. Résumé pour AMP seul, dans l'ordre (procédure répétée avec succès le 25/10/2026) :

| Quand | Commande | Ce qui se passe |
|-------|----------|-----------------|
| Étape 2 | `pull-old-servers.sh sync` | `/home/amp` (instances, mondes, config AMP) copié à chaud vers `vault/migration/gameserver` |
| Étape 3 | `AMP_SKIP_DBS=DynmapLitopia pull-old-servers.sh final` | `ampinstmgr stopall`, export MySQL (`amp-databases.sql`, `amp-users.sql`) via le compte de maintenance Debian, dernière copie |
| Étape 4 | `make deploy` | Le rôle `amp` installe AMP, Java et le conteneur `amp-mysql`, sans instance |
| Étape 5 | `restore-on-srv-main.sh amp` | `/home/amp` remis tel quel, bases et comptes MySQL rechargés, AMP redémarré |

AMP seul, sans le reste des machines : `ONLY=gameserver` sur les commandes `pull-old-servers.sh`.

**Vérifier après la restauration :**

```bash
sudo -u amp -H bash -c 'cd ~ && ampinstmgr status'   # les 5 instances : ADS01, Litopia, LitopiaCrea, Tuturu01, ServeurDragonWild01
```

Puis ouvrir `https://dashboard.litopia.fr` et se connecter avec les **identifiants AMP habituels**, copiés avec `/home/amp`. Démarrer les instances depuis le panneau.

**À savoir :**
- **Licence (obligatoire) :** chaque instance est liée à l'ancienne machine et refuse de démarrer ailleurs (`NoMatchingMachineId` dans `AMP_Logs`, vu pendant la répétition). Sur srv-main, réactiver chaque instance :

  ```bash
  sudo -u amp -H bash -c 'cd ~ && for i in ADS01 Litopia LitopiaCrea Tuturu01 ServeurDragonWild01; do ampinstmgr reactivate $i; done'
  ```

  À ne faire que sur le vrai srv-main, jamais dans la simulation : la licence suit la dernière machine activée.
- **Premier démarrage :** AMP réécrit lui-même ses fichiers de configuration (`AMPConfig.conf`, `*.kvp`, `server.properties`) et purge ses vieux journaux. C'est normal, les mondes ne sont pas touchés.
- **BlueMap :** sa carte était dans PostgreSQL sur webservice (`LitopiaMapDB`, `192.168.1.250`), qui disparaît. La base n'est pas migrée, la carte se régénère. Dans la config BlueMap de l'instance Litopia, passer au stockage sur fichiers.
- **Dynmap :** non migré avec `AMP_SKIP_DBS=DynmapLitopia`. La carte se régénère depuis le monde si le plugin est encore utilisé.
- **Anciennes instances :** les 5 dossiers non déclarés dans AMP (Cobbelmod01, LitopiaAdmin01, LitopiaEvent, LitopiaHytale01, MegaStunt) sont copiés mais restent inactifs, comme aujourd'hui.

### Étape 8 - Bascule réseau

Sur la box :
- rediriger les ports **80 et 443 vers 192.168.1.100**, à la place de .254 ;
- rediriger les **ports de jeu vers 192.168.1.100**, à la place de .200 : Minecraft 25565, 25566, 25569, 25570, Dragonwilds 7777/udp, etc.

Les noms de domaine ne changent pas, et Traefik obtient les certificats seul, y compris pour `dashboard.litopia.fr` et `bluemap.litopia.fr`.

### Étape 9 - Après une ou deux semaines sans problème

```bash
sudo zfs destroy -r vault/migration          # sur srv-backup
make deploy-backup                           # active la réplication srv-main -> srv-backup
```

Puis, sur srv-main, retirer de `/root/.ssh/authorized_keys` de srv-backup la clé ajoutée à l'étape 5.

Pourquoi attendre : `vault/migration` sert de filet de sécurité pendant la période de validation. Il faut le supprimer **avant** la première réplication : les deux ensemble rempliraient `vault` à environ 85 %, et ZFS ralentit au-delà de 80 %.
