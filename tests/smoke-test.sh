#!/usr/bin/env bash
set -Eeuo pipefail

# --- ANSI Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

IMAGE="${1:-ghcr.io/username/my-pihole-unbound:latest}"
NAME="${SMOKE_CONTAINER_NAME:-pihole-unbound-smoke}"
DNS_PORT="${SMOKE_DNS_PORT:-1053}"
WEB_PORT="${SMOKE_WEB_PORT:-8080}"
HTTPS_PORT="${SMOKE_HTTPS_PORT:-8443}"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-120}"

cleanup() {
  printf "${YELLOW}[smoke] 清理测试环境...${NC}\n"
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
}

log() {
  echo -e "${BLUE}[smoke]${NC} $*"
}

log_pass() {
  printf "${GREEN}[PASS] ✨ %s${NC}\n" "$*"
}

log_fail() {
  printf "${RED}[FAIL] ❌ %s${NC}\n" "$*"
}

wait_for_container() {
  local elapsed=0
  log "等待 DNS 和 Web 服务就绪 (超时: ${TIMEOUT_SECONDS}s)"
  
  until docker exec "${NAME}" pgrep -x pihole-FTL >/dev/null 2>&1 \
    && docker exec "${NAME}" pgrep -x unbound >/dev/null 2>&1 \
    && docker exec "${NAME}" dig +time=2 +tries=1 @127.0.0.1 pi.hole >/dev/null 2>&1 \
    && curl -fsS "http://127.0.0.1:${WEB_PORT}/admin/" >/dev/null 2>&1; do
    
    if (( elapsed >= TIMEOUT_SECONDS )); then
      log_fail "容器未能在 ${TIMEOUT_SECONDS}s 内就绪"
      docker logs "${NAME}" || true
      return 1
    fi
    
    printf "  ${YELLOW}⏳ [%ds/%ds]${NC} 正在探测核心进程与端口...\r" "$elapsed" "$TIMEOUT_SECONDS"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  printf "\n"
  log_pass "核心服务已上线"
}

assert_dnssec_resolution() {
  local elapsed=0
  local output=""
  log "验证递归 DNSSEC 解析功能 (测试域: dnssec.works)"

  until output="$(docker exec "${NAME}" dig +dnssec +adflag +multi @127.0.0.1 dnssec.works A)" \
    && grep -q "status: NOERROR" <<<"${output}" \
    && grep -q "flags:.* ad[ ;]" <<<"${output}" \
    && grep -q "RRSIG" <<<"${output}"; do
    
    if (( elapsed >= TIMEOUT_SECONDS )); then
      log_fail "DNSSEC 解析未能在 ${TIMEOUT_SECONDS}s 内完成验证"
      printf '%s\n' "${output}"
      log "尝试直接通过 Unbound (5335) 进行诊断"
      docker exec "${NAME}" dig +dnssec +adflag +multi @127.0.0.1 -p 5335 dnssec.works A || true
      log "检测预期的 DNSSEC 失败响应"
      docker exec "${NAME}" dig +dnssec +multi @127.0.0.1 -p 5335 fail01.dnssec.works A || true
      log "容器最近日志"
      docker logs --tail 200 "${NAME}" || true
      return 1
    fi

    printf "  ${YELLOW}⏳ [%ds/%ds]${NC} 正在验证 DNSSEC 签名与 AD 标志...\r" "$elapsed" "$TIMEOUT_SECONDS"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  
  printf "\n"
  printf "${BOLD}${BLUE}--- DNSSEC 响应详情 ---${NC}\n"
  printf '%s\n' "${output}"
  printf "${BOLD}${BLUE}-----------------------${NC}\n"
  log_pass "DNSSEC 验证成功 (Authenticated Data 标志已确认)"
}

# --- 执行流程 ---
cleanup

echo -e "${BOLD}${BLUE}===================================================="
echo -e "    PI-HOLE + UNBOUND 自动化冒烟测试启动"
echo -e "====================================================${NC}"

log "正在拉取/启动镜像: ${BOLD}${IMAGE}${NC}"
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

# 开始验证
wait_for_container

log "验证进程详细信息"
docker exec "${NAME}" pgrep -a -x unbound || log_fail "Unbound 进程不在运行列表"
docker exec "${NAME}" pgrep -a -x pihole-FTL || log_fail "Pi-hole FTL 进程不在运行列表"

assert_dnssec_resolution

echo -e "\n${BOLD}${GREEN}✅ 冒烟测试全部通过！系统运行状态良好。${NC}\n"
