# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is a **Kubernetes GitOps deployment repository** for the neonatal-care application running on a Hetzner server with k3s. It contains no application source code — only Kubernetes manifests and deployment automation.

## Common Commands

### Cluster Bootstrap (one-time)
```bash
make cluster-init        # Install Traefik (k3s built-in), cert-manager, Let's Encrypt ClusterIssuer
```

### Application Deployment
```bash
make deploy-neonatal                          # Apply all manifests (full deploy)
make rollout-neonatal IMAGE_TAG=<sha>         # Rolling update with new image tag
make status-neonatal                          # Show pods, services, ingress status
make logs-neonatal                            # Tail backend logs
make rollback-neonatal                        # Rollback to previous revision
make init-clickhouse                          # One-time database schema initialization
make destroy-neonatal                         # DELETE entire namespace (destructive)
```

### Key Makefile Variables
- `IMAGE_TAG` — container image tag (default: `latest`)
- `NEONATAL_NS` — Kubernetes namespace (default: `neonatal-care`)
- `IMAGE` — registry path (default: `ghcr.io/trehansalil/neonatal-care`)

### Manual Secret Setup
```bash
cp apps/neonatal-care/secret.yaml.example apps/neonatal-care/secret.yaml
# Fill in base64-encoded values, then:
kubectl apply -f apps/neonatal-care/secret.yaml -n neonatal-care
```

## Architecture

### Directory Layout
- `cluster/` — one-time cluster-wide bootstrap resources (namespaces, Traefik config, cert-manager, Let's Encrypt issuers)
- `apps/neonatal-care/` — all app manifests: configmap, secret template, PVCs, deployments, services, ingress
- `.github/workflows/deploy.yml` — GitHub Actions pipeline triggered by image pushes or manual dispatch

### Request Flow
```
Internet → Traefik Ingress (TLS termination + HTTP→HTTPS redirect)
        → nginx (static SPA + reverse proxy)
            /api/         → Flask backend (port 5000, gunicorn/gevent)
            /minio/       → MinIO API (port 9000)
            /minio-console/ → MinIO console (port 9001)
            /automation/  → n8n workflows (port 5678)
```

### Services (all ClusterIP, `neonatal-care` namespace)
| Service | Port | Storage |
|---------|------|---------|
| Flask backend | 5000 | — |
| ClickHouse | 8123 (HTTP), 9000 (native) | 10Gi data + 2Gi logs PVCs |
| MinIO | 9000 / 9001 | 20Gi PVC |
| Redis | 6379 | no persistence |
| n8n | 5678 | 2Gi PVC |
| nginx | 80 | — |

- **Static files**: nginx initContainer copies HTML from the backend image at startup
- **Config**: non-secret env vars + nginx.conf in `configmap.yaml`; credentials in `secret.yaml` (gitignored)
- **TLS**: cert-manager + Let's Encrypt (HTTP-01 challenge via Traefik), auto-managed

### Deployment Pipeline
Image builds happen in a separate `neonatal-care-repo`. When an image is pushed to GHCR, it triggers a `repository_dispatch` event that runs `deploy.yml` here, which applies manifests and does a rolling image update.
