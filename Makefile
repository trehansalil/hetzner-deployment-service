KUBECTL := kubectl
INFRA_NS := infra
NEONATAL_NS := neonatal-care
IMAGE_TAG ?= latest
IMAGE := ghcr.io/trehansalil/neonatal-care

# ─── Cluster Bootstrap ────────────────────────────────────────────────────────

INGRESS_NGINX_VERSION := controller-v1.10.1
CERT_MANAGER_VERSION := v1.14.5

.PHONY: cluster-init
cluster-init:
	$(KUBECTL) apply -f cluster/namespaces.yaml
	$(KUBECTL) apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(INGRESS_NGINX_VERSION)/deploy/static/provider/baremetal/deploy.yaml
	@echo "Waiting for ingress-nginx controller to be ready..."
	$(KUBECTL) wait --for=condition=ready pod -l app.kubernetes.io/component=controller -n ingress-nginx --timeout=120s
	$(KUBECTL) apply -f https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml
	@echo "Waiting for cert-manager to be ready..."
	$(KUBECTL) wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
	$(KUBECTL) apply -f cluster/cert-manager/cluster-issuer.yaml
	$(KUBECTL) apply -f cluster/traefik-config.yaml
	@echo "Cluster bootstrap complete."

# ─── Shared Infrastructure (datastores + observability) ───────────────────────
# Deploy this FIRST — every app depends on it; it depends on nothing.
# Secrets are gitignored: run `make k8s-secrets-infra` before `make deploy-infra`,
# or place apps/infra/secret.yaml so the inline apply below succeeds.

# Adminer IP allow-list source range. Injected into the `adminer-ipallow` Middleware at
# deploy time (kubectl patch) so the real admin IP is NEVER committed to this public repo.
# Override per-invocation:  make deploy-infra ADMIN_CIDR=198.51.100.7/32
# Left unset it stays the fail-closed RFC-5737 placeholder (Adminer unreachable until set).
ADMIN_CIDR ?= 203.0.113.0/24

.PHONY: deploy-infra
deploy-infra:
	$(KUBECTL) apply -f apps/infra/namespace.yaml
	$(KUBECTL) apply -f apps/infra/configmap.yaml -n $(INFRA_NS)
	$(KUBECTL) apply -f apps/infra/secret.yaml -n $(INFRA_NS)
	$(KUBECTL) apply -f apps/infra/pvc.yaml -n $(INFRA_NS)
	$(KUBECTL) apply -f apps/infra/rbac.yaml
	# Services before the StatefulSet — the postgres StatefulSet's governing headless
	# Service (serviceName: postgres) must exist first for stable pod DNS on bring-up.
	$(KUBECTL) apply -f apps/infra/service.yaml -n $(INFRA_NS)
	$(KUBECTL) apply -f apps/infra/statefulset.yaml -n $(INFRA_NS)
	$(KUBECTL) apply -f apps/infra/deployment.yaml -n $(INFRA_NS)
	$(KUBECTL) apply -f apps/infra/daemonset.yaml -n $(INFRA_NS)
	$(KUBECTL) apply -f apps/infra/certificate.yaml -n $(INFRA_NS)
	$(KUBECTL) apply -f apps/infra/ingress.yaml -n $(INFRA_NS)
	# Inject the Adminer IP allow-list from $(ADMIN_CIDR) — keeps the real admin IP out of
	# this public repo. JSON merge patch replaces sourceRange wholesale; unset keeps the
	# committed fail-closed placeholder. See apps/infra/ingress.yaml for the env-var note.
	$(KUBECTL) patch middleware adminer-ipallow -n $(INFRA_NS) --type merge \
		-p '{"spec":{"ipAllowList":{"sourceRange":["$(ADMIN_CIDR)"]}}}'
	# The legacy per-host Ingresses superseded by this consolidated host live in the
	# hr-chatbot namespace (hr-chatbot-grafana / hr-chatbot-adminer) and must keep serving
	# through the migration validation window — they are pruned at decommission, not here.
	# See apps/infra/MIGRATION.md Phase 5.
	$(KUBECTL) apply -f apps/infra/cronjob-pod-cleanup.yaml -n $(INFRA_NS)

.PHONY: status-infra
status-infra:
	$(KUBECTL) get pods,svc,ingress,ingressroute,middleware,certificate,pvc -n $(INFRA_NS)

.PHONY: clean-pods-infra
clean-pods-infra:
	@echo "Deleting Failed/Evicted pods in $(INFRA_NS)..."
	$(KUBECTL) delete pods -n $(INFRA_NS) --field-selector=status.phase==Failed --ignore-not-found
	@echo "Deleting Succeeded pods in $(INFRA_NS)..."
	$(KUBECTL) delete pods -n $(INFRA_NS) --field-selector=status.phase==Succeeded --ignore-not-found
	@echo "Current pods:"
	$(KUBECTL) get pods -n $(INFRA_NS)

.PHONY: k8s-secrets-infra
k8s-secrets-infra:
	@if [ ! -f apps/infra/secret.yaml ]; then \
		echo "ERROR: apps/infra/secret.yaml not found."; \
		echo "Copy secret.yaml.example, fill in base64 values, then re-run."; \
		exit 1; \
	fi
	$(KUBECTL) apply -f apps/infra/namespace.yaml
	$(KUBECTL) apply -f apps/infra/secret.yaml -n $(INFRA_NS)

# Initialize the ClickHouse schema (one-time). Requires the `infra-sql-init`
# ConfigMap to exist first:
#   kubectl create configmap infra-sql-init \
#     --from-file=init_clickhouse.sql=<path-to-file> -n infra
.PHONY: init-clickhouse
init-clickhouse:
	$(KUBECTL) apply -f apps/infra/jobs/init-clickhouse-job.yaml -n $(INFRA_NS)
	$(KUBECTL) wait --for=condition=complete job/init-clickhouse --timeout=120s -n $(INFRA_NS)

.PHONY: port-grafana-infra
port-grafana-infra:
	$(KUBECTL) port-forward -n $(INFRA_NS) svc/grafana 3000:3000

.PHONY: port-prometheus-infra
port-prometheus-infra:
	$(KUBECTL) port-forward -n $(INFRA_NS) svc/prometheus 9090:9090

.PHONY: port-adminer-infra
port-adminer-infra:
	$(KUBECTL) port-forward -n $(INFRA_NS) svc/adminer 8080:8080

.PHONY: destroy-infra
destroy-infra:
	@echo "WARNING: This deletes ALL shared infrastructure (datastores + observability)"
	@echo "         including persistent volumes. Every app depends on it — destroy the"
	@echo "         app namespaces FIRST. This should almost never be run."
	$(KUBECTL) delete namespace $(INFRA_NS)
	$(KUBECTL) delete clusterrole promtail-infra --ignore-not-found
	$(KUBECTL) delete clusterrolebinding promtail-infra --ignore-not-found

# ─── Neonatal Care App ────────────────────────────────────────────────────────

.PHONY: deploy-neonatal
deploy-neonatal:
	$(KUBECTL) apply -f apps/neonatal-care/namespace.yaml
	$(KUBECTL) apply -f apps/neonatal-care/limitrange.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/resourcequota.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/configmap.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/secret.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/deployment.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/service.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/ingress.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/cronjob-pod-cleanup.yaml -n $(NEONATAL_NS)

.PHONY: rollout-neonatal
rollout-neonatal:
	$(KUBECTL) set image deployment/neonatal-care-backend \
		neonatal-care-backend=$(IMAGE):$(IMAGE_TAG) \
		-n $(NEONATAL_NS)
	$(KUBECTL) set image deployment/neonatal-care-nginx \
		copy-static=$(IMAGE):$(IMAGE_TAG) \
		-n $(NEONATAL_NS)
	$(KUBECTL) rollout restart deployment/neonatal-care-nginx -n $(NEONATAL_NS)
	$(KUBECTL) rollout status deployment/neonatal-care-backend -n $(NEONATAL_NS)
	$(KUBECTL) rollout status deployment/neonatal-care-nginx -n $(NEONATAL_NS)

.PHONY: status-neonatal
status-neonatal:
	$(KUBECTL) get pods,svc,ingress -n $(NEONATAL_NS)

.PHONY: logs-neonatal
logs-neonatal:
	$(KUBECTL) logs -l app=neonatal-care-backend -n $(NEONATAL_NS) --tail=100 -f

.PHONY: rollback-neonatal
rollback-neonatal:
	$(KUBECTL) rollout undo deployment/neonatal-care-backend -n $(NEONATAL_NS)

.PHONY: clean-pods-neonatal
clean-pods-neonatal:
	@echo "Deleting Failed/Evicted pods in $(NEONATAL_NS)..."
	$(KUBECTL) delete pods -n $(NEONATAL_NS) --field-selector=status.phase==Failed --ignore-not-found
	@echo "Deleting Succeeded pods in $(NEONATAL_NS)..."
	$(KUBECTL) delete pods -n $(NEONATAL_NS) --field-selector=status.phase==Succeeded --ignore-not-found
	@echo "Current pods:"
	$(KUBECTL) get pods -n $(NEONATAL_NS)

.PHONY: k8s-secrets-neonatal
k8s-secrets-neonatal:
	@if [ ! -f apps/neonatal-care/secret.yaml ]; then \
		echo "ERROR: apps/neonatal-care/secret.yaml not found."; \
		echo "Copy secret.yaml.example, fill in base64 values, then re-run."; \
		exit 1; \
	fi
	$(KUBECTL) apply -f apps/neonatal-care/namespace.yaml
	$(KUBECTL) apply -f apps/neonatal-care/secret.yaml -n $(NEONATAL_NS)

.PHONY: status-neonatal-resources
status-neonatal-resources:
	@echo "=== ResourceQuota ==="
	$(KUBECTL) describe resourcequota neonatal-care-quota -n $(NEONATAL_NS)
	@echo "=== LimitRange ==="
	$(KUBECTL) describe limitrange neonatal-care-defaults -n $(NEONATAL_NS)
	@echo "=== Pods ==="
	$(KUBECTL) get pods -n $(NEONATAL_NS) -o wide

.PHONY: destroy-neonatal
destroy-neonatal:
	@echo "WARNING: This will delete all neonatal-care resources including persistent volumes!"
	$(KUBECTL) delete namespace $(NEONATAL_NS)

# ─── Airline HR Chatbot ───────────────────────────────────────────────────────

HR_NS := hr-chatbot
HR_IMAGE := ghcr.io/trehansalil/airline-hr-chatbot
HR_IMAGE_TAG ?= latest

.PHONY: deploy-hr
deploy-hr:
	$(KUBECTL) apply -f apps/airline-hr-chatbot/namespace.yaml
	$(KUBECTL) apply -f apps/airline-hr-chatbot/secret.yaml -n $(HR_NS)
	$(KUBECTL) apply -f apps/airline-hr-chatbot/deployment.yaml -n $(HR_NS)
	$(KUBECTL) apply -f apps/airline-hr-chatbot/service.yaml -n $(HR_NS)
	$(KUBECTL) apply -f apps/airline-hr-chatbot/ingress.yaml -n $(HR_NS)
	$(KUBECTL) apply -f apps/airline-hr-chatbot/cronjob-pod-cleanup.yaml -n $(HR_NS)

.PHONY: rollout-hr
rollout-hr:
	$(KUBECTL) set image deployment/app \
		app=$(HR_IMAGE):$(HR_IMAGE_TAG) \
		-n $(HR_NS)
	$(KUBECTL) set image deployment/oracle \
		oracle=$(HR_IMAGE):$(HR_IMAGE_TAG) \
		-n $(HR_NS)
	$(KUBECTL) rollout status deployment/app -n $(HR_NS) --timeout=300s
	$(KUBECTL) rollout status deployment/oracle -n $(HR_NS) --timeout=120s

.PHONY: status-hr
status-hr:
	$(KUBECTL) get pods,svc,ingress,pvc -n $(HR_NS)

.PHONY: logs-hr
logs-hr:
	$(KUBECTL) logs -l app=app -n $(HR_NS) --tail=100 -f

.PHONY: rollback-hr
rollback-hr:
	$(KUBECTL) rollout undo deployment/app -n $(HR_NS)

.PHONY: clean-pods-hr
clean-pods-hr:
	@echo "Deleting Failed/Evicted pods in $(HR_NS)..."
	$(KUBECTL) delete pods -n $(HR_NS) --field-selector=status.phase==Failed --ignore-not-found
	@echo "Deleting Succeeded pods in $(HR_NS)..."
	$(KUBECTL) delete pods -n $(HR_NS) --field-selector=status.phase==Succeeded --ignore-not-found
	@echo "Current pods:"
	$(KUBECTL) get pods -n $(HR_NS)

.PHONY: ghcr-secret-hr
ghcr-secret-hr:
	@if [ -z "$(GITHUB_PAT)" ]; then \
		echo "ERROR: GITHUB_PAT is required. Run: make ghcr-secret-hr GITHUB_PAT=<your-pat>"; \
		exit 1; \
	fi
	$(KUBECTL) apply -f apps/airline-hr-chatbot/namespace.yaml
	$(KUBECTL) create secret docker-registry ghcr-credentials \
		--docker-server=ghcr.io \
		--docker-username=trehansalil \
		--docker-password=$(GITHUB_PAT) \
		-n $(HR_NS) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

.PHONY: k8s-secrets-hr
k8s-secrets-hr:
	@if [ ! -f apps/airline-hr-chatbot/secret.yaml ]; then \
		echo "ERROR: apps/airline-hr-chatbot/secret.yaml not found."; \
		echo "Copy secret.yaml.example, fill in base64 values, then re-run."; \
		exit 1; \
	fi
	$(KUBECTL) apply -f apps/airline-hr-chatbot/namespace.yaml
	$(KUBECTL) apply -f apps/airline-hr-chatbot/secret.yaml -n $(HR_NS)

.PHONY: ingest-hr
ingest-hr:
	$(KUBECTL) exec -n $(HR_NS) deploy/app -- python ingest.py --docs-dir /app/docs

.PHONY: ingest-recreate-hr
ingest-recreate-hr:
	$(KUBECTL) exec -n $(HR_NS) deploy/app -- python ingest.py --recreate --docs-dir /app/docs

.PHONY: shell-hr
shell-hr:
	$(KUBECTL) exec -it -n $(HR_NS) deploy/app -- bash

.PHONY: port-app-hr
port-app-hr:
	$(KUBECTL) port-forward -n $(HR_NS) svc/app 9040:9040

# Grafana / Prometheus / Adminer now live in the infra namespace:
#   make port-grafana-infra | port-prometheus-infra | port-adminer-infra

.PHONY: destroy-hr
destroy-hr:
	@echo "WARNING: This will delete all hr-chatbot resources!"
	@echo "         Shared infra (Postgres, monitoring) is NOT touched — it lives in the infra namespace."
	$(KUBECTL) delete namespace $(HR_NS)
	# Legacy cluster-scoped RBAC from the pre-infra topology (promtail used to run in
	# hr-chatbot). It survives `kubectl delete namespace`, so prune it explicitly. No-op
	# on clusters provisioned from the current manifests (promtail now lives in infra as
	# promtail-infra).
	$(KUBECTL) delete clusterrole promtail-hr-chatbot --ignore-not-found
	$(KUBECTL) delete clusterrolebinding promtail-hr-chatbot --ignore-not-found

# ─── PageIndex MCP Server ────────────────────────────────────────────────────

PAGEINDEX_NS := pageindex-mcp
PAGEINDEX_IMAGE := ghcr.io/trehansalil/pageindex-mcp
PAGEINDEX_IMAGE_TAG ?= latest

.PHONY: deploy-pageindex
deploy-pageindex:
	$(KUBECTL) apply -f apps/pageindex-mcp/namespace.yaml
	$(KUBECTL) apply -f apps/pageindex-mcp/configmap.yaml -n $(PAGEINDEX_NS)
	$(KUBECTL) apply -f apps/pageindex-mcp/deployment.yaml -n $(PAGEINDEX_NS)
	$(KUBECTL) apply -f apps/pageindex-mcp/worker-deployment.yaml -n $(PAGEINDEX_NS)
	$(KUBECTL) apply -f apps/pageindex-mcp/service.yaml -n $(PAGEINDEX_NS)
	$(KUBECTL) apply -f apps/pageindex-mcp/certificate.yaml -n $(PAGEINDEX_NS)
	$(KUBECTL) apply -f apps/pageindex-mcp/ingress.yaml -n $(PAGEINDEX_NS)
	$(KUBECTL) delete ingress pageindex-mcp -n $(PAGEINDEX_NS) --ignore-not-found
	$(KUBECTL) apply -f apps/pageindex-mcp/cronjob-pod-cleanup.yaml -n $(PAGEINDEX_NS)

.PHONY: rollout-pageindex
rollout-pageindex:
	$(KUBECTL) set image deployment/pageindex-mcp \
		pageindex-mcp=$(PAGEINDEX_IMAGE):$(PAGEINDEX_IMAGE_TAG) \
		-n $(PAGEINDEX_NS)
	$(KUBECTL) set image deployment/pageindex-mcp-worker \
		worker=$(PAGEINDEX_IMAGE):$(PAGEINDEX_IMAGE_TAG) \
		-n $(PAGEINDEX_NS)
	$(KUBECTL) rollout status deployment/pageindex-mcp -n $(PAGEINDEX_NS) --timeout=300s
	$(KUBECTL) rollout status deployment/pageindex-mcp-worker -n $(PAGEINDEX_NS) --timeout=300s

.PHONY: status-pageindex
status-pageindex:
	$(KUBECTL) get pods,svc,ingress -n $(PAGEINDEX_NS)

.PHONY: logs-pageindex
logs-pageindex:
	$(KUBECTL) logs -l app=pageindex-mcp -n $(PAGEINDEX_NS) --tail=100 -f

.PHONY: rollback-pageindex
rollback-pageindex:
	$(KUBECTL) rollout undo deployment/pageindex-mcp -n $(PAGEINDEX_NS)
	$(KUBECTL) rollout undo deployment/pageindex-mcp-worker -n $(PAGEINDEX_NS)

.PHONY: ghcr-secret-pageindex
ghcr-secret-pageindex:
	@if [ -z "$(GITHUB_PAT)" ]; then \
		echo "ERROR: GITHUB_PAT is required. Run: make ghcr-secret-pageindex GITHUB_PAT=<your-pat>"; \
		exit 1; \
	fi
	$(KUBECTL) apply -f apps/pageindex-mcp/namespace.yaml
	$(KUBECTL) create secret docker-registry ghcr-credentials \
		--docker-server=ghcr.io \
		--docker-username=trehansalil \
		--docker-password=$(GITHUB_PAT) \
		-n $(PAGEINDEX_NS) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

.PHONY: k8s-secrets-pageindex
k8s-secrets-pageindex:
	@if [ ! -f apps/pageindex-mcp/secret.yaml ]; then \
		echo "ERROR: apps/pageindex-mcp/secret.yaml not found."; \
		echo "Copy secret.yaml.example, fill in base64 values, then re-run."; \
		exit 1; \
	fi
	$(KUBECTL) apply -f apps/pageindex-mcp/namespace.yaml
	$(KUBECTL) apply -f apps/pageindex-mcp/secret.yaml -n $(PAGEINDEX_NS)

.PHONY: destroy-pageindex
destroy-pageindex:
	@echo "WARNING: This will delete all pageindex-mcp resources including persistent volumes!"
	$(KUBECTL) delete namespace $(PAGEINDEX_NS)
