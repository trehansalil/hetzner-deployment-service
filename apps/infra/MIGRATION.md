# Migration runbook — extracting shared infra into the `infra` namespace

This is a **one-time, lossless cutover** from the old in-app datastores to the new
shared `infra` namespace. After it, every app depends on `infra` and `infra`
depends on nothing — tearing down any single app no longer takes shared
infrastructure (or the other apps) down with it.

The repo manifests already carry the post-migration topology (FQDN service names,
trimmed app dirs). This runbook is the **operational sequence the operator runs on
the live cluster**; nothing here is automated by CI.

## What moves and how

| Component | Class | Mechanism | Downtime |
|---|---|---|---|
| **PostgreSQL** (pgvector) | preserve | `pg_dump \| psql` over the network (old + new run concurrently) | ~0 |
| **MinIO** (objects) | preserve | `mc mirror` (live replication) | ~0 |
| **ClickHouse** (`baby_tracker`) | preserve | host-path `cp` of the local-path PV (file locks → stop pod) | ~8–15 min |
| **n8n** (SQLite workflows/creds) | preserve | host-path `cp` of the local-path PV (file locks → stop pod) | ~8–12 min |
| **Redis** | reset | fresh (no persistence configured) | seconds |
| **Prometheus / Loki / Grafana / Promtail** | reset | fresh (TSDB/chunks expire; dashboards/datasources reprovision from ConfigMaps) | ~minutes |
| **Adminer** | stateless | fresh | — |

> **Why host-path `cp` for ClickHouse/n8n but not Postgres/MinIO?** local-path PVs are
> namespace-bound HostPath dirs — a pod can only mount a PVC in its own namespace, so
> there is no "mount both and copy" option. Postgres and MinIO expose network copy
> tools (`pg_dump`, `mc mirror`) that work app-to-app with both sides live. ClickHouse
> and n8n hold exclusive file locks on binary data, so the only safe lossless path is
> to stop the writer and copy the on-disk directory.

## Pre-flight

```bash
# 0a. Snapshot the node first (Hetzner snapshot / LVM) — single-node cluster, no failover.
# 0b. Confirm free disk > 25 GB (old + new PVCs coexist during migration).
df -h /var/lib/rancher/k3s/storage
# 0c. Create infra secrets. infra-secrets MUST match the client creds already in the
#     app secrets (see apps/infra/secret.yaml.example for the exact equalities).
cp apps/infra/secret.yaml.example apps/infra/secret.yaml   # fill in base64 values
make k8s-secrets-infra
# 0d. Repopulate the ClickHouse schema ConfigMap under its new name in infra:
kubectl create configmap infra-sql-init \
  --from-file=init_clickhouse.sql=<path-to-neonatal-care-repo>/init_clickhouse.sql -n infra
# 0e. DNS: create an A record for infra.saliltrehan.com -> the Hetzner server IP
#     BEFORE deploy-infra, or the Let's Encrypt HTTP-01 challenge for the
#     infra-tls Certificate fails. This single host now fronts grafana/adminer/
#     minio/minio-console/automation (apps/infra/ingress.yaml). The old
#     grafana-hr / adminer-hr A records can be retired after cutover.
```

## Phase 0 — Stand up the empty infra stack (no app impact)

```bash
make deploy-infra
kubectl get pods -n infra -w     # wait until all are Running/Ready
```

The old datastores in `neonatal-care` / `hr-chatbot` keep serving the apps — nothing
is cut over yet.

## Phase 1 — Network copy: PostgreSQL + MinIO (zero downtime)

**PostgreSQL** (both DBs live; cutover is a later, separate step):

```bash
PGU=$(kubectl get secret infra-secrets -n infra -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
PGDB=$(kubectl get secret infra-secrets -n infra -o jsonpath='{.data.POSTGRES_DB}' | base64 -d)
kubectl exec -n infra postgres-0 -- pg_isready -U "$PGU" -d "$PGDB"

# Stream a full dump (schema + data + pgvector embeddings + indexes) old → new.
kubectl exec -n hr-chatbot postgres-0 -- \
  pg_dump -U "$PGU" -d "$PGDB" --no-owner --clean --if-exists \
  | kubectl exec -i -n infra postgres-0 -- psql -U "$PGU" -d "$PGDB"

# Verify parity (row counts must match the source).
kubectl exec -n infra postgres-0 -- psql -U "$PGU" -d "$PGDB" -c '\dt'
kubectl exec -n infra postgres-0 -- psql -U "$PGU" -d "$PGDB" -c 'SELECT count(*) FROM "User";'
kubectl exec -n infra postgres-0 -- psql -U "$PGU" -d "$PGDB" -c "SELECT extname FROM pg_extension WHERE extname IN ('vector','pg_trgm');"
```

**MinIO** (`mc mirror`, source stays live):

```bash
RU=$(kubectl get secret infra-secrets -n infra -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)
RP=$(kubectl get secret infra-secrets -n infra -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)

kubectl port-forward -n neonatal-care svc/neonatal-care-minio 9000:9000 >/dev/null 2>&1 & OLD=$!
kubectl port-forward -n infra          svc/minio             19000:9000 >/dev/null 2>&1 & NEW=$!
sleep 3
mc alias set old http://localhost:9000  "$RU" "$RP"
mc alias set new http://localhost:19000 "$RU" "$RP"
mc mirror --overwrite old/ new/
# parity check
diff <(mc ls --recursive old/pageindex | awk '{print $NF}' | sort) \
     <(mc ls --recursive new/pageindex | awk '{print $NF}' | sort) && echo "MinIO parity OK"
kill $OLD $NEW
```

## Phase 2 — Host-path copy: ClickHouse + n8n (brief downtime)

> Warn users — the neonatal-care app loses its DB / n8n during these windows.

> **Version check first.** The new ClickHouse/n8n images are pinned in
> `apps/infra/deployment.yaml` (ClickHouse `25.8`, n8n `1.123.52`). The copied data dir is
> only readable by an **equal-or-newer** engine — neither supports a downgrade — so before
> scaling the new pod up, confirm the pinned tag is ≥ the version running live (the old
> deployments used `:latest`). If the live version is newer, bump the pin to match first.

**ClickHouse** (owner UID/GID 999):

```bash
# Stop both writers so the on-disk data is quiescent.
kubectl scale deployment/clickhouse            -n infra         --replicas=0
kubectl scale deployment/neonatal-care-clickhouse -n neonatal-care --replicas=0
sleep 10

# Resolve the host PV directories.
OLD=$(kubectl get pv -o jsonpath='{.items[?(@.spec.claimRef.namespace=="neonatal-care")]}{range @[?(@.spec.claimRef.name=="clickhouse-data")]}{.spec.local.path}{end}')
NEW=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="infra")]}{.spec.claimRef.name}{" "}{.spec.local.path}{"\n"}{end}' | awk '$1=="clickhouse-data"{print $2}')
echo "OLD=$OLD  NEW=$NEW"

# Copy on the node (run on the host, or via a privileged busybox pod pinned to the node).
cp -av "$OLD/." "$NEW/" && chown -R 999:999 "$NEW"   # repeat for clickhouse-logs (optional)

kubectl scale deployment/clickhouse -n infra --replicas=1
kubectl exec -n infra deploy/clickhouse -- clickhouse-client -q 'SELECT count() FROM baby_tracker.events'
```

**n8n** (owner UID/GID 1000) — identical pattern with `claimRef.name=="n8n-data"` and `chown -R 1000:1000`:

```bash
kubectl scale deployment/n8n              -n infra         --replicas=0
kubectl scale deployment/neonatal-care-n8n -n neonatal-care --replicas=0
sleep 10
# ... resolve OLD/NEW paths as above for n8n-data, cp -av, chown 1000:1000 ...
kubectl scale deployment/n8n -n infra --replicas=1
```

> The init-clickhouse Job is **not** needed if the schema was copied with the data.
> Only run `make init-clickhouse` for a fresh (non-migrated) ClickHouse.

## Phase 3 — Cut the apps over to `infra`

The rewired ConfigMaps (FQDN service names) are already committed, so cutover is just
re-applying the trimmed app manifests + the one gitignored secret value.

```bash
# hr-chatbot: DATABASE_URL host must become postgres.infra.svc.cluster.local (gitignored — hand-edit)
# edit apps/airline-hr-chatbot/secret.yaml -> DATABASE_URL, then:
make k8s-secrets-hr

# Apply rewired manifests (these do NOT delete the old in-app datastores — kubectl apply
# does not prune — so the old copies remain as a hot backup).
make deploy-neonatal
make deploy-hr
make deploy-pageindex

# Roll the app pods so they pick up the new ConfigMaps/Secrets.
kubectl rollout restart deployment/neonatal-care-backend deployment/neonatal-care-nginx -n neonatal-care
kubectl rollout restart deployment/app -n hr-chatbot
kubectl rollout restart deployment/pageindex-mcp deployment/pageindex-mcp-worker -n pageindex-mcp
```

## Phase 4 — Verify

```bash
kubectl get pods -n infra
# neonatal: UI upload → MinIO, ClickHouse queries succeed
# infra host: https://infra.saliltrehan.com/grafana, /adminer, /minio-console, /automation/ all load
# hr-chatbot: chat round-trip (Postgres/pgvector)
# pageindex: index + search against minio.infra + redis.infra
curl -s http://prometheus.infra.svc.cluster.local:9090/api/v1/targets | jq '.data.activeTargets|length'
```

**Resilience proof (the whole point of this migration):**

```bash
# Tear down neonatal — PageIndex must keep serving (MinIO/Redis survive in infra).
make destroy-neonatal
make status-pageindex      # still Ready
# Tear down hr-chatbot — PageIndex metrics still scraped (Prometheus survives in infra).
make destroy-hr
# (re-deploy them afterwards: make deploy-neonatal && make deploy-hr)
```

## Phase 5 — Decommission old infra (after a validation window, e.g. 7 days)

Old datastores still run in the app namespaces as a backup. When confident:

```bash
# neonatal-care
kubectl delete deployment neonatal-care-clickhouse neonatal-care-minio neonatal-care-redis neonatal-care-n8n -n neonatal-care
kubectl delete service    neonatal-care-clickhouse neonatal-care-minio neonatal-care-redis neonatal-care-n8n -n neonatal-care
kubectl delete pvc clickhouse-data clickhouse-logs minio-data n8n-data -n neonatal-care   # deletes the backup data — only when sure

# hr-chatbot
kubectl delete statefulset postgres -n hr-chatbot
kubectl delete deployment adminer prometheus loki grafana -n hr-chatbot
kubectl delete daemonset promtail -n hr-chatbot
kubectl delete service postgres adminer prometheus loki grafana -n hr-chatbot
# Legacy per-host Ingresses + their cert-manager TLS secrets, superseded by the
# consolidated infra.saliltrehan.com IngressRoute. `kubectl apply` never prunes renamed
# objects, so these must be deleted explicitly or they keep serving stale routes/certs.
kubectl delete ingress hr-chatbot-grafana hr-chatbot-adminer -n hr-chatbot --ignore-not-found
kubectl delete secret  hr-chatbot-grafana-tls hr-chatbot-adminer-tls -n hr-chatbot --ignore-not-found
kubectl delete pvc postgres-data prometheus-data loki-data grafana-data -n hr-chatbot
kubectl delete clusterrole promtail-hr-chatbot; kubectl delete clusterrolebinding promtail-hr-chatbot
kubectl delete configmap postgres-init-sql prometheus-config loki-config promtail-config \
  grafana-datasources grafana-dashboard-provider grafana-dashboard-json -n hr-chatbot
kubectl delete configmap neonatal-care-sql-init -n neonatal-care --ignore-not-found
```

## Rollback (per component, before decommission)

Because the old datastores are untouched until Phase 5, rollback is: revert the app
ConfigMap/Secret to the old service names and roll the app pods. The old data is the
source of truth until the new side is validated. For ClickHouse/n8n, scale the new
pod to 0 and the old back to 1.

## Risk register (carried from the design review)

- **Single node, no failover** — snapshot before starting; keep old PVCs ≥7–30 days.
- **Secret value matching** — `infra-secrets` MinIO/ClickHouse/Postgres creds must equal
  the client copies in the app secrets, or apps fail to authenticate post-cutover.
- **Dual-run divergence** — between Phase 1 and Phase 3, writes still go to the OLD
  MinIO/Postgres. Keep the window short, or re-run `mc mirror` / `pg_dump` immediately
  before cutover to catch deltas.
- **Ownership on host copy** — ClickHouse dir must be `chown 999:999`, n8n `1000:1000`,
  or the pod won't start.
- **Prometheus/Loki history is discarded** (reset class) — export first if you need it.
