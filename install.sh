#!/bin/bash
# ================================================================
#  VLESS + REALITY + XRAY  NAT VPS 专版
#  针对 64MB RAM + NAT 端口转发 VPS 优化
#  https://github.com/YOUR_USERNAME/YOUR_REPO
#
#  本脚本支持带参数执行，不带参数将直接无敌
#  See --help for parameters
# ================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── 颜色 ─────────────────────────────────────────────────────
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
    echo -e "  ${YELLOW}NAT VPS 专版 / 64MB RAM Edition${NC}"
    echo -e "  本脚本支持带参数执行，不带参数将直接无敌 / See ${CYAN}--help${NC} for parameters"
    echo ""
    local mem_total mem_free
    mem_total=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    mem_free=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    echo -e "  内存 / RAM: ${YELLOW}${mem_total}MB 总计${NC}  |  ${GREEN}${mem_free}MB 可用${NC}"
    echo ""
}

usage() {
    banner
    cat <<EOF
  ${BOLD}用法 / Usage:${NC}
    bash install-nat.sh [选项]

  ${BOLD}选项 / Options:${NC}
    --ip      IP        NAT 外部公网 IP  (必填 / Required for NAT)
    --port    PORT      外部端口         (必填 / Required for NAT)
    --domain  DOMAIN    伪装域名         (默认 www.apple.com)
    --uuid    UUID      自定义 UUID      (默认随机)
    --ver     VERSION   指定 Xray 版本   (默认最新，如 1.8.13)
    --uninstall         卸载
    --help              显示帮助

  ${BOLD}示例 / Examples:${NC}
    bash install-nat.sh --ip 85.149.218.212 --port 14519
    bash install-nat.sh --ip 85.149.218.212 --port 14519 --domain www.bing.com

EOF
    exit 0
}

# ── 参数解析 ─────────────────────────────────────────────────
NAT_IP=""
PORT=""
DOMAIN="www.apple.com"
UUID_CUSTOM=""
XRAY_VER=""
UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)        NAT_IP="$2";      shift 2 ;;
        --port)      PORT="$2";        shift 2 ;;
        --domain)    DOMAIN="$2";      shift 2 ;;
        --uuid)      UUID_CUSTOM="$2"; shift 2 ;;
        --ver)       XRAY_VER="$2";    shift 2 ;;
        --uninstall) UNINSTALL=true;   shift   ;;
        --help|-h)   usage ;;
        *) die "未知参数: $1  使用 --help 查看帮助" ;;
    esac
done

START_TS=$(date +%s)
elapsed() { echo $(( $(date +%s) - START_TS )); }

# ── 检查 root ─────────────────────────────────────────────────
require_root() { [[ $EUID -eq 0 ]] || die "请以 root 运行 / Run as root"; }

# ── 检测系统 ─────────────────────────────────────────────────
detect_os() {
    if   [[ -f /etc/alpine-release ]]; then echo "alpine"
    elif [[ -f /etc/debian_version ]]; then echo "debian"
    elif [[ -f /etc/redhat-release ]]; then echo "redhat"
    else die "不支持的系统 / Unsupported OS"; fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "64" ;;
        aarch64) echo "arm64-v8a" ;;
        armv7l)  echo "arm32-v7a" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

# ── NAT VPS：交互输入 IP 和端口 ──────────────────────────────
prompt_nat_info() {
    # 如果参数已传入则跳过
    if [[ -z "$NAT_IP" ]]; then
        echo -e "  ${YELLOW}NAT VPS 需要手动输入外部公网 IP${NC}"
        read -rp "  外部公网 IP / Public IP (从面板获取): " NAT_IP
        [[ -z "$NAT_IP" ]] && die "IP 不能为空"
    fi
    if [[ -z "$PORT" ]]; then
        echo -e "  ${YELLOW}NAT VPS 需要手动输入外部端口${NC}"
        read -rp "  外部端口 / External Port (从面板获取): " PORT
        [[ -z "$PORT" ]] && die "端口不能为空"
    fi
    ok "NAT 配置: ${NAT_IP}:${PORT}"
}

# ── 释放内存缓存 ──────────────────────────────────────────────
drop_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

# ── 工具链检查（最小化）────────────────────────────────────────
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

# ── 获取 Xray 版本 ────────────────────────────────────────────
get_xray_version() {
    if [[ -n "$XRAY_VER" ]]; then
        echo "$XRAY_VER"; return
    fi
    curl -fsSL --retry 3 --connect-timeout 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"v\([^"]*\)".*/\1/'
}

# ── 安装 Xray（直接下 zip，不用官方脚本）────────────────────
step_install_xray() {
    info "开始，安装 XRAY / Install XRAY ..."
    drop_caches

    local arch; arch=$(detect_arch)
    local ver;  ver=$(get_xray_version)
    [[ -z "$ver" ]] && die "无法获取版本号 / Cannot fetch version"
    info "版本 v${ver}  架构 ${arch}"

    local url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-${arch}.zip"
    local tmp="/tmp/xr_$$"
    mkdir -p "$tmp"

    curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "${tmp}/xray.zip" \
        || die "下载失败 / Download failed: $url"

    unzip -q -o "${tmp}/xray.zip" xray -d "${tmp}/" 2>/dev/null \
        || unzip -q -o "${tmp}/xray.zip" -d "${tmp}/" >/dev/null 2>&1

    install -m 755 "${tmp}/xray" /usr/local/bin/xray
    rm -rf "$tmp"
    drop_caches

    # geodata（失败不阻断）
    local geodir="/usr/local/share/xray"
    mkdir -p "$geodir"
    for f in geoip.dat geosite.dat; do
        curl -fsSL --retry 2 --connect-timeout 15 \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/${f}" \
            -o "${geodir}/${f}" 2>/dev/null || warn "geodata ${f} 跳过"
    done

    /usr/local/bin/xray version 2>/dev/null | head -1 || die "Xray 二进制验证失败"
    ok "开始，安装 XRAY / Install XRAY ... [OK]  (v${ver})"
}

# ── 生成工具 ─────────────────────────────────────────────────
gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || (command -v uuidgen &>/dev/null && uuidgen | tr '[:upper:]' '[:lower:]') \
        || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/'
}

gen_reality_keys() {
    local out; out=$(/usr/local/bin/xray x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$out" | awk '/Private/{print $NF}')
    PUBLIC_KEY=$(echo  "$out" | awk '/Public/{print $NF}')
    SHORT_ID=$(
        openssl rand -hex 8 2>/dev/null ||
        tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c16 ||
        awk 'BEGIN{srand();printf "%08x",rand()*0xFFFFFFFF}'
    )
}

# ── 写配置（监听 0.0.0.0，NAT 穿透）────────────────────────
step_write_config() {
    info "块好了，手搓 / Configuring /usr/local/etc/xray/config.json ..."
    drop_caches

    [[ -z "$UUID_CUSTOM" ]] && UUID_CUSTOM=$(gen_uuid)
    gen_reality_keys

    mkdir -p /usr/local/etc/xray /var/log/xray

    # NAT VPS 关键点：
    # - listen 0.0.0.0 监听所有网卡
    # - port 用内部端口（NAT 面板已映射 外部PORT -> 内部PORT）
    # - dest 用伪装域名，不用真实 IP

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

# ── 安装服务（去掉内存硬限制）───────────────────────────────
step_install_service() {
    info "配置服务 / Configuring service ..."
    local os; os=$(detect_os)

    if [[ "$os" == "alpine" ]]; then
        cat > /etc/init.d/xray <<'SVC'
#!/sbin/openrc-run
name="xray"
description="Xray VLESS Reality NAT"
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
        # 注意：NAT VPS 64MB 不设内存硬限制，防止被压死
        # 用 soft 方式：只记录，不 OOM kill
        cat > /etc/systemd/system/xray.service <<SVC
[Unit]
Description=Xray VLESS Reality (NAT Edition)
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=10s

# ── 64MB NAT VPS：不设硬限制，防止端口监听失败 ──
# MemoryMax 已移除，改用软限制仅做监控
MemoryAccounting=yes

# ── 安全加固 ─────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/log/xray /usr/local/etc/xray

# ── 文件描述符 ────────────────────────────────────
LimitNOFILE=65535

StandardOutput=append:/var/log/xray/access.log
StandardError=append:/var/log/xray/error.log

[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
    fi

    ok "配置服务 / Configuring service ... [OK]"
}

# ── 启动服务 ─────────────────────────────────────────────────
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

# ── 服务检查 + 端口监听验证 ───────────────────────────────────
step_check_service() {
    info "检查服务状态 / Checking Service ..."
    local os; os=$(detect_os)
    local running=false

    if [[ "$os" == "alpine" ]]; then
        rc-service xray status 2>/dev/null | grep -q started && running=true
    else
        systemctl is-active --quiet xray && running=true
    fi

    $running || die "Xray 未运行\n$(tail -30 /var/log/xray/error.log 2>/dev/null)"

    # 验证端口是否真正监听
    sleep 1
    if grep -q ":$(printf '%04X' "$PORT") " /proc/net/tcp 2>/dev/null \
    || grep -q ":$(printf '%04X' "$PORT") " /proc/net/tcp6 2>/dev/null; then
        ok "检查服务状态 / Checking Service ... [OK]  端口 ${PORT} 监听正常"
    else
        warn "端口 ${PORT} 未见于 /proc/net/tcp，请检查日志"
        warn "$(tail -10 /var/log/xray/error.log 2>/dev/null)"
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

# ── 输出结果 ─────────────────────────────────────────────────
print_result() {
    # NAT VPS 用外部 IP 生成链接
    local link="vless://${UUID_CUSTOM}@${NAT_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#REALITY-${NAT_IP}"
    local mem_free; mem_free=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")

    echo ""
    echo -e "${GREEN}舒服了 / Done:${NC}"
    echo ""
    echo -e "  ${PINK}${link}${NC}"
    echo ""
    echo -e "  外部地址 / Public IP :  ${YELLOW}${NAT_IP}${NC}"
    echo -e "  端口     / Port      :  ${YELLOW}${PORT}${NC}"
    echo -e "  UUID                 :  ${YELLOW}${UUID_CUSTOM}${NC}"
    echo -e "  SNI                  :  ${YELLOW}${DOMAIN}${NC}"
    echo -e "  PublicKey            :  ${YELLOW}${PUBLIC_KEY}${NC}"
    echo -e "  ShortID              :  ${YELLOW}${SHORT_ID}${NC}"
    echo -e "  Flow                 :  ${YELLOW}xtls-rprx-vision${NC}"
    echo ""
    echo -e "  ${CYAN}剩余内存 / Free RAM: ${GREEN}${mem_free}MB${NC}  ${DIM}(无内存硬限制)${NC}"
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
    prompt_nat_info
    drop_caches
    step_tool_check
    step_install_xray
    step_write_config
    step_install_service
    step_start_service
    step_enable_bbr
    step_check_service
    print_result
}

main "$@"
