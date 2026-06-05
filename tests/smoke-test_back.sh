#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-ghcr.io/username/my-pihole-unbound:latest}"
NAME="${SMOKE_CONTAINER_NAME:-pihole-unbound-smoke}"
DNS_PORT="${SMOKE_DNS_PORT:-1053}"
WEB_PORT="${SMOKE_WEB_PORT:-8080}"
HTTPS_PORT="${SMOKE_HTTPS_PORT:-8443}"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-120}"

cleanup() {
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
}

log() {
  printf '[smoke] %s\n' "$*"
}

wait_for_container() {
  local elapsed=0
  until docker exec "${NAME}" pgrep -x pihole-FTL >/dev/null 2>&1 \
    && docker exec "${NAME}" pgrep -x unbound >/dev/null 2>&1 \
    && docker exec "${NAME}" dig +time=2 +tries=1 @127.0.0.1 pi.hole >/dev/null 2>&1 \
    && curl -fsS "http://127.0.0.1:${WEB_PORT}/admin/" >/dev/null 2>&1; do
    if (( elapsed >= TIMEOUT_SECONDS )); then
      log "Container did not become ready within ${TIMEOUT_SECONDS}s"
      docker logs "${NAME}" || true
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
}

assert_dnssec_resolution() {
  local elapsed=0
  local output=""

  until output="$(docker exec "${NAME}" dig +dnssec +adflag +multi @127.0.0.1 dnssec.works A)" \
    && grep -q "status: NOERROR" <<<"${output}" \
    && grep -q "flags:.* ad[ ;]" <<<"${output}" \
    && grep -q "RRSIG" <<<"${output}"; do
    if (( elapsed >= TIMEOUT_SECONDS )); then
      log "DNSSEC resolution did not validate within ${TIMEOUT_SECONDS}s"
      printf '%s\n' "${output}"
      log "Direct Unbound diagnostic"
      docker exec "${NAME}" dig +dnssec +adflag +multi @127.0.0.1 -p 5335 dnssec.works A || true
      log "Expected DNSSEC failure diagnostic"
      docker exec "${NAME}" dig +dnssec +multi @127.0.0.1 -p 5335 fail01.dnssec.works A || true
      log "Recent container logs"
      docker logs --tail 200 "${NAME}" || true
      return 1
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  printf '%s\n' "${output}"
}

cleanup

log "Starting ${IMAGE}"
docker run -d \
  --name "${NAME}" \
  -p "127.0.0.1:${DNS_PORT}:53/tcp" \
  -p "127.0.0.1:${DNS_PORT}:53/udp" \
  -p "127.0.0.1:${WEB_PORT}:80/tcp" \
  -p "127.0.0.1:${HTTPS_PORT}:443/tcp" \
  -e TZ="UTC" \
  -e FTLCONF_dns_upstreams="127.0.0.1#5335" \
  -e FTLCONF_webserver_api_password="smoke-test-password" \
  -e FTLCONF_dns_dnssec="true" \
  -e FTLCONF_dns_listeningMode="all" \
  "${IMAGE}" >/dev/null

trap cleanup EXIT

log "Waiting for DNS and web services"
wait_for_container

log "Verifying required processes"
docker exec "${NAME}" pgrep -a -x unbound
docker exec "${NAME}" pgrep -a -x pihole-FTL

log "Verifying recursive DNSSEC resolution"
assert_dnssec_resolution

log "Smoke test passed"
