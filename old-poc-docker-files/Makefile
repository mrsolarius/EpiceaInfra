# Chemins des fichiers Compose
NET_FILE = network/docker-compose.yml
PROXY_FILE = proxy/docker-compose.yml
IMMICH_FILE = immich/docker-compose.yml
JELLYFIN_FILE = jellyfin/docker-compose.yml
NEXTCLOUD_FILE = nextcloud/docker-compose.yml
DOZZLE_FILE = dozzle/docker-compose.yml

up:
	# 1. Configuration système
	sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80

	# 2. Lancement du réseau global
	sudo podman-compose -f $(NET_FILE) up -d

	# 3. Lancement du Proxy
	sudo podman-compose -f $(PROXY_FILE) up -d

	# 4. Lancement des applications (séparés pour conserver le contexte .env)
	sudo podman-compose -f $(IMMICH_FILE) up -d
	sudo podman-compose -f $(JELLYFIN_FILE) up -d
	sudo podman-compose -f $(NEXTCLOUD_FILE) up -d
	sudo podman-compose -f $(DOZZLE_FILE) up -d

down:
	sudo podman-compose -f $(NEXTCLOUD_FILE) down
	sudo podman-compose -f $(JELLYFIN_FILE) down
	sudo podman-compose -f $(IMMICH_FILE) down
	sudo podman-compose -f $(PROXY_FILE) down
	sudo podman-compose -f $(NET_FILE) down
	sudo podman-compose -f $(DOZZLE_FILE) down

logs:
	# Affiche les logs de tout le monde en même temps
	sudo podman-compose -f $(PROXY_FILE) -f $(IMMICH_FILE) -f $(JELLYFIN_FILE) -f $(NEXTCLOUD_FILE) -f $(DOZZLE_FILE) logs -f