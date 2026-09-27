#!/usr/bin/env bash
# Minimal, self-contained tests for docling-node.sh (Q5 items 12-13 of
# coldstart-investigation.md). No harness (bats, a shell-test script, or a CI
# job that runs shell tests) exists in this repo, so this is a standalone
# runner: `bash test_docling_node.sh`. It is NOT wired into any GitHub
# workflow -- deploy.yml applies manifests but runs no test step of any kind,
# so there is nothing to hook this into without inventing a new CI job, which
# was out of scope for this change.
#
# Technique: docling-node.sh is `source`d rather than executed (the tail of
# the script guards its runtime dispatch/locking behind
# `[ "${BASH_SOURCE[0]}" = "${0}" ]`, which is false under `source`), so every
# function becomes callable here. Effectful primitives (kubectl, hcloud,
# mac_ok, cmd_up, ...) are then overridden with fakes -- no real cluster,
# Hetzner account, or Redis is touched, and nothing here mutates anything
# outside $WORK (a mktemp -d cleaned on exit).
#
# Never run against a real KUBECONFIG/HCLOUD context: the stub `kubectl` and
# `hcloud` functions below shadow the real binaries for the remainder of this
# process, but `need hcloud; need kubectl; need jq; need curl` (docling-node.sh
# ~line 171) checks PATH at source time, before the shadowing functions exist
# -- so real-looking (but inert) stub executables are put on PATH first.
set -uo pipefail  # not -e: assertions must be able to fail and keep going

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/docling-node.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { printf '  ok   - %s\n' "$1"; }
fail() { printf '  FAIL - %s: %s\n' "$1" "$2"; FAIL=1; }
assert_contains() {  # assert_contains NAME HAYSTACK_FILE NEEDLE
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then pass "$1"
  else fail "$1" "expected to find [$3] in $2 (got: $(cat "$2" 2>/dev/null || echo '<missing>'))"; fi
}
assert_not_contains() {  # assert_not_contains NAME HAYSTACK_FILE NEEDLE
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then
    fail "$1" "did not expect [$3] in $2 (got: $(cat "$2")))"
  else pass "$1"; fi
}
assert_before() {  # assert_before NAME FILE NEEDLE_FIRST NEEDLE_SECOND
  local f=$2 a=$3 b=$4 la lb
  la=$(grep -nF -- "$a" "$f" | head -1 | cut -d: -f1)
  lb=$(grep -nF -- "$b" "$f" | head -1 | cut -d: -f1)
  if [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; then pass "$1"
  else fail "$1" "[$a] (line ${la:-?}) did not precede [$b] (line ${lb:-?}) in $f"; fi
}

# ---- real-but-inert stubs, so `need` (source time) is satisfied -----------
need() { command -v "$1" >/dev/null || { echo "$1 not found"; exit 1; }; }
need jq
need curl
BINSTUB="$WORK/bin"
mkdir -p "$BINSTUB"
for b in hcloud kubectl; do
  printf '#!/bin/sh\nexit 0\n' > "$BINSTUB/$b"
  chmod +x "$BINSTUB/$b"
done
export PATH="$BINSTUB:$PATH"

# ---- source the controller (dispatch tail is guarded off) -----------------
export DOCLING_STATE_DIR="$WORK/state"
export DOCLING_LOCK="$WORK/lock"
mkdir -p "$DOCLING_STATE_DIR"
# shellcheck source=/dev/null
source "$SCRIPT"
# docling-node.sh runs under `set -euo pipefail`; that persists into this
# shell once sourced. This test script asserts on exit statuses itself (grep
# with no match, etc. are expected outcomes, not fatal errors), so relax back
# to what it started with.
set +e +u +o pipefail

echo "== route_active: none writes empty endpoints (item 13) =="
CAPTURE="$WORK/applied.yaml"
: > "$CAPTURE"
kubectl() {  # shadow: only the two calls route_active makes
  case "$*" in
    *"get endpointslice $ACTIVE_SLICE"*)
      # Pretend something (e.g. the Mac) is currently routed, so route_active
      # sees a change and actually applies.
      echo '{"endpoints":[{"addresses":["100.106.50.6"]}],"ports":[{"port":8090}]}' ;;
    *"apply -f -"*) cat > "$CAPTURE" ;;
    *) : ;;
  esac
}
DRY_RUN=0
route_active none
assert_contains  "route_active none -> EndpointSlice applied"      "$CAPTURE" "kind: EndpointSlice"
assert_contains  "route_active none -> endpoints: []"              "$CAPTURE" "endpoints: []"
assert_not_contains "route_active none -> no Mac address leaked"   "$CAPTURE" "100.106.50.6"

echo "== cmd_down: Mac down does not route to the Mac (item 13) =="
SPY="$WORK/route_calls.log"
: > "$SPY"
route_active() { echo "route_active $*" >> "$SPY"; }
mac_ok() { return 1; }              # Mac is down
exists_server() { return 1; }       # no docling-1 to drain/delete
kubectl() {                         # node_ready's `kubectl get node` -> absent
  case "$*" in
    *"get node $NODE"*) return 1 ;;
    *) : ;;
  esac
}
hcloud() {
  case "$*" in
    *"primary-ip list"*) echo '[]' ;;
    *) : ;;
  esac
}
cmd_down
assert_contains     "cmd_down (Mac down) -> routed to none" "$SPY" "route_active none"
assert_not_contains "cmd_down (Mac down) -> never routed to mac" "$SPY" "route_active mac"

echo "== cmd_tick: phase=starting published before cmd_up blocks (item 12) =="
ORDER="$WORK/order.log"
: > "$ORDER"
mac_ok() { return 1; }                                  # Mac still down
node_pod_ip() { :; }                                     # no Ready pod on docling-1 yet
exists_server() { return 1; }                             # docling-1 does not exist yet
demand() { echo "1 1 0 0 0"; }                             # 1 job queued -> demand
autostarts_today() { echo 0; }                             # under the daily cap
route_active() { echo "route_active $*" >> "$ORDER"; }
publish_backend() { echo "publish_backend $*" >> "$ORDER"; }
cmd_up() { echo "cmd_up called" >> "$ORDER"; }             # stands in for the ~100s blocking call
# cmd_tick calls the real cmd_reap at the end; exists_server is already
# stubbed to return 1 above, so cmd_reap's own `exists_server || return 0`
# short-circuits it harmlessly -- no separate override needed (and none is
# left dangling to shadow the real cmd_reap for the orphan tests below).
echo "$MAC_FAILS" > "$DOCLING_STATE_DIR/mac-fails"        # already at the failure threshold
cmd_tick
assert_contains "cmd_tick -> publishes phase=starting"        "$ORDER" "publish_backend node starting"
assert_contains "cmd_tick -> still calls cmd_up"              "$ORDER" "cmd_up called"
assert_before   "cmd_tick -> starting published BEFORE cmd_up" "$ORDER" "publish_backend node starting" "cmd_up called"

echo "== cmd_reap orphan check (item 14, repair cycle 1) =="
# All five cases put the node into the same "reap-eligible, CPU busy" shape
# (docling_mcpu overridden to a busy value; hcloud stubbed so the node reads
# as 55 min old -- within the last-margin window of billed hour 1, but well
# under the MAX_HOURS cap so only the busy/orphan branch is exercised) and
# differ only in what docling_health/job_status_get report, then assert
# whether cmd_down was (or was not) called.
DOWN_LOG="$WORK/cmd_down_calls.log"
reap_hcloud_node_55min_old() {
  hcloud() {
    case "$*" in
      *"server describe $NODE -o json"*)
        local created; created=$(date -u -d '-55 minutes' '+%Y-%m-%dT%H:%M:%S+00:00')
        jq -nc --arg c "$created" '{created:$c}' ;;
      *) : ;;
    esac
  }
}
reap_case() {  # reap_case NAME HEALTH_FN_BODY JOBSTATUS_FN_BODY EXPECT_DELETED(0|1)
  local name=$1 health_body=$2 status_body=$3 expect_deleted=$4 deleted
  : > "$DOWN_LOG"
  exists_server() { return 0; }
  reap_hcloud_node_55min_old
  docling_mcpu() { echo 800; }  # >= BUSY_MCPU (default 500)
  eval "docling_health() { $health_body ; }"
  eval "job_status_get() { $status_body ; }"
  cmd_down() { echo "cmd_down called" >> "$DOWN_LOG"; }
  cmd_reap
  deleted=0
  grep -qF "cmd_down called" "$DOWN_LOG" && deleted=1
  if [ "$deleted" -eq "$expect_deleted" ]; then pass "$name"
  else fail "$name" "expected cmd_down called=$expect_deleted, got $deleted"; fi
}

# docling_health's real contract is PIPE-separated (see the comment on
# docling_health itself for why plain @tsv does not work either: bash's
# `read` collapses runs of ANY "IFS whitespace" character -- space, tab, AND
# newline -- regardless of which one IFS is set to, so two consecutive tabs
# collapse exactly like two consecutive spaces do; only a non-whitespace
# delimiter like `|` reliably preserves an empty middle field). Test stubs
# must emit real pipes to match -- using spaces or tabs here would exercise
# `IFS='|' read` incorrectly and give false passes/fails unrelated to the
# actual bug being guarded against.

# (a) Redis unreachable (job_status_get rc=1, prints nothing) + /health busy
#     -> transport failure must fall through to KEEP, never read as orphaned.
reap_case "reap orphan: Redis unreachable -> KEEP, cmd_down not called" \
  'echo "1|job-abc|2026-01-01T00:00:00Z"' \
  'return 1' \
  0

# (b) Redis positively answers status=done (job finished, docling-service
#     just hasn't noticed the disconnect yet) -> orphaned, delete.
reap_case "reap orphan: status=done -> DELETE despite busy CPU" \
  'echo "1|job-abc|2026-01-01T00:00:00Z"' \
  'echo done' \
  1

# (b, absent variant) the job hash doesn't exist at all -> also orphaned.
reap_case "reap orphan: status=absent -> DELETE despite busy CPU" \
  'echo "1|job-abc|2026-01-01T00:00:00Z"' \
  'echo absent' \
  1

# (c) Redis says the job is genuinely still processing -> real work, KEEP.
reap_case "reap orphan: status=processing -> KEEP" \
  'echo "1|job-abc|2026-01-01T00:00:00Z"' \
  'echo processing' \
  0

# (d) /health itself is unreachable (docling_health prints nothing) -> no
#     in_flight/current_job_id to cross-check at all, fall through to KEEP.
reap_case "reap orphan: /health unreachable -> KEEP" \
  ':' \
  'echo done' \
  0

# (e) Repair cycle 2 regression: a conversion with no X-Job-Id reports
# current_job_id=null on /health -> docling_health's real jq emits an EMPTY
# middle field: "1||1790000000.5" (in_flight 1, empty job id, a started_at
# UNIX-epoch-with-fraction timestamp -- deliberately NOT an ISO string here,
# so a bug that shifted it into $hj would also fail the job_status_get lookup
# for a completely different, equally wrong reason, making the failure mode
# unmistakable). Before the fix this was space-joined ("1  1790000000.5"),
# `read`'s IFS-whitespace collapsing swallowed the double space, and the
# timestamp silently became $hj -- job_status_get then answered "absent" for
# a job id that was never real, and the reap orphan check deleted a
# genuinely busy node. A first attempted fix (@tsv, tab-joined) turned out
# NOT to fix this either -- tab is also IFS whitespace and two consecutive
# tabs collapse the same way two consecutive spaces do. Only the pipe-joined
# form below, with `IFS='|' read`, reliably keeps the middle field empty and
# `[ -n "$hj" ]` correctly false, so the orphan check has nothing to
# cross-check and must KEEP.
reap_case "reap orphan: current_job_id=null (no X-Job-Id) -> KEEP, never orphan" \
  'echo "1||1790000000.5"' \
  'echo done' \
  0

echo "== publish_backend survives a Redis outage under set -e =="
# Every cmd_tick test above stubs publish_backend, so the real
# publish_backend -> redis_set_ex -> redis_cmd chain is exercised here, in a
# fresh subshell that re-sources the script to get the real function back.
PUB_LOG="$WORK/publish_outage.log"
(
  # shellcheck source=/dev/null
  source "$SCRIPT"
  set -euo pipefail
  redis_cmd() { return 1; }  # Redis unreachable
  publish_backend mac ready ""
  echo "after publish" > "$PUB_LOG"
) >/dev/null 2>&1
assert_contains "publish_backend with Redis down -> tick continues" "$PUB_LOG" "after publish"

echo "== raw Redis reads end: QUIT closes the reply, timeout reaches cat =="
# 2026-09-27: redis_cmd sent no QUIT, so Redis kept the socket open, and the
# controller's busybox `timeout 5` killed only the inner bash, never the cat
# it had forked. The tick hung for an hour and no demand check ran. A fake
# Redis on 127.0.0.2:6379 answers only once it sees QUIT (a real Redis
# answers at once but still holds the socket open until QUIT), and busybox
# timeout stands in for the alpine image's.
if command -v python3 >/dev/null && command -v busybox >/dev/null; then
  mkdir -p "$WORK/bb"
  ln -sf "$(command -v busybox)" "$WORK/bb/timeout"
  fake_redis() {  # fake_redis MODE -> starts it; MODE quit|silent
    python3 - "$1" <<'PY' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.2", 6379)); s.listen(1); s.settimeout(20)
c, _ = s.accept(); buf = b""
while sys.argv[1] == "quit" and b"QUIT" not in buf:
    d = c.recv(4096)
    if not d: break
    buf += d
if sys.argv[1] == "quit":
    c.sendall(b"+OK\r\n$3\r\nfoo\r\n+OK\r\n"); c.close()
else:
    c.recv(4096); __import__("time").sleep(20)
PY
    FAKE_PID=$!
    for _ in $(seq 50); do ss -ltn 2>/dev/null | grep -q '127.0.0.2:6379 ' && break; sleep 0.1; done
  }
  REDIS_OUT="$WORK/redis_get.out"
  fake_redis quit
  (
    source "$SCRIPT"; PATH="$WORK/bb:$PATH"
    kubectl() { echo 127.0.0.2; }
    start=$SECONDS; v=$(redis_get pageindex:probe)
    echo "value=$v secs=$((SECONDS - start))"
  ) >"$REDIS_OUT" 2>/dev/null
  wait "$FAKE_PID" 2>/dev/null
  assert_contains "redis_get sends QUIT and reads the reply" "$REDIS_OUT" "value=foo secs=0"

  fake_redis silent
  (
    source "$SCRIPT"; PATH="$WORK/bb:$PATH"
    kubectl() { echo 127.0.0.2; }
    start=$SECONDS; rc=0; redis_cmd "$(printf '*1\r\n$4\r\nPING\r\n')" || rc=$?
    echo "rc=$rc bounded=$(( SECONDS - start <= 7 ))"
  ) >"$REDIS_OUT" 2>/dev/null
  kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null
  assert_contains "redis_cmd on a Redis that never answers -> unknown within the timeout" \
    "$REDIS_OUT" "rc=1 bounded=1"
else
  echo "  skip - python3 or busybox missing"
fi

echo "== 'local' is no longer a valid subcommand (RFC-052 R5 AC5 / NG7) =="
# docling-service-local and `docling-node.sh local on|off` were removed
# 2026-09-27: no Docling conversion may ever run on portfolio. Exercise this
# as a real (unsourced) invocation -- the dispatch case that used to route
# `local` to cmd_local lives in the runtime-dispatch tail, which is guarded
# off under `source` (see the file header), so it cannot be reached from the
# sourced functions above.
LOCAL_OUT="$WORK/local_invalid.out"
LOCAL_RC=0
( PATH="$BINSTUB:$PATH"; bash "$SCRIPT" local on ) >"$LOCAL_OUT" 2>&1 || LOCAL_RC=$?
if [ "$LOCAL_RC" -ne 0 ]; then pass "docling-node.sh local on -> non-zero exit"
else fail "docling-node.sh local on -> non-zero exit" "got exit 0 (output: $(cat "$LOCAL_OUT"))"; fi
assert_not_contains "docling-node.sh local on -> no cmd_local usage text" \
  "$LOCAL_OUT" "usage: $SCRIPT local"
# The banner printed for any invalid subcommand documents the NG7 removal by
# name (see the file header) -- that is expected, so check for the one thing
# that would mean `local` was still wired up: an actual kubectl scale call.
assert_not_contains "docling-node.sh local on -> never scales any docling-service Deployment" \
  "$LOCAL_OUT" "scale deployment/docling-service"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
