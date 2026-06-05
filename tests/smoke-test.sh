#!/bin/bash

# ==============================================================================
# Smoke Test for Pi-hole and Unbound (Rich Logging Version)
# ==============================================================================

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Logging Helpers
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS] ✅${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN] ⚠️${NC} $1"; }
log_error() { echo -e "${RED}[FAIL] ❌${NC} $1"; }
log_step() { echo -e "\n${BOLD}${CYAN}🚀 STEP: $1${NC}\n$(printf '%.s-' {1..50})"; }

set -e

# --- Configuration ---
PIHOLE_CONTAINER="${PIHOLE_CONTAINER:-pihole}"
UNBOUND_CONTAINER="${UNBOUND_CONTAINER:-unbound}"
DNS_PORT="${DNS_PORT:-53}"
UNBOUND_PORT="${UNBOUND_PORT:-5335}"
TEST_DOMAIN="${TEST_DOMAIN:-google.com}"
AD_DOMAIN="${AD_DOMAIN:-flurry.com}"
MAX_RETRIES=30
SLEEP_INTERVAL=2

# Banner
echo -e "${BOLD}${BLUE}"
echo "===================================================="
echo "    Pi-hole + Unbound Smoke Test Suite v2.0"
echo "===================================================="
echo -e "${NC}"

# Function to wait for a condition with rich logging
wait_for_condition() {
    local label=$1
    local cmd=$2
    local attempt=1

    log_info "正在等待: ${BOLD}$label${NC} ..."
    
    while ! eval "$cmd" >/dev/null 2>&1; do
        if [ $attempt -ge $MAX_RETRIES ]; then
            log_error "超时！已尝试 $MAX_RETRIES 次，条件仍未达成。"
            return 1
        fi
        echo -ne "  ${YELLOW}⏳ [尝试 $attempt/$MAX_RETRIES]${NC} 仍在探测中... \r"
        sleep "$SLEEP_INTERVAL"
        ((attempt++))
    done
    echo -e "\n  ${GREEN}✨ 条件已达成！${NC}"
    return 0
}

# --- 1. Container Status ---
log_step "检查容器生命体征"

wait_for_condition "Pi-hole 容器状态 (running)" \
    "docker inspect -f '{{.State.Running}}' $PIHOLE_CONTAINER | grep 'true'"
log_success "Pi-hole 容器已启动"

wait_for_condition "Unbound 容器状态 (running)" \
    "docker inspect -f '{{.State.Running}}' $UNBOUND_CONTAINER | grep 'true'"
log_success "Unbound 容器已启动"


# --- 2. Port Availability ---
log_step "检查网络端口可用性"

wait_for_condition "DNS 端口 (TCP/53)" \
    "nc -z 127.0.0.1 $DNS_PORT"
log_success "外部 DNS 端口 (53) 可访问"

wait_for_condition "Unbound 内部端口 (UDP/5335)" \
    "docker exec $PIHOLE_CONTAINER nc -zu 127.0.0.1 $UNBOUND_PORT"
log_success "Pi-hole 内部可访问 Unbound 端口 (5335)"


# --- 3. DNS Resolution ---
log_step "执行 DNS 解析压力测试"

log_info "验证递归查询: ${BOLD}$TEST_DOMAIN${NC}"
wait_for_condition "DNS 正常解析 ($TEST_DOMAIN)" \
    "dig @127.0.0.1 -p $DNS_PORT $TEST_DOMAIN +short | grep -E '^[0-9.]+$'"
IP=$(dig @127.0.0.1 -p $DNS_PORT $TEST_DOMAIN +short | head -n1)
log_success "正常解析成功: $TEST_DOMAIN -> $IP"

log_info "验证广告拦截: ${BOLD}$AD_DOMAIN${NC}"
wait_for_condition "DNS 拦截功能 ($AD_DOMAIN)" \
    "dig @127.0.0.1 -p $DNS_PORT $AD_DOMAIN +short | grep -E '0.0.0.0|127.0.0.1'"
log_success "广告拦截成功: $AD_DOMAIN -> 0.0.0.0"


# --- 4. Web UI Check ---
log_step "检查 Web 管理后台"

log_info "尝试访问: http://localhost:$PIHOLE_WEB_PORT/admin"
wait_for_condition "Web 界面响应 (200 OK)" \
    "curl -Is http://127.0.0.1/admin/ | grep -E 'HTTP/1.1 (200|302)'"
log_success "Pi-hole Web 管理后台可达"


# --- Final Summary ---
echo -e "\n${BOLD}${BLUE}====================================================${NC}"
echo -e "${BOLD}${GREEN}        🎉 所有冒烟测试已顺利通过！${NC}"
echo -e "${CYAN}    状态: 系统健康 (System Healthy)"
echo -e "    时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${BOLD}${BLUE}====================================================${NC}\n"
