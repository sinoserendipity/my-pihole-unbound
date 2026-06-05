#!/usr/bin/env bash
set -Eeuo pipefail

# --- ANSI 颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- 配置参数 (继承自原版) ---
IMAGE="${1:-ghcr.io/username/my-pihole-unbound:latest}"
NAME="${SMOKE_CONTAINER_NAME:-pihole-unbound-smoke}"
DNS_PORT="${SMOKE_DNS_PORT:-1053}"
WEB_PORT="${SMOKE_WEB_PORT:-8080}"
HTTPS_PORT="${SMOKE_HTTPS_PORT:-8443}"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-120}"

# --- 日志函数 ---
cleanup() {
  echo -e "${YELLOW}[smoke] 🧹 正在清理/移除测试容器: ${NAME}...${NC}"
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
}

log() {
  echo -e "${BLUE}[smoke]${NC} $*"
}

log_pass() {
  echo -e "${GREEN}[PASS] ✨ $*${NC}"
}

log_fail() {
  echo -e "${RED}[FAIL] ❌ $*${NC}"
}

log_header() { 
    echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}"
    echo -e "${BLUE}$(printf '%.s-' {1..40})${NC}"
}

# --- 核心测试函数 ---

wait_for_container() {
  local elapsed=0
  log_header "阶段 1: 等待核心服务就绪"
  log "目标: 确认 FTL、Unbound 进程及 Web 端口响应"
  
  until docker exec "${NAME}" pgrep -x pihole-FTL >/dev/null 2>&1 \
    && docker exec "${NAME}" pgrep -x unbound >/dev/null 2>&1 \
    && docker exec "${NAME}" dig +time=2 +tries=1 @127.0.0.1 pi.hole >/dev/null 2>&1 \
    && curl -fsS "http://127.0.0.1:${WEB_PORT}/admin/" >/dev/null 2>&1; do
    
    if (( elapsed >= TIMEOUT_SECONDS )); then
      log_fail "容器初始化超时 (${TIMEOUT_SECONDS}s)"
      docker logs "${NAME}" || true
      return 1
    fi
    
    printf "  ${YELLOW}⏳ [%ds/%ds]${NC} 正在轮询健康检查接口...\r" "$elapsed" "$TIMEOUT_SECONDS"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  printf "\n"
  log_pass "核心服务上线完毕"
}

assert_ad_blocking() {
  log_header "阶段 2: 验证广告拦截功能 (Ad-blocking)"
  local ad_domain="flurry.com"
  log "测试域名: ${BOLD}${ad_domain}${NC} (预期结果: 0.0.0.0)"

  local result
  result=$(docker exec "${NAME}" dig +short @127.0.0.1 "${ad_domain}" | tr -d '\r')
  
  if [[ "$result" == "0.0.0.0" ]]; then
    log_pass "拦截生效: ${ad_domain} -> ${result}"
  else
    log_fail "拦截失效！${ad_domain} 解析结果为: ${result} (预期应为 0.0.0.0)"
    return 1
  fi
}

assert_dnssec_resolution() {
  local elapsed=0
  local output=""
  log_header "阶段 3: 验证递归 DNSSEC 解析 (Hardcore 模式)"
  log "测试域名: ${BOLD}dnssec.works${NC} (预期需包含 AD 标志位)"

  until output="$(docker exec "${NAME}" dig +dnssec +adflag +multi @127.0.0.1 dnssec.works A)" \
    && grep -q "status: NOERROR" <<<"${output}" \
    && grep -q "flags:.* ad[ ;]" <<<"${output}" \
    && grep -q "RRSIG" <<<"${output}"; do
    
    if (( elapsed >= TIMEOUT_SECONDS )); then
      log_fail "DNSSEC 验证失败"
      log "诊断详情:"
      printf '%s\n' "${output}"
      return 1
    fi

    printf "  ${YELLOW}⏳ [%ds/%ds]${NC} 正在验证上游递归链条与签名... \r" "$elapsed" "$TIMEOUT_SECONDS"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  
  printf "\n"
  log_pass "DNSSEC 验证通过 (Authenticated Data 已确认)"
}

# --- 执行主流程 ---
cleanup

echo -e "\n${BOLD}${CYAN}===================================================="
echo -e "    PI-HOLE + UNBOUND 全功能综合冒烟测试"
echo -e "====================================================${NC}"

log "启动镜像: ${BOLD}${IMAGE}${NC}"
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

# 顺序执行三大核心测试
wait_for_container
assert_ad_blocking
assert_dnssec_resolution

echo -e "\n${BOLD}${BLUE}====================================================${NC}"
echo -e "${BOLD}${GREEN}  🏆 恭喜！全功能冒烟测试顺利通关！${NC}"
echo -e "  - 核心服务: OK"
echo -e "  - 广告拦截: OK"
echo -e "  - DNSSEC递归: OK"
echo -e "${BOLD}${BLUE}====================================================${NC}\n"
