#!/usr/bin/env bash
# On-demand Docling node for the portfolio k3s cluster (RFC-050).
#
#   setup            one-time: private network, firewalls, DNS record, SSH key,
#                    and the portfolio k3s private-net drop-in (restarts k3s)
#   bake SHA         create docling-1 (cx33), build the docling-service image
#                    on it, snapshot it, delete it. Automatic: `tick` bakes
#                    each docling-service build deploy.yml records
#   up               create docling-1 from the newest snapshot and join it
#   down             drain and delete docling-1 (billing stops; snapshot kept)
#   status           what exists right now and what it costs
#   tick             run every 30 s by the in-cluster controller
#                    (apps/pageindex-mcp/docling-node-controller.yaml, deployed
#                    on every push to main): route docling-active to the Mac or
#                    docling-1, autostart docling-1 when the Mac is down and
#                    jobs wait, then `reap`
#   reap             spot-style auto-delete: in the last
#                    DOCLING_REAP_MARGIN_MIN (8) minutes of each billed hour,
#                    `down` unless the docling pod is busy converting (>=
#                    DOCLING_BUSY_MCPU, 500m); after DOCLING_MAX_HOURS (3)
#                    billed hours, `down` even if busy
#   reaper on|off    host fallback: the same tick from a systemd timer on
#                    portfolio (retires itself once the controller runs)
#
# NG7 / RFC-052 D10: no Docling conversion ever runs on portfolio (4 cores,
# ~2 GB free). The `local on|off` subcommand and the docling-service-local
# Deployment it scaled were removed 2026-09-27; the only backends are the
# Mac and docling-1.
#
# Flags: --dry-run prints every mutating command instead of running it.
#        --yes answers the confirmation prompts (non-interactive runs).
#
# Costs (hel1, 2026-09-26): cpx62 EUR 0.2083/h + primary IPv4 EUR 0.0008/h
# while docling-1 exists (powered off still bills; only `down` stops it).
# The snapshot bills EUR 0.0143/GB/month while kept. Private networks and
# firewalls are free.
#
# Run on portfolio as root: it needs hcloud (context with a project token),
# kubectl, and /var/lib/rancher/k3s/server/node-token. tick/up/down/reap/status
# also run in the controller pod (HCLOUD_TOKEN from Secret docling-node-hcloud).
set -euo pipefail

NODE=docling-1
# cpx62 (16 shared vCPU / 32 GB, EUR 0.2083/h) since 2026-09-26: the Mac mini
# is the primary converter and this node is a spot-style standby. cx23 (2 / 4
# GB) and cx33 (4 / 8 GB) were too slow for a 292-page PDF (~25-30 s/page; the
# cx33 hit the 55-min service limit). DOCLING_NODE_TYPE overrides it; the
# snapshot (80 GB disk) boots on any x86 type with a disk that large.
NODE_TYPE=${DOCLING_NODE_TYPE:-cpx62}
# Spot-style reaper (see `reap`). Hetzner bills every started hour from the
# server's creation, so deleting just before an hour ends wastes nothing.
REAP_MARGIN_MIN=${DOCLING_REAP_MARGIN_MIN:-8}
BUSY_MCPU=${DOCLING_BUSY_MCPU:-500}
MAX_HOURS=${DOCLING_MAX_HOURS:-3}
REAPER_UNIT=docling-node-reaper
# Stock-aware `up`: the first (type, location) pair Hetzner has in stock,
# walking types in order of preference and, for each, locations in order.
# All three EU locations share the eu-central zone of k3s-net, so a node in
# fsn1/nbg1 joins portfolio's private network like one in hel1. Types must be
# x86 with a disk at least the snapshot's size, and cost <= DOCLING_MAX_EUR_H.
# DOCLING_NODE_TYPE, when set, pins `up` to that one type.
NODE_TYPES=${DOCLING_NODE_TYPES:-cpx62 ccx33 cpx52 ccx43 cpx42 cx43}
[ -z "${DOCLING_NODE_TYPE:-}" ] || NODE_TYPES=$DOCLING_NODE_TYPE
NODE_LOCATIONS=${DOCLING_NODE_LOCATIONS:-hel1 fsn1 nbg1}
MAX_EUR_H=${DOCLING_MAX_EUR_H:-0.50}
# Headroom held back from docling-service's CPU/memory *requests* (see
# predict_pod_size/size_pod_to_node) so node-wide DaemonSets can still
# schedule once docling-service claims the rest of the node -- otherwise
# a request equal to full allocatable leaves them Pending with
# "Insufficient cpu"/"Insufficient memory" (seen live 2026-09-26: promtail
# never got a slot on docling-1, so its logs never reached Loki). Cluster
# DaemonSets today (`kubectl get ds -A`): promtail (infra), requests
# 50m/128Mi, limits 200m/256Mi, tolerates the docling taint; and
# svclb-traefik-<id> (kube-system), no requests/limits set and no
# toleration for `dedicated=docling:NoSchedule`, so it never lands on this
# node. k3s's own node agent and flannel are not pods (no DaemonSet, no
# request) -- they come out of the node's system-reserved share, which is
# already excluded from `allocatable`. 250m/384Mi leaves ~5x promtail's
# CPU request and ~3x its memory request as margin for future DaemonSets
# (e.g. node-exporter) without meaningfully starving docling-service.
DAEMONSET_RESERVE_CPU_M=${DOCLING_DAEMONSET_RESERVE_CPU_M:-250}
DAEMONSET_RESERVE_MEM_MI=${DOCLING_DAEMONSET_RESERVE_MEM_MI:-384}
# Failover (`tick`): the worker converts via docling-active:8090, a
# selector-less Service whose EndpointSlice `tick` points at the Mac while it
# answers, else at docling-1's pod. With AUTOSTART, a Mac that fails
# MAC_FAILS consecutive probes while conversion jobs are queued or running
# brings docling-1 up (at most AUTOSTART_MAX_PER_DAY times a day).
AUTOSTART=${DOCLING_AUTOSTART:-1}
AUTOSTART_MAX_PER_DAY=${DOCLING_AUTOSTART_MAX_PER_DAY:-6}
MAC_FAILS=${DOCLING_MAC_FAILS:-2}
MAC_SLICE=docling-service-mac-1
ACTIVE_SVC=docling-active
ACTIVE_SLICE=docling-active-1
REDIS_SVC=redis
REDIS_NS=infra
REDIS_DB=1
STATE_DIR=${DOCLING_STATE_DIR:-/var/lib/docling-node}
LOCK=${DOCLING_LOCK:-/run/lock/docling-node.lock}
# Autostart counts live in this ConfigMap, not STATE_DIR, so a restarted
# controller pod cannot reset the daily cap.
STATE_CM=docling-node-state
CONTROLLER=docling-node-controller
IN_CLUSTER=0; [ -z "${KUBERNETES_SERVICE_HOST:-}" ] || IN_CLUSTER=1
LOCATION=hel1
NET=k3s-net
NET_RANGE=10.0.0.0/16
SUBNET_RANGE=10.0.0.0/24
PORTFOLIO=portfolio
PORTFOLIO_PRIV_IP=10.0.0.2
NODE_PRIV_IP=10.0.0.3
FW_PORTFOLIO=firewall-1
FW_NODE=docling-node-fw
SSH_KEY_NAME=portfolio-docling
SSH_KEY=${DOCLING_SSH_KEY:-/root/.ssh/docling_node}
# `bake` builds on a small x86 type: the snapshot inherits the build server's
# disk size, and `up` can only boot it on types with at least that disk
# (cx33 = 80 GB fits every candidate in NODE_TYPES).
BAKE_TYPE=${DOCLING_BAKE_TYPE:-cx33}
# Automatic re-bake (`tick`): at most this many attempts per pageindex sha.
BAKE_MAX_ATTEMPTS=${DOCLING_BAKE_MAX_ATTEMPTS:-2}
SNAP_SELECTOR=docling-node=snapshot
ZONE=saliltrehan.com
RECORD=docling
NS=pageindex-mcp
HERE=$(cd "$(dirname "$0")" && pwd)
K3S_DROPIN=/etc/rancher/k3s/config.yaml.d/20-private-net.yaml
TMP=$(mktemp -d)
# A bake or up that dies after creating its server deletes it: it bills
# hourly, and a half-built docling-1 left behind would also stop the next
# tick's autostart (it sees the server) until the reaper got to it.
BAKING=0
STARTING=0
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$BAKING$STARTING" != 00 ]; then
  what=bake; [ "$STARTING" = 1 ] && what=up
  BAKING=0; STARTING=0; log "$what failed (exit $rc): deleting $NODE"; cmd_down || true; fi
  rm -rf "$TMP"' EXIT
# The controller's `timeout` sends TERM. Untrapped, bash still runs the EXIT
# trap but with $? = 0, so the cleanup above would be skipped.
trap 'exit 143' TERM

DRY_RUN=0
YES=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --yes) YES=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# Bold only on a terminal: in the controller pod stderr goes to the container
# log (and Loki), where escape codes would break the stable "==> " prefix.
if [ -t 2 ]; then
  log() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
else
  log() { printf '==> %s\n' "$*" >&2; }
fi
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Mutating commands go through run(): printed, and skipped under --dry-run.
run() {
  printf '  + %s\n' "$*" >&2
  [ "$DRY_RUN" = 1 ] || "$@"
}
confirm() {
  [ "$DRY_RUN" = 1 ] && return 0
  [ "$YES" = 1 ] && { echo "$1 [--yes]" >&2; return 0; }
  [ -t 0 ] || die "$1 needs an answer: run in a terminal, or pass --yes"
  read -r -p "$1 [y/N] " reply
  [ "$reply" = y ] || [ "$reply" = Y ] || die "aborted"
}

need() { command -v "$1" >/dev/null || die "$1 not found"; }
need hcloud; need kubectl; need jq; need curl

exists_server() { hcloud server describe "$1" -o json >/dev/null 2>&1; }
exists_network() { hcloud network describe "$1" -o json >/dev/null 2>&1; }
exists_firewall() { hcloud firewall describe "$1" -o json >/dev/null 2>&1; }

# Hetzner Cloud API token for the DNS zone calls (hcloud has no zone
# commands in this CLI build). HCLOUD_TOKEN wins; else the active context.
api_token() {
  if [ -n "${HCLOUD_TOKEN:-}" ]; then echo "$HCLOUD_TOKEN"; return; fi
  local ctx cfg=${HCLOUD_CONFIG:-$HOME/.config/hcloud/cli.toml}
  ctx=$(hcloud context active)
  awk -v c="$ctx" '
    $0 ~ "name = \"" c "\"" {found=1}
    found && /token = / {gsub(/.*token = "|"$/, ""); print; exit}' "$cfg"
}
api() {  # api METHOD PATH [JSON]
  local tok; tok=$(api_token)
  curl -sS -X "$1" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    ${3:+--data "$3"} "https://api.hetzner.cloud/v1$2"
}

newest_snapshot() {
  hcloud image list --type snapshot --selector "$SNAP_SELECTOR" -o json \
    | jq -r 'sort_by(.created) | last | .id // empty'
}

wait_for() {  # wait_for SECONDS DESCRIPTION CMD...
  local limit=$1 what=$2; shift 2
  [ "$DRY_RUN" = 1 ] && { log "(dry-run) would wait for $what"; return 0; }
  local t=0
  until "$@" >/dev/null 2>&1; do
    t=$((t+2)); [ "$t" -ge "$limit" ] && die "timed out after ${limit}s waiting for $what"
    sleep 2
  done
  log "$what: ok"
}

node_ready() { kubectl get node "$NODE" --no-headers 2>/dev/null | grep -qw Ready; }
# Host keys are pinned per run, in this run's own known_hosts: every
# docling-1 is a new instance and cloud-init regenerates its host keys, so a
# key pinned in ~/.ssh/known_hosts would fail the next bake/up.
ssh_node() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$TMP/known_hosts" -o LogLevel=ERROR \
    -o IdentitiesOnly=yes -o ConnectTimeout=5 "root@$NODE_PRIV_IP" "$@"
}

rules_portfolio() {
  # Public inbound only. Private-network traffic is not filtered by Hetzner
  # Cloud Firewalls. 3001 = SyncHub, 6443 = GitHub Actions deploys.
  jq -n '[
    ({"direction":"in","protocol":"icmp","source_ips":["0.0.0.0/0","::/0"],"description":"ping"}),
    (["22","ssh"],["80","http"],["443","https"],["3001","synchub"],["6443","k3s-api-ci-deploy"]
      | {"direction":"in","protocol":"tcp","port":.[0],"source_ips":["0.0.0.0/0","::/0"],"description":.[1]})
  ]'
}
rules_node() {
  # Nothing public inbound: SSH, kubelet and flannel all use the private net.
  jq -n '[{"direction":"in","protocol":"icmp","source_ips":["0.0.0.0/0","::/0"],"description":"ping"}]'
}

cmd_setup() {
  local tmp=$TMP

  log "SSH key for reaching $NODE over the private network"
  [ -f "$SSH_KEY" ] || run ssh-keygen -q -t ed25519 -N '' -C "portfolio->$NODE" -f "$SSH_KEY"
  hcloud ssh-key describe "$SSH_KEY_NAME" >/dev/null 2>&1 \
    || run hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "$SSH_KEY.pub"

  log "Private network $NET ($NET_RANGE)"
  if ! exists_network "$NET"; then
    run hcloud network create --name "$NET" --ip-range "$NET_RANGE" --label app=pageindex
    run hcloud network add-subnet "$NET" --type cloud --network-zone eu-central --ip-range "$SUBNET_RANGE"
  fi
  if ! hcloud server describe "$PORTFOLIO" -o json \
       | jq -e --arg ip "$PORTFOLIO_PRIV_IP" '.private_net[]? | select(.ip == $ip)' >/dev/null; then
    run hcloud server attach-to-network "$PORTFOLIO" --network "$NET" --ip "$PORTFOLIO_PRIV_IP"
  fi
  wait_for 120 "$PORTFOLIO_PRIV_IP on a local NIC" sh -c "ip -o -4 addr show | grep -q ' $PORTFOLIO_PRIV_IP/'"

  log "Firewalls"
  rules_portfolio > "$tmp/portfolio.json"
  rules_node > "$tmp/node.json"
  hcloud firewall describe "$FW_PORTFOLIO" -o json > "$tmp/$FW_PORTFOLIO.before.json"
  run cp "$tmp/$FW_PORTFOLIO.before.json" "/root/$FW_PORTFOLIO.before.$(date +%Y%m%d%H%M%S).json"
  echo "  $FW_PORTFOLIO new public rules: tcp 22,80,443,3001,6443 + icmp (was: tcp 22-9000)" >&2
  confirm "Replace $FW_PORTFOLIO rules?"
  run hcloud firewall replace-rules "$FW_PORTFOLIO" --rules-file "$tmp/portfolio.json"
  exists_firewall "$FW_NODE" \
    || run hcloud firewall create --name "$FW_NODE" --rules-file "$tmp/node.json" --label app=pageindex

  log "DNS $RECORD.$ZONE -> portfolio public IP"
  local pub; pub=$(hcloud server describe "$PORTFOLIO" -o json | jq -r '.public_net.ipv4.ip')
  if api GET "/zones/$ZONE/rrsets/$RECORD/A" | jq -e '.rrset' >/dev/null; then
    echo "  record exists: $(api GET "/zones/$ZONE/rrsets/$RECORD/A" | jq -c '[.rrset.records[].value]')" >&2
  else
    local body; body=$(jq -nc --arg n "$RECORD" --arg ip "$pub" \
      '{name:$n,type:"A",ttl:300,records:[{value:$ip,comment:"docling-service via portfolio traefik"}]}')
    printf '  + POST /zones/%s/rrsets %s\n' "$ZONE" "$body" >&2
    [ "$DRY_RUN" = 1 ] || api POST "/zones/$ZONE/rrsets" "$body" | jq -e '.rrset' >/dev/null \
      || die "DNS record create failed"
  fi

  log "k3s on portfolio: node-ip + flannel on the private NIC"
  local iface
  iface=$(ip -o -4 addr show | awk -v ip="$PORTFOLIO_PRIV_IP/" 'index($4, ip)==1 {print $2; exit}')
  [ -n "$iface" ] || { [ "$DRY_RUN" = 1 ] && iface="<private-nic>"; } || die "no NIC holds $PORTFOLIO_PRIV_IP"
  if [ -f "$K3S_DROPIN" ]; then
    echo "  $K3S_DROPIN already installed" >&2
  else
    sed "s|__PRIVATE_IFACE__|$iface|" "$HERE/server-private-net.yaml" > "$tmp/20-private-net.yaml"
    echo "  k3s restarts: API down ~30-90s, containers keep running (KillMode=process)" >&2
    confirm "Install $K3S_DROPIN (flannel-iface: $iface) and restart k3s?"
    run install -d -m 0755 "$(dirname "$K3S_DROPIN")"
    [ -f /etc/rancher/k3s/config.yaml ] || run install -m 0600 /dev/null /etc/rancher/k3s/config.yaml
    run install -m 0600 "$tmp/20-private-net.yaml" "$K3S_DROPIN"
    run systemctl restart k3s
    wait_for 300 "portfolio InternalIP = $PORTFOLIO_PRIV_IP" sh -c \
      "kubectl get node $PORTFOLIO -o jsonpath='{.status.addresses}' | grep -q '\"$PORTFOLIO_PRIV_IP\"'"
  fi
  log "setup done"
}

cmd_bake() {
  local sha=${1:-}
  [ -n "$sha" ] || die "usage: bake <pageindex commit sha> (full 40-char sha)"
  [ "${#sha}" = 40 ] || die "give the full 40-char sha"
  exists_server "$NODE" && die "$NODE already exists; run '$0 down' first"
  exists_network "$NET" || die "run '$0 setup' first"

  need ssh
  # The controller gets the join token from Secret docling-node-bake.
  local k3s_token=${DOCLING_K3S_TOKEN:-}
  [ -n "$k3s_token" ] || k3s_token=$(cat /var/lib/rancher/k3s/server/node-token)
  # A token from a Secret file keeps its trailing newline; sed would choke.
  k3s_token=$(tr -d '\r\n' <<<"$k3s_token")
  local tmp=$TMP
  ( umask 077
    sed -e "s|__K3S_NODE_TOKEN__|$k3s_token|" \
        -e "s|__PAGEINDEX_SHA__|$sha|" \
        "$HERE/cloud-init-docling-agent.yaml" > "$tmp/user-data.yaml" )

  # First location with $BAKE_TYPE in stock (a create can fail on stock).
  local loc created=
  for loc in $NODE_LOCATIONS; do
    log "Create $NODE ($BAKE_TYPE, ubuntu-24.04, $loc) — billing starts"
    BAKING=1
    if run hcloud server create --name "$NODE" --type "$BAKE_TYPE" --image ubuntu-24.04 \
        --location "$loc" --ssh-key "$SSH_KEY_NAME" --firewall "$FW_NODE" \
        --label role=k3s-agent --label workload=docling \
        --user-data-from-file "$tmp/user-data.yaml" --start-after-create=false </dev/null; then
      created=$loc; break
    fi
    exists_server "$NODE" && run hcloud server delete "$NODE"
  done
  [ -n "$created" ] || { BAKING=0; die "$BAKE_TYPE could not be created in any of [$NODE_LOCATIONS]"; }
  run hcloud server attach-to-network "$NODE" --network "$NET" --ip "$NODE_PRIV_IP"
  run hcloud server poweron "$NODE"

  # The build downloads the Docling models from the HF Hub; a token avoids
  # anonymous rate limits. It goes over SSH into /run (tmpfs), not into
  # user-data, so it is never in the metadata service, /var/lib/cloud, or
  # the snapshot. The bake waits up to 10 min for it, then builds anonymously.
  # The controller gets it as env (optional secretKeyRef), not via the API.
  local hf=${HF_TOKEN:-}
  [ -n "$hf" ] || [ "$IN_CLUSTER" = 1 ] || hf=$(kubectl -n "$NS" get secret pageindex-mcp-secrets \
         -o jsonpath='{.data.HF_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)
  wait_for 300 "SSH on $NODE" ssh_node true
  if [ -n "$hf" ]; then
    log "Hand HF_TOKEN to $NODE (/run/hf_token)"
    [ "$DRY_RUN" = 1 ] || printf '%s' "$hf" | ssh_node 'umask 077; cat > /run/hf_token'
  else
    log "no HF_TOKEN in pageindex-mcp-secrets; the model download runs anonymously"
    [ "$DRY_RUN" = 1 ] || ssh_node 'touch /run/hf_token'
  fi
  unset hf

  log "Build runs on $NODE (~15-30 min); log: ssh -i $SSH_KEY root@$NODE_PRIV_IP tail -f /var/log/docling-bake.log"
  wait_for 2700 "image build + import on $NODE" ssh_node test -f /var/lib/docling-bake.done
  [ "$DRY_RUN" = 1 ] || ssh_node tail -3 /var/log/docling-bake.log
  wait_for 300 "$NODE Ready" node_ready

  local tag="docling-service:${sha:0:7}"
  # docling-1 runs the baked image; `up` re-pins it from the snapshot.
  log "Point the docling-service Deployment at $tag"
  run kubectl -n "$NS" set image deployment/docling-service "docling-service=$tag"

  log "Snapshot $NODE, then delete it"
  run hcloud server shutdown "$NODE"
  wait_for 180 "$NODE off" sh -c "hcloud server describe $NODE -o json | jq -e '.status==\"off\"'"
  run hcloud server create-image "$NODE" --type snapshot \
    --description "docling-node $tag" --label "$SNAP_SELECTOR" --label "pageindex-sha=${sha:0:7}"
  # Keep the previous snapshot as a rollback (~EUR 0.11/month): `up` boots
  # the newest; to roll back, delete the newest. Older ones go.
  local old
  for old in $(hcloud image list --type snapshot --selector "$SNAP_SELECTOR" -o json \
      | jq -r 'sort_by(.created) | reverse | .[2:][] | .id'); do
    run hcloud image delete "$old"
  done
  BAKING=0
  cmd_down
  log "bake done: '$0 up' boots from the new snapshot"
}

# Give the docling pod the whole node, whatever type `up` got: the service
# derives its threads, parallel chunk processes and chunk size from its own
# cgroup limits, so the CPU limit is left at the full node and is the only
# sizing input. Requests (both cpu and memory) and the memory limit hold
# back DAEMONSET_RESERVE_CPU_M/_MEM_MI on top of the eviction margin, so a
# runaway conversion is still OOM-killed in its cgroup before the kubelet
# evicts the pod for node memory pressure, and node-wide DaemonSets can
# still schedule.
size_pod_to_node() {
  local cpu mem cpu_m mem_mi cpu_req_m
  cpu=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.cpu}')
  mem=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.memory}')
  case "$cpu" in *m) cpu_m=${cpu%m} ;; *) cpu_m=$((cpu * 1000)) ;; esac
  case "$mem" in
    *Ki) mem_mi=$((${mem%Ki} / 1024)) ;;
    *Mi) mem_mi=${mem%Mi} ;;
    *Gi) mem_mi=$((${mem%Gi} * 1024)) ;;
    *) mem_mi=$((mem / 1048576)) ;;
  esac
  # Hold back DAEMONSET_RESERVE_MEM_MI (was a flat 256Mi) so a runaway
  # conversion is still OOM-killed inside its own cgroup short of node
  # memory pressure, and so node-wide DaemonSets (promtail; see
  # DAEMONSET_RESERVE_CPU_M/_MEM_MI above) fit once docling-service claims
  # the rest of the node. Applied to both request and limit: unlike CPU,
  # a memory pod that exceeds its limit is OOM-killed rather than
  # throttled, so letting the limit run up to the full node would risk the
  # kernel killing a DaemonSet pod instead of docling-service's own cgroup.
  mem_mi=$((mem_mi - DAEMONSET_RESERVE_MEM_MI))
  # The CPU *request* holds back DAEMONSET_RESERVE_CPU_M for the same
  # reason; the CPU *limit* stays at the full node so docling-service can
  # still burst there. CPU is throttled, not OOM-killed, past its limit,
  # and the service derives its thread/process/chunk-size sizing from the
  # cgroup CPU limit (see comment above), so reducing the limit would
  # silently cut parallelism.
  cpu_req_m=$((cpu_m - DAEMONSET_RESERVE_CPU_M))
  log "Size docling-service to $NODE: requests cpu ${cpu_req_m}m mem ${mem_mi}Mi, limits cpu ${cpu_m}m mem ${mem_mi}Mi (allocatable $cpu / $mem)"
  run kubectl -n "$NS" set resources deployment/docling-service -c docling-service \
    --requests="cpu=${cpu_req_m}m,memory=${mem_mi}Mi" --limits="cpu=${cpu_m}m,memory=${mem_mi}Mi"
}

# "type location eur_per_h" lines, best first: in stock right now, x86, disk
# >= the snapshot's, price <= MAX_EUR_H. Types outrank locations: a worse
# type is tried only after the preferred one is out of stock everywhere.
node_candidates() {  # node_candidates SNAPSHOT_DISK_GB
  jq -rn --argjson st "$(hcloud server-type list -o json)" \
    --argjson dc "$(hcloud datacenter list -o json)" \
    --arg types "$NODE_TYPES" --arg locs "$NODE_LOCATIONS" \
    --argjson cap "$MAX_EUR_H" --argjson disk "$1" '
    ($locs | split(" ") | map(select(. != ""))) as $L
    | $types | split(" ") | map(select(. != ""))[] as $t
    | ($st[] | select(.name == $t)) as $s
    | select($s.architecture == "x86" and $s.disk >= $disk)
    | $L[] as $l
    | ($s.prices[] | select(.location == $l) | .price_hourly.gross | tonumber) as $p
    | select($p <= $cap)
    | select(any($dc[]; .location.name == $l and (.server_types.available | index($s.id)) != null))
    | "\($t) \($l) \($p * 10000 | round / 10000)"'
}

# Requests/limits for the pod, predicted from the server type so the pod can
# be created before the node exists and schedule the moment it joins.
# Allocatable measured 2026-09-26: cpx62 (32 GB) -> 30619Mi, cx33 (8 GB) ->
# ~7014Mi; 90% of RAM less 512Mi stays under both. All cores are allocatable.
# The request (both cpu and memory) holds back DAEMONSET_RESERVE_CPU_M /
# DAEMONSET_RESERVE_MEM_MI so node-wide DaemonSets can still schedule once
# docling-service claims the rest of the node -- this is the sizing that
# produced the live requests=limits=full-node patch that starved promtail
# (cpx62: requests.cpu 16000m, requests.memory 28979Mi, 2026-09-26). The
# limit is left at the full predicted size: docling-service derives its
# thread/process/chunk sizing from its cgroup limits, not its requests, so
# only the request needs the reserve to fix the DaemonSet scheduling gap.
predict_pod_size() {  # predict_pod_size TYPE -> "req_cpu_m req_mem_mi lim_cpu_m lim_mem_mi"
  hcloud server-type describe "$1" -o json \
    | jq -r --argjson rc "$DAEMONSET_RESERVE_CPU_M" --argjson rm "$DAEMONSET_RESERVE_MEM_MI" '
      (.cores * 1000) as $cpu | ((.memory * 1024 * 0.9 - 512) | floor) as $mem
      | "\($cpu - $rc) \($mem - $rm) \($cpu) \($mem)"'
}

# ON_SERVER_CREATED (a command name, optional) runs each time `up` actually
# creates a server -- the moment billing starts -- so `tick` counts autostarts
# by money spent: a stock miss creates nothing and costs no quota, and an `up`
# that dies after its create (the EXIT trap deletes the node) still counts.
# Here, not after cmd_up returns: its failures exit the script.
ON_SERVER_CREATED=
server_created() {
  [ "$DRY_RUN" = 1 ] || [ -z "$ON_SERVER_CREATED" ] || "$ON_SERVER_CREATED" \
    || log "WARN: $ON_SERVER_CREATED failed after creating $NODE"
}

cmd_up() {
  exists_server "$NODE" && { log "$NODE already exists"; cmd_status; return; }
  local snap; snap=$(newest_snapshot)
  [ -n "$snap" ] || die "no snapshot labelled $SNAP_SELECTOR; run '$0 bake <sha>' first"
  local snap_json; snap_json=$(hcloud image describe "$snap" -o json)
  # Run the image baked into the snapshot (its description ends in the tag).
  # A docling-service deploy dispatch can repoint the Deployment at a ghcr
  # tag that was never pushed; the node would then sit in ImagePullBackOff.
  local img; img=$(jq -r '.description | split(" ") | last' <<<"$snap_json")
  [[ "$img" == docling-service:* ]] || die "snapshot $snap description has no docling-service:<tag>"

  local cands; cands=$(node_candidates "$(jq -r .disk_size <<<"$snap_json")")
  [ -n "$cands" ] || die "no type in [$NODE_TYPES] is in stock in [$NODE_LOCATIONS] at <= EUR $MAX_EUR_H/h"
  log "In stock, best first: $(tr '\n' ';' <<<"$cands")"

  local type loc price created=
  while read -r type loc price; do
    # Create the pod first (Pending until the node joins), sized for this
    # type, so it schedules the moment the node is Ready.
    local size req_cpu_m req_mem_mi lim_cpu_m lim_mem_mi
    size=$(predict_pod_size "$type"); read -r req_cpu_m req_mem_mi lim_cpu_m lim_mem_mi <<<"$size"
    run kubectl -n "$NS" patch deployment/docling-service --type=strategic </dev/null -p "$(jq -nc \
      --arg img "$img" --arg req_cpu "${req_cpu_m}m" --arg req_mem "${req_mem_mi}Mi" \
      --arg lim_cpu "${lim_cpu_m}m" --arg lim_mem "${lim_mem_mi}Mi" \
      '{spec: {replicas: 1, template: {spec: {containers: [{name: "docling-service", image: $img,
        resources: {requests: {cpu: $req_cpu, memory: $req_mem},
                    limits: {cpu: $lim_cpu, memory: $lim_mem}}}]}}}}')"
    log "Create $NODE: $type in $loc (EUR $price/h) from snapshot $snap -- billing starts"
    STARTING=1
    # A type can sell out between the stock check and the create: move on.
    if run hcloud server create --name "$NODE" --type "$type" --image "$snap" \
        --location "$loc" --ssh-key "$SSH_KEY_NAME" --firewall "$FW_NODE" \
        --label role=k3s-agent --label workload=docling --start-after-create=false </dev/null; then
      server_created; created=$type; break
    fi
    log "create of $type in $loc failed; trying the next candidate"
    # A half-failed create still left a server behind: its hour is billed.
    exists_server "$NODE" && { server_created; run hcloud server delete "$NODE"; }
  done <<<"$cands"
  if [ -z "$created" ]; then
    STARTING=0
    run kubectl -n "$NS" scale deployment/docling-service --replicas=0
    die "every in-stock candidate failed to create"
  fi

  # Attach before the first boot: the snapshot's k3s config pins node-ip.
  run hcloud server attach-to-network "$NODE" --network "$NET" --ip "$NODE_PRIV_IP"
  run hcloud server poweron "$NODE"
  wait_for 300 "$NODE Ready" node_ready
  run kubectl uncordon "$NODE"
  # The prediction is conservative; if the pod still cannot fit, size it to
  # the node's real allocatable (this restarts the pod, ~20 s).
  if [ "$DRY_RUN" != 1 ] && ! wait_for_scheduled 20; then
    log "pod not schedulable with the predicted size; sizing to allocatable"
    size_pod_to_node
  fi
  run kubectl -n "$NS" rollout status deployment/docling-service --timeout=600s
  # The pod is serving: from here a failure no longer deletes the node.
  STARTING=0
  # traefik picks up the new endpoint a few seconds after the rollout: retry
  # the 503 for up to a minute, and warn rather than fail (the node is up).
  # Skipped in the controller: failover routes to the pod IP, not the ingress.
  if [ "$DRY_RUN" != 1 ] && [ "$IN_CLUSTER" = 0 ]; then
    local t=0
    until curl -fsS -m 10 "https://$RECORD.$ZONE/health"; do
      t=$((t+5)); [ "$t" -ge 60 ] && { log "WARN: https://$RECORD.$ZONE/health not answering yet"; break; }
      sleep 5
    done
    echo
  fi
  if [ "$IN_CLUSTER" = 1 ] || systemctl is-active --quiet "$REAPER_UNIT.timer"; then
    log "up ($created). The reaper deletes $NODE near the end of each billed hour unless it is converting (max $MAX_HOURS h)."
  else
    log "up ($created). WARN: reaper timer is off ('$0 reaper on'); run '$0 down' when done -- $NODE bills hourly."
  fi
}

wait_for_scheduled() {  # wait_for_scheduled SECONDS
  local t=0
  until kubectl -n "$NS" get pods -l app=docling-service,copy=node -o json \
      | jq -e '[.items[] | select(.spec.nodeName == "'"$NODE"'")] | length > 0' >/dev/null; do
    t=$((t+2)); [ "$t" -ge "$1" ] && return 1
    sleep 2
  done
}

cmd_down() {
  # Send new conversions back to the Mac before the node goes away -- but only
  # if it actually answers. Routing to a Mac that is down (Q5 item 13) would
  # blackhole every job for up to 130s instead of failing fast; go to "none"
  # (empty endpoints, immediate ECONNREFUSED) instead.
  if mac_ok; then route_active mac; else route_active none; fi
  # 0 at rest, so no Pending pod holds the node's full request meanwhile.
  run kubectl -n "$NS" scale deployment/docling-service --replicas=0
  if node_ready || kubectl get node "$NODE" >/dev/null 2>&1; then
    run kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=120s || true
    run kubectl delete node "$NODE"
  fi
  if exists_server "$NODE"; then
    run hcloud server delete "$NODE"
  else
    log "$NODE does not exist"
  fi
  # A primary IP created with the server is deleted with it (auto_delete);
  # anything left unattached still bills.
  local stray; stray=$(hcloud primary-ip list -o json | jq -r '.[] | select(.assignee_id == null) | "\(.id) \(.ip)"')
  [ -z "$stray" ] || log "unattached primary IPs still billing: $stray"
}

cmd_status() {
  if exists_server "$NODE"; then
    hcloud server describe "$NODE" -o json | jq -r '.datacenter.location.name as $loc |
      "server: \(.name) \(.server_type.name) \(.status) created \(.created)  (EUR \(.server_type.prices[] | select(.location == $loc) | .price_hourly.gross | tonumber * 10000 | round / 10000)/h while it exists)"'
  else
    echo "server: $NODE absent (not billing)"
  fi
  kubectl get node "$NODE" --no-headers 2>/dev/null | sed 's/^/node:   /' || true
  kubectl -n "$NS" get pods -l app=docling-service -o wide --no-headers 2>/dev/null | sed 's/^/pod:    /' || true
  hcloud image list --type snapshot --selector "$SNAP_SELECTOR" -o json | jq -r \
    '.[] | "snapshot: \(.id) \(.description) \(.image_size // 0 | . * 100 | round / 100) GB  (~EUR \(.image_size // 0 | . * 0.0143 * 100 | round / 100)/month)"'
  hcloud server describe "$PORTFOLIO" -o json | jq -r '"portfolio: \(.server_type.name) (\(.server_type.memory) GB)"'
}

# Summed CPU in millicores of the docling-service pods on docling-1: 0 when
# none runs there, "unknown" when one does but its CPU cannot be read (API
# error, metrics-server not scraped it yet). A failed read must not look idle,
# or the reaper deletes a node mid-conversion. copy=node only: no other copy
# exists (NG7 -- there is no portfolio copy to keep docling-1 alive
# spuriously). kubectl top prints "1234m" or whole cores ("2").
docling_mcpu() {
  local pods top
  pods=$(kubectl -n "$NS" get pods -l app=docling-service,copy=node -o json 2>/dev/null \
    | jq -r --arg n "$NODE" '.items[] | select(.spec.nodeName == $n) | .metadata.name') \
    || { echo unknown; return; }
  [ -n "$pods" ] || { echo 0; return; }
  top=$(kubectl top pod -n "$NS" -l app=docling-service,copy=node --no-headers 2>/dev/null) \
    || { echo unknown; return; }
  # Every pod on docling-1 needs a sample; a missing one is not a zero.
  awk -v want="$(tr '\n' ' ' <<<"$pods")" '
    BEGIN {n=split(want, w, " "); for (i=1; i<=n; i++) need[w[i]]=1}
    ($1 in need) {c=$2; if (c ~ /m$/) {sub(/m$/, "", c)} else {c=c*1000}; s+=c; delete need[$1]}
    END {for (p in need) {print "unknown"; exit} print s+0}' <<<"$top"
}

cmd_reap() {
  exists_server "$NODE" || return 0
  local age_min into_hour billed cpu
  # In jq, not date -d: the controller image's busybox date cannot parse it.
  age_min=$(hcloud server describe "$NODE" -o json | jq -r '
    (now - (.created | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601)) / 60 | floor')
  into_hour=$(( age_min % 60 ))
  billed=$(( age_min / 60 + 1 ))
  # Any age from the last margin of the final allowed hour onwards, so a
  # missed tick (host reboot, API error) cannot let the node outlive the cap.
  if [ "$age_min" -ge $(( MAX_HOURS * 60 - REAP_MARGIN_MIN )) ]; then
    log "reap: $NODE is ${age_min} min old, hour $billed of max $MAX_HOURS -- deleting even if busy"
    cmd_down
    return
  fi
  if [ "$into_hour" -lt $(( 60 - REAP_MARGIN_MIN )) ]; then
    log "reap: $NODE ${age_min} min old (billed hour $billed, ${into_hour} min in) -- keep"
    return 0
  fi
  cpu=$(docling_mcpu)
  if [ "$cpu" = unknown ]; then
    log "reap: $NODE CPU unreadable near the end of hour $billed -- keeping it (the $MAX_HOURS h cap still applies)"
    return 0
  fi
  if [ "$cpu" -ge "$BUSY_MCPU" ]; then
    # Q5 item 14: CPU alone cannot tell a real conversion from an orphan (the
    # client disconnected but the docling-service request, and therefore the
    # CPU, is still running -- see Q3). Cross-check docling-service's own
    # /health (in_flight/current_job_id, Q5 item 10) against the app's job
    # status hash: if the service still claims to be working current_job_id
    # but that job is no longer "processing" in Redis, the work is orphaned
    # and must not extend a billed hour just because the orphan is busy-CPU.
    if [ "$ORPHAN_CHECK" = 1 ]; then
      local h hi hj hs
      h=$(docling_health)
      if [ -n "$h" ]; then
        # Pipe-delimited (see docling_health): a NON-whitespace IFS so an
        # empty current_job_id field stays empty instead of `read` collapsing
        # it away and shifting started_at into its place -- tab or space as
        # IFS both collapse consecutive occurrences (they're "IFS
        # whitespace"); pipe does not.
        IFS='|' read -r hi hj hs <<<"$h"
        if [ "${hi:-0}" -gt 0 ] 2>/dev/null && [ -n "$hj" ]; then
          # job_status_get distinguishes "Redis positively answered" (rc=0,
          # prints a status word or "absent") from "could not ask" (rc=1,
          # nothing printed -- a ClusterIP lookup failure, TCP timeout, or
          # dropped connection). Only a POSITIVE terminal/absent answer counts
          # as orphaned; a transport failure, "processing"/"pending", or any
          # other unrecognized status all fall through to the CPU-busy KEEP
          # below, same as the /health-unreachable case already does. This is
          # the fix for the blocker where a Redis blip (empty string, same as
          # a real nil) could delete docling-1 mid-conversion.
          local st rc=0
          st=$(job_status_get "$hj") || rc=$?
          if [ "$rc" -eq 0 ] && { [ "$st" = done ] || [ "$st" = error ] || [ "$st" = absent ]; }; then
            log "reap: $NODE reports in_flight=$hi current_job_id=$hj (started $hs) but pageindex:job:$hj status=$st -- orphaned, deleting despite ${cpu}m CPU"
            cmd_down
            return
          elif [ "$rc" -ne 0 ]; then
            log "reap: $NODE reports in_flight=$hi current_job_id=$hj but pageindex:job:$hj status could not be read (Redis unreachable) -- treating as busy, not orphaned"
          fi
          # KNOWN GAP (opposite direction, not fixed here): if arq retries
          # job_id $hj and it re-enters "processing" before this check runs,
          # a genuinely stale orphan reads as live and is kept for another
          # billed hour. That costs money, not correctness -- it never kills
          # a real conversion, so it is left as a known gap rather than
          # guessed at with no live-log evidence of it actually happening.
        fi
      fi
      # health unreachable, in_flight=0, or current_job_id genuinely empty
      # (no X-Job-Id on this conversion, or docling-service hasn't shipped
      # the field yet): nothing to positively cross-check, so "cannot
      # determine" -> fall through to the plain CPU-busy KEEP below. Never
      # treated as orphaned -- only a POSITIVE done/error/absent answer for a
      # REAL job id does that (see above).
    fi
    log "reap: $NODE busy (${cpu}m CPU) near the end of hour $billed -- keeping it for hour $(( billed + 1 ))"
    return 0
  fi
  log "reap: $NODE idle (${cpu}m CPU), ${into_hour} min into billed hour $billed -- deleting"
  cmd_down
}

# ---- failover: docling-active routing + autostart --------------------------

# "addr port" of the Mac, from its EndpointSlice (the one place it is written).
mac_endpoint() {
  kubectl -n "$NS" get endpointslice "$MAC_SLICE" -o json \
    | jq -r '"\(.endpoints[0].addresses[0]) \(.ports[0].port)"'
}
mac_ok() {
  local addr port; read -r addr port <<<"$(mac_endpoint)"
  curl -fsS -m 5 -o /dev/null "http://$addr:$port/health"
}
# IP of a Ready docling-service pod on docling-1, or empty.
node_pod_ip() {
  kubectl -n "$NS" get pods -l app=docling-service,copy=node -o json | jq -r '
    [.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
     | .status.podIP] | first // empty'
}

# Point docling-active (what the worker calls) at the Mac, docling-1's pod, or
# nowhere. "none" (Q5 item 13) writes an EndpointSlice with endpoints: [], so
# kube-proxy REJECTs (immediate ECONNREFUSED) instead of a SYN blackhole to a
# dead Mac. Never falls back to the Mac silently: a caller wanting the Mac
# route must ask for it explicitly and mac_ok has already been checked by the
# caller (cmd_down, cmd_tick) -- route_active itself does not gate on mac_ok,
# so it must never be called with "mac" when the Mac is down.
route_active() {  # route_active mac|node|none
  local addr port want cur
  case "$1" in
    node)
      addr=$(node_pod_ip); port=8080
      [ -n "$addr" ] || { log "route: no Ready pod on $NODE; leaving routing as is"; return 0; }
      ;;
    none) addr=""; port=8090 ;;
    *) read -r addr port <<<"$(mac_endpoint)" ;;
  esac
  want="$addr:$port"
  cur=$(kubectl -n "$NS" get endpointslice "$ACTIVE_SLICE" -o json 2>/dev/null \
    | jq -r 'if (.endpoints // []) == [] then "" else "\(.endpoints[0].addresses[0]):\(.ports[0].port)" end' || true)
  [ -n "$addr" ] || want=""
  [ "$cur" = "$want" ] && return 0
  log "route: $ACTIVE_SVC -> $1 (${want:-empty}, was ${cur:-unset})"
  [ "$DRY_RUN" = 1 ] && return 0
  if [ -z "$addr" ]; then
    kubectl apply -f - >/dev/null <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: $ACTIVE_SLICE
  namespace: $NS
  labels:
    kubernetes.io/service-name: $ACTIVE_SVC
    endpointslice.kubernetes.io/managed-by: docling-node-tick
addressType: IPv4
ports:
  - name: http
    port: 8090
    protocol: TCP
endpoints: []
EOF
  else
    kubectl apply -f - >/dev/null <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: $ACTIVE_SLICE
  namespace: $NS
  labels:
    kubernetes.io/service-name: $ACTIVE_SVC
    endpointslice.kubernetes.io/managed-by: docling-node-tick
addressType: IPv4
ports:
  - name: http
    port: $port
    protocol: TCP
endpoints:
  - addresses: ["$addr"]
EOF
  fi
}

# Conversion demand: queued arq jobs + running ones (arq's own cron excluded).
# Raw RESP over /dev/tcp: no redis-cli on the host.
# Real ingest work waiting in arq (Redis DB $REDIS_DB). Prints one line,
#   "<total> <queued> <running> <cron> <deferred>"
# where only total (= queued + running) is demand. arq cron jobs are excluded
# on both sides: the worker enqueues each one into arq:queue ~1 s before it
# fires (id "cron:<name>:<ms>", e.g. cron:reap_stale_jobs every minute), so a
# raw ZCARD that lands in that window reads 1 and autostarted docling-1 for
# nothing (5x on 2026-09-26, every decision within 0.4 s of :00). Queue
# entries scored in the future (deferred; arq scores are ms epochs) are not
# demand yet either; "now" comes from Redis TIME, not this pod's clock.
demand_fetch() {
  local ip
  ip=$(kubectl -n "$REDIS_NS" get svc "$REDIS_SVC" -o jsonpath='{.spec.clusterIP}')
  # `exec cat`: cat must BE the process timeout signals. A cat forked by the
  # inner bash outlives it (busybox timeout kills only its own pid), keeps the
  # pipe to tr open, and hangs the whole tick -- see redis_cmd.
  timeout 5 bash -c "exec 3<>/dev/tcp/$ip/6379
    printf 'SELECT $REDIS_DB\r\nTIME\r\nZRANGE arq:queue 0 -1 WITHSCORES\r\nKEYS arq:in-progress:*\r\nQUIT\r\n' >&3
    exec cat <&3" 2>/dev/null | tr -d '\r' || true
}

# RESP replies on stdin, in pipeline order: 1 SELECT, 2 TIME, 3 ZRANGE, 4 KEYS.
# POSIX awk only (the controller image is alpine/busybox). Unreachable Redis
# yields empty input and therefore "0 0 0 0 0" -- no demand, as before.
demand_parse() {
  awk '
    need { v[r, ++n[r]] = $0; need = 0; left--; next }
    left > 0 && /^\$/ { if ($0 == "$-1") left--; else need = 1; next }
    { r++; left = 0; if ($0 ~ /^\*/) left = substr($0, 2) + 0 }
    END {
      now = v[2, 1] * 1000 + int(v[2, 2] / 1000)
      for (i = 1; i <= n[3]; i += 2) {
        if (index(v[3, i], "cron:") == 1) cron++
        else if (now > 0 && v[3, i + 1] + 0 > now) deferred++
        else queued++
      }
      for (i = 1; i <= n[4]; i++) {
        if (index(v[4, i], "arq:in-progress:cron:") == 1) cron++
        else running++
      }
      printf "%d %d %d %d %d\n", queued + running, queued, running, cron, deferred
    }'
}

demand() { demand_fetch | demand_parse; }

# ---- docling:backend (Q5 item 12) + orphan-aware reap (Q5 item 14) --------

BACKEND_KEY=docling:backend
BACKEND_TTL_S=120
# docling-service's /health orphan fields (in_flight, current_job_id,
# started_at -- Q5 item 10) are built concurrently by another workstream; this
# flag is the kill switch if that contract lands differently than expected.
# 0 falls back to the plain CPU-only busy check reap always had.
ORPHAN_CHECK=${DOCLING_ORPHAN_CHECK:-1}

# Raw RESP over /dev/tcp, same channel as demand_fetch/demand(). The RESP
# bytes are built as a separate variable and handed to the inner bash as a
# positional arg ($1), never interpolated into the -c string itself, so a
# value containing '$', quotes or CR/LF cannot break the command text (only
# $ip/$REDIS_DB, both controller-known, are interpolated into the script).
# Exit status distinguishes "Redis answered" from "could not ask at all":
# 0 with the raw RESP bytes on stdout when a reply was actually received
# (including a real nil reply -- "$-1" is non-empty text); 1 with nothing on
# stdout when the ClusterIP lookup failed, the TCP connect/timeout failed, or
# the connection dropped mid-reply. Callers (job_status_get, cmd_reap) MUST
# treat exit 1 as "unknown", never as a positive nil/absent answer -- a Redis
# blip must never look identical to "the job really doesn't exist".
redis_cmd() {  # redis_cmd RESP_BYTES -> raw reply on stdout; see exit-status note above
  local resp=$1 ip out
  ip=$(kubectl -n "$REDIS_NS" get svc "$REDIS_SVC" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  [ -n "$ip" ] || return 1
  # QUIT makes Redis close the socket, so cat sees EOF as soon as the reply
  # is in; `exec cat` makes cat the process timeout kills if it never is.
  # Without both, the 2026-09-27 tick hung for an hour on a cat that the
  # 5 s timeout never reached (it killed only the inner bash), and no demand
  # check ran, so a queued job waited for a docling-1 that never started.
  out=$(timeout 5 bash -c "exec 3<>/dev/tcp/$ip/6379
    printf 'SELECT $REDIS_DB\r\n%sQUIT\r\n' \"\$1\" >&3
    exec cat <&3" _ "$resp" 2>/dev/null | tr -d '\r')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

redis_get() {  # redis_get KEY -> value on stdout, or empty (incl. on any error)
  local key=$1 raw
  raw=$(redis_cmd "$(printf '*2\r\n$3\r\nGET\r\n$%d\r\n%s\r\n' "${#key}" "$key")") || return 0
  awk 'NR==2{if ($0=="$-1") exit} NR==3{print; exit}' <<<"$raw"
}

redis_set_ex() {  # redis_set_ex KEY VALUE TTL_S
  local key=$1 val=$2 ttl=$3
  redis_cmd "$(printf '*5\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n$2\r\nEX\r\n$%d\r\n%s\r\n' \
    "${#key}" "$key" "${#val}" "$val" "${#ttl}" "$ttl")" >/dev/null || return 0
  # Best-effort, like redis_get: under `set -e` a failed publish would abort
  # cmd_tick before cmd_reap, silently disabling the MAX_HOURS cap and orphan
  # cleanup for as long as Redis is down. The key's 120 s TTL lets readers
  # see the gap as a stale/missing key instead.
}

# HGET pageindex:job:<id> status -- the app's own job-status hash
# (job_status.py:_job_key / JobStatus), written by upload_app.py/worker.py.
# It lives in the SAME Redis DB as arq (configmap.yaml REDIS_URL is
# redis://.../1, matching this script's REDIS_DB), so no extra SELECT is
# needed. The X-Job-Id header the worker sends docling-service (client/
# remote.py _CORRELATION_HEADERS) is this same app-level UUID -- NOT arq's own
# internal job id used for arq:in-progress:<id> -- so this is the correct key
# to check for docling-service's current_job_id, not an arq:in-progress scan.
#
# Returns 1 (nothing printed) when Redis could NOT be reached at all -- a
# transport failure, distinct from a real answer. Prints "absent" only for an
# actual $-1 (nil) reply -- HGET replies nil the same way whether the hash key
# is entirely missing or just has no `status` field, and either case means
# "nothing to call processing" -- or the status string when HGET found one.
# Collapsing "couldn't ask" and "hash absent" into the same empty
# string was the reap-orphan bug this function fixes: a Redis blip must fall
# through to the existing CPU-busy KEEP, not read as "not processing" and
# delete a node mid-conversion.
job_status_get() {  # job_status_get JOB_ID -> status string, "absent", or (rc=1) unknown
  local id=$1 key raw
  [ -n "$id" ] || return 1
  key="pageindex:job:$id"
  raw=$(redis_cmd "$(printf '*3\r\n$4\r\nHGET\r\n$%d\r\n%s\r\n$6\r\nstatus\r\n' "${#key}" "$key")") || return 1
  awk 'NR==2{if ($0=="$-1"){print "absent"; exit}} NR==3{print; exit}' <<<"$raw"
}

# in_flight/current_job_id/started_at from docling-1's own pod directly (not
# through docling-active, which may be routed at the Mac): Q5 item 10, built
# concurrently. Fields are read with `// empty`/`// 0` so a docling-service
# that has not shipped them yet degrades safely (docling_health prints
# "0||", ORPHAN_CHECK below then finds current_job_id empty and no-ops).
#
# Pipe-separated, NOT space- or tab-separated: a conversion with no X-Job-Id
# (current_job_id null) produces an EMPTY middle field. Space-joined that
# collapsed under `read`'s IFS word-splitting -- "1  1790000000.5" (in_flight
# 1, empty job id, a started_at timestamp) would `read -r hi hj hs` as
# hi=1 hj=1790000000.5 hs="", silently shifting the timestamp into the job-id
# slot instead of leaving it empty. job_status_get then looked up
# "pageindex:job:1790000000.5", found nothing, answered "absent", and the
# reap orphan check deleted a genuinely busy node. Switching to `@tsv` alone
# does NOT fix this: bash's `read` treats space, tab AND newline as "IFS
# whitespace" and collapses RUNS of any of them regardless of which one(s)
# IFS is set to, so two consecutive tabs collapse exactly like two
# consecutive spaces do (verified: `IFS=$'\t' read -r a b c <<<$'1\t\t2'`
# still yields b empty and c holding nothing / a wrong shift, not b=""
# c="2"). A PIPE is not IFS whitespace, so `IFS='|' read` does not collapse
# repeats and reliably preserves empty fields positionally. None of these
# values (a bare int, a uuid, an ISO/epoch timestamp) can contain a literal
# "|", so there is nothing for the join to need to escape.
docling_health() {  # docling_health -> "in_flight|current_job_id|started_at", or empty
  local ip; ip=$(node_pod_ip)
  [ -n "$ip" ] || return 0
  curl -fsS -m 5 "http://$ip:8080/health" 2>/dev/null \
    | jq -r '[(.in_flight // 0), (.current_job_id // ""), (.started_at // "")] | join("|")' 2>/dev/null || true
}

# Publish controller state for the worker's readiness gate (Q5 item 2/12).
# `since` is held stable while `phase` is unchanged, so the worker can measure
# an autostart's age even across ticks that just re-publish the same phase.
publish_backend() {  # publish_backend TARGET PHASE REASON [ETA_S]
  local target=$1 phase=$2 reason=$3 eta=${4:-0} since prev prev_phase prev_since
  since=$(date -u +%s)
  prev=$(redis_get "$BACKEND_KEY")
  if [ -n "$prev" ]; then
    prev_phase=$(jq -r '.phase // empty' <<<"$prev" 2>/dev/null || true)
    prev_since=$(jq -r '.since // empty' <<<"$prev" 2>/dev/null || true)
    [ "$prev_phase" = "$phase" ] && [ -n "$prev_since" ] && since=$prev_since
  fi
  local json
  json=$(jq -nc --arg t "$target" --arg p "$phase" --arg r "$reason" \
    --argjson since "$since" --argjson eta "$eta" --argjson n "$(autostarts_today)" \
    '{target:$t, phase:$p, reason:$r, since:$since, eta_s:$eta, autostarts_today:$n}')
  [ "$DRY_RUN" = 1 ] && { printf '  + publish_backend %s\n' "$json" >&2; return 0; }
  redis_set_ex "$BACKEND_KEY" "$json" "$BACKEND_TTL_S"
}

# Controller state that must survive a pod restart, in ConfigMap
# docling-node-state: autostarts-<date> (the daily cap), bake-want (the
# pageindex sha deploy.yml asks to bake) and bake-tries-<sha>.
state_get() {  # state_get KEY -> value or empty
  kubectl -n "$NS" get configmap "$STATE_CM" -o json 2>/dev/null \
    | jq -r --arg k "$1" '.data[$k] // empty' || true
}
state_set() {  # state_set KEY VALUE; drops autostarts-* keys of other days
  # The patch is a JSON merge patch (--type merge): keys it leaves out are
  # kept as they are, so bake-want and bake-tries-* survive. It carries only
  # KEY and a null for each autostarts-* key of another day (null deletes).
  # --dry-run must leave the counters the real tick decides on untouched.
  [ "$DRY_RUN" = 1 ] && { printf '  + state_set %s %s\n' "$1" "$2" >&2; return 0; }
  kubectl -n "$NS" create configmap "$STATE_CM" >/dev/null 2>&1 || true
  local cur; cur=$(kubectl -n "$NS" get configmap "$STATE_CM" -o json | jq -c '.data // {}')
  kubectl -n "$NS" patch configmap "$STATE_CM" --type merge -p "$(jq -nc \
    --argjson cur "$cur" --arg k "$1" --arg v "$2" --arg today "autostarts-$(date -u +%F)" \
    '{data: (($cur | with_entries(select(.key | startswith("autostarts-")) | select(.key != $today)
      | .value = null)) + {($k): $v})}')" >/dev/null
}
autostarts_today() { local n; n=$(state_get "autostarts-$(date -u +%F)"); echo "${n:-0}"; }
record_autostart() { state_set "autostarts-$(date -u +%F)" $(( $(autostarts_today) + 1 )); }

# Re-bake when deploy.yml has recorded a newer docling-service build than the
# snapshot's. Only while nothing else needs the node: the Mac answers, no
# docling-1 exists. The bake holds the tick's lock (~20-30 min), so failover
# is paused meanwhile; a Mac that fails first delays the bake instead.
maybe_bake() {
  local want have tries
  want=$(state_get bake-want)
  [ -n "$want" ] || return 0
  have=$(hcloud image list --type snapshot --selector "$SNAP_SELECTOR" -o json \
    | jq -r 'sort_by(.created) | last | .labels["pageindex-sha"] // empty')
  [ "${want:0:7}" != "$have" ] || return 0
  exists_server "$NODE" && return 0
  tries=$(state_get "bake-tries-${want:0:7}"); tries=${tries:-0}
  if [ "$tries" -ge "$BAKE_MAX_ATTEMPTS" ]; then
    log "tick: bake of ${want:0:7} failed $tries times -- not retrying (snapshot stays ${have:-none})"
    return 0
  fi
  state_set "bake-tries-${want:0:7}" $(( tries + 1 ))
  log "tick: snapshot is ${have:-none}, docling-service ${want:0:7} was built -- baking (attempt $(( tries + 1 ))/$BAKE_MAX_ATTEMPTS)"
  cmd_bake "$want"
}

cmd_tick() {
  # --dry-run reads the probe counter to show the decision but never writes
  # it: the real timer's failover depends on it.
  local fails=0
  if mac_ok; then
    [ "$DRY_RUN" = 1 ] || { mkdir -p "$STATE_DIR"; echo 0 >"$STATE_DIR/mac-fails"; }
  else
    fails=$(( $(cat "$STATE_DIR/mac-fails" 2>/dev/null || echo 0) + 1 ))
    [ "$DRY_RUN" = 1 ] || { mkdir -p "$STATE_DIR"; echo "$fails" >"$STATE_DIR/mac-fails"; }
  fi

  # Q5 item 13: no blackhole routing. Every branch below either routes to a
  # backend that just proved itself (mac_ok this tick, or a Ready node pod) or
  # routes to "none" (empty endpoints -> immediate ECONNREFUSED). Previously
  # the no-pod/no-autostart branches left routing untouched, which could keep
  # pointing at a Mac that had already failed MAC_FAILS probes.
  if [ "$fails" -eq 0 ]; then
    route_active mac
    publish_backend mac ready ""
  elif [ -n "$(node_pod_ip)" ]; then
    route_active node
    publish_backend node ready ""
  elif [ "$fails" -ge "$MAC_FAILS" ] && [ "$AUTOSTART" = 1 ] && ! exists_server "$NODE"; then
    local d q r c f
    read -r d q r c f <<<"$(demand)"
    # Breakdown on every Mac-down tick so a start (or a cron-only non-start)
    # is explainable from Loki alone.
    local why="queued $q, running $r; ignored $c cron, $f deferred"
    if [ "$d" -gt 0 ]; then
      local n; n=$(autostarts_today)
      if [ "$n" -ge "$AUTOSTART_MAX_PER_DAY" ]; then
        log "tick: Mac down ($fails probes), $d job(s) waiting ($why), but $n autostarts today (max $AUTOSTART_MAX_PER_DAY) -- not starting"
        route_active none
        publish_backend none down "autostart cap ${n}/${AUTOSTART_MAX_PER_DAY} reached"
      else
        log "tick: Mac down ($fails probes) and $d job(s) waiting ($why) -- starting $NODE ($n/$AUTOSTART_MAX_PER_DAY autostarts today; counted when a server is created)"
        # Published BEFORE cmd_up, which blocks ~100s: this is the only
        # chance for the worker's readiness gate to see "starting" while the
        # lock held by this tick keeps every other tick from running.
        publish_backend node starting "" 150
        ON_SERVER_CREATED=record_autostart
        cmd_up
        ON_SERVER_CREATED=
        route_active node
        publish_backend node ready ""
      fi
    else
      [ $(( c + f )) -gt 0 ] && log "tick: Mac down ($fails probes), no demand ($why) -- not starting"
      route_active none
      publish_backend none down "mac down, no demand"
    fi
  elif exists_server "$NODE"; then
    # docling-1 exists (an earlier tick's autostart still booting, or a manual
    # `up`) but has no Ready pod yet. Route away from the dead Mac rather than
    # leaving the previous route in place.
    route_active none
    publish_backend node starting "" 150
  elif [ "$fails" -lt "$MAC_FAILS" ]; then
    # Mac down but short of MAC_FAILS (the Q4 "may be asleep" short-wait
    # window): no node, nothing proven yet. Reported as target=mac/phase=down
    # so the worker's short DOCLING_MAC_WAIT_S policy applies instead of
    # failing fast as target=none would. This window applies REGARDLESS of
    # AUTOSTART: a disabled autostart still gets to ride out a probe blip
    # before the worker gives up -- only once MAC_FAILS is actually reached
    # does "autostart disabled" mean the Mac is not coming back via this path.
    route_active none
    publish_backend mac down "mac probe failed ($fails/$MAC_FAILS)"
  elif [ "$AUTOSTART" != 1 ]; then
    route_active none
    publish_backend none down "autostart disabled"
  else
    # fails >= MAC_FAILS, AUTOSTART=1, no node -- demand-gated branches above
    # already handle every real case (start it, cap hit, or no demand); this
    # is unreachable but kept as a safe fallback rather than an assert.
    route_active none
    publish_backend none down "no backend available"
  fi
  cmd_reap
  [ "$fails" -ne 0 ] || maybe_bake
  # One line per tick, even when nothing changed: the steady state (Mac up,
  # no docling-1, no bake) otherwise logs nothing, and a silent controller is
  # indistinguishable from a dead one in Loki (RFC-052 R1 AC5).
  if [ "$fails" -eq 0 ]; then log "tick: done (mac up)"
  else log "tick: done (mac down, $fails consecutive failed probe(s))"; fi
}

cmd_reaper() {
  local unit=/etc/systemd/system/$REAPER_UNIT
  case "${1:-}" in
    on)
      [ "$DRY_RUN" = 1 ] || {
        cat >"$unit.service" <<EOF
[Unit]
Description=docling node failover + spot-style reaper ($NODE)

[Service]
Type=oneshot
Environment=HOME=/root
Environment=KUBECONFIG=/etc/rancher/k3s/k3s.yaml
TimeoutStartSec=20min
ExecStart=$HERE/docling-node.sh tick
EOF
        cat >"$unit.timer" <<EOF
[Unit]
Description=Run the docling node tick (failover + reaper) every 30 seconds

[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF
      }
      run systemctl daemon-reload
      run systemctl enable --now "$REAPER_UNIT.timer"
      ;;
    off) run systemctl disable --now "$REAPER_UNIT.timer" ;;
    *) die "usage: $0 reaper on|off" ;;
  esac
}

# Everything below this point is runtime dispatch (locking, mutation) and only
# runs when this file is EXECUTED, not when it is `source`d -- tests source it
# to reach the functions above with PATH-shimmed kubectl/hcloud/redis, without
# tripping the lock, the host-timer handoff, or a real subcommand dispatch.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

# A host timer from before the in-cluster controller retires itself once the
# controller is running, so exactly one tick loop drives docling-1.
case "${1:-}" in
  tick|reap)
    if [ "$IN_CLUSTER" = 0 ] && [ "$(kubectl -n "$NS" get deployment "$CONTROLLER" \
         -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ]; then
      log "$CONTROLLER runs $1 in the cluster; disabling the host timer $REAPER_UNIT.timer"
      [ "$DRY_RUN" = 1 ] || systemctl disable --now "$REAPER_UNIT.timer" 2>/dev/null || true
      exit 0
    fi ;;
esac

# One mutating command at a time: the timer's tick skips its turn while a
# manual up/down (or a long autostart) holds the lock.
case "${1:-}" in
  up|down|reap|tick)
    mkdir -p "$(dirname "$LOCK")"
    exec 9>"$LOCK"
    # Polled, not `flock -w`: the controller image's busybox flock has no -w.
    if [ "$1" = tick ]; then flock -n 9 || { log "tick: lock busy ($LOCK) -- skipping this tick"; exit 0; }
    else
      t=0
      until flock -n 9; do
        t=$((t+2)); [ "$t" -ge 900 ] && die "lock busy: $LOCK"
        sleep 2
      done
    fi ;;
esac

case "${1:-}" in
  setup) cmd_setup ;;
  bake) shift; cmd_bake "$@" ;;
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  reap) cmd_reap ;;
  tick) cmd_tick ;;
  reaper) shift; cmd_reaper "$@" ;;
  *) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

fi # BASH_SOURCE guard
