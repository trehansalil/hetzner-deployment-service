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
#
# Flags: --dry-run prints every mutating command instead of running it.
#        --yes answers the confirmation prompts (non-interactive runs).
#
# Costs (hel1, 2026-09-25): cx23 EUR 0.0088/h + primary IPv4 EUR 0.0008/h
# while docling-1 exists (powered off still bills; only `down` stops it).
# The snapshot bills EUR 0.0143/GB/month while kept. Private networks and
# firewalls are free.
#
# Run on portfolio as root: it needs hcloud (context with a project token),
# kubectl, and /var/lib/rancher/k3s/server/node-token.
set -euo pipefail

NODE=docling-1
NODE_TYPE=cx23
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
    t=$((t+10)); [ "$t" -ge "$limit" ] && die "timed out after ${limit}s waiting for $what"
    sleep 10
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

cmd_up() {
  exists_server "$NODE" && { log "$NODE already exists"; cmd_status; return; }
  local snap; snap=$(newest_snapshot)
  [ -n "$snap" ] || die "no snapshot labelled $SNAP_SELECTOR; run '$0 bake <sha>' first"

  log "Create $NODE from snapshot $snap — billing starts"
  run hcloud server create --name "$NODE" --type "$NODE_TYPE" --image "$snap" \
    --location "$LOCATION" --ssh-key "$SSH_KEY_NAME" --firewall "$FW_NODE" \
    --label role=k3s-agent --label workload=docling --start-after-create=false
  # Attach before the first boot: the snapshot's k3s config pins node-ip.
  run hcloud server attach-to-network "$NODE" --network "$NET" --ip "$NODE_PRIV_IP"
  run hcloud server poweron "$NODE"
  wait_for 300 "$NODE Ready" node_ready
  run kubectl uncordon "$NODE"
  run kubectl -n "$NS" rollout status deployment/docling-service --timeout=600s
  [ "$DRY_RUN" = 1 ] || curl -fsS "https://$RECORD.$ZONE/health" && echo
  log "up. Remember '$0 down' when done: $NODE bills hourly while it exists."
}

cmd_down() {
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
    hcloud server describe "$NODE" -o json | jq -r \
      '"server: \(.name) \(.server_type.name) \(.status) created \(.created)  (EUR 0.0096/h while it exists)"'
  else
    echo "server: $NODE absent (not billing)"
  fi
  kubectl get node "$NODE" --no-headers 2>/dev/null | sed 's/^/node:   /' || true
  kubectl -n "$NS" get pods -l app=docling-service -o wide --no-headers 2>/dev/null | sed 's/^/pod:    /' || true
  hcloud image list --type snapshot --selector "$SNAP_SELECTOR" -o json | jq -r \
    '.[] | "snapshot: \(.id) \(.description) \(.image_size // 0 | . * 100 | round / 100) GB  (~EUR \(.image_size // 0 | . * 0.0143 * 100 | round / 100)/month)"'
  hcloud server describe "$PORTFOLIO" -o json | jq -r '"portfolio: \(.server_type.name) (\(.server_type.memory) GB)"'
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

case "${1:-}" in
  setup) cmd_setup ;;
  bake) shift; cmd_bake "$@" ;;
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  local) shift; cmd_local "$@" ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
