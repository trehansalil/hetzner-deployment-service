#!/usr/bin/env bash
# On-demand Docling node for the portfolio k3s cluster (RFC-050).
#
#   setup            one-time: private network, firewalls, DNS record, SSH key,
#                    and the portfolio k3s private-net drop-in (restarts k3s)
#   bake [SHA]       one-time per image: create docling-1, build the
#                    docling-service image on it, snapshot it, delete it
#   up               create docling-1 from the newest snapshot and join it
#   down             drain and delete docling-1 (billing stops; snapshot kept)
#   status           what exists right now and what it costs
#   local on|off     the portfolio copy of docling-service (needs cx43 RAM)
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
SSH_KEY=/root/.ssh/docling_node
SNAP_SELECTOR=docling-node=snapshot
ZONE=saliltrehan.com
RECORD=docling
NS=pageindex-mcp
HERE=$(cd "$(dirname "$0")" && pwd)
K3S_DROPIN=/etc/rancher/k3s/config.yaml.d/20-private-net.yaml
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

log() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
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
    -o ConnectTimeout=5 "root@$NODE_PRIV_IP" "$@"
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

  local tmp=$TMP
  ( umask 077
    sed -e "s|__K3S_NODE_TOKEN__|$(cat /var/lib/rancher/k3s/server/node-token)|" \
        -e "s|__PAGEINDEX_SHA__|$sha|" \
        "$HERE/cloud-init-docling-agent.yaml" > "$tmp/user-data.yaml" )

  log "Create $NODE ($NODE_TYPE, ubuntu-24.04) — billing starts"
  run hcloud server create --name "$NODE" --type "$NODE_TYPE" --image ubuntu-24.04 \
    --location "$LOCATION" --ssh-key "$SSH_KEY_NAME" --firewall "$FW_NODE" \
    --label role=k3s-agent --label workload=docling \
    --user-data-from-file "$tmp/user-data.yaml" --start-after-create=false
  run hcloud server attach-to-network "$NODE" --network "$NET" --ip "$NODE_PRIV_IP"
  run hcloud server poweron "$NODE"

  # The build downloads the Docling models from the HF Hub; a token avoids
  # anonymous rate limits. It goes over SSH into /run (tmpfs), not into
  # user-data, so it is never in the metadata service, /var/lib/cloud, or
  # the snapshot. The bake waits up to 10 min for it, then builds anonymously.
  local hf
  hf=$(kubectl -n "$NS" get secret pageindex-mcp-secrets \
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
  log "Point both docling Deployments at $tag"
  for d in docling-service docling-service-local; do
    run kubectl -n "$NS" set image "deployment/$d" "docling-service=$tag"
  done

  log "Snapshot $NODE, then delete it"
  run hcloud server shutdown "$NODE"
  wait_for 180 "$NODE off" sh -c "hcloud server describe $NODE -o json | jq -e '.status==\"off\"'"
  local old; old=$(newest_snapshot)
  run hcloud server create-image "$NODE" --type snapshot \
    --description "docling-node $tag" --label "$SNAP_SELECTOR" --label "pageindex-sha=${sha:0:7}"
  [ -n "$old" ] && run hcloud image delete "$old"
  cmd_down
  log "bake done: '$0 up' boots from the new snapshot"
}

# Give the docling pod the whole node, whatever type `up` got: the service
# derives its threads, parallel chunk processes and chunk size from its own
# cgroup limits, so these limits are the only sizing input. Only the eviction
# margin is held back, so a runaway conversion is OOM-killed in its cgroup
# before the kubelet evicts the pod for node memory pressure.
size_pod_to_node() {
  local cpu mem cpu_m mem_mi
  cpu=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.cpu}')
  mem=$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.memory}')
  case "$cpu" in *m) cpu_m=${cpu%m} ;; *) cpu_m=$((cpu * 1000)) ;; esac
  case "$mem" in
    *Ki) mem_mi=$((${mem%Ki} / 1024)) ;;
    *Mi) mem_mi=${mem%Mi} ;;
    *Gi) mem_mi=$((${mem%Gi} * 1024)) ;;
    *) mem_mi=$((mem / 1048576)) ;;
  esac
  mem_mi=$((mem_mi - 256))
  log "Size docling-service to $NODE: cpu ${cpu_m}m, memory ${mem_mi}Mi (allocatable $cpu / $mem)"
  run kubectl -n "$NS" set resources deployment/docling-service -c docling-service \
    --requests="cpu=${cpu_m}m,memory=${mem_mi}Mi" --limits="cpu=${cpu_m}m,memory=${mem_mi}Mi"
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
predict_pod_size() {  # predict_pod_size TYPE -> "cpu_m mem_mi"
  hcloud server-type describe "$1" -o json \
    | jq -r '"\(.cores * 1000) \((.memory * 1024 * 0.9 - 512) | floor)"'
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
    local size cpu_m mem_mi; size=$(predict_pod_size "$type"); read -r cpu_m mem_mi <<<"$size"
    run kubectl -n "$NS" patch deployment/docling-service --type=strategic </dev/null -p "$(jq -nc \
      --arg img "$img" --arg cpu "${cpu_m}m" --arg mem "${mem_mi}Mi" \
      '{spec: {replicas: 1, template: {spec: {containers: [{name: "docling-service", image: $img,
        resources: {requests: {cpu: $cpu, memory: $mem}, limits: {cpu: $cpu, memory: $mem}}}]}}}}')"
    log "Create $NODE: $type in $loc (EUR $price/h) from snapshot $snap -- billing starts"
    # A type can sell out between the stock check and the create: move on.
    if run hcloud server create --name "$NODE" --type "$type" --image "$snap" \
        --location "$loc" --ssh-key "$SSH_KEY_NAME" --firewall "$FW_NODE" \
        --label role=k3s-agent --label workload=docling --start-after-create=false </dev/null; then
      created=$type; break
    fi
    log "create of $type in $loc failed; trying the next candidate"
    exists_server "$NODE" && run hcloud server delete "$NODE"
  done <<<"$cands"
  if [ -z "$created" ]; then
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
  # Send new conversions back to the Mac before the node goes away.
  route_active mac
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

# Summed CPU of the docling-service pods in millicores (0 when none or no
# metrics yet). kubectl top prints "1234m" or whole cores ("2").
docling_mcpu() {
  { kubectl top pod -n "$NS" -l app=docling-service --no-headers 2>/dev/null || true; } \
    | awk '{c=$2; if (c ~ /m$/) {sub(/m$/, "", c)} else {c=c*1000}; s+=c} END {print s+0}'
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
  if [ "$cpu" -ge "$BUSY_MCPU" ]; then
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

# Point docling-active (what the worker calls) at the Mac or docling-1's pod.
route_active() {  # route_active mac|node
  local addr port want cur
  if [ "$1" = node ]; then
    addr=$(node_pod_ip); port=8080
    [ -n "$addr" ] || { log "route: no Ready pod on $NODE; leaving routing as is"; return 0; }
  else
    read -r addr port <<<"$(mac_endpoint)"
  fi
  want="$addr:$port"
  cur=$(kubectl -n "$NS" get endpointslice "$ACTIVE_SLICE" -o json 2>/dev/null \
    | jq -r '"\(.endpoints[0].addresses[0]):\(.ports[0].port)"' || true)
  [ "$cur" = "$want" ] && return 0
  log "route: $ACTIVE_SVC -> $1 ($want, was ${cur:-unset})"
  [ "$DRY_RUN" = 1 ] && return 0
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
}

# Conversion demand: queued arq jobs + running ones (arq's own cron excluded).
# Raw RESP over /dev/tcp: no redis-cli on the host.
demand() {
  local ip out
  ip=$(kubectl -n "$REDIS_NS" get svc "$REDIS_SVC" -o jsonpath='{.spec.clusterIP}')
  out=$(timeout 5 bash -c "exec 3<>/dev/tcp/$ip/6379
    printf 'SELECT $REDIS_DB\r\nZCARD arq:queue\r\nKEYS arq:in-progress:*\r\nQUIT\r\n' >&3
    cat <&3" 2>/dev/null | tr -d '\r') || true
  local queued running
  queued=$(awk '/^:/ {sub(/^:/, ""); print; exit}' <<<"$out")
  running=$(grep '^arq:in-progress:' <<<"$out" | grep -vc ':cron:' || true)
  echo $(( ${queued:-0} + ${running:-0} ))
}

autostarts_today() {
  local n
  n=$(kubectl -n "$NS" get configmap "$STATE_CM" -o json 2>/dev/null \
    | jq -r --arg k "autostarts-$(date -u +%F)" '.data[$k] // "0"' || true)
  echo "${n:-0}"
}
# Rewrites the whole ConfigMap: yesterday's count drops out.
record_autostarts() {
  kubectl -n "$NS" create configmap "$STATE_CM" --from-literal="autostarts-$(date -u +%F)=$1" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

cmd_tick() {
  mkdir -p "$STATE_DIR"
  local fails=0
  if mac_ok; then
    echo 0 >"$STATE_DIR/mac-fails"
  else
    fails=$(( $(cat "$STATE_DIR/mac-fails" 2>/dev/null || echo 0) + 1 ))
    echo "$fails" >"$STATE_DIR/mac-fails"
  fi

  if [ "$fails" -eq 0 ]; then
    route_active mac
  elif [ -n "$(node_pod_ip)" ]; then
    route_active node
  elif [ "$fails" -ge "$MAC_FAILS" ] && [ "$AUTOSTART" = 1 ] && ! exists_server "$NODE"; then
    local d; d=$(demand)
    if [ "$d" -gt 0 ]; then
      local n; n=$(autostarts_today)
      if [ "$n" -ge "$AUTOSTART_MAX_PER_DAY" ]; then
        log "tick: Mac down ($fails probes), $d job(s) waiting, but $n autostarts today (max $AUTOSTART_MAX_PER_DAY) -- not starting"
      else
        record_autostarts $(( n + 1 ))
        log "tick: Mac down ($fails probes) and $d job(s) waiting -- starting $NODE (autostart $(( n + 1 ))/$AUTOSTART_MAX_PER_DAY today)"
        cmd_up
        route_active node
      fi
    fi
  fi
  cmd_reap
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

cmd_local() {
  case "${1:-}" in
    off) run kubectl -n "$NS" scale deployment/docling-service-local --replicas=0 ;;
    on)
      local mem; mem=$(hcloud server describe "$PORTFOLIO" -o json | jq -r '.server_type.memory')
      awk -v m="$mem" 'BEGIN{exit !(m >= 16)}' \
        || die "portfolio has ${mem} GB; the local copy needs >=16 GB (cx43). Not scaling."
      local img; img=$(kubectl -n "$NS" get deployment/docling-service-local \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
      # A registry ref (ghcr.io/...) is pulled by the kubelet; only a bare
      # locally built tag has to be copied from the node's containerd.
      if [[ "$img" != */* ]] && ! k3s ctr -n k8s.io images ls -q | grep -qx "docker.io/library/$img"; then
        node_ready || die "image $img is not on portfolio; run '$0 up' so it can be copied from $NODE"
        log "Copy $img from $NODE to portfolio over the private network"
        [ "$DRY_RUN" = 1 ] || ssh_node "k3s ctr -n k8s.io images export - docker.io/library/$img" \
          | k3s ctr -n k8s.io images import -
      fi
      run kubectl -n "$NS" scale deployment/docling-service-local --replicas=1
      ;;
    *) die "usage: $0 local on|off" ;;
  esac
}

# A host timer from before the in-cluster controller retires itself once the
# controller is running, so exactly one tick loop drives docling-1.
case "${1:-}" in
  tick|reap)
    if [ "$IN_CLUSTER" = 0 ] && [ "$(kubectl -n "$NS" get deployment "$CONTROLLER" \
         -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ]; then
      log "$CONTROLLER runs $1 in the cluster; disabling the host timer $REAPER_UNIT.timer"
      systemctl disable --now "$REAPER_UNIT.timer" 2>/dev/null || true
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
    if [ "$1" = tick ]; then flock -n 9 || exit 0
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
  local) shift; cmd_local "$@" ;;
  reap) cmd_reap ;;
  tick) cmd_tick ;;
  reaper) shift; cmd_reaper "$@" ;;
  *) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
