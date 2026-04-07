# PageIndex MCP Server — CI/CD & Deployment Design

**Date:** 2026-04-07
**Status:** Approved
**Approach:** Mirror existing hetzner-deployment-service pattern (Approach A)

## Overview

Add CI/CD pipeline for the PageIndex MCP Server (`trehansalil/pageindex`) using the existing hetzner-deployment-service GitOps pattern. On push to `main`, the source repo builds a Docker image, pushes to GHCR, and fires a `repository_dispatch` event that triggers a deploy workflow applying K8s manifests and performing a rolling update on the Hetzner k3s cluster.

**Future intent:** Tagged releases will trigger deployment to a staging environment (separate from the current dev flow). Not in scope for this spec.

## Source Repo: `trehansalil/pageindex`

### Dockerfile

Multi-stage build using `uv` for dependency resolution:

- **Base image:** `python:3.12-slim`
- **Build stage:** Install `uv`, copy `pyproject.toml` + `uv.lock`, run `uv sync --frozen`. The `pageindex` dependency (`git+https://github.com/trehansalil/PageIndex-salil.git`) is public — no auth needed. Copy application source.
- **Runtime stage:** Copy installed virtualenv from build stage. Copy `mcp_server.py`, `src/`, `pyproject.toml`.
- **Expose:** port 8201
- **Entrypoint:** Run via the installed virtualenv's Python (e.g., `python mcp_server.py` with the venv on PATH, or `uv run python mcp_server.py` if uv is available in the runtime image). The exact mechanism will be determined during implementation based on the uv Docker best practices.
- **No `.env` baked in** — all configuration injected via K8s environment variables.

### `.dockerignore`

Exclude: `.venv/`, `.git/`, `logs/`, `.env`, `__pycache__/`, `doc_store/`, `*.pyc`, `preprocess.log`

### `.github/workflows/build-push.yml`

Triggered on push to `main`:

1. Checkout the repo
2. Log in to GHCR using `GITHUB_TOKEN` (automatic)
3. Build and push Docker image to `ghcr.io/trehansalil/pageindex-mcp` with tags:
   - `sha-<short-sha>` (immutable, for rollbacks)
   - `latest` (convenience)
4. Fire `repository_dispatch` to `trehansalil/hetzner-deployment-service`:
   - Event type: `pageindex-mcp-image-updated`
   - Payload: `{ app: "pageindex-mcp", image_tag: "sha-<short-sha>" }`
   - Requires repo secret: `DEPLOY_PAT` (GitHub PAT with `repo` scope)

## Deployment Repo: `trehansalil/hetzner-deployment-service`

### New Directory: `apps/pageindex-mcp/`

#### `namespace.yaml`

New namespace: `pageindex-mcp`

#### `configmap.yaml`

Non-secret environment variables:

| Key | Value |
|-----|-------|
| `MINIO_ENDPOINT` | `neonatal-care-minio.neonatal-care:9000` |
| `MINIO_BUCKET` | `pageindex` |
| `MINIO_SECURE` | `false` |
| `MCP_HOST` | `0.0.0.0` |
| `MCP_PORT` | `8201` |

Uses cross-namespace Kubernetes DNS for MinIO (instead of hardcoded ClusterIP `10.43.246.106`). Resolves to the same service but survives service recreation.

#### `secret.yaml.example` (committed) + `secret.yaml` (gitignored)

Base64-encoded secrets:

- `OPENAI_API_KEY`
- `MINIO_ACCESS_KEY` (currently `minioadmin`)
- `MINIO_SECRET_KEY` (currently `minioadmin`)

#### `deployment.yaml`

Single Deployment:

- **Image:** `ghcr.io/trehansalil/pageindex-mcp:latest`
- **imagePullSecrets:** `[ghcr-credentials]` (private GHCR image)
- **Replicas:** 1
- **Strategy:** RollingUpdate (maxSurge: 0, maxUnavailable: 1)
- **Port:** 8201
- **Env:** Injected from configmap refs + secret refs
- **Probes:** TCP check on port 8201 for liveness/readiness (FastMCP may not expose a dedicated health endpoint)
- **Resources:**
  - Requests: 200m CPU, 256Mi memory
  - Limits: 1000m CPU, 2Gi memory

#### `service.yaml`

ClusterIP service exposing port 8201.

#### `ingress.yaml`

- **Host:** `pageindex.aiwithsalil.work`
- **Ingress class:** `traefik`
- **TLS:** cert-manager with `letsencrypt-prod` ClusterIssuer
- **Backend:** `pageindex-mcp:8201`

**Prerequisite:** DNS A record `pageindex.aiwithsalil.work` pointing to the Hetzner server IP.

#### `cronjob-pod-cleanup.yaml`

Same evicted/failed/succeeded pod cleanup CronJob pattern used by the other apps.

### Modified Files

#### `cluster/namespaces.yaml`

Add `pageindex-mcp` namespace entry.

#### `.github/workflows/deploy.yml`

- Add `pageindex-mcp-image-updated` to `repository_dispatch` types
- Add `pageindex-mcp` as a choice in `workflow_dispatch` inputs
- Add conditional steps:
  - "Apply k8s manifests -- pageindex-mcp"
  - "Update image tag (rolling deploy) -- pageindex-mcp"
  - "Post-deploy pod cleanup -- pageindex-mcp"
  - Update "Verify deployment" step for `pageindex-mcp` namespace

#### `Makefile`

New variables:

```makefile
PAGEINDEX_NS := pageindex-mcp
PAGEINDEX_IMAGE := ghcr.io/trehansalil/pageindex-mcp
PAGEINDEX_IMAGE_TAG ?= latest
```

New targets:

| Target | Description |
|--------|-------------|
| `deploy-pageindex` | Apply all manifests |
| `rollout-pageindex IMAGE_TAG=<sha>` | Rolling update with new image tag |
| `status-pageindex` | Show pods, services, ingress |
| `logs-pageindex` | Tail MCP server logs |
| `rollback-pageindex` | Rollback to previous revision |
| `ghcr-secret-pageindex GITHUB_PAT=<token>` | Create GHCR pull secret |
| `k8s-secrets-pageindex` | Apply app secrets |
| `destroy-pageindex` | Delete namespace (destructive) |

### Observability: Extend Existing Monitoring Stack

No new monitoring services are deployed. The existing Grafana/Loki/Promtail stack in the `hr-chatbot` namespace is extended.

#### Promtail Config Change (`apps/airline-hr-chatbot/configmap.yaml`)

Update the `kubernetes_sd_configs` namespaces list from `[hr-chatbot]` to `[hr-chatbot, pageindex-mcp]`. The DaemonSet already runs on the node and has access to all pod logs — this change tells it to also scrape the `pageindex-mcp` namespace.

#### Grafana Dashboard Addition (`apps/airline-hr-chatbot/configmap.yaml`)

New entry in `grafana-dashboard-json` ConfigMap: `pageindex_mcp_overview.json`

Dashboard: **"PageIndex MCP Overview"**

Panels:

| Panel | Type | Datasource | Query |
|-------|------|------------|-------|
| MCP Server Logs | logs | Loki | `{namespace="pageindex-mcp", service="pageindex-mcp"}` |
| Warnings & Errors | logs | Loki | `{namespace="pageindex-mcp", service="pageindex-mcp"} \| json \| level=~"error\|warning"` |
| Log Volume by Level | timeseries | Loki | `count_over_time(...)` grouped by level |

The dashboard is accessible from the existing Grafana instance at `grafana-hr.saliltrehan.com`.

## End-to-End Flow

```
push to main (trehansalil/pageindex)
  -> build-push.yml: build Docker image
  -> push to ghcr.io/trehansalil/pageindex-mcp:sha-<sha>
  -> fire repository_dispatch to hetzner-deployment-service
  -> deploy.yml: apply K8s manifests to pageindex-mcp namespace
  -> kubectl set image deployment/pageindex-mcp -> rolling update
  -> verify pods healthy
  -> accessible at https://pageindex.aiwithsalil.work/mcp
  -> logs visible in Grafana at grafana-hr.saliltrehan.com
```

## One-Time Setup Checklist

1. DNS A record: `pageindex.aiwithsalil.work` -> Hetzner server IP
2. Add `DEPLOY_PAT` secret to `trehansalil/pageindex` repo (GitHub PAT with `repo` scope)
3. `KUBECONFIG_B64` secret already exists in `hetzner-deployment-service`
4. Run `make ghcr-secret-pageindex GITHUB_PAT=<token>` to create image pull secret
5. Create `apps/pageindex-mcp/secret.yaml` from `secret.yaml.example`, fill in base64 values, apply with `make k8s-secrets-pageindex`

## File Summary

### Created

| Repo | File |
|------|------|
| `pageindex` | `Dockerfile` |
| `pageindex` | `.dockerignore` |
| `pageindex` | `.github/workflows/build-push.yml` |
| `hetzner-deployment-service` | `apps/pageindex-mcp/namespace.yaml` |
| `hetzner-deployment-service` | `apps/pageindex-mcp/configmap.yaml` |
| `hetzner-deployment-service` | `apps/pageindex-mcp/secret.yaml.example` |
| `hetzner-deployment-service` | `apps/pageindex-mcp/deployment.yaml` |
| `hetzner-deployment-service` | `apps/pageindex-mcp/service.yaml` |
| `hetzner-deployment-service` | `apps/pageindex-mcp/ingress.yaml` |
| `hetzner-deployment-service` | `apps/pageindex-mcp/cronjob-pod-cleanup.yaml` |

### Modified

| Repo | File | Change |
|------|------|--------|
| `hetzner-deployment-service` | `.github/workflows/deploy.yml` | Add pageindex-mcp dispatch type, workflow_dispatch option, deploy/rollout/cleanup steps |
| `hetzner-deployment-service` | `Makefile` | Add pageindex-mcp variables and targets |
| `hetzner-deployment-service` | `cluster/namespaces.yaml` | Add pageindex-mcp namespace |
| `hetzner-deployment-service` | `apps/airline-hr-chatbot/configmap.yaml` | Extend Promtail namespace scrape list; add pageindex_mcp_overview.json dashboard |
