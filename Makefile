.PHONY: help init secrets vault-encrypt vault-decrypt vault-view traefik-pass sim-up sim-deploy sim-deploy-backup sim-test sim-test-restore sim-all sim-status sim-down deploy deploy-backup validate lint

# ========================================
# Makefile Epicea Infrastructure
# Point d'entrée unique pour tout
# ========================================

# Ansible passe par scripts/ansible.sh : sous Windows (Git Bash), il est relancé dans WSL
ANSIBLE := bash scripts/ansible.sh
ANSIBLE_PLAYBOOK := $(ANSIBLE) ansible-playbook
ANSIBLE_INVENTORY := ansible/inventory/hosts.yml
ANSIBLE_VAULT := $(ANSIBLE) ansible-vault
VAULT_FILE := ansible/secrets/vault.yml
# Mot de passe du vault : lu dans ce fichier s'il existe (non versionné, utilisé par
# scripts/ansible.sh), sinon demandé
VAULT_PASS_FILE := ansible/.vault_pass
VAULT_ARGS = $(if $(wildcard $(VAULT_PASS_FILE)),,--ask-vault-pass)
VAULT_IS_ENCRYPTED = head -1 $(VAULT_FILE) | grep -q '^\$$ANSIBLE_VAULT'

# ========================================
# HELP
# ========================================
help:
	@echo "========================================"
	@echo "  Epicea Infrastructure - Makefile"
	@echo "========================================"
	@echo ""
	@echo "Simulation (VMs Multipass reproduisant srv-main et srv-backup) :"
	@echo "  make sim-all            # Tout enchaîner : VMs, déploiements, tests"
	@echo "  make sim-up             # Créer les VMs et simuler les disques"
	@echo "  make sim-deploy         # Déployer srv-main (configuration de production)"
	@echo "  make sim-deploy-backup  # Déployer srv-backup + réplication"
	@echo "  make sim-test           # Tests de bout en bout"
	@echo "  make sim-test-restore   # Tester les procédures de restauration"
	@echo "  make sim-test-migration # Tester la migration AMP (ancien gameserver -> srv-main)"
	@echo "  make sim-status         # Conteneurs et pools des VMs"
	@echo "  make sim-down           # Détruire les VMs"
	@echo ""
	@echo "Production :"
	@echo "  make init               # Initialiser secrets"
	@echo "  make secrets            # Éditer les secrets (reste chiffré)"
	@echo "  make vault-encrypt      # Chiffrer vault.yml"
	@echo "  make vault-decrypt      # Déchiffrer vault.yml (le laisse en clair)"
	@echo "  make vault-view         # Afficher les secrets sans déchiffrer le fichier"
	@echo "  make traefik-pass       # Changer le mot de passe du dashboard Traefik"
	@echo "  make deploy             # Déployer srv-main"
	@echo "  make deploy-backup      # Déployer srv-backup + réplication ZFS"
	@echo ""
	@echo "Qualité :"
	@echo "  make validate           # Vérifier la syntaxe des playbooks"
	@echo "  make lint               # Lancer ansible-lint"
	@echo ""

# ========================================
# SECRETS
# ========================================
# Active aussi le hook qui refuse de committer vault.yml en clair
init:
	@git config core.hooksPath .githooks
	@if [ ! -f $(VAULT_FILE) ]; then \
		cp ansible/secrets/vault.yml.example $(VAULT_FILE); \
		$(ANSIBLE_VAULT) encrypt $(VAULT_ARGS) $(VAULT_FILE); \
		echo "✅ vault.yml créé et chiffré. Éditez-le avec : make secrets"; \
	else \
		echo "✅ vault.yml existe déjà"; \
	fi

# Éditer sans jamais laisser le fichier en clair sur le disque
secrets:
	$(ANSIBLE_VAULT) edit $(VAULT_ARGS) $(VAULT_FILE)

vault-encrypt:
	@if $(VAULT_IS_ENCRYPTED); then \
		echo "✅ vault.yml est déjà chiffré"; \
	else \
		$(ANSIBLE_VAULT) encrypt $(VAULT_ARGS) $(VAULT_FILE) && echo "🔒 vault.yml chiffré"; \
	fi

# Laisse le fichier en clair : penser à make vault-encrypt ensuite
vault-decrypt:
	@if $(VAULT_IS_ENCRYPTED); then \
		$(ANSIBLE_VAULT) decrypt $(VAULT_ARGS) $(VAULT_FILE) && echo "🔓 vault.yml en clair : make vault-encrypt une fois fini"; \
	else \
		echo "✅ vault.yml est déjà en clair"; \
	fi

vault-view:
	$(ANSIBLE_VAULT) view $(VAULT_ARGS) $(VAULT_FILE)

# Déchiffre le vault si besoin, y écrit le hash du mot de passe, puis le rechiffre s'il l'était
traefik-pass:
	@was_encrypted=0; \
	if $(VAULT_IS_ENCRYPTED); then was_encrypted=1; $(MAKE) --no-print-directory vault-decrypt || exit 1; fi; \
	bash scripts/traefik-pass.sh $(VAULT_FILE); status=$$?; \
	if [ $$was_encrypted = 1 ]; then $(MAKE) --no-print-directory vault-encrypt; fi; \
	exit $$status

# ========================================
# SIMULATION (VMs reproduisant srv-main et srv-backup)
# ========================================
# Voir scripts/simulation/README.md
SIM_MAIN := srv-main-sim
SIM_BACKUP := srv-backup-sim
# ANSIBLE_CONFIG explicite : Ansible ignore le ansible.cfg d'un dossier monté (droits trop ouverts).
# Les surcharges de la simulation viennent du groupe « simulation » de cet inventaire.
SIM_ANSIBLE := MSYS_NO_PATHCONV=1 multipass exec $(SIM_MAIN) -- bash -c "cd /home/ubuntu/infra && ANSIBLE_CONFIG=/home/ubuntu/infra/ansible.cfg ansible-playbook -i ansible/inventory/simulation.yml $(if $(TAGS),--tags $(TAGS))

sim-up:
	bash ./scripts/simulation/setup-sim.sh

# Vault chiffré : le mot de passe (ansible/.vault_pass) est recopié dans la VM en 0600. Lu depuis
# le dossier monté, il paraîtrait exécutable et Ansible le lancerait comme un script.
SIM_VAULT_PASS := /home/ubuntu/.vault_pass

sim-deploy:
	@bash ./scripts/simulation/ensure-mount.sh
	@if [ -f $(VAULT_PASS_FILE) ]; then \
		MSYS_NO_PATHCONV=1 multipass exec $(SIM_MAIN) -- bash -c "echo $$(base64 -w0 $(VAULT_PASS_FILE)) | base64 -d > $(SIM_VAULT_PASS) && chmod 600 $(SIM_VAULT_PASS)"; \
	elif $(VAULT_IS_ENCRYPTED); then \
		echo "❌ vault.yml est chiffré : mettre son mot de passe dans $(VAULT_PASS_FILE) pour la simulation"; exit 1; \
	fi
	$(SIM_ANSIBLE) $(if $(wildcard $(VAULT_PASS_FILE)),--vault-password-file $(SIM_VAULT_PASS)) ansible/playbooks/site.yml"

sim-deploy-backup:
	@bash ./scripts/simulation/ensure-mount.sh
	$(SIM_ANSIBLE) ansible/playbooks/backup.yml"

sim-test:
	bash ./scripts/simulation/test-sim.sh

sim-test-restore:
	bash ./scripts/simulation/test-restore.sh

sim-test-migration:
	bash ./scripts/simulation/test-migration-amp.sh

sim-all: sim-up sim-deploy sim-deploy-backup sim-test

sim-status:
	@MSYS_NO_PATHCONV=1 multipass exec $(SIM_MAIN) -- sudo docker ps --format "{{.Names}}\t{{.Status}}"
	@MSYS_NO_PATHCONV=1 multipass exec $(SIM_MAIN) -- sudo zpool list
	@MSYS_NO_PATHCONV=1 multipass exec $(SIM_BACKUP) -- sudo zpool list

sim-down:
	-MSYS_NO_PATHCONV=1 multipass delete --purge $(SIM_MAIN) $(SIM_BACKUP)
	-MSYS_NO_PATHCONV=1 multipass delete --purge gameserver-sim 2>/dev/null
	rm -f ansible/inventory/simulation.yml

# ========================================
# DÉPLOIEMENT
# ========================================
# Premier déploiement sur disques vierges : ajouter ZFS_CREATE=1 pour autoriser
# la création des pools (EFFACE les disques listés dans zfs_pools).
# TAGS=zfs (ou tout autre tag de site.yml) limite le déploiement à certains rôles.
deploy:
	$(ANSIBLE_PLAYBOOK) \
		-i $(ANSIBLE_INVENTORY) \
		$(VAULT_ARGS) \
		$(if $(ZFS_CREATE),-e zfs_allow_pool_creation=true) \
		$(if $(TAGS),--tags $(TAGS)) \
		ansible/playbooks/site.yml

# LIMIT=backup : srv-backup seul (srv-main pas encore installé, ex. pendant la migration)
deploy-backup:
	$(ANSIBLE_PLAYBOOK) \
		-i $(ANSIBLE_INVENTORY) \
		$(if $(ZFS_CREATE),-e zfs_allow_pool_creation=true) \
		$(if $(LIMIT),--limit $(LIMIT)) \
		ansible/playbooks/backup.yml

# ========================================
# QUALITÉ
# ========================================
validate:
	$(ANSIBLE_PLAYBOOK) --syntax-check ansible/playbooks/site.yml
	$(ANSIBLE_PLAYBOOK) --syntax-check ansible/playbooks/backup.yml

lint:
	$(ANSIBLE) ansible-lint ansible/
