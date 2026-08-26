#!/bin/bash
# ================================================================
#  VLESS + REALITY + XRAY  一键安装脚本
#  One-click installer for VLESS + REALITY + Xray
#  https://github.com/YOUR_USERNAME/YOUR_REPO
#
#  本脚本支持带参数执行，不带参数将直接无敌
#  See --help for parameters
# ================================================================

set -euo pipefail

# ── 颜色 / Colors ─────────────────────────────────────────────
RED='\033[0;31m';   GREEN='\033[0;32m';  YELLOW='\033[1;33m'
CYAN='\033[0;36m';  PINK='\033[0;35m';   BOLD='\033[1m';  NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
info() { echo -e "${CYAN}[..]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

# ── Banner ────────────────────────────────────────────────────
banner() {
    echo ""
    echo -e "  ${PINK}https://github.com/YOUR_USERNAME/YOUR_REPO${NC}"
    echo -e "  本脚本支持带参数执行，不带参数将直接无敌 / See ${CYAN}--help${NC} for parameters"
    echo ""
}

# ── 帮助 / Help ───────────────────────────────────────────────
usage() {
    banner
    cat <<EOF
  ${BOLD}用法 / Usage:${NC}
    bash install.sh [选项]

  ${BOLD}选项 / Options:${NC}
    --port    PORT     监听端口        (默认随机 10000-65535)
    --domain  DOMAIN   伪装域名        (默认 www.apple.com)
    --uuid    UUID     自定义 UUID     (默认随机生成)
    --uninstall        卸载 Xray 及配置
    --help             显示此帮助

  ${BOLD}示例 / Examples:${NC}
    bash install.sh
    bash install.sh --port 443 --domain www.bing.com
    bash install.sh --uuid xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    bash install.sh --uninstall

EOF
    exit 0
}

# ── 参数解析 / Argument parsing ───────────────────────────────
PORT=""
DOMAIN="www.apple.com"
UUID_CUSTOM=""
UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)      PORT="$2";         shift 2 ;;
        --domain)    DOMAIN="$2";       shift 2 ;;
        --uuid)      UUID_CUSTOM="$2";  shift 2 ;;
        --uninstall) UNINSTALL=true;    shift   ;;
        --help|-h)   usage ;;
        *) die "未知参数 / Unknown argument: $1" ;;
    esac
done

# ── 计时 / Timer ──────────────────────────────────────────────
START_TS=$(date +%s)
elapsed() { echo $(( $(date +%s) - START_TS )); }

# ── 系统工具 / Utils ──────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "请以 root 运行 / Please run as root"
}

detect_os() {
    if   [[ -f /etc/alpine-release ]]; then echo "alpine"
    elif [[ -f /etc/debian_version ]]; then echo "debian"
    elif [[ -f /etc/redhat-release ]]; then echo "redhat"
    else die "不支持的系统 / Unsupported OS"; fi
}

pkg_install() {
    local os; os=$(detect_os)
    case "$os" in
        alpine) apk add --quiet "$@" >/dev/null 2>&1 ;;
        debian) apt-get update -qq && apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
        redhat) yum install -y -q "$@" >/dev/null 2>&1 ;;
    esac
}

gen_uuid() {
    command -v uuidgen &>/dev/null \
        && uuidgen | tr '[:upper:]' '[:lower:]' \
        || cat /proc/sys/kernel/random/uuid
}

gen_port() {
    local p
    while true; do
        p=$(shuf -i 10000-65535 -n 1 2>/dev/null \
            || awk 'BEGIN{srand();print int(rand()*55535)+10000}')
        ss -tuln 2>/dev/null | grep -q ":$p " || { echo "$p"; return; }
    done
}

get_ip() {
    SERVER_IP=$(
        curl -4fsSL --retry 3 --connect-timeout 5 https://api.ipify.org 2>/dev/null ||
        curl -4fsSL --retry 2 --connect-timeout 5 https://ifconfig.me  2>/dev/null ||
        hostname -I | awk '{print $1}'
    )
}

open_firewall() {
    local port="$1"
    if   command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q active; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

# ── 低内存 Swap ───────────────────────────────────────────────
setup_swap() {
    local mem_mb; mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    if [[ $mem_mb -lt 256 ]] && ! swapon --show 2>/dev/null | grep -q '/swapfile'; then
        info "内存仅 ${mem_mb}MB，创建 Swap / Low RAM, creating swap ..."
        fallocate -l 512M /swapfile 2>/dev/null \
            || dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
        chmod 600 /swapfile
        mkswap /swapfile -q
        swapon /swapfile
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
}

# ── 卸载 / Uninstall ─────────────────────────────────────────
do_uninstall() {
    banner
    warn "开始卸载 / Uninstalling ..."
    systemctl stop    xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
        @ remove >/dev/null 2>&1 || true
    rm -rf /usr/local/etc/xray /var/log/xray
    ok "卸载完成 / Uninstall done"
    exit 0
}

# ── 步骤 1：工具链检查 / Tool check ───────────────────────────
step_tool_check() {
    info "工具链检查 / Tool check ..."
    local need=()
    for cmd in curl wget unzip; do
        command -v "$cmd" &>/dev/null || need+=("$cmd")
    done
    [[ ${#need[@]} -gt 0 ]] && pkg_install "${need[@]}"
    ok "工具链检查 / Tool check ... [OK]"
}

# ── 步骤 2：安装 Xray / Install XRAY ─────────────────────────
step_install_xray() {
    info "开始，安装 XRAY / Install XRAY ..."
    local attempt=0
    while [[ $attempt -lt 3 ]]; do
        if bash -c "$(curl -fsSL --retry 3 \
            https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
            @ install >/dev/null 2>&1; then
            ok "开始，安装 XRAY / Install XRAY ... [OK]"
            return 0
        fi
        (( attempt++ ))
        warn "安装失败，重试 ${attempt}/3 / Retrying ..."
        sleep 3
    done
    die "Xray 安装失败 / Xray install failed after 3 attempts"
}

# ── 步骤 3：更新 geodata ──────────────────────────────────────
step_update_geodata() {
    info "加速，更新 geodata / Updating geodata ..."
    local geoDir="/usr/local/share/xray"
    mkdir -p "$geoDir"
    for f in geoip.dat geosite.dat; do
        curl -fsSL --retry 3 \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/${f}" \
            -o "${geoDir}/${f}" 2>/dev/null || true
    done
    ok "加速，更新 geodata / Updating geodata ... [OK]"
}

# ── 步骤 4：生成密钥对 ────────────────────────────────────────
gen_reality_keys() {
    local out; out=$(/usr/local/bin/xray x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$out" | awk '/Private/{print $NF}')
    PUBLIC_KEY=$(echo  "$out" | awk '/Public/{print $NF}')
    SHORT_ID=$(openssl rand -hex 8 2>/dev/null \
               || head -c4 /dev/urandom | xxd -p 2>/dev/null \
               || tr -dc 'a-f0-9' </dev/urandom | head -c16)
}

# ── 步骤 4：写配置 / Config ───────────────────────────────────
step_write_config() {
    info "块好了，手搓 / Configuring /usr/local/etc/xray/config.json ..."

    [[ -z "$UUID_CUSTOM" ]] && UUID_CUSTOM=$(gen_uuid)
    [[ -z "$PORT"        ]] && PORT=$(gen_port)
    gen_reality_keys

    mkdir -p /usr/local/etc/xray /var/log/xray

    cat > /usr/local/etc/xray/config.json <<JSON
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID_CUSTOM}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DOMAIN}:443",
          "xver": 0,
          "serverNames": ["${DOMAIN}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom",  "tag": "direct"  },
    { "protocol": "blackhole","tag": "blocked" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip":     ["geoip:private"],           "outboundTag": "blocked" },
      { "type": "field", "domain": ["geosite:category-ads-all"],"outboundTag": "blocked" }
    ]
  }
}
JSON

    ok "块好了，手搓 / Configuring /usr/local/etc/xray/config.json ... [OK]"
}

# ── 步骤 5：启动服务 / Start service ─────────────────────────
step_start_service() {
    info "冲刺，开启服务 / Starting Service ..."
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 1
    ok "冲刺，开启服务 / Starting Service ... [OK]"
}

# ── 步骤 6：BBR ───────────────────────────────────────────────
step_enable_bbr() {
    info "最后，打开 BBR / Finishing, Enabling BBR ..."
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        {
            echo 'net.core.default_qdisc=fq'
            echo 'net.ipv4.tcp_congestion_control=bbr'
        } >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1 || true
    fi
    ok "最后，打开 BBR / Finishing, Enabling BBR ... [OK]"
}

# ── 步骤 7：放行防火墙 ────────────────────────────────────────
step_firewall() {
    open_firewall "$PORT"
}

# ── 步骤 8：服务状态检查 ──────────────────────────────────────
step_check_service() {
    info "检查服务状态 / Checking Service ..."
    systemctl is-active --quiet xray \
        || die "Xray 未运行\n$(journalctl -u xray -n 20 --no-pager)"
    ok "检查服务状态 / Checking Service ... [OK]"
}

# ── 输出结果 / Print result ───────────────────────────────────
print_result() {
    get_ip
    local link="vless://${UUID_CUSTOM}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#REALITY-${SERVER_IP}"

    echo ""
    echo -e "${GREEN}舒服了 / Done:${NC}"
    echo ""
    echo -e "  ${PINK}${link}${NC}"
    echo ""
    echo -e "  地址  / Address  :  ${YELLOW}${SERVER_IP}${NC}"
    echo -e "  端口  / Port     :  ${YELLOW}${PORT}${NC}"
    echo -e "  UUID             :  ${YELLOW}${UUID_CUSTOM}${NC}"
    echo -e "  SNI              :  ${YELLOW}${DOMAIN}${NC}"
    echo -e "  PublicKey        :  ${YELLOW}${PUBLIC_KEY}${NC}"
    echo -e "  ShortID          :  ${YELLOW}${SHORT_ID}${NC}"
    echo -e "  Flow             :  ${YELLOW}xtls-rprx-vision${NC}"
    echo ""
    echo -e "总用时 / Elapsed Time:  ${GREEN}$(elapsed) 秒${NC}"
    echo -e "${CYAN}---------- live free or die hard ----------${NC}"
    echo ""
}

# ── 主流程 / Main ─────────────────────────────────────────────
main() {
    require_root
    banner
    $UNINSTALL && do_uninstall
    setup_swap
    step_tool_check
    step_install_xray
    step_update_geodata
    step_write_config
    step_start_service
    step_enable_bbr
    step_firewall
    step_check_service
    print_result
}

main "$@"
