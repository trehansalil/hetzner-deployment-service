KUBECTL := kubectl
NEONATAL_NS := neonatal-care
IMAGE_TAG ?= latest
IMAGE := ghcr.io/trehansalil/neonatal-care

# ─── Cluster Bootstrap ────────────────────────────────────────────────────────

.PHONY: cluster-init
cluster-init:
	$(KUBECTL) apply -f cluster/namespaces.yaml
	$(KUBECTL) apply -f cluster/ingress-nginx/
	$(KUBECTL) apply -f cluster/cert-manager/
	@echo "Cluster bootstrap complete. Wait ~60s for ingress-nginx pods to be ready."

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
	$(KUBECTL) rollout status deployment/neonatal-care-backend -n $(NEONATAL_NS)

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
