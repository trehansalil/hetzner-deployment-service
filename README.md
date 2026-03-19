# hetzner-deployment-service

Kubernetes GitOps orchestration repo for all services deployed on the Hetzner server.

## Architecture

```
hetzner-deployment-service/
├── cluster/                  # Cluster-wide resources (run once during setup)
│   ├── namespaces.yaml
│   ├── ingress-nginx/        # Nginx Ingress Controller
│   └── cert-manager/         # TLS via Let's Encrypt
├── apps/
│   └── neonatal-care/        # One directory per deployed application
│       ├── namespace.yaml
│       ├── configmap.yaml    # nginx.conf + non-secret env vars
│       ├── secret.yaml.example
│       ├── pvc.yaml          # Persistent volumes (ClickHouse, MinIO, n8n)
│       ├── deployment.yaml   # All service Deployments/StatefulSets
│       ├── service.yaml      # ClusterIP + NodePort services
│       ├── ingress.yaml      # Ingress rules (TLS via cert-manager)
│       └── jobs/
│           └── init-clickhouse-job.yaml
├── .github/
│   └── workflows/
│       ├── build-push.yml    # Runs in neonatal-care-repo: builds & pushes image
│       └── deploy.yml        # Applies k8s manifests to Hetzner on image update
├── Makefile
└── .gitignore
```

## Prerequisites

- `kubectl` configured to point to your Hetzner K8s cluster
- `kubeconfig` set via `KUBECONFIG` env var or `~/.kube/config`
- Container registry access (GHCR — `ghcr.io/trehansalil`)

## Cluster Bootstrap (first time only)

```bash
# 1. Create namespaces
kubectl apply -f cluster/namespaces.yaml

# 2. Install Nginx Ingress Controller
kubectl apply -f cluster/ingress-nginx/

# 3. Install cert-manager (TLS)
kubectl apply -f cluster/cert-manager/

# 4. Deploy neonatal-care app
make deploy-neonatal
```

## Deploying / Updating an App

```bash
# Deploy or update neonatal-care
make deploy-neonatal

# Update only the image tag (rolling restart)
make rollout-neonatal IMAGE_TAG=sha-abc1234

# View pod status
make status-neonatal

# Tail logs
make logs-neonatal

# Rollback to previous revision
make rollback-neonatal
```

## Secret Management

Copy `apps/neonatal-care/secret.yaml.example` to `apps/neonatal-care/secret.yaml`,
fill in values (base64 encoded), and apply:

```bash
kubectl apply -f apps/neonatal-care/secret.yaml -n neonatal-care
```

> `secret.yaml` is gitignored. For production, use Sealed Secrets or External Secrets Operator.

## Image Build Flow

The `neonatal-care-repo` GitHub Actions workflow builds and pushes the image:

```
push to main (neonatal-care-repo)
  → build Docker image
  → push to ghcr.io/trehansalil/neonatal-care:<sha>
  → trigger deploy workflow in this repo (hetzner-deployment-service)
  → kubectl set image deployment/neonatal-care-backend ...
```

Copy `.github/workflows/build-push.yml` into `neonatal-care-repo/.github/workflows/`.
The `deploy.yml` workflow lives in THIS repo.

## Adding a New Application

1. Create `apps/<your-app>/` directory
2. Copy structure from `apps/neonatal-care/` as a template
3. Add a `deploy-<your-app>` target to the `Makefile`
4. Add a build workflow in the source repo and a deploy trigger here
