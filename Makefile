KUBECTL := kubectl
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

# ─── Neonatal Care App ────────────────────────────────────────────────────────

.PHONY: deploy-neonatal
deploy-neonatal:
	$(KUBECTL) apply -f apps/neonatal-care/namespace.yaml
	$(KUBECTL) apply -f apps/neonatal-care/configmap.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/secret.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/pvc.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/deployment.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/service.yaml -n $(NEONATAL_NS)
	$(KUBECTL) apply -f apps/neonatal-care/ingress.yaml -n $(NEONATAL_NS)

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

.PHONY: init-clickhouse
init-clickhouse:
	$(KUBECTL) apply -f apps/neonatal-care/jobs/init-clickhouse-job.yaml -n $(NEONATAL_NS)
	$(KUBECTL) wait --for=condition=complete job/init-clickhouse --timeout=120s -n $(NEONATAL_NS)

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
	$(KUBECTL) apply -f apps/airline-hr-chatbot/rbac.yaml
	$(KUBECTL) apply -f apps/airline-hr-chatbot/configmap.yaml -n $(HR_NS)
	$(KUBECTL) apply -f apps/airline-hr-chatbot/secret.yaml -n $(HR_NS)
	$(KUBECTL) apply -f apps/airline-hr-chatbot/pvc.yaml -n $(HR_NS)
	$(KUBECTL) apply -f apps/airline-hr-chatbot/deployment.yaml -n $(HR_NS)
	$(KUBECTL) apply -f apps/airline-hr-chatbot/daemonset.yaml -n $(HR_NS)
	$(KUBECTL) apply -f apps/airline-hr-chatbot/service.yaml -n $(HR_NS)
	$(KUBECTL) apply -f apps/airline-hr-chatbot/ingress.yaml -n $(HR_NS)

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

.PHONY: port-grafana-hr
port-grafana-hr:
	$(KUBECTL) port-forward -n $(HR_NS) svc/grafana 3000:3000

.PHONY: port-prometheus-hr
port-prometheus-hr:
	$(KUBECTL) port-forward -n $(HR_NS) svc/prometheus 9090:9090

.PHONY: port-adminer-hr
port-adminer-hr:
	$(KUBECTL) port-forward -n $(HR_NS) svc/adminer 8080:8080

.PHONY: destroy-hr
destroy-hr:
	@echo "WARNING: This will delete all hr-chatbot resources including persistent volumes!"
	$(KUBECTL) delete namespace $(HR_NS)
	$(KUBECTL) delete clusterrole promtail-hr-chatbot --ignore-not-found
	$(KUBECTL) delete clusterrolebinding promtail-hr-chatbot --ignore-not-found
