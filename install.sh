#!/bin/bash
# ================================================================
#  VLESS + REALITY + XRAY  极限内存版 / Ultra-Low RAM Edition
#  专为 64MB RAM VPS 优化 / Optimized for 64MB RAM VPS
#  https://github.com/YOUR_USERNAME/YOUR_REPO
#
#  本脚本支持带参数执行，不带参数将直接无敌
#  See --help for parameters
# ================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

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
    echo -e "  ${YELLOW}极限内存版 / Ultra-Low RAM Edition (64MB)${NC}"
    echo -e "  本脚本支持带参数执行，不带参数将直接无敌 / See ${CYAN}--help${NC} for parameters"
    echo ""
    # 显示当前内存状态
    local mem_total mem_free
    mem_total=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    mem_free=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    echo -e "  内存 / RAM: ${YELLOW}${mem_total}MB 总计 / Total${NC}  |  ${GREEN}${mem_free}MB 可用 / Free${NC}"
    echo ""
}

usage() {
    banner
    cat <<EOF
  ${BOLD}用法 / Usage:${NC}
    bash install-64mb.sh [选项]

  ${BOLD}选项 / Options:${NC}
    --port    PORT     监听端口     (默认随机)
    --domain  DOMAIN   伪装域名     (默认 www.apple.com)
    --uuid    UUID     自定义 UUID  (默认随机)
    --ver     VERSION  指定 Xray 版本 (如 1.8.13，默认最新)
    --uninstall        卸载
    --help             显示帮助

EOF
    exit 0
}

# ── 参数解析 ─────────────────────────────────────────────────
PORT=""; DOMAIN="www.apple.com"; UUID_CUSTOM=""; XRAY_VER=""; UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)      PORT="$2";        shift 2 ;;
        --domain)    DOMAIN="$2";      shift 2 ;;
        --uuid)      UUID_CUSTOM="$2"; shift 2 ;;
        --ver)       XRAY_VER="$2";    shift 2 ;;
        --uninstall) UNINSTALL=true;   shift   ;;
        --help|-h)   usage ;;
        *) die "未知参数: $1" ;;
    esac
done

START_TS=$(date +%s)
elapsed() { echo $(( $(date +%s) - START_TS )); }

# ── 必须 root ─────────────────────────────────────────────────
require_root() { [[ $EUID -eq 0 ]] || die "请以 root 运行 / Run as root"; }

# ── 检测系统 ─────────────────────────────────────────────────
detect_os() {
    if   [[ -f /etc/alpine-release ]]; then echo "alpine"
    elif [[ -f /etc/debian_version ]]; then echo "debian"
    elif [[ -f /etc/redhat-release ]]; then echo "redhat"
    else die "不支持的系统"; fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "64" ;;
        aarch64) echo "arm64-v8a" ;;
        armv7l)  echo "arm32-v7a" ;;
        *)       die "不支持的架构: $(uname -m)" ;;
    esac
}

# ── 极限内存：释放缓存 / Drop caches ─────────────────────────
drop_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

# ── 极限内存：最小化安装依赖 ─────────────────────────────────
step_tool_check() {
    info "工具链检查 / Tool check ..."
    drop_caches
    local os; os=$(detect_os)
    case "$os" in
        alpine)
            # Alpine 最省内存：只装必须的
            apk add --quiet --no-cache curl unzip >/dev/null 2>&1 || true
            ;;
        debian)
            # 最小化安装，不更新整个列表
            apt-get install -y -qq --no-install-recommends curl unzip >/dev/null 2>&1 || \
            { apt-get update -qq && apt-get install -y -qq --no-install-recommends curl unzip >/dev/null 2>&1; }
            ;;
        redhat)
            yum install -y -q curl unzip >/dev/null 2>&1 || true
            ;;
    esac
    ok "工具链检查 / Tool check ... [OK]"
}

# ── 获取 Xray 版本号 ─────────────────────────────────────────
get_xray_version() {
    if [[ -n "$XRAY_VER" ]]; then
        echo "$XRAY_VER"
        return
    fi
    # 不用 jq，直接 grep
    curl -fsSL --retry 3 --connect-timeout 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"v\([^"]*\)".*/\1/'
}

# ── 极限内存安装 Xray / Streaming install ────────────────────
step_install_xray() {
    info "开始，安装 XRAY / Install XRAY ..."
    drop_caches

    local arch; arch=$(detect_arch)
    local ver;  ver=$(get_xray_version)
    [[ -z "$ver" ]] && die "无法获取版本号 / Cannot fetch version"

    info "版本 / Version: v${ver}  架构 / Arch: ${arch}"

    local url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-${arch}.zip"
    local tmp="/tmp/xr"
    mkdir -p "$tmp"

    # 流式下载 + 解压，不落盘完整 zip（省内存）
    # 先尝试流式，失败则落盘
    if command -v unzip &>/dev/null; then
        curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "${tmp}/xray.zip" \
            || die "下载失败 / Download failed"
        unzip -q -o "${tmp}/xray.zip" xray -d "${tmp}/" 2>/dev/null \
            || unzip -q -o "${tmp}/xray.zip" -d "${tmp}/" >/dev/null 2>&1
    else
        die "unzip 未找到 / unzip not found"
    fi

    # 安装二进制
    install -m 755 "${tmp}/xray" /usr/local/bin/xray
    rm -rf "$tmp"
    drop_caches

    # geoip / geosite 使用轻量版（省磁盘和下载时间）
    local geodir="/usr/local/share/xray"
    mkdir -p "$geodir"
    for f in geoip.dat geosite.dat; do
        curl -fsSL --retry 2 --connect-timeout 10 \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/${f}" \
            -o "${geodir}/${f}" 2>/dev/null || warn "geodata ${f} 下载失败（跳过）"
    done

    # 验证
    /usr/local/bin/xray version 2>/dev/null | head -1 || die "Xray 安装验证失败"
    ok "开始，安装 XRAY / Install XRAY ... [OK]  (v${ver})"
}

# ── 生成工具 ─────────────────────────────────────────────────
gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || (command -v uuidgen &>/dev/null && uuidgen | tr '[:upper:]' '[:lower:]') \
        || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/'
}

gen_port() {
    local p
    while true; do
        p=$(awk 'BEGIN{srand();print int(rand()*55535)+10000}')
        # 不用 ss（某些精简系统没有），用 /proc/net
        grep -q ":$(printf '%04X' "$p") " /proc/net/tcp  2>/dev/null \
        || grep -q ":$(printf '%04X' "$p") " /proc/net/tcp6 2>/dev/null \
        || { echo "$p"; return; }
    done
}

get_ip() {
    SERVER_IP=$(
        curl -4fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null ||
        curl -4fsSL --connect-timeout 5 https://ifconfig.me  2>/dev/null ||
        ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' ||
        hostname -I 2>/dev/null | awk '{print $1}'
    )
}

gen_reality_keys() {
    local out; out=$(/usr/local/bin/xray x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$out" | awk '/Private/{print $NF}')
    PUBLIC_KEY=$(echo  "$out" | awk '/Public/{print $NF}')
    # Short ID：不依赖 openssl（某些精简系统没有）
    SHORT_ID=$(
        openssl rand -hex 8 2>/dev/null ||
        tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c16 ||
        awk 'BEGIN{srand();printf "%08x%08x\n",rand()*0xFFFFFFFF,rand()*0xFFFFFFFF}'
    )
}

# ── 写配置 / Write config ─────────────────────────────────────
step_write_config() {
    info "块好了，手搓 / Configuring /usr/local/etc/xray/config.json ..."
    drop_caches

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

# ── 服务配置（内存限制版）/ Systemd with memory limits ───────
step_install_service() {
    local os; os=$(detect_os)

    if [[ "$os" == "alpine" ]]; then
        # OpenRC（Alpine 无 systemd，更省内存）
        cat > /etc/init.d/xray <<'SVC'
#!/sbin/openrc-run
name="xray"
description="Xray VLESS Reality"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"
depend() { need net; }
SVC
        chmod +x /etc/init.d/xray
        rc-update add xray default >/dev/null 2>&1

    else
        # systemd：严格限制内存，防止 OOM
        cat > /etc/systemd/system/xray.service <<SVC
[Unit]
Description=Xray VLESS Reality (64MB Edition)
After=network.target nss-lookup.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=10s

# ── 内存限制 / Memory limits ──────────────────
MemoryMax=48M
MemoryHigh=40M
MemorySwapMax=0

# ── 安全加固 ──────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/log/xray /usr/local/etc/xray

# ── 文件描述符 ────────────────────────────────
LimitNOFILE=65535

StandardOutput=append:/var/log/xray/access.log
StandardError=append:/var/log/xray/error.log

[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
    fi
}

# ── 启动服务 / Start service ─────────────────────────────────
step_start_service() {
    info "冲刺，开启服务 / Starting Service ..."
    drop_caches
    local os; os=$(detect_os)
    if [[ "$os" == "alpine" ]]; then
        rc-service xray restart >/dev/null 2>&1
    else
        systemctl restart xray
    fi
    sleep 2
    ok "冲刺，开启服务 / Starting Service ... [OK]"
}

# ── BBR ───────────────────────────────────────────────────────
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

# ── 服务检查 / Check service ─────────────────────────────────
step_check_service() {
    info "检查服务状态 / Checking Service ..."
    local os; os=$(detect_os)
    local running=false
    if [[ "$os" == "alpine" ]]; then
        rc-service xray status 2>/dev/null | grep -q started && running=true
    else
        systemctl is-active --quiet xray && running=true
    fi
    if $running; then
        ok "检查服务状态 / Checking Service ... [OK]"
    else
        die "Xray 未运行 / Not running\n$(tail -20 /var/log/xray/error.log 2>/dev/null)"
    fi
}

# ── 防火墙 ────────────────────────────────────────────────────
open_firewall() {
    local p="$1"
    if   command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q active; then
        ufw allow "${p}/tcp" >/dev/null 2>&1 || true
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
    fi
}

# ── 卸载 ─────────────────────────────────────────────────────
do_uninstall() {
    banner
    warn "开始卸载 / Uninstalling ..."
    local os; os=$(detect_os)
    if [[ "$os" == "alpine" ]]; then
        rc-service xray stop 2>/dev/null || true
        rc-update del xray  2>/dev/null || true
        rm -f /etc/init.d/xray
    else
        systemctl stop    xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload
    fi
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray /var/log/xray /usr/local/share/xray
    ok "卸载完成 / Uninstall done"
    exit 0
}

# ── 输出结果 / Print result ───────────────────────────────────
print_result() {
    get_ip
    local link="vless://${UUID_CUSTOM}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#REALITY-${SERVER_IP}"

    # 安装后内存状态
    local mem_free; mem_free=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")

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
    echo -e "  ${CYAN}剩余内存 / Free RAM: ${GREEN}${mem_free}MB${NC}"
    echo -e "  ${CYAN}Xray 内存限制 / RAM cap: 48MB${NC}"
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
    drop_caches
    step_tool_check
    step_install_xray
    step_write_config
    step_install_service
    step_start_service
    step_enable_bbr
    open_firewall "$PORT"
    step_check_service
    print_result
}

main "$@"
