# Makefile — Edge Device Security Demo
# Unified entrypoints for Control Plane (Docker) and Jetson edge device.
#
# Control Plane targets:
#   make up-mac        — start Vault Enterprise, PostgreSQL 16
#   make down-mac      — stop containers (volumes preserved)
#   make vault-status  — print Vault seal/init status
#   make setup-vault   — init + unseal + provision engines, policies, roles
#
# Jetson targets (run from Workstation/Control Plane). HOST is optional and defaults to
# JETSON_IP from .env; a <user>@ prefix in HOST is ignored, the SSH user is JETSON_USER:
#   make bootstrap-jetson HOST=<jetson-ip>
#   make jetson-status    HOST=<jetson-ip>
#   make jetson-logs      HOST=<jetson-ip>

SHELL         := /bin/bash
.DEFAULT_GOAL := help

# Docker Desktop on Mac puts its binaries in /usr/local/bin, which is absent
# from the non-interactive SSH PATH.  Resolve to the full path here so every
# recipe works whether invoked interactively or over SSH.
DOCKER        := /usr/local/bin/docker
DOCKER_COMPOSE := $(DOCKER) compose

-include .env
export

JETSON_REPO   := ~/edge-device-demo
VAULT_ADDR    := https://127.0.0.1:8200
COMPOSE_FILE  := docker-compose.yml

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m

# ─────────────────────────────────────────────────────────────────────────────
# Mac / Docker Compose targets
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: up-mac
up-mac: ## Start Vault Enterprise and PostgreSQL 16
	@echo -e "$(GREEN)► Starting Mac control-plane services…$(NC)"
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d --remove-orphans
	@echo ""
	@echo -e "$(GREEN)► Waiting for PostgreSQL to be ready…$(NC)"
	@for i in $$(seq 1 30); do \
		$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) exec -T postgres sh -c 'pg_isready -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -q' 2>/dev/null && \
		echo -e "$(GREEN)  ✓ PostgreSQL ready$(NC)" && break; \
		[ $$i -eq 30 ] && echo -e "$(RED)  ✗ PostgreSQL did not become ready in time$(NC)"; \
		sleep 2; \
	done
	@echo ""
	@echo -e "$(YELLOW)► Vault will be sealed until 'make setup-vault' is run.$(NC)"
	@echo -e "$(YELLOW)  Check status: make vault-status$(NC)"
	@echo ""
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) ps

.PHONY: down-mac
down-mac: ## Stop and remove Mac containers (volumes are preserved)
	@echo -e "$(YELLOW)► Stopping Mac control-plane services…$(NC)"
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) down
	@echo -e "$(GREEN)  ✓ Containers stopped. Volumes preserved.$(NC)"
	@echo -e "  To also remove volumes: $(DOCKER) volume rm vault-data postgres-data"

.PHONY: vault-status
vault-status: ## Print Vault seal / init status
	@echo -e "$(GREEN)► Vault status ($(VAULT_ADDR))$(NC)"
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) exec -T \
		-e VAULT_ADDR=$(VAULT_ADDR) \
		-e VAULT_CACERT=/vault/tls/vault.crt \
		vault vault status 2>&1 || true

.PHONY: gen-tls
gen-tls: ## Create tls/vault.key + tls/vault.crt if missing (SANs from .env); FORCE=1 replaces
	@PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH" bash vault/gen-tls.sh $(if $(FORCE),--force,)

.PHONY: setup-vault
setup-vault: ## Initialise, unseal, and provision Vault engines/policies
	@echo -e "$(GREEN)► Running Vault setup…$(NC)"
	@PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH" \
		VAULT_CACERT=tls/vault.crt bash vault/init-vault.sh

MAC_RESUME_LABEL := com.edge-demo.mac-resume
MAC_RESUME_PLIST := $(HOME)/Library/LaunchAgents/$(MAC_RESUME_LABEL).plist

.PHONY: install-mac-resume
install-mac-resume: ## Run on the Mac: at every login start containers + unseal Vault (scripts/mac-resume.sh)
	@mkdir -p $(HOME)/Library/LaunchAgents
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>Label</key><string>$(MAC_RESUME_LABEL)</string>' \
		'<key>ProgramArguments</key><array><string>/bin/bash</string><string>$(CURDIR)/scripts/mac-resume.sh</string></array>' \
		'<key>RunAtLoad</key><true/>' \
		'</dict></plist>' > $(MAC_RESUME_PLIST)
	@plutil -lint $(MAC_RESUME_PLIST)
	@launchctl bootout gui/$$(id -u)/$(MAC_RESUME_LABEL) 2>/dev/null || true
	@launchctl bootstrap gui/$$(id -u) $(MAC_RESUME_PLIST)
	@echo -e "$(GREEN)  ✓ $(MAC_RESUME_LABEL) installed; runs at each login of $$(id -un). Log: $(CURDIR)/.mac-resume.log$(NC)"

.PHONY: uninstall-mac-resume
uninstall-mac-resume: ## Run on the Mac: remove the login job
	@launchctl bootout gui/$$(id -u)/$(MAC_RESUME_LABEL) 2>/dev/null || true
	@rm -f $(MAC_RESUME_PLIST)
	@echo -e "$(GREEN)  ✓ $(MAC_RESUME_LABEL) removed$(NC)"



.PHONY: upgrade-vault
upgrade-vault: ## Upgrade to 2.2.0-ent: down + pull + up + re-unseal
	@echo -e "$(YELLOW)► Stopping services (volumes preserved)…$(NC)"
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) down
	@echo -e "$(GREEN)► Pulling hashicorp/vault-enterprise:2.2.0-ent…$(NC)"
	@$(DOCKER) pull hashicorp/vault-enterprise:2.2.0-ent
	@echo -e "$(GREEN)► Starting services…$(NC)"
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d --remove-orphans
	@echo -e "$(GREEN)► Waiting 10 s for Vault to initialise…$(NC)"
	@sleep 10
	@echo -e "$(GREEN)► Re-unsealing and re-provisioning (idempotent)…$(NC)"
	@PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH" bash vault/init-vault.sh
	@echo -e "$(GREEN)► Done. Vault version:$(NC)"
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) exec -T -e VAULT_ADDR=$(VAULT_ADDR) vault \
		vault status 2>&1 | grep -E "Version|Sealed|Initialized" || true

.PHONY: setup-tpm-auth
setup-tpm-auth: ## Enable auth/tpm, create tpmgroup, write role
	@echo -e "$(GREEN)► Running TPM auth setup…$(NC)"
	@chmod +x vault/setup-tpm-auth.sh
	@PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH" \
		VAULT_CACERT=tls/vault.crt bash vault/setup-tpm-auth.sh

.PHONY: setup-gateway-credstore
setup-gateway-credstore: ## Split TPM roles + policies + narrowness proofs
	@echo -e "$(GREEN)► Provisioning gateway credential store / role split…$(NC)"
	@PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH" \
		VAULT_CACERT=tls/vault.crt bash vault/setup-gateway-credstore.sh

.PHONY: setup-control-reader
setup-control-reader: ## control-plane-reader AppRole (Transit decrypt only) + narrowness proofs
	@echo -e "$(GREEN)► Provisioning control-plane-reader AppRole…$(NC)"
	@PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH" \
		VAULT_CACERT=tls/vault.crt bash vault/setup-control-reader.sh

.PHONY: setup-roles
setup-roles: setup-gateway-credstore ## Alias: split TPM roles, apply policies, run narrowness proofs

# ─────────────────────────────────────────────────────────────────────────────
# Jetson targets (SSH)
# ─────────────────────────────────────────────────────────────────────────────

HOST ?= $(if $(JETSON_IP),$(JETSON_IP),192.0.2.20)
TARGET_IP := $(shell echo $(HOST) | sed 's/.*@//')
TARGET_USER := $(if $(JETSON_USER),$(JETSON_USER),jetson)
JETSON_SSH := $(TARGET_USER)@$(TARGET_IP)
TARGET_KEY := $(if $(JETSON_SSH_KEY),$(JETSON_SSH_KEY),~/.ssh/id_ed25519)
SSH_KEY_OPT := -i $(TARGET_KEY)

.PHONY: bootstrap-jetson
bootstrap-jetson: ## Bootstrap Jetson over SSH (HOST=<ip>)
	@bash scripts/bootstrap-jetson.sh $(TARGET_IP)

.PHONY: jetson-status
jetson-status: ## Check Jetson services, thermals, VRAM (HOST=<ip>)
	@ssh $(SSH_KEY_OPT) $(JETSON_SSH) '\
		echo "=== System Services ==="; \
		for svc in vlm-server trusted-edge live-vlm-webui; do \
			echo "$$svc: $$(systemctl is-active $$svc 2>/dev/null || echo "inactive")"; \
		done; \
		echo "openshell-gateway: $$(XDG_RUNTIME_DIR=/run/user/$$(id -u jetson) systemctl --user is-active openshell-gateway 2>/dev/null || echo "inactive")"; \
		echo ""; \
		echo "=== Memory & Swap ==="; \
		free -h; \
		echo ""; \
		echo "=== GPU/Thermals (tegrastats) ==="; \
		if command -v tegrastats >/dev/null; then sudo tegrastats --single; else echo "tegrastats not available"; fi'

.PHONY: jetson-logs
jetson-logs: ## Tail Jetson service logs (HOST=<ip>)
	@ssh $(SSH_KEY_OPT) $(JETSON_SSH) 'sudo journalctl -u vlm-server -u trusted-edge -u live-vlm-webui -n 50 --no-pager'

.PHONY: demo-smoke-test
demo-smoke-test: ## Run policy & inference tests on Jetson and assert database encryption on Mac
	@echo -e "$(GREEN)► Running demo end-to-end smoke test…$(NC)"
	@echo -e "$(GREEN)  → 1. Running OpenShell policy test on Jetson…$(NC)"
	@ssh $(SSH_KEY_OPT) $(JETSON_SSH) 'bash ~/edge-device-demo/scripts/07-test-openshell-policy.sh'
	@echo -e "$(GREEN)  → 2. Running inference smoke test on Jetson…$(NC)"
	@ssh $(SSH_KEY_OPT) $(JETSON_SSH) 'bash ~/edge-device-demo/scripts/05-smoke-test-inference.sh'
	@echo -e "$(GREEN)  → 3. Asserting PostgreSQL database encryption on Mac…$(NC)"
	@COUNT=$$($(DOCKER_COMPOSE) -f $(COMPOSE_FILE) exec -T postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -tAc "SELECT COUNT(*) FROM events WHERE encrypted_datakey LIKE '"'"'vault:v1:%'"'"';"'); \
	echo -e "$(GREEN)     Found $$COUNT encrypted event rows in database.$(NC)"; \
	if [ "$$COUNT" -gt 0 ] 2>/dev/null; then \
		echo -e "$(GREEN)  ✓ PASS: End-to-end flow verified. $$COUNT rows encrypted in PostgreSQL with vault:v1: ciphertext.$(NC)"; \
	else \
		echo -e "$(RED)  ✗ FAIL: No encrypted rows found in database!$(NC)"; \
		exit 1; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# Utility
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: ps
ps: ## Show running containers
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) ps

.PHONY: logs
logs: ## Tail all Mac service logs
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-22s$(NC) %s\n", $$1, $$2}'
