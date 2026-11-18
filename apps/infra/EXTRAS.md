# Adopted-from-live stacks (2026-11-18)

Added so `apps/infra/` covers everything running in the `infra` namespace.
Apply with `make deploy-infra-extras` (CI's infra job does not apply these).

| Dir/file | Workloads | Notes |
|---|---|---|
| `claude-mem/` | claude-mem, claude-mem-server-beta, claude-mem-gen-worker (+KEDA ScaledObject), claude-mem-local-gen, cronjobs backup / pg-sync / summary-generator, ingresses, Traefik middlewares, certs | Mirrors github.com/trehansalil/claude-mem-deploy. gen-worker replicas are KEDA-managed (not pinned). Backup cronjob uses a hostPath, so no backup PVC. |
| `doop.yaml` | doop (+ `doop-exports` ingress to MinIO) | Mirrors /root/doop-deploy. |
| `synchub-service.yaml` | Service + Endpoints -> host `synchub.service` :3001 | Runs on the node under systemd, not in-cluster. |
| `service.yaml` (`postgres-stable`) | ClusterIP VIP for postgres | Used by host-run SyncHub. |

Out-of-band secrets (never in git): claude-mem-creds, claude-mem-azure-keys, claude-mem-groq-key (Groq free-tier key used by gen-worker), claude-mem-gen-worker-keys,
claude-mem-server-beta, claude-mem-sync-token, claude-mem-mtls-ca, doop-app, doop-db, doop-s3,
paper-mcp-oauth, paper-exports-s3.

Not in this repo: `tailscale` namespace operator (Helm), `keda` (see apps/keda), cert-manager (cluster/).
Known live-only drift: MinIO runs `coollabsio/minio:RELEASE.2025-10-15T17-29-55Z` (see deployment.yaml).
