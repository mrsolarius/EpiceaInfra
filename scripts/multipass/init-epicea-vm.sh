#!/bin/bash
set -euo pipefail

STORAGE_IP="${1:-}"

if [[ -z "$STORAGE_IP" ]]; then
    echo "❌ Usage: $0 <STORAGE_IP>"
    exit 1
fi

echo "=== Initialisation Epicea VM (Serveur applicatif) ==="
echo "Storage NFS : $STORAGE_IP"

# Mise à jour système
echo "📦 Mise à jour système..."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

# Installation paquets de base
echo "📦 Installation paquets essentiels..."
sudo apt-get install -y -qq \
    curl \
    git \
    vim \
    htop \
    ncdu \
    ufw \
    nfs-common \
    python3-pip \
    python3-venv \
    ca-certificates \
    gnupg \
    lsb-release

# Installation Docker
echo "🐳 Installation Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker ubuntu
    echo "✅ Docker installé"
else
    echo "✅ Docker déjà installé"
fi

# Installation Docker Compose v2
echo "🐳 Vérification Docker Compose..."
if ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose v2 non disponible"
else
    echo "✅ Docker Compose v2 disponible"
fi

# Configuration Docker daemon (log rotation)
echo "🔧 Configuration Docker daemon..."
sudo mkdir -p /etc/docker
sudo bash -c 'cat > /etc/docker/daemon.json << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF'
sudo systemctl restart docker

# Installation Ansible
echo "📦 Installation Ansible..."
if ! command -v ansible &> /dev/null; then
    python3 -m pip install --user ansible ansible-lint --break-system-packages
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    export PATH="$HOME/.local/bin:$PATH"
    echo "✅ Ansible installé"
else
    echo "✅ Ansible déjà installé"
fi

# Création points de montage NFS
echo "📁 Création points de montage NFS..."
sudo mkdir -p /mnt/{media,photos,cloud,backups}

# Montage NFS
echo "🔗 Montage NFS depuis Storage VM ($STORAGE_IP)..."
sudo mount -t nfs -o rw,hard,intr,nfsvers=4 ${STORAGE_IP}:/exports/media /mnt/media
sudo mount -t nfs -o rw,hard,intr,nfsvers=4 ${STORAGE_IP}:/exports/photos /mnt/photos
sudo mount -t nfs -o rw,hard,intr,nfsvers=4 ${STORAGE_IP}:/exports/cloud /mnt/cloud
sudo mount -t nfs -o rw,hard,intr,nfsvers=4 ${STORAGE_IP}:/exports/backups /mnt/backups

# Vérification montages
echo "✅ Vérification montages NFS..."
df -h | grep /mnt

# Configuration fstab pour montage auto (au cas où VM reboot)
echo "📝 Configuration fstab..."
sudo bash -c "cat >> /etc/fstab << EOF

# NFS mounts pour tests Epicea
${STORAGE_IP}:/exports/media    /mnt/media    nfs    rw,hard,intr,nfsvers=4    0 0
${STORAGE_IP}:/exports/photos   /mnt/photos   nfs    rw,hard,intr,nfsvers=4    0 0
${STORAGE_IP}:/exports/cloud    /mnt/cloud    nfs    rw,hard,intr,nfsvers=4    0 0
${STORAGE_IP}:/exports/backups  /mnt/backups  nfs    rw,hard,intr,nfsvers=4    0 0
EOF"

# Configuration UFW (firewall basique)
echo "🔥 Configuration firewall..."
sudo ufw --force enable
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 80/tcp    # HTTP
sudo ufw allow 443/tcp   # HTTPS
sudo ufw allow 8080/tcp  # Traefik dashboard
sudo ufw status

# Configuration DNS local (pour domaines .local)
echo "📝 Configuration DNS local..."
sudo bash -c "cat >> /etc/hosts << EOF

# Domaines locaux Epicea test
127.0.0.1 epicea-test.local
127.0.0.1 traefik.epicea-test.local
127.0.0.1 photos.epicea-test.local
127.0.0.1 media.epicea-test.local
127.0.0.1 cloud.epicea-test.local
127.0.0.1 monitoring.epicea-test.local
127.0.0.1 logs.epicea-test.local
127.0.0.1 db.epicea-test.local
EOF"

# Afficher infos système
echo ""
echo "📊 Informations système :"
echo "  CPU  : $(nproc) cores"
echo "  RAM  : $(free -h | awk '/^Mem:/ {print $2}')"
echo "  Disk : $(df -h / | awk 'NR==2 {print $2}')"
echo ""

echo "✅ Epicea VM configurée avec succès !"
echo ""
echo "Projet monté : /home/ubuntu/infra"
echo "NFS monté    : /mnt/{media,photos,cloud,backups}"
echo ""
echo "Prochaines étapes (depuis ton PC) :"
echo "  make test-init"
echo "  make test-deploy"
