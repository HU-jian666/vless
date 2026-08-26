#!/bin/bash
# ================================================================
#  VLESS + REALITY + XRAY  NAT VPS 全自动版
#  64MB RAM + NAT 端口转发 · 复制链接即用
#  https://github.com/YOUR_USERNAME/YOUR_REPO
# ================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; PINK='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
info() { echo -e "${CYAN}[..]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

START_TS=$(date +%s)
elapsed() { echo $(( $(date +%s) - START_TS )); }

require_root() { [[ $EUID -eq 0 ]] || die "请以 root 运行 / Run as root"; }

# ── 检测系统和架构 ────────────────────────────────────────────
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
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

# ── 释放内存 ──────────────────────────────────────────────────
drop_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

# ── 全自动获取 NAT 公网 IP ────────────────────────────────────
# NAT VPS 本机 IP 是内网，需从外部服务获取宿主机公网 IP
get_nat_ip() {
    info "自动获取公网 IP / Detecting public IP ..."
    PUBLIC_IP=""
    for api in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://ifconfig.me" \
        "https://api4.my-ip.io/ip" \
        "https://ipecho.net/plain"; do
        PUBLIC_IP=$(curl -4fsSL --connect-timeout 5 --retry 2 "$api" 2>/dev/null | tr -d '[:space:]')
        # 验证是合法 IP
        if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ok "公网 IP / Public IP: ${PUBLIC_IP}"
            return
        fi
    done
    die "无法自动获取公网 IP，请检查网络 / Cannot detect public IP"
}

# ── 全自动检测可用端口 ────────────────────────────────────────
# NAT VPS：检测 /proc/net/tcp 确认端口未被占用
get_free_port() {
    local p
    while true; do
        p=$(awk 'BEGIN{srand();print int(rand()*55535)+10000}')
        grep -q ":$(printf '%04X' "$p") " /proc/net/tcp  2>/dev/null && continue
        grep -q ":$(printf '%04X' "$p") " /proc/net/tcp6 2>/dev/null && continue
        echo "$p"; return
    done
}

# ── 工具链（最小化安装）──────────────────────────────────────
step_tool_check() {
    info "工具链检查 / Tool check ..."
    drop_caches
    local os; os=$(detect_os)
    case "$os" in
        alpine) apk add --quiet --no-cache curl unzip >/dev/null 2>&1 ;;
        debian)
            apt-get install -y -qq --no-install-recommends curl unzip >/dev/null 2>&1 || \
            { apt-get update -qq; apt-get install -y -qq --no-install-recommends curl unzip >/dev/null 2>&1; }
            ;;
        redhat) yum install -y -q curl unzip >/dev/null 2>&1 ;;
    esac
    ok "工具链检查 / Tool check ... [OK]"
}

# ── 安装 Xray（直接下 zip，不跑官方脚本）────────────────────
step_install_xray() {
    info "开始，安装 XRAY / Install XRAY ..."
    drop_caches

    local arch; arch=$(detect_arch)
    local ver
    ver=$(curl -fsSL --retry 3 --connect-timeout 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
    [[ -z "$ver" ]] && die "无法获取版本号"

    local url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-${arch}.zip"
    local tmp="/tmp/xr_$$"
    mkdir -p "$tmp"

    curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "${tmp}/xray.zip" \
        || die "下载失败 / Download failed"

    unzip -q -o "${tmp}/xray.zip" xray -d "${tmp}/" 2>/dev/null || \
        unzip -q -o "${tmp}/xray.zip" -d "${tmp}/" >/dev/null 2>&1

    install -m 755 "${tmp}/xray" /usr/local/bin/xray
    rm -rf "$tmp"
    drop_caches

    # geodata（失败不阻断）
    mkdir -p /usr/local/share/xray
    for f in geoip.dat geosite.dat; do
        curl -fsSL --retry 2 --connect-timeout 15 \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/${f}" \
            -o "/usr/local/share/xray/${f}" 2>/dev/null || warn "geodata ${f} 跳过"
    done

    /usr/local/bin/xray version 2>/dev/null | head -1 || die "Xray 验证失败"
    ok "开始，安装 XRAY / Install XRAY ... [OK]  (v${ver})"
}

# ── 生成配置所需参数 ──────────────────────────────────────────
gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/'
}

gen_reality_keys() {
    local out; out=$(/usr/local/bin/xray x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$out" | awk '/Private/{print $NF}')
    PUBLIC_KEY=$(echo  "$out" | awk '/Public/{print $NF}')
    SHORT_ID=$(openssl rand -hex 8 2>/dev/null \
        || tr -dc 'a-f0-9' </dev/urandom | head -c16)
}

# ── 写配置 ────────────────────────────────────────────────────
step_write_config() {
    info "块好了，手搓 / Configuring /usr/local/etc/xray/config.json ..."
    drop_caches

    UUID=$(gen_uuid)
    PORT=$(get_free_port)
    DOMAIN="www.apple.com"
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
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
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

# ── 安装系统服务（无内存硬限制）─────────────────────────────
step_install_service() {
    info "配置开机自启 / Configuring autostart ..."
    local os; os=$(detect_os)

    if [[ "$os" == "alpine" ]]; then
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
        cat > /etc/systemd/system/xray.service <<SVC
[Unit]
Description=Xray VLESS Reality
After=network.target nss-lookup.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/log/xray /usr/local/etc/xray
StandardOutput=append:/var/log/xray/access.log
StandardError=append:/var/log/xray/error.log

[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
    fi

    ok "配置开机自启 / Configuring autostart ... [OK]"
}

# ── 启动服务 ──────────────────────────────────────────────────
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

# ── 开启 BBR ──────────────────────────────────────────────────
step_enable_bbr() {
    info "最后，打开 BBR / Finishing, Enabling BBR ..."
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        { echo 'net.core.default_qdisc=fq'
          echo 'net.ipv4.tcp_congestion_control=bbr'; } >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1 || true
    fi
    ok "最后，打开 BBR / Finishing, Enabling BBR ... [OK]"
}

# ── 服务 + 端口验证 ───────────────────────────────────────────
step_check_service() {
    info "检查服务状态 / Checking Service ..."
    local os; os=$(detect_os)
    local ok_flag=false

    if [[ "$os" == "alpine" ]]; then
        rc-service xray status 2>/dev/null | grep -q started && ok_flag=true
    else
        systemctl is-active --quiet xray && ok_flag=true
    fi

    $ok_flag || die "Xray 未运行\n$(tail -20 /var/log/xray/error.log 2>/dev/null)"

    # 端口是否监听
    sleep 1
    if grep -q ":$(printf '%04X' "$PORT") " /proc/net/tcp  2>/dev/null \
    || grep -q ":$(printf '%04X' "$PORT") " /proc/net/tcp6 2>/dev/null; then
        ok "检查服务状态 / Checking Service ... [OK]  (端口 ${PORT} 已监听)"
    else
        warn "端口 ${PORT} 暂未出现在 /proc/net/tcp，请稍候再确认"
    fi
}

# ── NAT 端口转发提示 ──────────────────────────────────────────
nat_remind() {
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠ NAT VPS 必须在面板添加端口转发规则：${NC}"
    echo -e "  ${BOLD}协议${NC}: TCP"
    echo -e "  ${BOLD}外部端口${NC}: ${YELLOW}${PORT}${NC}  →  ${BOLD}内部端口${NC}: ${YELLOW}${PORT}${NC}"
    echo -e "  ${BOLD}（如已添加请忽略）${NC}"
    echo ""
}

# ── 输出最终链接 ──────────────────────────────────────────────
print_result() {
    local LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#REALITY-${PUBLIC_IP}"

    echo ""
    echo -e "${GREEN}舒服了 / Done:${NC}"
    echo ""
    echo -e "  ${PINK}${LINK}${NC}"
    echo ""
    echo -e "  地址  / Address  :  ${YELLOW}${PUBLIC_IP}${NC}"
    echo -e "  端口  / Port     :  ${YELLOW}${PORT}${NC}"
    echo -e "  UUID             :  ${YELLOW}${UUID}${NC}"
    echo -e "  SNI              :  ${YELLOW}${DOMAIN}${NC}"
    echo -e "  PublicKey        :  ${YELLOW}${PUBLIC_KEY}${NC}"
    echo -e "  ShortID          :  ${YELLOW}${SHORT_ID}${NC}"
    echo -e "  Flow             :  ${YELLOW}xtls-rprx-vision${NC}"
    echo ""
    echo -e "  ${CYAN}剩余内存 / Free RAM: $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)MB${NC}"
    echo ""
    echo -e "总用时 / Elapsed Time:  ${GREEN}$(elapsed) 秒${NC}"
    echo -e "${CYAN}---------- live free or die hard ----------${NC}"
    echo ""
}

# ── 主流程 ────────────────────────────────────────────────────
main() {
    require_root
    echo ""
    echo -e "  ${PINK}https://github.com/YOUR_USERNAME/YOUR_REPO${NC}"
    echo -e "  ${YELLOW}NAT VPS 全自动版 / 64MB RAM · 复制链接即用${NC}"
    echo ""

    drop_caches
    get_nat_ip          # 全自动获取公网 IP
    step_tool_check
    step_install_xray
    step_write_config   # 内部自动生成 UUID、端口、密钥
    step_install_service
    step_start_service
    step_enable_bbr
    step_check_service
    nat_remind          # 提示面板加端口转发
    print_result        # 输出完整可用链接
}

main "$@"
