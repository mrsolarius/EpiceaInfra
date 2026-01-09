# 🧪 Environnement de test Multipass Epicea

## Vue d'ensemble

Ce dossier contient les scripts pour créer un environnement de test complet avec **2 VMs Multipass** :

### VM 1 : `storage-test` (NAS simulé)
- **Rôle** : Serveur NFS simulant les Ubiquiti NAS Pro/Quad
- **Specs** : 2 CPU, 4GB RAM, 20GB disque
- **Exports NFS** :
  - `/exports/media` → Films/Séries (Jellyfin)
  - `/exports/photos` → Photos (Immich)
  - `/exports/cloud` → Fichiers (Nextcloud)
  - `/exports/backups` → Sauvegardes

### VM 2 : `epicea-test` (Serveur applicatif)
- **Rôle** : Serveur bare-metal simulé avec tous les services
- **Specs** : 4 CPU, 8GB RAM, 100GB disque
- **Mount** : Projet monté automatiquement dans `/home/ubuntu/infra`
- **Services** : Docker, Traefik, Immich, Jellyfin, Nextcloud, Monitoring...

---

## 🚀 Utilisation

### 1. Installation Multipass

**Windows** :
```powershell
winget install Canonical.Multipass
```

**macOS** :
```bash
brew install multipass
```

**Linux** :
```bash
snap install multipass
```

### 2. Créer les VMs

Depuis la racine du projet :

```bash
bash scripts/multipass/setup-vms.sh
```

Ce script va :
- ✅ Créer les 2 VMs avec les bonnes specs
- ✅ Monter le projet dans la VM Epicea
- ✅ Configurer NFS sur la VM Storage
- ✅ Installer Docker + Ansible sur la VM Epicea
- ✅ Mettre à jour l'inventory Ansible automatiquement
- ✅ Monter les partages NFS dans la VM Epicea

**Durée** : ~5-10 minutes

### 3. Déployer l'infrastructure

Depuis ton PC :

```bash
# Initialiser les secrets en mode test
make test-init

# Déployer sur les VMs
make test-deploy

# Vérifier le statut
make test-status
```

### 4. Accéder aux services

Les domaines `.local` sont configurés automatiquement dans `/etc/hosts` de la VM Epicea.

**Depuis la VM** (via SSH) :
```bash
multipass shell epicea-test
curl http://traefik.epicea-test.local
```

**Depuis ton PC** (tunnel SSH) :
```bash
# Tunnel pour Traefik dashboard
multipass exec epicea-test -- sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080

# Accès depuis ton navigateur
http://<IP_VM_EPICEA>:8080
```

Ou utiliser port-forwarding :
```bash
ssh -L 8080:localhost:80 ubuntu@<IP_VM_EPICEA>
# Puis naviguer vers http://localhost:8080
```

### 5. Travailler sur le projet

Le projet est **monté automatiquement** dans la VM :
```
C:\Users\Louis\IdeaProjects\EpiceaInfra  →  /home/ubuntu/infra (dans la VM)
```

Tu édites les fichiers sur **ton PC** (Windows), et ils sont **immédiatement disponibles** dans la VM !

```bash
# Editer sur PC (VSCode, IntelliJ...)
# Puis redéployer :
make test-deploy
```

### 6. Commandes utiles

```bash
# Lister les VMs
multipass list

# SSH dans une VM
multipass shell epicea-test
multipass shell storage-test

# Infos VM
multipass info epicea-test

# Arrêter une VM
multipass stop epicea-test

# Redémarrer une VM
multipass start epicea-test

# Supprimer les VMs
bash scripts/multipass/destroy-vms.sh
```

---

## 📁 Fichiers

- **`setup-vms.sh`** : Crée et configure les 2 VMs
- **`init-storage-vm.sh`** : Configure NFS + données test sur VM Storage
- **`init-epicea-vm.sh`** : Configure Docker + Ansible + NFS client sur VM Epicea
- **`destroy-vms.sh`** : Supprime proprement les VMs

---

## 🔧 Configuration

### Modifier les specs VMs

Éditer `setup-vms.sh` :
```bash
EPICEA_CPUS=4     # Nombre de CPUs
EPICEA_MEM="8G"   # RAM
EPICEA_DISK="100G" # Disque
```

### Ajouter des exports NFS

Éditer `init-storage-vm.sh` :
```bash
sudo mkdir -p /exports/nouveau-share
# Ajouter dans /etc/exports
```

---

## 🐛 Troubleshooting

### Les VMs ne se créent pas
```bash
# Vérifier Multipass
multipass version

# Réinitialiser Multipass
multipass delete --all --purge
multipass restart
```

### Le mount du projet ne fonctionne pas
```bash
# Windows : vérifier que Hyper-V est activé
# macOS : vérifier les permissions Disk Access

# Remonter manuellement
multipass unmount epicea-test
multipass mount C:\Users\Louis\IdeaProjects\EpiceaInfra epicea-test:/home/ubuntu/infra
```

### NFS ne monte pas
```bash
# Dans la VM Epicea
sudo showmount -e <IP_STORAGE_VM>

# Remonter manuellement
sudo mount -t nfs <IP_STORAGE>:/exports/media /mnt/media
```

### Docker n'est pas accessible
```bash
multipass shell epicea-test

# Relogger pour appliquer groupe docker
exit
multipass shell epicea-test

# Vérifier
docker ps
```

---

## ⚠️ Différences test vs production

| Fonctionnalité | Test (Multipass) | Production |
|---|---|---|
| GPU | ❌ Désactivé | ✅ RTX 5060 |
| Let's Encrypt | ❌ Certificats auto-signés | ✅ Vrais certificats |
| Stockage | NFS VM (20GB) | Ubiquiti NAS (32TB) |
| Domaines | `*.epicea-test.local` | `*.ton-domaine.fr` |
| Backups | Simulés | NAS Quad réel |
| ZFS | ❌ Non utilisé | ✅ Snapshots avant update |

Le code Ansible détecte automatiquement l'environnement via `environment: test|production`.

---

## 🎯 Workflow de développement

1. **Coder sur PC** (Windows, ton IDE préféré)
2. **Tester sur VMs** : `make test-deploy`
3. **Valider** : `make test-status`, vérifier services
4. **Commit** : `git commit + push`
5. **CI/CD GitHub** : validation automatique
6. **Déployer en prod** : `make prod-deploy` (manuel)

---

## 📚 Ressources

- [Multipass Documentation](https://multipass.run/docs)
- [NFS Ubuntu Guide](https://ubuntu.com/server/docs/service-nfs)
- Documentation projet : `../docs/`
