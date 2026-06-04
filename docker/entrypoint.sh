#!/usr/bin/env sh
set -eu

UNBOUND_CONFIG="${UNBOUND_CONFIG:-/etc/unbound/unbound.conf}"
UNBOUND_ROOT_KEY="${UNBOUND_ROOT_KEY:-/var/lib/unbound/root.key}"
SENTINEL_INTERVAL="${SENTINEL_INTERVAL:-5}"

log() {
  printf '%s %s\n' "[pihole-unbound]" "$*"
}

is_unbound_running() {
  pgrep -x unbound >/dev/null 2>&1
}

refresh_root_anchor() {
  log "Refreshing DNSSEC root trust anchor with unbound-anchor"
  install -d -m 0755 -o unbound -g unbound "$(dirname "$UNBOUND_ROOT_KEY")"

  if unbound-anchor -a "$UNBOUND_ROOT_KEY"; then
    chown unbound:unbound "$UNBOUND_ROOT_KEY" 2>/dev/null || true
    chmod 0644 "$UNBOUND_ROOT_KEY" 2>/dev/null || true
    log "DNSSEC root trust anchor is ready"
  else
    log "WARNING: unbound-anchor failed; continuing with existing trust anchor if present"
  fi
}

start_unbound() {
  if is_unbound_running; then
    return 0
  fi

  log "Validating Unbound configuration"
  unbound-checkconf "$UNBOUND_CONFIG"

  log "Starting Unbound recursive resolver on 127.0.0.1:5335"
  unbound -d -c "$UNBOUND_CONFIG" &
}

sentinel_loop() {
  log "Sentinel monitor started; checking Unbound every ${SENTINEL_INTERVAL}s"
  while :; do
    sleep "$SENTINEL_INTERVAL"
    if ! is_unbound_running; then
      log "Unbound is not running; attempting restart"
      start_unbound || log "WARNING: Unbound restart attempt failed"
    fi
  done
}

refresh_root_anchor
start_unbound
sentinel_loop &

log "Handing PID 1 to official Pi-hole start.sh"
exec start.sh "$@"
