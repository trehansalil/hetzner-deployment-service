#!/usr/bin/env bash
# pageindex-ctl.sh — park / restore the whole pageindex-mcp stack.
#
#   scripts/pageindex-ctl.sh down [--yes]        back up live state, then delete the namespace
#   scripts/pageindex-ctl.sh up [--from DIR]     restore state from a backup and redeploy
#   scripts/pageindex-ctl.sh status              what is running / what backup is current
#
# WHY this exists: `make destroy-pageindex` deletes the namespace but (a) throws away the
# gitignored Secrets, (b) leaves the cluster-scoped docling-node-controller ClusterRole /
# ClusterRoleBinding behind, and (c) `make deploy-pageindex` never applies the KEDA
# ScaledObject, so a rebuild silently loses worker autoscaling.
#
# What survives a `down` (all live in the `infra` namespace, untouched here):
#   Postgres DB `pageindex`, MinIO bucket `pageindex`, Redis db 1, Prometheus/Loki history.
#
# Backups hold live Secrets (API keys, TLS keys, Hetzner token) so they live OUTSIDE git, in
# $PAGEINDEX_BACKUP_ROOT (default /mnt/HC_Volume_106759881/root-ssd-archive/pageindex-mcp-backups/pageindex-mcp), mode 700/600. Never commit them.
#
# Env:
#   KUBECONFIG                 default /etc/rancher/k3s/k3s.yaml when that file exists
#   PAGEINDEX_BACKUP_ROOT      backup parent dir
#   GITHUB_PAT                 (up) if set, (re)creates the ghcr-credentials pull secret
#   KEDA_PAUSED_REPLICAS       (up) override the ScaledObject pause value; "none" = unpaused
set -euo pipefail

NS=pageindex-mcp
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${PAGEINDEX_BACKUP_ROOT:-/mnt/HC_Volume_106759881/root-ssd-archive/pageindex-mcp-backups/pageindex-mcp}"
SO=pageindex-mcp-worker
PAUSE_ANN='autoscaling.keda.sh/paused-replicas'
# Cluster-scoped objects owned by docling-node-controller.yaml (namespace delete won't remove them).
CLUSTER_OBJS=(clusterrolebinding/docling-node-controller clusterrole/docling-node-controller)

if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ns_exists() { kubectl get ns "$NS" >/dev/null 2>&1; }

# Drop server-managed fields so a saved object can be re-applied cleanly. Skips the
# auto-generated root CA configmap and service-account token secrets.
CLEAN_PY='
import json, sys
SKIP_META = ("uid", "resourceVersion", "creationTimestamp", "managedFields", "ownerReferences", "generation", "selfLink")
out = []
for o in json.load(sys.stdin).get("items", []):
    name, kind = o["metadata"]["name"], o["kind"]
    if name == "kube-root-ca.crt" or o.get("type") == "kubernetes.io/service-account-token":
        continue
    for k in SKIP_META:
        o["metadata"].pop(k, None)
    ann = o["metadata"].get("annotations", {})
    ann.pop("kubectl.kubernetes.io/last-applied-configuration", None)
    if not ann:
        o["metadata"].pop("annotations", None)
    o.pop("status", None)
    out.append(o)
json.dump({"apiVersion": "v1", "kind": "List", "items": out}, sys.stdout, indent=1)
'

cmd_backup() {
  ns_exists || die "namespace $NS does not exist; nothing to back up"
  local ts dir; ts="$(date -u +%Y%m%dT%H%M%SZ)"; dir="$BACKUP_ROOT/$ts"
  umask 077
  mkdir -p "$dir"; chmod 700 "$BACKUP_ROOT" "$dir"
  log "backing up $NS -> $dir"

  kubectl get secret    -n "$NS" -o json | python3 -I -c "$CLEAN_PY" > "$dir/secrets.json"
  kubectl get configmap -n "$NS" -o json | python3 -I -c "$CLEAN_PY" > "$dir/configmaps.json"
  # Reference copies (not restored automatically): full workload / routing / RBAC state.
  kubectl get deploy,svc,cronjob,sa,role,rolebinding,networkpolicy,certificate,ingressroute,middleware,scaledobject \
    -n "$NS" -o yaml > "$dir/reference-resources.yaml" 2>/dev/null || true
  kubectl get "${CLUSTER_OBJS[@]}" -o yaml > "$dir/reference-cluster-rbac.yaml" 2>/dev/null || true
  # The pause annotation is live-only (not in worker-scaledobject.yaml): record it explicitly.
  kubectl get scaledobject "$SO" -n "$NS" \
    -o go-template='{{index .metadata.annotations "'"$PAUSE_ANN"'"}}' 2>/dev/null \
    | sed 's/<no value>//' > "$dir/keda-paused-replicas" || true
  kubectl get deploy -n "$NS" -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image' \
    > "$dir/replicas-and-images.txt" 2>/dev/null || true

  # Refuse to leave a useless backup behind: the real secrets must be in it.
  python3 -I - "$dir/secrets.json" <<'PY'
import json, sys
names = {i["metadata"]["name"] for i in json.load(open(sys.argv[1]))["items"]}
need = {"pageindex-mcp-secrets"}
missing = need - names
if missing:
    sys.exit("backup incomplete, missing secrets: %s" % ", ".join(sorted(missing)))
print("    secrets saved: " + ", ".join(sorted(names)))
PY
  chmod 600 "$dir"/* ; ln -sfn "$dir" "$BACKUP_ROOT/latest"
  log "backup OK ($(du -sh "$dir" | cut -f1)); latest -> $dir"
}

cmd_down() {
  local yes=0; [[ "${1:-}" == "--yes" ]] && yes=1
  if ! ns_exists; then
    log "namespace $NS already gone — nothing to do (existing backups untouched)"
    kubectl delete "${CLUSTER_OBJS[@]}" --ignore-not-found
    return 0
  fi
  cmd_backup
  if (( ! yes )); then
    read -r -p "Delete namespace $NS (and cluster RBAC for docling-node-controller)? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || { log "aborted; backup kept, cluster unchanged"; return 1; }
  fi
  log "deleting namespace $NS"
  kubectl delete ns "$NS" --wait=true --timeout=180s
  kubectl delete "${CLUSTER_OBJS[@]}" --ignore-not-found
  log "pageindex-mcp is down. Restore with: scripts/pageindex-ctl.sh up"
}

cmd_up() {
  local from="$BACKUP_ROOT/latest"
  [[ "${1:-}" == "--from" ]] && from="${2:?--from needs a backup dir}"
  [[ -r "$from/secrets.json" ]] || die "no usable backup at $from (need secrets.json). Restore secrets manually (make k8s-secrets-pageindex) or pass --from DIR"
  from="$(readlink -f "$from")"

  # Preconditions the stack depends on (they live outside this namespace).
  kubectl -n infra get deploy/redis deploy/minio sts/postgres >/dev/null 2>&1 \
    || die "infra stack (redis/minio/postgres) is not up; start infra first"
  kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1 || die "KEDA CRDs missing; the ScaledObject cannot be applied"

  log "restoring state from $from"
  kubectl apply -f "$REPO/apps/pageindex-mcp/namespace.yaml"
  kubectl apply -n "$NS" -f "$from/secrets.json"
  # Only the controller's runtime state; the other configmaps are git-managed and re-applied below.
  python3 -I - "$from/configmaps.json" <<'PY' | kubectl apply -n "$NS" -f -
import json, sys
items = [i for i in json.load(open(sys.argv[1]))["items"] if i["metadata"]["name"] == "docling-node-state"]
json.dump({"apiVersion": "v1", "kind": "List", "items": items}, sys.stdout)
PY
  if [[ -n "${GITHUB_PAT:-}" ]]; then
    ( cd "$REPO" && make ghcr-secret-pageindex GITHUB_PAT="$GITHUB_PAT" )
  elif ! kubectl -n "$NS" get secret ghcr-credentials >/dev/null 2>&1; then
    log "note: no ghcr-credentials secret (same as before teardown). If an image pull fails, rerun with GITHUB_PAT=<pat>"
  fi

  log "deploying manifests (make deploy-pageindex)"
  ( cd "$REPO" && make deploy-pageindex )

  log "applying KEDA ScaledObject"
  kubectl apply -n "$NS" -f "$REPO/apps/pageindex-mcp/worker-scaledobject.yaml"
  local paused="${KEDA_PAUSED_REPLICAS:-$(cat "$from/keda-paused-replicas" 2>/dev/null || true)}"
  if [[ -n "$paused" && "$paused" != "none" ]]; then
    kubectl annotate scaledobject "$SO" -n "$NS" "$PAUSE_ANN=$paused" --overwrite
    log "ScaledObject paused at $paused replica(s) (as before teardown; KEDA_PAUSED_REPLICAS=none to autoscale)"
  fi

  log "waiting for rollouts"
  kubectl rollout status deploy/pageindex-mcp        -n "$NS" --timeout=300s
  kubectl rollout status deploy/pageindex-mcp-worker -n "$NS" --timeout=300s
  cmd_status
}

cmd_status() {
  if ns_exists; then
    kubectl get pods,svc,scaledobject,certificate -n "$NS"
  else
    log "namespace $NS: DOWN (parked)"
  fi
  if [[ -L "$BACKUP_ROOT/latest" ]]; then log "latest backup: $(readlink -f "$BACKUP_ROOT/latest")"; else log "no backup yet"; fi
}

case "${1:-}" in
  down)   shift; cmd_down "$@" ;;
  up)     shift; cmd_up "$@" ;;
  backup) cmd_backup ;;
  status) cmd_status ;;
  *) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
