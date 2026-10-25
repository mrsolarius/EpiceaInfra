.PHONY: help init secrets sim-up sim-deploy sim-deploy-backup sim-test sim-test-restore sim-all sim-status sim-down deploy deploy-backup validate lint

# ========================================
# Makefile Epicea Infrastructure
# Point d'entrée unique pour tout
# ========================================

ANSIBLE_PLAYBOOK := ansible-playbook
ANSIBLE_INVENTORY := ansible/inventory/hosts.yml
ANSIBLE_VAULT := ansible-vault

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
	@echo "  make sim-status         # Conteneurs et pools des VMs"
	@echo "  make sim-down           # Détruire les VMs"
	@echo ""
	@echo "Production :"
	@echo "  make init               # Initialiser secrets"
	@echo "  make secrets            # Éditer les secrets"
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
init:
	@if [ ! -f ansible/secrets/vault.yml ]; then \
		cp ansible/secrets/vault.yml.example ansible/secrets/vault.yml; \
		$(ANSIBLE_VAULT) encrypt ansible/secrets/vault.yml; \
		echo "✅ vault.yml créé et chiffré. Éditez-le avec : make secrets"; \
	else \
		echo "✅ vault.yml existe déjà"; \
	fi

secrets:
	$(ANSIBLE_VAULT) edit ansible/secrets/vault.yml

# ========================================
# SIMULATION (VMs reproduisant srv-main et srv-backup)
# ========================================
# Voir scripts/simulation/README.md
SIM_MAIN := srv-main-sim
SIM_BACKUP := srv-backup-sim
# ANSIBLE_CONFIG explicite : Ansible ignore le ansible.cfg d'un dossier monté (droits trop ouverts)
SIM_ANSIBLE := MSYS_NO_PATHCONV=1 multipass exec $(SIM_MAIN) -- bash -c "cd /home/ubuntu/infra && ANSIBLE_CONFIG=/home/ubuntu/infra/ansible.cfg ansible-playbook -i ansible/inventory/simulation.yml $(if $(TAGS),--tags $(TAGS))

sim-up:
	bash ./scripts/simulation/setup-sim.sh

sim-deploy:
	@bash ./scripts/simulation/ensure-mount.sh
	$(SIM_ANSIBLE) --limit production ansible/playbooks/site.yml -e @ansible/group_vars/production.yml -e @ansible/group_vars/simulation.yml -e @ansible/group_vars/simulation-network.yml"

sim-deploy-backup:
	@bash ./scripts/simulation/ensure-mount.sh
	$(SIM_ANSIBLE) ansible/playbooks/backup.yml -e @ansible/group_vars/simulation-network.yml -e zfs_allow_pool_creation=true"

sim-test:
	bash ./scripts/simulation/test-sim.sh

sim-test-restore:
	bash ./scripts/simulation/test-restore.sh

sim-all: sim-up sim-deploy sim-deploy-backup sim-test

sim-status:
	@MSYS_NO_PATHCONV=1 multipass exec $(SIM_MAIN) -- sudo docker ps --format "{{.Names}}\t{{.Status}}"
	@MSYS_NO_PATHCONV=1 multipass exec $(SIM_MAIN) -- sudo zpool list
	@MSYS_NO_PATHCONV=1 multipass exec $(SIM_BACKUP) -- sudo zpool list

sim-down:
	-MSYS_NO_PATHCONV=1 multipass delete --purge $(SIM_MAIN) $(SIM_BACKUP)
	rm -f ansible/inventory/simulation.yml ansible/group_vars/simulation-network.yml

# ========================================
# DÉPLOIEMENT
# ========================================
# Premier déploiement sur disques vierges : ajouter ZFS_CREATE=1 pour autoriser
# la création des pools (EFFACE les disques listés dans zfs_pools).
# TAGS=zfs (ou tout autre tag de site.yml) limite le déploiement à certains rôles.
deploy:
	$(ANSIBLE_PLAYBOOK) \
		-i $(ANSIBLE_INVENTORY) \
		--limit production \
		--ask-vault-pass \
		-e @ansible/group_vars/production.yml \
		$(if $(ZFS_CREATE),-e zfs_allow_pool_creation=true) \
		$(if $(TAGS),--tags $(TAGS)) \
		ansible/playbooks/site.yml

deploy-backup:
	$(ANSIBLE_PLAYBOOK) \
		-i $(ANSIBLE_INVENTORY) \
		$(if $(ZFS_CREATE),-e zfs_allow_pool_creation=true) \
		ansible/playbooks/backup.yml

# ========================================
# QUALITÉ
# ========================================
validate:
	$(ANSIBLE_PLAYBOOK) --syntax-check ansible/playbooks/site.yml
	$(ANSIBLE_PLAYBOOK) --syntax-check ansible/playbooks/backup.yml

lint:
	ansible-lint
