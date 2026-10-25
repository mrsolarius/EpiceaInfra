# Banc de simulation de la production

Deux VMs Multipass reproduisent **srv-main** et **srv-backup** pour tester la configuration Ansible de production avant de l'appliquer sur le vrai matériel.

```bash
make sim-all            # VMs + disques simulés, déploiement des deux serveurs, tests de bout en bout
make sim-test-restore   # tester les procédures de restauration (docs/GUIDE.md §5)
make sim-test-migration # tester la migration AMP : ancien gameserver -> srv-backup -> srv-main (docs/MIGRATION.md)
make sim-down           # tout détruire
```

Durée d'un `make sim-all` depuis zéro : environ 15 minutes (surtout le téléchargement des images Docker).

## Ce qui est simulé

| | Production | Simulation |
|---|---|---|
| **srv-main** | Xeon E3-1275 v6, 64 Go | VM `srv-main-sim` : 4 vCPU, 6 Go |
| HDD | 8 x Seagate ST4000NM000A 4 To | 8 x 5 Go |
| SSD bases de données | Crucial MX500 1 To | 2 Go |
| SSD cache | Samsung 850 PRO 256 Go | 4 Go (Jellyfin exige 2 Gio libres) |
| **srv-backup** | i7-6800K, 16 Go | VM `srv-backup-sim` : 2 vCPU, 2 Go |
| HDD | 2 x Seagate ST26000NM000C 26 To | 2 x 33 Go |

Les disques sont des fichiers creux attachés en loop device. Une règle udev leur donne **exactement les mêmes noms `/dev/disk/by-id`** que les vrais disques (modèle + numéro de série, partitions `-partN` comprises). Les variables `zfs_pools` de production s'appliquent donc sans modification (`simulate-disks.sh`).

Le déploiement utilise `production.yml` tel quel, plus quelques surcharges dans [`inventory/group_vars/simulation.yml`](../../ansible/inventory/group_vars/simulation.yml), appliquées par le groupe `simulation` de l'inventaire généré :
- domaines `*.epicea-sim.local` ;
- pas de Let's Encrypt ;
- ARC limité à 1 Gio ;
- création des pools autorisée.

Les IPs des VMs sont générées dans `inventory/simulation.yml` (non versionné), en variables d'hôte.

Non simulé :
- **Quick Sync :** pas d'iGPU dans une VM, ce qui permet de tester le repli de Jellyfin en transcodage CPU.
- **SMART :** les disques simulés n'ont pas de données SMART.
- **Let's Encrypt.**

## Les tests (`make sim-test`)

1. **Disques et pools :** noms by-id, RAIDZ2 de 8 disques, `ashift`, propriétés des datasets, limite ARC.
2. **Conteneurs :** tous lancés et sains, bases sur `ssd_tank`, caches sur `scratch`, médias sur `tank`.
3. **Traefik :** chaque domaine répond en HTTPS.
4. **Monitoring :** toutes les cibles Prometheus UP (srv-backup compris), métriques ZFS, règles d'alerte chargées.
5. **Snapshots :** sanoid sur `tank` et `ssd_tank` (pas sur `scratch`), copie quotidienne de `/opt/epicea`.
6. **Sauvegarde :**
   - réplication complète puis incrémentale vers srv-backup ;
   - fichier témoin relu côté backup ;
   - copies en lecture seule ;
   - métriques remontées à Prometheus.
7. **Sécurité :** l'utilisateur `syncoid` ne peut ni détruire de snapshot ni écrire dans les données.
8. **Panne de disque :**
   - un disque est mis hors ligne et `tank` passe DEGRADED tout en restant lisible ;
   - l'alerte `ZFSPoolDegraded` se déclenche, et sa notification part vers Discord ;
   - le pool redevient ONLINE après remise en ligne, et la notification de rétablissement part aussi.
9. **Redémarrage de srv-main :** pools réimportés, Docker relancé seulement après le montage des datasets, conteneurs sains, rien écrit sur le disque système.

## Les tests de restauration (`make sim-test-restore`)

Ils rejouent les procédures du [guide](../../docs/GUIDE.md#5-restaurer-une-sauvegarde) :
1. **Fichier supprimé :** récupéré depuis `.zfs/snapshot`.
2. **Mise à jour ratée :** retour arrière de la base et des fichiers de Nextcloud au même snapshot.
3. **SSD des bases mort :**
   - le pool est détruit et le disque effacé ;
   - `make sim-deploy TAGS=zfs` recrée le pool vide ;
   - `scripts/restore-from-backup.sh` restaure les données depuis srv-backup ;
   - `make sim-deploy` et `make sim-deploy-backup` relancent les services et la réplication.

   On vérifie ensuite que les données sont revenues, que les services sont sains et que la réplication reprend.

Les alertes partent vers le webhook Discord de `ansible/secrets/vault.yml` : le test de panne de disque envoie une vraie notification (déclenchement puis rétablissement).

## Suivre la progression

`setup-sim.sh` horodate chaque étape. Si une étape ne bouge plus pendant plusieurs minutes, regarder ce qui tourne dans la VM :

```bash
multipass exec srv-main-sim -- ps -eo etime,cmd --sort=-etime
```

## Particularités de Multipass sous Windows

- **Fichiers vers une VM :** les scripts passent les fichiers et les commandes en base64. Sous Windows, `multipass transfer`, l'entrée standard de `multipass exec` et les guillemets imbriqués sont peu fiables.
- **Scripts du dossier monté :** un script n'est jamais exécuté directement depuis le dossier du projet monté dans la VM. Si le fichier est modifié côté Windows pendant la lecture, bash reste bloqué.

## Le test de migration AMP (`make sim-test-migration`)

Crée une VM `gameserver-sim` qui reproduit l'ancien serveur de jeu : Ubuntu 20.04, AMP installé depuis le dépôt CubeCoders, MySQL 8.0 natif avec une base de plugin.

1. **Copie à chaud** : `pull-old-servers.sh sync` tourne pendant qu'un faux serveur de jeu écrit dans son monde et qu'un faux plugin écrit dans MySQL.
2. **Passe finale** : `final` arrête AMP, exporte MySQL et prend le snapshot ; `verify` doit trouver 0 différence.
3. **Restauration** : `restore-on-srv-main.sh amp` sur srv-main. Le test vérifie que c'est la même instance AMP, que le monde est identique, qu'AMP redémarre et que le plugin se reconnecte avec son ancien compte.

`make sim-down` supprime aussi `gameserver-sim`.
