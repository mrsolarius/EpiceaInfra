#!/bin/bash
set -euo pipefail

echo "=== Initialisation Storage VM (NFS Server) ==="

# Mise à jour système
echo "📦 Mise à jour système..."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

# Installation NFS server
echo "📦 Installation NFS server..."
sudo apt-get install -y -qq nfs-kernel-server

# Création des répertoires d'export
echo "📁 Création des répertoires NFS..."
sudo mkdir -p /exports/{media,photos,cloud,backups}

# Peuplement avec données test
echo "📝 Création de données de test..."

# Media : quelques fichiers vidéo factices
sudo mkdir -p /exports/media/{movies,tv-shows}
sudo dd if=/dev/zero of=/exports/media/movies/sample-movie.mkv bs=1M count=100 2>/dev/null
sudo dd if=/dev/zero of=/exports/media/tv-shows/sample-episode.mkv bs=1M count=50 2>/dev/null

# Photos : images factices
sudo mkdir -p /exports/photos/{2024,2025}
for i in {1..10}; do
    sudo dd if=/dev/urandom of=/exports/photos/2024/photo-$i.jpg bs=1M count=5 2>/dev/null
done

# Cloud : fichiers test
sudo mkdir -p /exports/cloud/documents
echo "Test file from Nextcloud" | sudo tee /exports/cloud/documents/test.txt > /dev/null

# Permissions (UID/GID 1000 = ubuntu par défaut dans VMs)
echo "🔐 Configuration permissions..."
sudo chown -R 1000:1000 /exports
sudo chmod -R 755 /exports

# Configuration exports NFS
echo "📝 Configuration exports NFS..."
sudo bash -c 'cat > /etc/exports << EOF
# Exports pour tests Epicea
/exports/media      *(rw,sync,no_subtree_check,no_root_squash)
/exports/photos     *(rw,sync,no_subtree_check,no_root_squash)
/exports/cloud      *(rw,sync,no_subtree_check,no_root_squash)
/exports/backups    *(rw,sync,no_subtree_check,no_root_squash)
EOF'

# Appliquer configuration
echo "🔄 Application configuration NFS..."
sudo exportfs -ra
sudo systemctl restart nfs-kernel-server

# Vérification
echo "✅ Vérification exports..."
sudo exportfs -v

# Afficher taille utilisée
echo ""
echo "📊 Espace utilisé :"
du -sh /exports/*

echo ""
echo "✅ Storage VM configurée avec succès !"
echo "NFS exports disponibles : /exports/{media,photos,cloud,backups}"
