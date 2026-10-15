SHELL := /usr/bin/env bash
COMPOSE := docker compose

.DEFAULT_GOAL := help
.PHONY: help env certs up bootstrap deploy smoke-test down destroy logs ps backup restore lint

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example (if missing)
	@test -f .env || { cp .env.example .env && chmod 600 .env && echo "Created .env — edit the passwords before deploying"; }

certs: env ## Generate a local CA + TLS certificate
	@scripts/generate-certs.sh

up: certs ## Start Nexus and the Nginx proxy
	$(COMPOSE) up -d

bootstrap: ## Configure repositories, realms, RBAC (idempotent)
	@scripts/bootstrap.sh

deploy: up bootstrap ## Full deployment: certs + start + configure

smoke-test: ## Push/pull an image end to end
	@scripts/smoke-test.sh

ps: ## Show service status
	$(COMPOSE) ps

logs: ## Tail logs
	$(COMPOSE) logs -f --tail=100

backup: ## Back up the nexus-data volume to ./backups
	@scripts/backup.sh

restore: ## Restore from a backup: make restore FILE=backups/xxx.tar.gz
	@scripts/restore.sh "$(FILE)"

down: ## Stop the stack (data is kept)
	$(COMPOSE) down

destroy: ## Stop the stack and DELETE all data
	$(COMPOSE) down -v

lint: ## Lint shell scripts, compose file and nginx config
	docker run --rm -v .:/mnt -w /mnt koalaman/shellcheck:v0.10.0 -x scripts/*.sh
	$(COMPOSE) --env-file .env.example config -q
	@scripts/generate-certs.sh >/dev/null
	docker run --rm -e NEXUS_HOST=localhost \
	  -v ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro \
	  -v ./nginx/templates:/etc/nginx/templates:ro \
	  -v ./nginx/snippets:/etc/nginx/snippets:ro \
	  -v ./certs:/etc/nginx/certs:ro \
	  --add-host nexus:127.0.0.1 \
	  nginx:1.31.7-alpine sh -c '/docker-entrypoint.sh nginx -t'
