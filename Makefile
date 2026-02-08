.PHONY: help test-init test-deploy test-status vm-up vm-down

# ========================================
# Makefile Epicea Infrastructure
# Point d'entrée unique pour tout
# ========================================

# Chemins
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
	@echo "Tests Multipass :"
	@echo "  make vm-up              # Créer les VMs de test"
	@echo "  make vm-down            # Détruire les VMs"
	@echo "  make test-init          # Initialiser secrets test"
	@echo "  make test-deploy        # Déployer sur VM test"
	@echo "  make test-status        # Status services test"
	@echo ""
	@echo "Production :"
	@echo "  make init               # Initialiser secrets"
	@echo "  make deploy             # Déployer infrastructure"
	@echo "  make status             # Status services"
	@echo ""

# ========================================
# VMS (tests)
# ========================================
vm-up:
	@echo "🚀 Création des VMs Multipass..."
	bash ./scripts/multipass/setup-vms.sh

vm-down:
	@echo "🗑️  Destruction des VMs Multipass..."
	bash ./scripts/multipass/destroy-vms.sh

# ========================================
# INIT SECRETS
# ========================================
test-init:
	@echo "🔐 Initialisation secrets test..."
	@if [ ! -f ansible/secrets/vault.yml ]; then \
		cp ansible/secrets/vault.yml.example ansible/secrets/vault.yml; \
		echo "✅ Fichier vault.yml créé (non chiffré pour tests)"; \
	else \
		echo "✅ vault.yml existe déjà"; \
	fi

init:
	@echo "🔐 Initialisation secrets production..."
	@if [ ! -f ansible/secrets/vault.yml ]; then \
		cp ansible/secrets/vault.yml.example ansible/secrets/vault.yml; \
		$(ANSIBLE_VAULT) encrypt ansible/secrets/vault.yml; \
		echo "✅ vault.yml créé et chiffré"; \
		echo "Éditez avec: make secrets"; \
	else \
		echo "✅ vault.yml existe déjà"; \
	fi

secrets:
	$(ANSIBLE_VAULT) edit ansible/secrets/vault.yml

# ========================================
# DÉPLOIEMENT
# ========================================
test-deploy:
	@echo "🚀 Déploiement sur environnement TEST..."
	@MSYS_NO_PATHCONV=1 multipass exec epicea-test -- bash -c "cd /home/ubuntu/infra/ansible && export PATH=\$PATH:/usr/bin && ANSIBLE_CONFIG=/home/ubuntu/infra/ansible/ansible.cfg ansible-playbook -i inventory/hosts.yml --limit test playbooks/site.yml -e '@group_vars/test.yml'"

deploy:
	@echo "🚀 Déploiement sur PRODUCTION..."
	$(ANSIBLE_PLAYBOOK) \
		-i $(ANSIBLE_INVENTORY) \
		--limit production \
		--ask-vault-pass \
		ansible/playbooks/site.yml

# ========================================
# OPÉRATIONS
# ========================================
test-status:
	@echo "📊 Status services TEST..."
	@MSYS_NO_PATHCONV=1 multipass exec epicea-test -- docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

status:
	@echo "📊 Status services..."
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

test-logs:
	@echo "📋 Logs services TEST..."
	@MSYS_NO_PATHCONV=1 multipass exec epicea-test -- docker compose -f /opt/epicea/docker/traefik/docker-compose.yml logs -f --tail=100

# ========================================
# VALIDATION
# ========================================
validate:
	@echo "✅ Validation configuration..."
	@$(ANSIBLE_PLAYBOOK) --syntax-check ansible/playbooks/site.yml
	@echo "✅ Syntax Ansible OK"

# ========================================
# NETTOYAGE
# ========================================
clean:
	@echo "🧹 Nettoyage Docker..."
	@docker system prune -af --volumes
	@echo "✅ Nettoyage terminé"
