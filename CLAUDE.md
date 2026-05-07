# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is a **Kubernetes GitOps deployment repository** for three applications running on a single-node Hetzner server with k3s. It contains no application source code — only Kubernetes manifests and deployment automation. Source code lives in separate repos that build images, push to GHCR, and fire `repository_dispatch` events here.

## Common Commands

### Cluster Bootstrap (one-time)
```bash
make cluster-init        # Apply namespaces, install ingress-nginx + cert-manager, create Let's Encrypt ClusterIssuers, configure Traefik HTTP→HTTPS
```
Note: `cluster-init` installs `ingress-nginx`, but live ingresses target the k3s built-in **Traefik** controller (`ingressClassName: traefik`). The nginx install is legacy/unused — the active controller for all apps is Traefik.

### Per-app targets (uniform Makefile pattern)
Every app has the same target shape: `deploy-<app>`, `rollout-<app>` (with `IMAGE_TAG=<sha>` or app-specific `HR_IMAGE_TAG` / `PAGEINDEX_IMAGE_TAG`), `status-<app>`, `logs-<app>`, `rollback-<app>`, `destroy-<app>`, `ghcr-secret-<app> GITHUB_PAT=<pat>`, `k8s-secrets-<app>`. Substitute `<app>` with `neonatal`, `hr`, or `pageindex`.

App-specific extras:
- **Neonatal**: `make init-clickhouse` (one-time DB schema), `make clean-pods-neonatal`, `make status-neonatal-resources` (ResourceQuota + LimitRange).
- **HR**: `make ingest-hr` / `make ingest-recreate-hr` (run vector-DB ingest in-pod), `make shell-hr`, port-forwards `port-app-hr` (9040), `port-grafana-hr` (3000), `port-prometheus-hr` (9090), `port-adminer-hr` (8080), `make clean-pods-hr`.

### Manual Secret Setup
`secret.yaml` files are **gitignored**. Each app ships a `secret.yaml.example` template:
```bash
cp apps/<app>/secret.yaml.example apps/<app>/secret.yaml
# fill in base64 values: echo -n 'value' | base64
make k8s-secrets-<app>
# For private GHCR images (hr, pageindex):
make ghcr-secret-<app> GITHUB_PAT=<token>
```

## Architecture

### Directory Layout
- `cluster/` — cluster-wide bootstrap: namespaces, Traefik HelmChartConfig (HTTP→HTTPS redirect), cert-manager install, ACME ClusterIssuers (`letsencrypt-prod`, `letsencrypt-staging`), `pod-cleanup.yaml`.
- `apps/neonatal-care/` — configmap, secret template, PVCs, deployments, service, ingress, ClickHouse init job, **resourcequota + limitrange**, pod-cleanup CronJob.
- `apps/airline-hr-chatbot/` — configmap (PostgreSQL init SQL), secret template, PVCs, deployments, StatefulSet (Postgres), DaemonSet (promtail), **cluster-scoped RBAC**, services, ingresses, pod-cleanup CronJob.
- `apps/pageindex-mcp/` — configmap, secret template, server + worker deployments, service, **explicit Certificate**, Traefik **IngressRoute** (sticky sessions), pod-cleanup CronJob.
- `.github/workflows/deploy.yml` — triggered by `repository_dispatch` (types: `neonatal-care-image-updated`, `airline-hr-chatbot-image-updated`, `pageindex-mcp-image-updated`) or manual `workflow_dispatch`. Selects the app via `client_payload.app` / `inputs.app`, applies manifests, runs `kubectl set image` for rolling update. Uses `secrets.KUBECONFIG_B64`.
- `docs/superpowers/{plans,specs}/` — design docs (currently: pageindex-mcp CI/CD).

### Adding a new app
Mirror an existing app directory, add a `deploy-<app>` block to the `Makefile`, register the app+namespace in `.github/workflows/deploy.yml` (three places: dispatch types, manifest apply step, image rollout step), and add the namespace to `cluster/namespaces.yaml`.

### Neonatal Care — Request Flow
```
Internet → Traefik (TLS termination + HTTP→HTTPS)
        → nginx (static SPA + reverse proxy)
            /api/             → Flask backend :5000 (gunicorn/gevent, 2 workers)
            /minio/           → MinIO API :9000
            /minio-console/   → MinIO console :9001
            /automation/      → n8n :5678
```
Static files are copied from the backend image by an nginx initContainer (`copy-static`) at startup into an emptyDir shared volume. The nginx ConfigMap (`default.conf`) holds the full reverse-proxy config including SSE pass-through (`X-Accel-Buffering: no`) and `sub_filter` URL rewrites for the n8n and MinIO console subpaths. **Both** the backend and nginx Deployments get bumped during `rollout-neonatal` because the nginx pod's `copy-static` initContainer pulls the same backend image. The backend uses `maxSurge: 0, maxUnavailable: 1` and `terminationGracePeriodSeconds: 60` so gunicorn drains in-flight requests under memory pressure.

### Neonatal Care — Services (`neonatal-care` namespace)
| Service | Port | Storage | Strategy |
|---------|------|---------|----------|
| Flask backend (`uv run gunicorn`) | 5000 | — | RollingUpdate, maxSurge: 0 |
| nginx | 80 | — | RollingUpdate, maxSurge: 0 |
| ClickHouse | 8123 (HTTP), 9000 (native) | 10Gi data + 2Gi logs | **Recreate** (PVC lock) |
| MinIO | 9000 / 9001 | 20Gi | **Recreate** (PVC lock) |
| n8n | 5678 | 2Gi (SQLite) | **Recreate** (PVC lock) |
| Redis | 6379 | none | RollingUpdate |

A namespace-scoped `ResourceQuota` (3Gi/1500m requests, 7Gi/5000m limits, 20 pods, 10 PVCs) and `LimitRange` (default container: 128Mi/100m req, 512Mi/500m lim) are applied **before** workloads — overshooting the quota will block pod scheduling. Quota + LimitRange are unique to neonatal; the other namespaces are uncapped.

The `make init-clickhouse` Job expects a ConfigMap **`neonatal-care-sql-init`** to already exist (it isn't in the repo). Populate it from the source repo's schema before running the job:
```bash
kubectl create configmap neonatal-care-sql-init \
  --from-file=init_clickhouse.sql=<path-to-file> -n neonatal-care
```

### Airline HR Chatbot — Services (`hr-chatbot` namespace)
| Service | Port | Storage |
|---------|------|---------|
| PostgreSQL (StatefulSet, pgvector:pg16) | 5432 | 10Gi |
| Oracle Mock Server (FastAPI, uvicorn) | 8001 | — |
| Chainlit app | 9040 (UI), 9091 (metrics + `/health`) | — |
| Adminer | 8080 | — |
| Prometheus | 9090 | 20Gi (`Recreate` strategy — TSDB lock) |
| Loki | 3100 | 10Gi (`Recreate` strategy — compactor lock) |
| Grafana | 3000 | 5Gi (`Recreate` strategy — SQLite lock) |
| Promtail (DaemonSet) | 9080 | hostPath (read-only) |

Chainlit waits for both Postgres and the Oracle Mock Server via init containers. The Chainlit app runs at **replicas: 1** because session state is held in-process. The Chainlit container exposes the UI on `:9040` and a separate metrics + `/health` endpoint on `:9091` (the readiness/liveness probes target `:9091`, and an `app-metrics` Service routes Prometheus to `:9091` while the `app` Service exposes only `:9040` to the Ingress).

Postgres bootstraps from the **`postgres-init-sql` ConfigMap** mounted at `/docker-entrypoint-initdb.d/init.sql`. That ConfigMap is enormous (~1500 lines of SQL embedded in `configmap.yaml`) and contains: `vector` + `pg_trgm` extensions, the RAG tables (`knowledge_embeddings`, `session_embeddings`, `session_document_links`, `session_tabular_files`, `knowledge_tabular_files` — all with HNSW + GIN trigram indexes on `vector(2000)`), the Chainlit persistence tables (`User`, `Thread`, `Step`, `Element`, `Feedback`), and seed users (`EMP001`, `EMP002`, `EMP003`, `ADMIN001`). The init script is idempotent (`CREATE ... IF NOT EXISTS`, `ON CONFLICT DO NOTHING`), so editing it and recycling Postgres re-applies cleanly **only if PGDATA is empty** — for an existing DB you must apply migrations manually. The vector dimension is hard-wired to 2000.

Promtail requires a **ClusterRole** (get/list/watch on pods/nodes/namespaces) for k8s service discovery; this is the only cluster-scoped resource owned by an app, so `make destroy-hr` deletes the ClusterRole + ClusterRoleBinding explicitly (`kubectl delete namespace` won't).

**The HR namespace's monitoring stack also observes PageIndex MCP cross-namespace**: `prometheus-config` scrapes `pageindex-mcp.pageindex-mcp.svc:8201/metrics`, and `promtail-config` lists `pageindex-mcp` alongside `hr-chatbot` in its `kubernetes_sd_configs` namespaces. PageIndex has no monitoring of its own — Grafana/Prometheus/Loki/Promtail in `hr-chatbot` are the de-facto cluster-wide observability stack.

### PageIndex MCP — Services (`pageindex-mcp` namespace)
| Service | Port | Notes |
|---------|------|-------|
| MCP server | 8201 | streamable-http transport, **stateful per session**, also exposes `/metrics` |
| Worker | — | `arq pageindex_mcp.worker.WorkerSettings` against Redis (no service) |

Architectural notes that are easy to miss:
- **Cross-namespace dependencies**: server + worker reach MinIO and Redis from the `neonatal-care` namespace via FQDN service names (`neonatal-care-minio.neonatal-care:9000`, `neonatal-care-redis.neonatal-care:6379/1`). Neonatal must be deployed first. The MinIO bucket used by PageIndex is `pageindex` and shares `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` with neonatal — keep `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` in the PageIndex Secret matching the values used by the neonatal MinIO Deployment.
- **Ingress is a Traefik `IngressRoute`** (not a standard `Ingress`), with **sticky sessions** (`mcp_affinity` cookie). MCP's streamable-http transport requires session affinity to a single pod. cert-manager's ingress-shim does not auto-issue certs for IngressRoutes, so `certificate.yaml` declares the `Certificate` resource explicitly. The deploy step also runs `kubectl delete ingress pageindex-mcp --ignore-not-found` to remove a stale standard-Ingress object that was previously deployed under the same name (legacy cleanup; do not re-create).
- **Azure OpenAI prefix mismatch**: the server uses `AsyncAzureOpenAI` directly and wants the bare deployment name (e.g. `gpt-4.1`); the worker uses `litellm` via the pageindex library and needs the `azure/` prefix. The ConfigMap holds bare names; `worker-deployment.yaml` overrides `PAGEINDEX_*MODEL` env vars to add the prefix. Both `OPENAI_API_KEY` and `AZURE_API_KEY` must be set to the same value when `OPENAI_BASE_URL` points at Azure.

### TLS & Networking
- **Ingress class**: `traefik` (k3s built-in). Standard Ingresses use `ingressClassName: traefik`; PageIndex uses native Traefik `IngressRoute` CRDs.
- **TLS**: cert-manager v1.14.5 with Let's Encrypt HTTP-01 challenge.
- **Issuers**: `letsencrypt-prod` and `letsencrypt-staging` (rate-limit-free testing).
- **HTTP→HTTPS** redirect is global, set on Traefik via `cluster/traefik-config.yaml` (`HelmChartConfig` overlay in `kube-system`).
- **Domains**: `neonate-logger.saliltrehan.com`, `airline-hr.saliltrehan.com`, `grafana-hr.saliltrehan.com`, `adminer-hr.saliltrehan.com`, `pageindex.aiwithsalil.work`.

### Storage
Default storage class is k3s `local-path` (single-node HostPath, `accessModes: ReadWriteOnce`). To use Hetzner block storage on multi-node clusters, switch the PVC `storageClassName` to `hcloud-volumes`. Every stateful workload that holds a file lock on its PVC — **ClickHouse, MinIO, n8n, Postgres (StatefulSet), Prometheus, Loki, Grafana** — uses `strategy: Recreate` (or is a StatefulSet) because two pods cannot mount the same `local-path` PVC simultaneously. This is a global pattern: when adding a new PVC-backed Deployment, set `strategy: Recreate` unless you've separately verified the workload tolerates two writers.

### Pod Cleanup
Each app namespace ships its own `cronjob-pod-cleanup.yaml` (every 15 min, dedicated ServiceAccount + namespace-scoped Role) that deletes pods in `Failed` or `Succeeded` phase. The deploy workflow also runs cleanup post-deploy. Use `make clean-pods-<app>` for a manual sweep.

### Deployment Pipeline
Source repos (`neonatal-care-repo`, `airline-hr-chatbot`, `pageindex-mcp`) build images and push to GHCR (`ghcr.io/trehansalil/<app>:<sha>`), then fire `repository_dispatch` here. The deploy workflow decodes `secrets.KUBECONFIG_B64`, applies manifests, and runs `kubectl set image` for a rolling update. **HR chatbot and PageIndex** images are in private GHCR registries requiring the `ghcr-credentials` pull secret (created via `make ghcr-secret-<app>`).

## Conventions

- **Never commit `secret.yaml`** (gitignored). Use the `.example` template + `make k8s-secrets-<app>`.
- When adding manifests, also update the corresponding `deploy-<app>` Makefile target **and** the `Apply k8s manifests — <app>` step in `.github/workflows/deploy.yml`. The Makefile and workflow apply the same files in the same order — keep them in sync.
- Cluster-scoped resources (ClusterRole, ClusterRoleBinding, ClusterIssuer) are not deleted by `kubectl delete namespace`. The `destroy-<app>` target must clean these up explicitly (see `destroy-hr` for the pattern).
- Cross-namespace coupling is intentional and load-bearing: PageIndex consumes neonatal-care's MinIO + Redis, and HR's Prometheus/Promtail scrapes the PageIndex namespace. When destroying or relocating a namespace, check the other apps' ConfigMaps for FQDN references first.
- All app images live under `ghcr.io/trehansalil/<app>`. Neonatal is public; HR and PageIndex are private and require the `ghcr-credentials` pull secret in their namespace (the Deployments declare `imagePullSecrets: [{name: ghcr-credentials}]`). Adding a new private-image app means provisioning that secret as part of bootstrap.
