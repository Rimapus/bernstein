# Cluster addresses come from the Ansible inventory. Override on the command
# line (make REGISTRY=... INGRESS_IP=...) when needed.
REGISTRY_HOST ?= $(shell scripts/inventory-host.sh registry)
REGISTRY_PORT ?= 5000
REGISTRY      ?= $(REGISTRY_HOST):$(REGISTRY_PORT)
TAG           ?= $(shell git describe --always --dirty 2>/dev/null)
SERVICE       ?=
ARGS          ?=

INGRESS_IP ?= $(shell scripts/inventory-host.sh workers)
INGRESS_CA ?= $(HOME)/.kube/bernstein-ingress-ca.crt
K6_ARGS    ?=
K6 = docker run --rm -v $(INGRESS_CA):/ca.crt:ro -e SSL_CERT_FILE=/ca.crt \
	--add-host poll.bernstein.local:$(INGRESS_IP) --add-host result.bernstein.local:$(INGRESS_IP) \
	-v $(CURDIR)/tests/load:/scripts:ro grafana/k6:2.3.0 run $(K6_ARGS)

-include .env
export

.DEFAULT_GOAL := help
.PHONY: help infra images deploy up ingress tunnel test smoke chaos load monitoring logging metrics _secrets

##@ General
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} \
	/^##@/ {printf "\n%s\n", substr($$0, 5)} \
	/^[a-zA-Z_-]+:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Provision
infra: ## Provision the registry and Kubernetes cluster
	cd ansible && ansible-playbook infra.yaml $(ARGS)

##@ Deploy
images: ## Build and push images (TAG=<tag>, SERVICE=poll|result|worker)
	@test -n "$(TAG)" || { echo "TAG is empty: pass TAG=<tag>" >&2; exit 1; }
	cd poll-application && REGISTRY=$(REGISTRY) TAG=$(TAG) docker buildx bake --push $(SERVICE)

deploy: ## Deploy the app stack (TAG=<tag>)
	@scripts/deploy.sh

up: ## Deploy and expose the app (TAG=<tag>)
	$(MAKE) deploy
	$(MAKE) ingress

ingress: ## Install ingress-nginx, TLS and Ingress resources
	kubectl apply -f kubernetes/namespace.yaml
	cd ansible && ansible-playbook ingress.yaml $(ARGS)
	kubectl apply -k kubernetes/ingress

tunnel: ## Install the Cloudflare Tunnel connector
	@test -n "$(CLOUDFLARE_TUNNEL_TOKEN)" || { echo "CLOUDFLARE_TUNNEL_TOKEN is empty: set it in .env" >&2; exit 1; }
	kubectl apply -f kubernetes/cloudflared/namespace.yaml
	kubectl -n cloudflared create secret generic cloudflared-tunnel-token \
		--from-literal=token="$$CLOUDFLARE_TUNNEL_TOKEN" \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -k kubernetes/cloudflared
	kubectl -n cloudflared rollout restart deployment/cloudflared
	kubectl -n cloudflared rollout status deployment/cloudflared --timeout=120s

##@ Test
test: ## Run smoke and Redis chaos tests
	$(MAKE) smoke
	$(MAKE) chaos

smoke: ## Run the end-to-end smoke test
	INGRESS_IP=$(INGRESS_IP) CACERT=$(INGRESS_CA) tests/smoke.sh

chaos: ## Kill Redis and verify poll readiness recovery
	INGRESS_IP=$(INGRESS_IP) CACERT=$(INGRESS_CA) tests/chaos.sh

load: ## Run the k6 poll and result load tests
	$(K6) /scripts/poll.js
	$(K6) /scripts/result.js

##@ Add-ons
monitoring: ## Install Prometheus, Grafana and the poll dashboards
	kubectl apply -f kubernetes/namespace.yaml
	cd ansible && ansible-playbook monitoring.yaml $(ARGS)
	kubectl apply -k kubernetes/monitoring

logging: ## Install Loki, Alloy and the poll logs dashboard
	@kubectl get namespace monitoring >/dev/null 2>&1 || { echo "monitoring namespace not found: run 'make monitoring' first" >&2; exit 1; }
	kubectl apply -f kubernetes/namespace.yaml
	cd ansible && ansible-playbook logging.yaml $(ARGS)
	kubectl apply -k kubernetes/logging

metrics: ## Install metrics-server for the HPAs
	cd ansible && ansible-playbook metrics-server.yaml $(ARGS)

# Internal: create the poll-app secrets from .env.
_secrets:
	@scripts/secrets.sh
