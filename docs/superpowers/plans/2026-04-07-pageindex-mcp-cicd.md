# PageIndex MCP CI/CD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a full CI/CD pipeline for the PageIndex MCP Server, from Docker image build through GitHub Actions to Kubernetes deployment on Hetzner, with log monitoring via the existing Grafana stack.

**Architecture:** Source repo (`trehansalil/pageindex`) builds and pushes a Docker image to GHCR on every push to `main`, then fires a `repository_dispatch` event to `trehansalil/hetzner-deployment-service`. The deployment repo's workflow applies K8s manifests and performs a rolling update on the Hetzner k3s cluster. Logs are scraped by the existing Promtail DaemonSet and visualized in the existing Grafana instance.

**Tech Stack:** Docker (multi-stage, uv), GitHub Actions, Kubernetes (k3s), Traefik Ingress, cert-manager, Loki/Promtail/Grafana

---

## File Map

### Source Repo: `/root/pageindex_deployment/` (remote: `trehansalil/pageindex`)

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `Dockerfile` | Multi-stage build: install deps with uv, copy app, expose port 8201 |
| Create | `.dockerignore` | Exclude .venv, .git, .env, logs, doc_store, __pycache__ |
| Create | `.github/workflows/build-push.yml` | Build image, push to GHCR, fire repository_dispatch |

### Deployment Repo: `/root/hetzner-deployment-service/` (remote: `trehansalil/hetzner-deployment-service`)

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `apps/pageindex-mcp/namespace.yaml` | Namespace definition |
| Create | `apps/pageindex-mcp/configmap.yaml` | Non-secret env vars (MinIO endpoint, MCP host/port) |
| Create | `apps/pageindex-mcp/secret.yaml.example` | Template for secrets (OPENAI_API_KEY, MinIO creds) |
| Create | `apps/pageindex-mcp/deployment.yaml` | MCP server Deployment (1 replica, GHCR image, probes) |
| Create | `apps/pageindex-mcp/service.yaml` | ClusterIP service on port 8201 |
| Create | `apps/pageindex-mcp/ingress.yaml` | Traefik ingress for pageindex.aiwithsalil.work with TLS |
| Create | `apps/pageindex-mcp/cronjob-pod-cleanup.yaml` | CronJob to clean evicted/failed pods every 15 min |
| Modify | `cluster/namespaces.yaml` | Add pageindex-mcp namespace entry |
| Modify | `.github/workflows/deploy.yml` | Add pageindex-mcp dispatch, manifests, rollout steps |
| Modify | `Makefile` | Add pageindex-mcp variables and targets |
| Modify | `apps/airline-hr-chatbot/configmap.yaml` | Extend Promtail namespaces; add Grafana dashboard JSON |

---

### Task 1: Dockerfile and .dockerignore (source repo)

**Files:**
- Create: `/root/pageindex_deployment/Dockerfile`
- Create: `/root/pageindex_deployment/.dockerignore`

- [ ] **Step 1: Create `.dockerignore`**

```dockerignore
.venv/
.git/
.env
.env.*
logs/
doc_store/
__pycache__/
*.pyc
preprocess.log
*.egg-info/
.claude/
docs/
tests/
.github/
```

- [ ] **Step 2: Create `Dockerfile`**

Multi-stage build using the official `uv` Docker pattern. The `pageindex` pip dependency comes from a public GitHub repo, so no auth is needed. `git` is installed in the build stage to support the `git+https://` dependency.

```dockerfile
FROM python:3.12-slim AS builder

# Install uv and git (needed for git+https:// dependencies)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install dependencies first (cache-friendly layer ordering)
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# Copy source and install the project itself
COPY mcp_server.py ./
COPY src/ ./src/
RUN uv sync --frozen --no-dev

# ─── Runtime ─────────────────────────────────────────────────────────────────
FROM python:3.12-slim

WORKDIR /app

# Copy the entire virtual environment from the builder
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/mcp_server.py ./
COPY --from=builder /app/src/ ./src/

# Put the venv's Python on PATH
ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8201

CMD ["python", "mcp_server.py"]
```

- [ ] **Step 3: Verify Docker build succeeds locally**

Run:
```bash
cd /root/pageindex_deployment && docker build -t pageindex-mcp:test .
```

Expected: Build completes successfully, image is created.

- [ ] **Step 4: Verify the image runs**

Run:
```bash
docker run --rm -e OPENAI_API_KEY=test -e MINIO_ENDPOINT=localhost:9000 -p 8201:8201 pageindex-mcp:test &
sleep 5
curl -s http://localhost:8201/mcp || echo "Server responded (MCP endpoint may not serve GET)"
docker stop $(docker ps -q --filter ancestor=pageindex-mcp:test) 2>/dev/null
```

Expected: Container starts, prints "Starting PageIndex MCP server at http://0.0.0.0:8201/mcp". The curl may get a non-200 (MCP uses POST), but the server should be listening.

- [ ] **Step 5: Commit**

```bash
cd /root/pageindex_deployment
git add Dockerfile .dockerignore
git commit -m "feat: add Dockerfile and .dockerignore for containerized deployment"
```

---

### Task 2: Build & Push GitHub Actions workflow (source repo)

**Files:**
- Create: `/root/pageindex_deployment/.github/workflows/build-push.yml`

- [ ] **Step 1: Create workflow directory**

```bash
mkdir -p /root/pageindex_deployment/.github/workflows
```

- [ ] **Step 2: Create `build-push.yml`**

```yaml
name: Build & Push to GHCR

on:
  push:
    branches: [main]

env:
  IMAGE_NAME: ghcr.io/trehansalil/pageindex-mcp

jobs:
  build-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.IMAGE_NAME }}:sha-${{ github.sha }}
            ${{ env.IMAGE_NAME }}:latest

      - name: Trigger deploy
        uses: peter-evans/repository-dispatch@v3
        with:
          token: ${{ secrets.DEPLOY_PAT }}
          repository: trehansalil/hetzner-deployment-service
          event-type: pageindex-mcp-image-updated
          client-payload: '{"app": "pageindex-mcp", "image_tag": "sha-${{ github.sha }}"}'
```

- [ ] **Step 3: Validate workflow YAML syntax**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('/root/pageindex_deployment/.github/workflows/build-push.yml'))" && echo "YAML valid"
```

Expected: "YAML valid"

- [ ] **Step 4: Commit**

```bash
cd /root/pageindex_deployment
git add .github/workflows/build-push.yml
git commit -m "ci: add build-push workflow for GHCR and deploy trigger"
```

---

### Task 3: K8s namespace, configmap, and secret template (deployment repo)

**Files:**
- Create: `/root/hetzner-deployment-service/apps/pageindex-mcp/namespace.yaml`
- Create: `/root/hetzner-deployment-service/apps/pageindex-mcp/configmap.yaml`
- Create: `/root/hetzner-deployment-service/apps/pageindex-mcp/secret.yaml.example`

- [ ] **Step 1: Create the app directory**

```bash
mkdir -p /root/hetzner-deployment-service/apps/pageindex-mcp
```

- [ ] **Step 2: Create `namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: pageindex-mcp
  labels:
    app.kubernetes.io/part-of: pageindex-mcp
```

- [ ] **Step 3: Create `configmap.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pageindex-mcp-config
  namespace: pageindex-mcp
data:
  MINIO_ENDPOINT: "neonatal-care-minio.neonatal-care:9000"
  MINIO_BUCKET: "pageindex"
  MINIO_SECURE: "false"
  MCP_HOST: "0.0.0.0"
  MCP_PORT: "8201"
```

- [ ] **Step 4: Create `secret.yaml.example`**

```yaml
# Copy this file to secret.yaml, fill in base64-encoded values, then apply:
#   make k8s-secrets-pageindex
#
# To base64 encode a value:
#   echo -n 'your-value' | base64
#
# secret.yaml is gitignored. For production use Sealed Secrets or External Secrets Operator.
apiVersion: v1
kind: Secret
metadata:
  name: pageindex-mcp-secrets
  namespace: pageindex-mcp
type: Opaque
data:
  OPENAI_API_KEY: CHANGE_ME_BASE64
  MINIO_ACCESS_KEY: bWluaW9hZG1pbg==       # base64('minioadmin') — CHANGE THIS
  MINIO_SECRET_KEY: bWluaW9hZG1pbg==       # base64('minioadmin') — CHANGE THIS
```

- [ ] **Step 5: Validate manifests with kubectl dry-run**

Run:
```bash
kubectl apply -f /root/hetzner-deployment-service/apps/pageindex-mcp/namespace.yaml --dry-run=client
kubectl apply -f /root/hetzner-deployment-service/apps/pageindex-mcp/configmap.yaml --dry-run=client
```

Expected: `namespace/pageindex-mcp configured (dry run)` and `configmap/pageindex-mcp-config configured (dry run)`

- [ ] **Step 6: Commit**

```bash
cd /root/hetzner-deployment-service
git add apps/pageindex-mcp/namespace.yaml apps/pageindex-mcp/configmap.yaml apps/pageindex-mcp/secret.yaml.example
git commit -m "feat: add pageindex-mcp namespace, configmap, and secret template"
```

---

### Task 4: K8s deployment, service, and ingress (deployment repo)

**Files:**
- Create: `/root/hetzner-deployment-service/apps/pageindex-mcp/deployment.yaml`
- Create: `/root/hetzner-deployment-service/apps/pageindex-mcp/service.yaml`
- Create: `/root/hetzner-deployment-service/apps/pageindex-mcp/ingress.yaml`

- [ ] **Step 1: Create `deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pageindex-mcp
  namespace: pageindex-mcp
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
  selector:
    matchLabels:
      app: pageindex-mcp
  template:
    metadata:
      labels:
        app: pageindex-mcp
    spec:
      imagePullSecrets:
        - name: ghcr-credentials
      containers:
        - name: pageindex-mcp
          image: ghcr.io/trehansalil/pageindex-mcp:latest
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 8201
          envFrom:
            - configMapRef:
                name: pageindex-mcp-config
            - secretRef:
                name: pageindex-mcp-secrets
          readinessProbe:
            tcpSocket:
              port: 8201
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 5
          livenessProbe:
            tcpSocket:
              port: 8201
            initialDelaySeconds: 30
            periodSeconds: 15
            failureThreshold: 3
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "2Gi"
```

- [ ] **Step 2: Create `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pageindex-mcp
  namespace: pageindex-mcp
spec:
  type: ClusterIP
  selector:
    app: pageindex-mcp
  ports:
    - name: http
      port: 8201
      targetPort: 8201
```

- [ ] **Step 3: Create `ingress.yaml`**

```yaml
# Prerequisites:
#   1. cert-manager installed and letsencrypt-prod ClusterIssuer configured (make cluster-init)
#   2. DNS A record: pageindex.aiwithsalil.work -> Hetzner server IP
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pageindex-mcp
  namespace: pageindex-mcp
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - pageindex.aiwithsalil.work
      secretName: pageindex-mcp-tls
  rules:
    - host: pageindex.aiwithsalil.work
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: pageindex-mcp
                port:
                  number: 8201
```

- [ ] **Step 4: Validate manifests with kubectl dry-run**

Run:
```bash
kubectl apply -f /root/hetzner-deployment-service/apps/pageindex-mcp/deployment.yaml --dry-run=client
kubectl apply -f /root/hetzner-deployment-service/apps/pageindex-mcp/service.yaml --dry-run=client
kubectl apply -f /root/hetzner-deployment-service/apps/pageindex-mcp/ingress.yaml --dry-run=client
```

Expected: All three report `configured (dry run)` with no errors.

- [ ] **Step 5: Commit**

```bash
cd /root/hetzner-deployment-service
git add apps/pageindex-mcp/deployment.yaml apps/pageindex-mcp/service.yaml apps/pageindex-mcp/ingress.yaml
git commit -m "feat: add pageindex-mcp deployment, service, and ingress manifests"
```

---

### Task 5: CronJob pod cleanup (deployment repo)

**Files:**
- Create: `/root/hetzner-deployment-service/apps/pageindex-mcp/cronjob-pod-cleanup.yaml`

- [ ] **Step 1: Create `cronjob-pod-cleanup.yaml`**

Same pattern as `apps/neonatal-care/cronjob-pod-cleanup.yaml` but scoped to `pageindex-mcp` namespace.

```yaml
# ─── ServiceAccount for pod cleanup ──────────────────────────────────────────
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-cleanup
  namespace: pageindex-mcp
---
# ─── Role: minimal permissions to list and delete pods in this namespace ──────
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-cleanup
  namespace: pageindex-mcp
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "delete"]
---
# ─── RoleBinding ──────────────────────────────────────────────────────────────
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-cleanup
  namespace: pageindex-mcp
subjects:
- kind: ServiceAccount
  name: pod-cleanup
  namespace: pageindex-mcp
roleRef:
  kind: Role
  name: pod-cleanup
  apiGroup: rbac.authorization.k8s.io
---
# ─── CronJob: delete Evicted, Failed, and Succeeded pods every 15 minutes ────
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pod-cleanup
  namespace: pageindex-mcp
spec:
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 300
      template:
        spec:
          serviceAccountName: pod-cleanup
          restartPolicy: OnFailure
          containers:
          - name: kubectl
            image: alpine/k8s:1.29.7
            resources:
              requests:
                memory: "32Mi"
                cpu: "10m"
              limits:
                memory: "64Mi"
                cpu: "100m"
            command:
            - /bin/sh
            - -c
            - |
              set -e
              NS="pageindex-mcp"
              echo "=== Pod cleanup run: $(date) ==="

              # Delete all pods in Failed phase (includes Evicted + OOMKilled)
              FAILED=$(kubectl get pods -n "$NS" \
                --field-selector=status.phase==Failed \
                -o jsonpath='{.items[*].metadata.name}')
              if [ -n "$FAILED" ]; then
                echo "Deleting failed/evicted pods: $FAILED"
                echo "$FAILED" | tr ' ' '\n' | \
                  xargs kubectl delete pod -n "$NS" --ignore-not-found
              else
                echo "No failed/evicted pods found."
              fi

              # Delete pods in Succeeded phase (completed init containers, jobs, etc.)
              SUCCEEDED=$(kubectl get pods -n "$NS" \
                --field-selector=status.phase==Succeeded \
                -o jsonpath='{.items[*].metadata.name}')
              if [ -n "$SUCCEEDED" ]; then
                echo "Deleting succeeded pods: $SUCCEEDED"
                echo "$SUCCEEDED" | tr ' ' '\n' | \
                  xargs kubectl delete pod -n "$NS" --ignore-not-found
              else
                echo "No succeeded pods found."
              fi

              echo "=== Cleanup complete ==="
```

- [ ] **Step 2: Validate with dry-run**

Run:
```bash
kubectl apply -f /root/hetzner-deployment-service/apps/pageindex-mcp/cronjob-pod-cleanup.yaml --dry-run=client
```

Expected: All four resources (ServiceAccount, Role, RoleBinding, CronJob) report `configured (dry run)`.

- [ ] **Step 3: Commit**

```bash
cd /root/hetzner-deployment-service
git add apps/pageindex-mcp/cronjob-pod-cleanup.yaml
git commit -m "feat: add pageindex-mcp pod cleanup cronjob"
```

---

### Task 6: Update cluster namespaces (deployment repo)

**Files:**
- Modify: `/root/hetzner-deployment-service/cluster/namespaces.yaml`

- [ ] **Step 1: Add pageindex-mcp namespace**

Append to the end of `cluster/namespaces.yaml` (after the existing `cert-manager` namespace entry):

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: pageindex-mcp
  labels:
    app.kubernetes.io/managed-by: kubectl
```

- [ ] **Step 2: Validate**

Run:
```bash
kubectl apply -f /root/hetzner-deployment-service/cluster/namespaces.yaml --dry-run=client
```

Expected: All five namespaces report `configured (dry run)`.

- [ ] **Step 3: Commit**

```bash
cd /root/hetzner-deployment-service
git add cluster/namespaces.yaml
git commit -m "feat: add pageindex-mcp to cluster namespace definitions"
```

---

### Task 7: Update deploy workflow (deployment repo)

**Files:**
- Modify: `/root/hetzner-deployment-service/.github/workflows/deploy.yml`

- [ ] **Step 1: Add `pageindex-mcp-image-updated` to repository_dispatch types**

In the `on.repository_dispatch.types` array, add the new event type. The section becomes:

```yaml
on:
  repository_dispatch:
    types:
      - neonatal-care-image-updated
      - airline-hr-chatbot-image-updated
      - pageindex-mcp-image-updated
```

- [ ] **Step 2: Add `pageindex-mcp` to workflow_dispatch choices**

In `on.workflow_dispatch.inputs.app.options`, add the new option:

```yaml
        options:
          - neonatal-care
          - airline-hr-chatbot
          - pageindex-mcp
```

- [ ] **Step 3: Add "Apply k8s manifests -- pageindex-mcp" step**

Insert after the "Post-deploy pod cleanup -- airline-hr-chatbot" step (after line 84):

```yaml
      - name: Apply k8s manifests — pageindex-mcp
        if: steps.vars.outputs.app == 'pageindex-mcp'
        run: |
          kubectl apply -f apps/pageindex-mcp/namespace.yaml
          kubectl apply -f apps/pageindex-mcp/configmap.yaml -n pageindex-mcp
          kubectl apply -f apps/pageindex-mcp/deployment.yaml -n pageindex-mcp
          kubectl apply -f apps/pageindex-mcp/service.yaml -n pageindex-mcp
          kubectl apply -f apps/pageindex-mcp/ingress.yaml -n pageindex-mcp
          kubectl apply -f apps/pageindex-mcp/cronjob-pod-cleanup.yaml -n pageindex-mcp
```

- [ ] **Step 4: Add "Update image tag (rolling deploy) -- pageindex-mcp" step**

Insert after the airline-hr-chatbot rolling deploy step:

```yaml
      - name: Update image tag (rolling deploy) — pageindex-mcp
        if: steps.vars.outputs.app == 'pageindex-mcp'
        run: |
          kubectl set image deployment/pageindex-mcp \
            pageindex-mcp=ghcr.io/trehansalil/pageindex-mcp:${{ steps.vars.outputs.image_tag }} \
            -n pageindex-mcp
          kubectl rollout status deployment/pageindex-mcp -n pageindex-mcp --timeout=300s
```

- [ ] **Step 5: Add "Post-deploy pod cleanup -- pageindex-mcp" step**

Insert after the neonatal-care pod cleanup step:

```yaml
      - name: Post-deploy pod cleanup — pageindex-mcp
        if: steps.vars.outputs.app == 'pageindex-mcp'
        run: |
          echo "Cleaning up evicted/failed/succeeded pods post-deploy..."
          kubectl delete pods -n pageindex-mcp --field-selector=status.phase==Failed --ignore-not-found || true
          kubectl delete pods -n pageindex-mcp --field-selector=status.phase==Succeeded --ignore-not-found || true
```

- [ ] **Step 6: Update "Verify deployment" step**

The existing verify step uses a conditional namespace expression. Update it to also handle `pageindex-mcp`. Replace the existing verify step with:

```yaml
      - name: Verify deployment
        run: |
          APP="${{ steps.vars.outputs.app }}"
          if [ "$APP" = "airline-hr-chatbot" ]; then
            NS="hr-chatbot"
          else
            NS="$APP"
          fi
          kubectl get pods -n "$NS"
```

- [ ] **Step 7: Validate workflow YAML syntax**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('/root/hetzner-deployment-service/.github/workflows/deploy.yml'))" && echo "YAML valid"
```

Expected: "YAML valid"

- [ ] **Step 8: Commit**

```bash
cd /root/hetzner-deployment-service
git add .github/workflows/deploy.yml
git commit -m "ci: add pageindex-mcp to deploy workflow (dispatch, manifests, rollout)"
```

---

### Task 8: Update Makefile (deployment repo)

**Files:**
- Modify: `/root/hetzner-deployment-service/Makefile`

- [ ] **Step 1: Add pageindex-mcp variables and targets**

Append the following section at the end of the Makefile (after the hr-chatbot section ending at the `destroy-hr` target):

```makefile
# ─── PageIndex MCP Server ────────────────────────────────────────────────────

PAGEINDEX_NS := pageindex-mcp
PAGEINDEX_IMAGE := ghcr.io/trehansalil/pageindex-mcp
PAGEINDEX_IMAGE_TAG ?= latest

.PHONY: deploy-pageindex
deploy-pageindex:
	$(KUBECTL) apply -f apps/pageindex-mcp/namespace.yaml
	$(KUBECTL) apply -f apps/pageindex-mcp/configmap.yaml -n $(PAGEINDEX_NS)
	$(KUBECTL) apply -f apps/pageindex-mcp/deployment.yaml -n $(PAGEINDEX_NS)
	$(KUBECTL) apply -f apps/pageindex-mcp/service.yaml -n $(PAGEINDEX_NS)
	$(KUBECTL) apply -f apps/pageindex-mcp/ingress.yaml -n $(PAGEINDEX_NS)
	$(KUBECTL) apply -f apps/pageindex-mcp/cronjob-pod-cleanup.yaml -n $(PAGEINDEX_NS)

.PHONY: rollout-pageindex
rollout-pageindex:
	$(KUBECTL) set image deployment/pageindex-mcp \
		pageindex-mcp=$(PAGEINDEX_IMAGE):$(PAGEINDEX_IMAGE_TAG) \
		-n $(PAGEINDEX_NS)
	$(KUBECTL) rollout status deployment/pageindex-mcp -n $(PAGEINDEX_NS) --timeout=300s

.PHONY: status-pageindex
status-pageindex:
	$(KUBECTL) get pods,svc,ingress -n $(PAGEINDEX_NS)

.PHONY: logs-pageindex
logs-pageindex:
	$(KUBECTL) logs -l app=pageindex-mcp -n $(PAGEINDEX_NS) --tail=100 -f

.PHONY: rollback-pageindex
rollback-pageindex:
	$(KUBECTL) rollout undo deployment/pageindex-mcp -n $(PAGEINDEX_NS)

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
```

- [ ] **Step 2: Validate Makefile syntax**

Run:
```bash
cd /root/hetzner-deployment-service && make -n deploy-pageindex
```

Expected: Prints the kubectl commands that would run (dry-run mode), no syntax errors.

- [ ] **Step 3: Commit**

```bash
cd /root/hetzner-deployment-service
git add Makefile
git commit -m "feat: add pageindex-mcp Makefile targets (deploy, rollout, status, logs, secrets)"
```

---

### Task 9: Extend Promtail + add Grafana dashboard (deployment repo)

**Files:**
- Modify: `/root/hetzner-deployment-service/apps/airline-hr-chatbot/configmap.yaml`

- [ ] **Step 1: Update Promtail namespace scrape list**

In the `promtail-config` ConfigMap, locate the `kubernetes_sd_configs` section (around line 341-345). Change the namespaces list from:

```yaml
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names:
                - hr-chatbot
```

to:

```yaml
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names:
                - hr-chatbot
                - pageindex-mcp
```

- [ ] **Step 2: Add Grafana dashboard provider entry**

In the `grafana-dashboard-provider` ConfigMap, update the provider name and folder to be more general since it now serves multiple apps. Locate the `dashboards.yml` key (around line 423-435). Change:

```yaml
      - name: "HR Chatbot"
        orgId: 1
        folder: "HR Chatbot"
```

to:

```yaml
      - name: "Applications"
        orgId: 1
        folder: "Applications"
```

- [ ] **Step 3: Add PageIndex MCP dashboard JSON**

In the `grafana-dashboard-json` ConfigMap, after the `hr_chatbot_full.json` entry (after its closing `}`), add the new dashboard. The key is `pageindex_mcp_overview.json` and the value is the dashboard JSON:

```yaml
  pageindex_mcp_overview.json: |
    {
      "description": "PageIndex MCP Server — log monitoring and service health",
      "editable": true,
      "graphTooltip": 1,
      "id": null,
      "links": [],
      "panels": [
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
          "id": 1,
          "title": "MCP Server Logs",
          "type": "row"
        },
        {
          "datasource": { "type": "loki", "uid": "loki" },
          "gridPos": { "h": 14, "w": 24, "x": 0, "y": 1 },
          "id": 2,
          "options": {
            "dedupStrategy": "none",
            "enableLogDetails": true,
            "prettifyLogMessage": true,
            "showCommonLabels": false,
            "showLabels": false,
            "showTime": true,
            "sortOrder": "Descending",
            "wrapLogMessage": true
          },
          "targets": [
            {
              "datasource": { "type": "loki", "uid": "loki" },
              "expr": "{namespace=\"pageindex-mcp\", service=\"pageindex-mcp\"}",
              "refId": "A"
            }
          ],
          "title": "All Logs",
          "type": "logs"
        },
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 15 },
          "id": 3,
          "title": "Errors & Warnings",
          "type": "row"
        },
        {
          "datasource": { "type": "loki", "uid": "loki" },
          "gridPos": { "h": 12, "w": 24, "x": 0, "y": 16 },
          "id": 4,
          "options": {
            "dedupStrategy": "signature",
            "enableLogDetails": true,
            "prettifyLogMessage": true,
            "showCommonLabels": false,
            "showLabels": true,
            "showTime": true,
            "sortOrder": "Descending",
            "wrapLogMessage": true
          },
          "targets": [
            {
              "datasource": { "type": "loki", "uid": "loki" },
              "expr": "{namespace=\"pageindex-mcp\", service=\"pageindex-mcp\"} | json | drop __error__, __error_details__ | level=~\"error|warning\" | line_format \"[{{.level}}] {{.message}}\"",
              "refId": "A"
            }
          ],
          "title": "Warnings & Errors",
          "type": "logs"
        },
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 28 },
          "id": 5,
          "title": "Log Volume",
          "type": "row"
        },
        {
          "datasource": { "type": "loki", "uid": "loki" },
          "fieldConfig": {
            "defaults": { "color": { "mode": "palette-classic" }, "unit": "short" },
            "overrides": []
          },
          "gridPos": { "h": 10, "w": 24, "x": 0, "y": 29 },
          "id": 6,
          "options": {
            "tooltip": { "mode": "multi" },
            "legend": { "displayMode": "table", "placement": "bottom", "calcs": ["sum"] }
          },
          "targets": [
            {
              "datasource": { "type": "loki", "uid": "loki" },
              "expr": "sum(count_over_time({namespace=\"pageindex-mcp\", service=\"pageindex-mcp\"} | json | drop __error__, __error_details__ | level=\"error\" [5m]))",
              "legendFormat": "errors",
              "refId": "A"
            },
            {
              "datasource": { "type": "loki", "uid": "loki" },
              "expr": "sum(count_over_time({namespace=\"pageindex-mcp\", service=\"pageindex-mcp\"} | json | drop __error__, __error_details__ | level=\"warning\" [5m]))",
              "legendFormat": "warnings",
              "refId": "B"
            },
            {
              "datasource": { "type": "loki", "uid": "loki" },
              "expr": "sum(count_over_time({namespace=\"pageindex-mcp\", service=\"pageindex-mcp\"} | json | drop __error__, __error_details__ | level=\"info\" [5m]))",
              "legendFormat": "info",
              "refId": "C"
            }
          ],
          "title": "Log Volume by Level",
          "type": "timeseries"
        }
      ],
      "refresh": "30s",
      "schemaVersion": 39,
      "tags": ["pageindex-mcp"],
      "templating": { "list": [] },
      "time": { "from": "now-1h", "to": "now" },
      "timepicker": {},
      "timezone": "browser",
      "title": "PageIndex MCP Overview",
      "uid": "pageindex-mcp-overview",
      "version": 1
    }
```

- [ ] **Step 4: Validate the modified configmap YAML**

Run:
```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('/root/hetzner-deployment-service/apps/airline-hr-chatbot/configmap.yaml'))); print('YAML valid')"
```

Expected: "YAML valid"

- [ ] **Step 5: Commit**

```bash
cd /root/hetzner-deployment-service
git add apps/airline-hr-chatbot/configmap.yaml
git commit -m "feat: extend monitoring to pageindex-mcp (Promtail scrape + Grafana dashboard)"
```

---

### Task 10: End-to-end validation

This task covers the manual one-time setup and first deployment verification.

- [ ] **Step 1: Create the namespace on the cluster**

Run:
```bash
kubectl apply -f /root/hetzner-deployment-service/apps/pageindex-mcp/namespace.yaml
```

Expected: `namespace/pageindex-mcp created`

- [ ] **Step 2: Create the GHCR pull secret**

Run (substitute your actual PAT):
```bash
cd /root/hetzner-deployment-service && make ghcr-secret-pageindex GITHUB_PAT=<your-github-pat>
```

Expected: `secret/ghcr-credentials configured`

- [ ] **Step 3: Create and apply the secret**

```bash
cp /root/hetzner-deployment-service/apps/pageindex-mcp/secret.yaml.example /root/hetzner-deployment-service/apps/pageindex-mcp/secret.yaml
```

Edit `secret.yaml` — replace `CHANGE_ME_BASE64` for `OPENAI_API_KEY` with the actual base64-encoded key:
```bash
echo -n 'your-actual-openai-key' | base64
```

Then apply:
```bash
cd /root/hetzner-deployment-service && make k8s-secrets-pageindex
```

Expected: `secret/pageindex-mcp-secrets configured`

- [ ] **Step 4: Apply updated monitoring config (before deploying pageindex-mcp)**

The Promtail + Grafana config changes must be applied first so that logs are captured from the start. Run:
```bash
cd /root/hetzner-deployment-service && make deploy-hr
```

This re-applies the hr-chatbot manifests (including the updated Promtail config and Grafana dashboard). Then restart Promtail and Grafana to pick up the config changes:

```bash
kubectl rollout restart daemonset/promtail -n hr-chatbot
kubectl rollout restart deployment/grafana -n hr-chatbot
```

Expected: Promtail and Grafana restart and pick up the new config.

- [ ] **Step 5: Deploy all pageindex-mcp manifests**

Run:
```bash
cd /root/hetzner-deployment-service && make deploy-pageindex
```

Expected: All resources created (namespace, configmap, deployment, service, ingress, cronjob).

- [ ] **Step 6: Verify pods are running**

Run:
```bash
make status-pageindex
```

Expected: The `pageindex-mcp` pod shows `Running` status with `1/1` ready containers.

- [ ] **Step 7: Verify the MCP endpoint is reachable**

Run (once DNS is configured):
```bash
curl -sk https://pageindex.aiwithsalil.work/mcp
```

Expected: A response from the MCP server (likely a 405 Method Not Allowed since MCP uses POST, but confirms the endpoint is live and TLS is working).

- [ ] **Step 8: Verify logs appear in Grafana**

Open `https://grafana-hr.saliltrehan.com`, navigate to the "PageIndex MCP Overview" dashboard. Confirm log panels are populated with MCP server output.
