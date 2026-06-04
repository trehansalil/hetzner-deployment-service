# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is a **Kubernetes GitOps deployment repository** for three applications plus a shared infrastructure layer, running on a single-node Hetzner server with k3s. It contains no
application source code — only Kubernetes manifests and deployment automation. Source code
lives in separate repos that build images, push to GHCR, and fire `repository_dispatch`
events here.

**Shared infrastructure (datastores + observability) lives in a dedicated `infra`
namespace** that the apps depend on. The dependency direction is one-way: every app
depends on `infra`, and `infra` depends on nothing. Tearing down any single app namespace
therefore leaves shared infrastructure (and the other apps) running.

## Common Commands

### Cluster Bootstrap (one-time)
```bash
make cluster-init        # Apply namespaces, install ingress-nginx + cert-manager, create Let's Encrypt ClusterIssuers, configure Traefik HTTP→HTTPS
```
Note: `cluster-init` installs `ingress-nginx`, but live ingresses target the k3s built-in **Traefik** controller (`ingressClassName: traefik`). The nginx install is legacy/unused — the active controller for all apps is Traefik.

### Deploy order
**`infra` must be deployed before the apps** — the apps' init containers and runtime
connections block until the shared datastores resolve.
```bash
make deploy-infra        # datastores + observability (deploy FIRST)
make deploy-neonatal
make deploy-hr
make deploy-pageindex
```
Destroy order is the reverse: tear down apps first; `make destroy-infra` last (it should
almost never be run — it deletes every datastore and the observability stack).

### Per-app targets (Makefile pattern)
Every app exposes the core lifecycle targets `deploy-<app>`, `rollout-<app>` (with `IMAGE_TAG=<sha>` or app-specific `HR_IMAGE_TAG` / `PAGEINDEX_IMAGE_TAG`), `status-<app>`, `logs-<app>`, `rollback-<app>`, `destroy-<app>`, and `k8s-secrets-<app>`. Substitute `<app>` with `neonatal`, `hr`, or `pageindex`.

`infra` exposes `deploy-infra`, `status-infra`, `clean-pods-infra`, `k8s-secrets-infra`, `destroy-infra` (no `rollout-infra` — it runs pinned third-party images, not CI-built ones).

`ghcr-secret-<app> GITHUB_PAT=<pat>` exists only for `hr` and `pageindex` (private GHCR images); the neonatal image is public and needs no pull secret.

App-specific extras:
- **Infra**: `make init-clickhouse` (one-time ClickHouse schema), port-forwards `port-grafana-infra` (3000), `port-prometheus-infra` (9090), `port-adminer-infra` (8080).
- **Neonatal**: `make clean-pods-neonatal`, `make status-neonatal-resources` (ResourceQuota + LimitRange).
- **HR**: `make ingest-hr` / `make ingest-recreate-hr` (run vector-DB ingest in-pod), `make shell-hr`, `port-app-hr` (9040), `make clean-pods-hr`.

### Manual Secret Setup
`secret.yaml` files are **gitignored**. Each app (and `infra`) ships a `secret.yaml.example` template:
```bash
cp apps/<app>/secret.yaml.example apps/<app>/secret.yaml
# fill in base64 values: echo -n 'value' | base64
make k8s-secrets-<app>
# For private GHCR images (hr, pageindex):
make ghcr-secret-<app> GITHUB_PAT=<token>
```
**Cross-namespace credential matching is load-bearing** (Secrets cannot be referenced across
namespaces, so client-side copies must mirror the infra server-side values):
- `infra-secrets.MINIO_ROOT_USER/PASSWORD` == neonatal & pageindex `MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY`
- `infra-secrets.CLICKHOUSE_PASSWORD` == neonatal `DB_PASSWORD`
- `infra-secrets.POSTGRES_USER/PASSWORD/DB` == the values embedded in hr `app-secrets.DATABASE_URL` (host `postgres.infra.svc.cluster.local`)

## Architecture

### Directory Layout
- `cluster/` — cluster-wide bootstrap: namespaces (incl. `infra`), Traefik HelmChartConfig (HTTP→HTTPS redirect), cert-manager install, ACME ClusterIssuers (`letsencrypt-prod`, `letsencrypt-staging`), `pod-cleanup.yaml`.
- `apps/infra/` — **shared infrastructure**: ClickHouse, MinIO, Redis, n8n, PostgreSQL (StatefulSet), Adminer, Prometheus, Loki, Grafana, Promtail (DaemonSet + cluster-scoped RBAC). Bundles `configmap.yaml` (infra-config + all monitoring configs + Postgres init SQL), `secret.yaml.example` (`infra-secrets` + `monitoring-secrets`), `pvc.yaml`, `deployment.yaml`, `statefulset.yaml`, `daemonset.yaml`, `service.yaml`, `rbac.yaml`, `certificate.yaml` (`infra-tls` for `infra.saliltrehan.com`), `ingress.yaml` (Traefik **IngressRoute** + Middlewares — path-based routing for grafana/adminer/minio/minio-console/automation under the single host `infra.saliltrehan.com`), `cronjob-pod-cleanup.yaml`, `jobs/init-clickhouse-job.yaml`, and **`MIGRATION.md`** (the lossless cutover runbook).
- `apps/neonatal-care/` — stateless app only: Flask backend + nginx. configmap, secret template, deployment, service, ingress, **resourcequota + limitrange**, pod-cleanup CronJob.
- `apps/airline-hr-chatbot/` — stateless app only: Chainlit `app` + Oracle mock MCP. deployment, service, ingress (app only), secret template, pod-cleanup CronJob.
- `apps/pageindex-mcp/` — configmap, secret template, server + worker deployments, service, **explicit Certificate**, Traefik **IngressRoute** (sticky sessions), pod-cleanup CronJob.
- `.github/workflows/deploy.yml` — triggered by `repository_dispatch` (types: `neonatal-care-image-updated`, `airline-hr-chatbot-image-updated`, `pageindex-mcp-image-updated`) or manual `workflow_dispatch` (app choices include `infra`). Selects the app, applies manifests, runs `kubectl set image` for the rolling update (apps only; `infra` is apply-only). Uses `secrets.KUBECONFIG_B64`.

### Shared Infrastructure (`infra` namespace)
| Service | Port | Storage | Strategy | Origin |
|---------|------|---------|----------|--------|
| ClickHouse | 8123 (HTTP), 9000 (native) | 10Gi data + 2Gi logs | **Recreate** (PVC lock) | was neonatal |
| MinIO | 9000 / 9001 | 20Gi | **Recreate** (PVC lock) | was neonatal |
| Redis | 6379 | none | RollingUpdate | was neonatal |
| n8n | 5678 | 2Gi (SQLite) | **Recreate** (PVC lock) | was neonatal |
| PostgreSQL (StatefulSet, pgvector:pg16) | 5432 | 10Gi | StatefulSet | was hr |
| Adminer | 8080 | — | RollingUpdate | was hr |
| Prometheus | 9090 | 20Gi | **Recreate** (TSDB lock) | was hr |
| Loki | 3100 | 10Gi | **Recreate** (compactor lock) | was hr |
| Grafana | 3000 | 5Gi | **Recreate** (SQLite lock) | was hr |
| Promtail (DaemonSet) | 9080 | hostPath (read-only) | DaemonSet | was hr |

Service names are bare (`clickhouse`, `minio`, `redis`, `n8n`, `postgres`, `adminer`,
`prometheus`, `loki`, `grafana`) and consumed cross-namespace as
`<svc>.infra.svc.cluster.local:<port>`. `infra` is **uncapped** (no ResourceQuota) so
critical datastores always schedule.

**Cross-namespace dependency matrix** (arrows = "depends on / reads from"):

| Namespace | Depends on |
|---|---|
| `infra` | nothing |
| `neonatal-care` | `infra` (ClickHouse, MinIO, Redis, n8n) |
| `hr-chatbot` | `infra` (Postgres) |
| `pageindex-mcp` | `infra` (MinIO, Redis) |

Reverse references that originate **in** `infra`: Prometheus scrapes
`app-metrics.hr-chatbot.svc.cluster.local:9091` and `pageindex-mcp.pageindex-mcp.svc:8201`;
Promtail discovers pods in `infra`, `neonatal-care`, `hr-chatbot`, `pageindex-mcp`. The
infra monitoring stack is the de-facto **cluster-wide** observability stack.

**Promtail** requires a **ClusterRole** (`promtail-infra`, get/list/watch on
pods/nodes/namespaces); it is the only cluster-scoped resource owned by `infra`, so
`make destroy-infra` deletes the ClusterRole + ClusterRoleBinding explicitly
(`kubectl delete namespace` won't). The name is deliberately distinct from the legacy
`promtail-hr-chatbot` so the two never collide during migration.

**Grafana** is reset-tolerant: dashboards (`grafana-dashboard-json`) and datasources
(`grafana-datasources`, pointing at the co-located `prometheus`/`loki` by short name) are
provisioned from ConfigMaps; admin creds come from `monitoring-secrets`.

**Consolidated external host (`infra.saliltrehan.com`)**: all externally-exposed infra
UIs/endpoints live under one host with path-based routing, via a Traefik **IngressRoute**
(`apps/infra/ingress.yaml`) + explicit cert-manager **Certificate** (`apps/infra/certificate.yaml`,
secret `infra-tls`, same namespace — Traefik can't read TLS secrets cross-namespace). Routes:
`/grafana` → grafana:3000 (NO strip; `GF_SERVER_SERVE_FROM_SUB_PATH=true` + `GF_SERVER_ROOT_URL`
with trailing slash — strip+serve_from_sub_path is the infinite-301 loop, Grafana #72577),
`/adminer` → adminer:8080 (ipAllowList + StripPrefix + trailing-slash redirect — relative-URL DB-admin UI with no app-level auth, so an `adminer-ipallow` middleware restricts it to trusted source CIDRs; the committed value is a fail-closed RFC-5737 placeholder and the real admin CIDR is injected at deploy time from `$ADMIN_CIDR` (`make deploy-infra ADMIN_CIDR=…`, or the `ADMIN_CIDR` Actions variable) via `kubectl patch`, so the real IP never lands in this public repo),
`/minio-console` → minio:9001 (StripPrefix + trailing-slash redirect; base path from
`MINIO_BROWSER_REDIRECT_URL`), `/minio` → minio:9000 (StripPrefix; S3 API, ≡ the old nginx
trailing-slash proxy), `/automation` → n8n:5678 (NO strip; `N8N_PATH=/automation/`), and `/`
→ 302 → `/grafana/`. Route priority is left to Traefik's default length-sorting so
`/minio-console` outranks `/minio`; no explicit `priority:` is set. This replaced the former
per-host Ingresses (`hr-chatbot-grafana` / `hr-chatbot-adminer` in the `hr-chatbot`
namespace — hosts `grafana-hr` / `adminer-hr`, TLS secrets `hr-chatbot-grafana-tls` /
`hr-chatbot-adminer-tls`) **and** the infra paths previously proxied through the
neonatal-care nginx (`neonate-logger.saliltrehan.com/{minio,minio-console,automation}`).
Those legacy Ingresses + their TLS secrets are pruned at **decommission**
(`apps/infra/MIGRATION.md` Phase 5), **not** by `deploy-infra`: they must keep serving
through the migration validation window, and `kubectl apply` never prunes renamed objects.

**Postgres** bootstraps from the `postgres-init-sql` ConfigMap (~1500-line idempotent SQL
in `apps/infra/configmap.yaml`): `vector` + `pg_trgm` extensions; RAG tables
(`knowledge_embeddings`, `session_embeddings`, `session_document_links`,
`session_tabular_files`, `knowledge_tabular_files` — HNSW + GIN trigram indexes on
`vector(2000)`); Chainlit persistence tables (`User`, `Thread`, `Step`, `Element`,
`Feedback`); seed users (`EMP001`–`EMP003`, `ADMIN001`). It runs only when `PGDATA` is
empty — for an existing DB you apply migrations manually. Vector dimension is hard-wired to 2000.

**`make init-clickhouse`** expects a ConfigMap **`infra-sql-init`** (not in the repo).
Populate it from the source repo's schema before running the job:
```bash
kubectl create configmap infra-sql-init \
  --from-file=init_clickhouse.sql=<path-to-file> -n infra
```

**Data migration** from the original in-app datastores into `infra` is a one-time
operation documented in **`apps/infra/MIGRATION.md`** (lossless network copy for
Postgres/MinIO; host-path copy for ClickHouse/n8n; reset for Redis/Prometheus/Loki/Grafana).

### Adding a new app
Mirror an existing app directory, add a `deploy-<app>` block to the `Makefile`, register the app+namespace in `.github/workflows/deploy.yml` (dispatch types, manifest apply step, image rollout step), and add the namespace to `cluster/namespaces.yaml`. **Reuse the shared `infra` datastores** rather than running new ones in-namespace; reference them via `<svc>.infra.svc.cluster.local`, and add a matching client-side Secret if it needs MinIO/ClickHouse/Postgres credentials.

### Neonatal Care — Request Flow
```
Internet → Traefik (TLS termination + HTTP→HTTPS)
        → nginx (static SPA + reverse proxy)
            /api/             → Flask backend :5000 (gunicorn/gevent, 2 workers)
            /                 → static SPA (index + @backend fallback)
```
The MinIO API, MinIO console, and n8n are **no longer proxied through this nginx** —
they moved to the consolidated `infra.saliltrehan.com` host (`apps/infra/ingress.yaml`).
The backend still talks to those services in-cluster via FQDN; only the *external* entry
points relocated. `MINIO_EXTERNAL_ENDPOINT` / `WEBHOOK_URL` in `neonatal-care-config` now
point at `infra.saliltrehan.com`.

Static files are copied from the backend image by an nginx initContainer (`copy-static`) at startup into an emptyDir shared volume. **Both** the backend and nginx Deployments get bumped during `rollout-neonatal` because the nginx pod's `copy-static` initContainer pulls the same backend image. The backend uses `maxSurge: 0, maxUnavailable: 1` and `terminationGracePeriodSeconds: 60` so gunicorn drains in-flight requests under memory pressure.

### Neonatal Care — Services (`neonatal-care` namespace)
| Service | Port | Strategy |
|---------|------|----------|
| Flask backend (`uv run gunicorn`) | 5000 | RollingUpdate, maxSurge: 0 |
| nginx | 80 | RollingUpdate, maxSurge: 0 |

ClickHouse/MinIO/Redis/n8n moved to `infra`; the backend reaches them via the FQDNs in its
`neonatal-care-config` ConfigMap. The namespace-scoped `ResourceQuota`
(1Gi/750m requests, 3Gi/3000m limits, 15 pods, 2 PVCs) and `LimitRange` (default container:
128Mi/100m req, 512Mi/500m lim) were relaxed from the original full-stack sizing now that
the datastores left. Quota + LimitRange remain unique to neonatal; other namespaces are uncapped.

### Airline HR Chatbot — Services (`hr-chatbot` namespace)
| Service | Port | Notes |
|---------|------|-------|
| Oracle Mock Server (FastAPI, uvicorn) | 8001 | intra-namespace dependency of `app` |
| Chainlit app | 9040 (UI), 9091 (metrics + `/health`) | `app` Service → 9040; `app-metrics` Service → 9091 |

Postgres, Adminer, Prometheus, Loki, Grafana, Promtail moved to `infra`. The Chainlit `app`
init containers wait on `postgres.infra.svc.cluster.local:5432` (cross-namespace) and
`http://oracle:8001` (intra-namespace); it connects to Postgres via `app-secrets.DATABASE_URL`
(host `postgres.infra.svc.cluster.local`). The app runs at **replicas: 1** because session
state is in-process. Prometheus scrapes the `app-metrics` Service cross-namespace.

### PageIndex MCP — Services (`pageindex-mcp` namespace)
| Service | Port | Notes |
|---------|------|-------|
| MCP server | 8201 | streamable-http transport, **stateful per session**, also exposes `/metrics` |
| Worker | — | `arq pageindex_mcp.worker.WorkerSettings` against Redis (no service) |

Architectural notes that are easy to miss:
- **Cross-namespace dependencies**: server + worker reach MinIO and Redis in the `infra` namespace via FQDN (`minio.infra.svc.cluster.local:9000`, `redis://redis.infra.svc.cluster.local:6379/1`). Infra must be deployed first. The MinIO bucket is `pageindex`; keep `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` in the PageIndex Secret equal to `infra-secrets.MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`.
- **Ingress is a Traefik `IngressRoute`** (not a standard `Ingress`), with **sticky sessions** (`mcp_affinity` cookie). MCP's streamable-http transport requires session affinity to a single pod. cert-manager's ingress-shim does not auto-issue certs for IngressRoutes, so `certificate.yaml` declares the `Certificate` resource explicitly. The deploy step also runs `kubectl delete ingress pageindex-mcp --ignore-not-found` to remove a stale standard-Ingress object that was previously deployed under the same name (legacy cleanup; do not re-create).
- **Azure OpenAI prefix mismatch**: the server uses `AsyncAzureOpenAI` directly and wants the bare deployment name (e.g. `gpt-4.1`); the worker uses `litellm` via the pageindex library and needs the `azure/` prefix. The ConfigMap holds bare names; `worker-deployment.yaml` overrides `PAGEINDEX_*MODEL` env vars to add the prefix. Both `OPENAI_API_KEY` and `AZURE_API_KEY` must be set to the same value when `OPENAI_BASE_URL` points at Azure.

### TLS & Networking
- **Ingress class**: `traefik` (k3s built-in). The app Ingresses (neonatal, hr) use standard `ingressClassName: traefik`; **PageIndex and the consolidated `infra` host use native Traefik `IngressRoute` CRDs** (each with an explicit cert-manager `Certificate`, since ingress-shim does not auto-issue for IngressRoutes).
- **TLS**: cert-manager v1.14.5 with Let's Encrypt HTTP-01 challenge.
- **Issuers**: `letsencrypt-prod` and `letsencrypt-staging` (rate-limit-free testing).
- **HTTP→HTTPS** redirect is global, set on Traefik via `cluster/traefik-config.yaml` (`HelmChartConfig` overlay in `kube-system`).
- **Domains**: `neonate-logger.saliltrehan.com` (neonatal app), `airline-hr.saliltrehan.com` (hr app), `pageindex.aiwithsalil.work` (pageindex), and **`infra.saliltrehan.com`** — the single host for all shared-infra UIs/endpoints via path-based routing (`/grafana`, `/adminer`, `/minio`, `/minio-console`, `/automation`; `/` → `/grafana/`). This replaced the former `grafana-hr.saliltrehan.com` / `adminer-hr.saliltrehan.com` hosts and the `neonate-logger.saliltrehan.com/{minio,minio-console,automation}` nginx-proxied paths.

### Storage
Default storage class is k3s `local-path` (single-node HostPath, `accessModes: ReadWriteOnce`). To use Hetzner block storage on multi-node clusters, switch the PVC `storageClassName` to `hcloud-volumes`. **All PVC-backed workloads now live in `infra`**: ClickHouse, MinIO, n8n, Postgres (StatefulSet), Prometheus, Loki, Grafana — each uses `strategy: Recreate` (or is a StatefulSet) because two pods cannot mount the same `local-path` PVC simultaneously. `local-path` PVs are **namespace-bound**: data does not follow a PVC across namespaces, which is why the one-time migration (`apps/infra/MIGRATION.md`) uses network copy or host-path copy rather than re-pointing a PVC.

### Pod Cleanup
Each namespace (incl. `infra`) ships its own `cronjob-pod-cleanup.yaml` (every 15 min, dedicated ServiceAccount + namespace-scoped Role) that deletes pods in `Failed` or `Succeeded` phase. The deploy workflow also runs cleanup post-deploy. Use `make clean-pods-<app>` for a manual sweep.

### Deployment Pipeline
Source repos (`neonatal-care-repo`, `airline-hr-chatbot`, `pageindex-mcp`) build images and push to GHCR (`ghcr.io/trehansalil/<app>:<sha>`), then fire `repository_dispatch` here. The deploy workflow decodes `secrets.KUBECONFIG_B64`, applies manifests, and runs `kubectl set image` for a rolling update. **`infra` is apply-only** (no image rollout — pinned third-party images) and is deployed manually via `workflow_dispatch` or `make deploy-infra`. **HR chatbot and PageIndex** images are in private GHCR registries requiring the `ghcr-credentials` pull secret (created via `make ghcr-secret-<app>`).

## Conventions

- **Never commit `secret.yaml`** (gitignored). Use the `.example` template + `make k8s-secrets-<app>`.
- When adding manifests, also update the corresponding `deploy-<app>` Makefile target **and** the `Apply k8s manifests — <app>` step in `.github/workflows/deploy.yml`. Keep the **non-secret** manifest list in sync between the two; `secret.yaml` is gitignored and is the intentional exception (the workflow never applies it).
- Secret application is not uniform across `deploy-<app>` targets: `deploy-infra`, `deploy-neonatal`, and `deploy-hr` apply `apps/<app>/secret.yaml` inline, but `deploy-pageindex` does **not** — operators must run `make k8s-secrets-pageindex` separately. Use `make k8s-secrets-<app>` for any app when you want a deterministic secret-only apply.
- App-owned cluster-scoped resources are not deleted by `kubectl delete namespace`, so `destroy-<app>` must clean them up explicitly. The only such resource is the `promtail-infra` ClusterRole + ClusterRoleBinding (deleted by `make destroy-infra`). The Let's Encrypt `ClusterIssuer`s are owned by `cluster-init`, not by any app.
- **Dependency direction is one-way and load-bearing**: apps depend on `infra`; `infra` depends on nothing. Deploy `infra` first; destroy it last. Reverse references (Prometheus scrape targets, Promtail SD namespaces) originate in `infra` and point outward, so they degrade gracefully if an app is absent. When relocating a service, grep the consuming namespaces' ConfigMaps/Secrets for `*.infra.svc.cluster.local` (and the credential-matching equalities above) first.
- All app images live under `ghcr.io/trehansalil/<app>`. Neonatal is public; HR and PageIndex are private and require the `ghcr-credentials` pull secret in their namespace (the Deployments declare `imagePullSecrets: [{name: ghcr-credentials}]`). Adding a new private-image app means provisioning that secret as part of bootstrap.
