#!/usr/bin/env bash
# Resize the portfolio server (the k3s host) to a bigger type once Hetzner
# has capacity for it in the server's location.
#
# Runs on a GitHub runner, never on the host itself: Hetzner only changes the
# type of a powered-off server, and powering off the host kills everything on it.
#
#   portfolio-resize.sh probe    prints ready=true|false (to $GITHUB_OUTPUT when set)
#   portfolio-resize.sh resize   re-probes, then shutdown -> change_type -> poweron
#
# Env: HCLOUD_TOKEN, SERVER_ID, TARGET_TYPE, LOCATION.
# The disk is kept (upgrade_disk=false) so a later downgrade stays possible.
set -euo pipefail

: "${HCLOUD_TOKEN:?}" "${SERVER_ID:?}" "${TARGET_TYPE:?}" "${LOCATION:?}"
API=https://api.hetzner.cloud/v1

api() { # api METHOD PATH [JSON]
  local args=(-fsS --retry 3 --retry-all-errors -X "$1" -H "Authorization: Bearer $HCLOUD_TOKEN")
  [ $# -ge 3 ] && args+=(-H "Content-Type: application/json" -d "$3")
  curl "${args[@]}" "$API/$2"
}

server_field() { api GET "servers/$SERVER_ID" | jq -r ".server.$1"; }

summary() {
  echo "$1"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$1" >> "$GITHUB_STEP_SUMMARY"
  return 0
}

# true when TARGET_TYPE can be ordered or migrated to in LOCATION right now
available() {
  local st id by_loc by_dc
  st=$(api GET "server_types?name=$TARGET_TYPE")
  id=$(jq -r '.server_types[0].id' <<<"$st")
  by_loc=$(jq --arg l "$LOCATION" \
    '[.server_types[0].locations[]? | select(.name == $l) | .available] | any' <<<"$st")
  by_dc=$(api GET datacenters | jq --arg l "$LOCATION" --argjson id "$id" \
    '[.datacenters[] | select(.location.name == $l) | .server_types.available_for_migration[]] | index($id) != null')
  echo "availability $TARGET_TYPE@$LOCATION: location=$by_loc migration=$by_dc" >&2
  [ "$by_dc" = true ] || [ "$by_loc" = true ]
}

# wait_action ID: poll a Hetzner action until it finishes; fail on error
wait_action() {
  local status
  for _ in $(seq 1 120); do
    status=$(api GET "actions/$1" | jq -r .action.status)
    case $status in
      success) return 0 ;;
      error) api GET "actions/$1" | jq -c .action.error >&2; return 1 ;;
    esac
    sleep 5
  done
  echo "action $1 still $status after 10 min" >&2
  return 1
}

wait_status() { # wait_status WANT SECONDS
  local s
  for _ in $(seq 1 $(($2 / 5))); do
    s=$(server_field status)
    [ "$s" = "$1" ] && return 0
    sleep 5
  done
  return 1
}

probe() {
  local current ready=false
  current=$(server_field server_type.name)
  if [ "$current" = "$TARGET_TYPE" ]; then
    summary "Server $SERVER_ID is already $TARGET_TYPE; nothing to do."
  elif available; then
    ready=true
    summary "$TARGET_TYPE is available in $LOCATION (server is $current). Resize awaits approval."
  else
    summary "$TARGET_TYPE not available in $LOCATION yet (server is $current)."
  fi
  echo "ready=$ready"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "ready=$ready" >> "$GITHUB_OUTPUT"
  return 0
}

power_on() {
  [ "$(server_field status)" = running ] && return 0
  echo "powering on" >&2
  wait_action "$(api POST "servers/$SERVER_ID/actions/poweron" | jq -r .action.id)" || true
  wait_status running 300
}

resize() {
  local current
  current=$(server_field server_type.name)
  if [ "$current" = "$TARGET_TYPE" ]; then
    summary "Already $TARGET_TYPE; nothing to do."
    return 0
  fi
  # Approval can come hours after the probe: never power off unless it is
  # still available now.
  if ! available; then
    summary "$TARGET_TYPE no longer available in $LOCATION; server left running as $current."
    return 0
  fi

  # From here on, whatever fails, the server must end up powered on.
  trap 'power_on || summary "WARNING: server $SERVER_ID may still be off"' EXIT

  echo "graceful shutdown" >&2
  api POST "servers/$SERVER_ID/actions/shutdown" >/dev/null
  if ! wait_status off 240; then
    echo "graceful shutdown timed out; forcing poweroff" >&2
    wait_action "$(api POST "servers/$SERVER_ID/actions/poweroff" | jq -r .action.id)"
    wait_status off 120
  fi

  echo "change_type $current -> $TARGET_TYPE (disk kept)" >&2
  wait_action "$(api POST "servers/$SERVER_ID/actions/change_type" \
    "{\"server_type\":\"$TARGET_TYPE\",\"upgrade_disk\":false}" | jq -r .action.id)"

  power_on
  trap - EXIT
  current=$(server_field server_type.name)
  [ "$current" = "$TARGET_TYPE" ] || { summary "Resize finished but server reports $current."; return 1; }
  summary "Resized server $SERVER_ID to $TARGET_TYPE and powered it on."
}

case "${1:-}" in
  probe) probe ;;
  resize) resize ;;
  *) echo "usage: $0 probe|resize" >&2; exit 2 ;;
esac
