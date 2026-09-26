#!/usr/bin/env bash
# loki-tailscale host guard (RFC-052 D2, task 1.9). OPERATOR STEP: run as
# root on portfolio.
#
# Makes the Loki NodePort (Service infra/loki-tailscale, default 31100)
# reachable ONLY through tailscale0: that is the Mac's Alloy push to
# 100.120.146.20. Every other interface is dropped: eth0 (public), enp7s0
# (Hetzner private network), cni0 and flannel.1 (pods). Loki has no auth, so
# this rule, not the Service, is the access control.
#
# Why raw/PREROUTING and not filter/INPUT: kube-proxy DNATs NodePort traffic
# in nat/PREROUTING straight to the pod IP, so that traffic never reaches
# filter/INPUT. raw/PREROUTING runs before any NAT, iptables and nftables alike.
#
# Usage:
#   apply-firewall.sh                      apply (idempotent), then --check
#   apply-firewall.sh --dry-run            print what apply would do; change nothing
#   apply-firewall.sh --check              exit 0 only if the guard is fully in place
#   apply-firewall.sh --remove [--dry-run] remove the guard. This re-opens the port
#                                          on every interface, so delete the Service first.
#   apply-firewall.sh --persist [--dry-run]    boot-time systemd unit that applies
#                                              the guard before k3s starts
#   apply-firewall.sh --unpersist [--dry-run]  disable and remove that unit
#
# Env: LOKI_NODEPORT (default 31100; must match loki-tailscale-service.yaml)
#      TS_IFACE      (default tailscale0)
set -euo pipefail

PORT=${LOKI_NODEPORT:-31100}
IFACE=${TS_IFACE:-tailscale0}
CHAIN=LOKI-TAILSCALE
TABLE=raw
COMMENT="rfc052 loki nodeport ${PORT}: ${IFACE} only"
UNIT=loki-tailscale-firewall.service
UNIT_PATH=/etc/systemd/system/$UNIT
SELF=$(readlink -f "$0")

MODE=apply
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --check|--remove|--persist|--unpersist) MODE=${a#--} ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a (see --help)" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (reading the raw table needs it too)"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 30000 ] && [ "$PORT" -le 32767 ] \
  || die "LOKI_NODEPORT=$PORT is not in the NodePort range 30000-32767"
command -v iptables >/dev/null || die "iptables not found"

# kube-proxy also serves a NodePort on IPv6 when the node has a v6 address,
# so guard both families where ip6tables exists.
TOOLS=(iptables)
command -v ip6tables >/dev/null 2>&1 && TOOLS+=(ip6tables)

JUMP=(-p tcp --dport "$PORT" -m comment --comment "$COMMENT" -j "$CHAIN")

run() {  # print the command; run it unless --dry-run
  echo "  + $*"
  [ "$DRY" = 1 ] || "$@"
}

chain_exists() { "$1" -t "$TABLE" -S "$CHAIN" >/dev/null 2>&1; }
chain_ok() {  # CHAIN holds exactly: ACCEPT on IFACE, then DROP
  local want got
  want=$(printf -- '-N %s\n-A %s -i %s -j ACCEPT\n-A %s -j DROP' \
    "$CHAIN" "$CHAIN" "$IFACE" "$CHAIN")
  got=$("$1" -t "$TABLE" -S "$CHAIN" 2>/dev/null) || return 1
  [ "$got" = "$want" ]
}
jump_ok() { "$1" -t "$TABLE" -C PREROUTING "${JUMP[@]}" 2>/dev/null; }

apply_tool() {
  local t=$1
  if chain_exists "$t"; then
    if ! chain_ok "$t"; then
      echo "$t: $TABLE/$CHAIN exists with unexpected rules:" >&2
      "$t" -t "$TABLE" -S "$CHAIN" >&2
      echo "$t: not rewriting it in place (that would open a window); run --remove, then apply" >&2
      return 1
    fi
    echo "$t: $TABLE/$CHAIN already correct"
  else
    # Chain rules first, jump last: the port is never behind an empty chain.
    run "$t" -t "$TABLE" -N "$CHAIN"
    run "$t" -t "$TABLE" -A "$CHAIN" -i "$IFACE" -j ACCEPT
    run "$t" -t "$TABLE" -A "$CHAIN" -j DROP
  fi
  if jump_ok "$t"; then
    echo "$t: $TABLE/PREROUTING jump for tcp/$PORT already present"
  else
    run "$t" -t "$TABLE" -I PREROUTING 1 "${JUMP[@]}"
  fi
}

check_tool() {
  local t=$1 rc=0 pos
  if chain_ok "$t"; then echo "ok   $t: $TABLE/$CHAIN = ACCEPT -i $IFACE, then DROP"
  else echo "FAIL $t: $TABLE/$CHAIN missing, or not exactly ACCEPT -i $IFACE + DROP"; rc=1; fi
  if jump_ok "$t"; then
    echo "ok   $t: $TABLE/PREROUTING sends tcp/$PORT to $CHAIN"
    # An earlier raw ACCEPT would end the raw table before our jump.
    pos=$("$t" -t "$TABLE" -S PREROUTING | grep -n -- "-j $CHAIN" | head -1 | cut -d: -f1)
    if "$t" -t "$TABLE" -S PREROUTING | head -n $(( pos - 1 )) | grep -q -- '-j ACCEPT'; then
      echo "FAIL $t: a $TABLE/PREROUTING ACCEPT precedes the $CHAIN jump"; rc=1
    fi
  else
    echo "FAIL $t: no $TABLE/PREROUTING jump for tcp/$PORT"; rc=1
  fi
  return $rc
}

check_all() {
  local rc=0 np addr
  for t in "${TOOLS[@]}"; do check_tool "$t" || rc=1; done
  addr=$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}')
  if [ -n "$addr" ]; then echo "info $IFACE is up ($addr)"
  else echo "info $IFACE is absent or down: the port stays closed everywhere, and the Mac cannot push"; fi
  if command -v kubectl >/dev/null 2>&1; then
    np=$(kubectl -n infra get svc loki-tailscale -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
    if [ -z "$np" ]; then echo "info Service infra/loki-tailscale is not applied"
    elif [ "$np" != "$PORT" ]; then echo "FAIL Service nodePort $np is not the guarded port $PORT"; rc=1
    else echo "ok   Service infra/loki-tailscale nodePort $np"; fi
  fi
  return $rc
}

remove_tool() {
  local t=$1
  if jump_ok "$t"; then
    run "$t" -t "$TABLE" -D PREROUTING "${JUMP[@]}"
    # Duplicates, if any were ever added by hand.
    [ "$DRY" = 1 ] || while jump_ok "$t"; do "$t" -t "$TABLE" -D PREROUTING "${JUMP[@]}"; done
  fi
  if chain_exists "$t"; then
    run "$t" -t "$TABLE" -F "$CHAIN"
    run "$t" -t "$TABLE" -X "$CHAIN"
  fi
  echo "$t: guard removed"
}

persist() {
  # No ExecStop: stopping the unit must never re-open the port.
  local unit
  unit="[Unit]
Description=RFC-052 Loki NodePort guard (tcp/$PORT on $IFACE only)
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target k3s.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=LOKI_NODEPORT=$PORT TS_IFACE=$IFACE
ExecStart=$SELF

[Install]
WantedBy=multi-user.target"
  echo "  + write $UNIT_PATH (runs $SELF at boot)"
  if [ "$DRY" = 1 ]; then printf '%s\n' "$unit" | sed 's/^/      /'
  else printf '%s\n' "$unit" >"$UNIT_PATH"; fi
  run systemctl daemon-reload
  run systemctl enable "$UNIT"
}

unpersist() {
  if [ -e "$UNIT_PATH" ]; then
    run systemctl disable "$UNIT"
    run rm -f "$UNIT_PATH"
    run systemctl daemon-reload
  else
    echo "$UNIT_PATH not installed"
  fi
}

rc=0
case "$MODE" in
  apply)
    for t in "${TOOLS[@]}"; do apply_tool "$t" || rc=1; done
    if [ "$DRY" = 0 ]; then echo "--- check"; check_all || rc=1; fi ;;
  check) check_all || rc=1 ;;
  remove) for t in "${TOOLS[@]}"; do remove_tool "$t"; done ;;
  persist) persist ;;
  unpersist) unpersist ;;
esac
[ "$DRY" = 1 ] && echo "(dry run: nothing was changed)"
exit $rc
