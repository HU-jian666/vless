#!/bin/bash
# ============================================================
# VLESS + REALITY + XRAY
# LOW MEMORY EDITION
# 适用于 64MB / 128MB / 256MB VPS
# 无 Swap / 容器 / NAT VPS 兼容
#
# Usage:
# bash install.sh
# bash install.sh --port 443
# bash install.sh --domain www.apple.com
# bash install.sh --port 443 --domain www.apple.com
# bash install.sh --uninstall
# ============================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PINK='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

START_TIME=$(date +%s)

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

info() {
    echo -e "${CYAN}[..]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[!!]${NC} $*"
}

die() {
    echo -e "${RED}[ERR]${NC} $*"
    exit 1
}

trap 'echo -e "\n${RED}[ERR]${NC} 脚本在第 ${LINENO} 行退出"' ERR

# ============================================================
# Banner
# ============================================================

banner() {
cat <<'EOF'

  __   ___    ___  ___ ___   ___  ___ _   _   ___ ___ ___
  \ \ / / |  | __|| __/ __| | _ \| __/_\ | | |_ _|_ _\ \ /
   \ V /| |__| _| | _|\__ \ |   /| _/ _ \| |  | | | | \ V /
    \_/ |____|___||___|___/ |_|_\|_/_/ \_\_| |___|___| \_/

                  XRAY-CORE · VLESS · REALITY
                       LOW MEMORY EDITION

  64MB / 128MB / 256MB
  NO GEODATA · NO LOG · NO SWAP REQUIRED

EOF

echo -e "${PINK}  Xray official installer${NC}"
echo "  ───────────────────────────────────────────────"
}

# ============================================================
# Variables
# ============================================================

PORT=""
DOMAIN="www.apple.com"
UUID=""
UNINSTALL=false

# ============================================================
# Arguments
# ============================================================

while [[ $# -gt 0 ]]; do

    case "$1" in

        --port)
            [[ $# -ge 2 ]] || die "--port 缺少参数"
            PORT="$2"
            shift 2
            ;;

        --domain)
            [[ $# -ge 2 ]] || die "--domain 缺少参数"
            DOMAIN="$2"
            shift 2
            ;;

        --uuid)
            [[ $# -ge 2 ]] || die "--uuid 缺少参数"
            UUID="$2"
            shift 2
            ;;

        --uninstall)
            UNINSTALL=true
            shift
            ;;

        --help|-h)

            banner

            cat <<EOF

用法:

  bash install.sh

指定端口:

  bash install.sh --port 443

指定 REALITY SNI:

  bash install.sh --domain www.apple.com

指定 UUID:

  bash install.sh --uuid YOUR-UUID

卸载:

  bash install.sh --uninstall

EOF
            exit 0
            ;;

        *)
            die "未知参数: $1"
            ;;

    esac

done

# ============================================================
# Root
# ============================================================

require_root() {

    [[ "$EUID" -eq 0 ]] || die "必须使用 root 运行"

}

# ============================================================
# Memory detection
# ============================================================

detect_memory() {

    local mem

    mem=$(awk '/MemTotal:/ {
        printf "%d", $2/1024
    }' /proc/meminfo 2>/dev/null || echo 0)

    [[ "$mem" =~ ^[0-9]+$ ]] || mem=0

    echo "$mem"
}

# ============================================================
# Cgroup memory detection
# ============================================================

detect_cgroup_memory() {

    local limit=""

    # cgroup v2
    if [[ -f /sys/fs/cgroup/memory.max ]]; then

        limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)

        if [[ "$limit" != "max" && "$limit" =~ ^[0-9]+$ ]]; then
            echo $((limit / 1024 / 1024))
            return
        fi

    fi

    # cgroup v1
    if [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then

        limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)

        if [[ "$limit" =~ ^[0-9]+$ ]]; then

            # Ignore unrealistic huge values
            if (( limit < 9223372036854771712 )); then
                echo $((limit / 1024 / 1024))
                return
            fi

        fi

    fi

    echo 0
}

# ============================================================
# Memory information
# ============================================================

memory_check() {

    local mem
    local cg

    mem=$(detect_memory)
    cg=$(detect_cgroup_memory)

    info "检测物理/容器内存: ${mem}MB"

    if (( cg > 0 )); then
        info "检测 cgroup 内存限制: ${cg}MB"
    else
        info "未检测到有效 cgroup 内存限制"
    fi

    if (( mem <= 96 )); then
        warn "极低内存模式: ${mem}MB"
    elif (( mem <= 192 )); then
        warn "低内存模式: ${mem}MB"
    else
        ok "内存环境: ${mem}MB"
    fi

}

# ============================================================
# Tool check
# ============================================================

install_package() {

    local os="$1"
    shift

    case "$os" in

        debian)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install \
                -y \
                -qq \
                "$@"

            ;;

        redhat)

            yum install \
                -y \
                -q \
                "$@"

            ;;

        alpine)

            apk add \
                --quiet \
                "$@"

            ;;

        *)

            die "无法识别系统"

            ;;

    esac

}

detect_os() {

    if [[ -f /etc/debian_version ]]; then
        echo "debian"
        return
    fi

    if [[ -f /etc/redhat-release ]]; then
        echo "redhat"
        return
    fi

    if [[ -f /etc/alpine-release ]]; then
        echo "alpine"
        return
    fi

    die "不支持的 Linux 系统"

}

check_tools() {

    info "检查工具链..."

    local missing=()
    local cmd

    for cmd in curl unzip openssl awk sed grep; do

        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi

    done

    if (( ${#missing[@]} > 0 )); then

        local os
        os=$(detect_os)

        info "安装缺失工具: ${missing[*]}"

        install_package "$os" "${missing[@]}"

    fi

    ok "工具链检查完成"

}

# ============================================================
# UUID
# ============================================================

gen_uuid() {

    if command -v uuidgen >/dev/null 2>&1; then

        uuidgen | tr '[:upper:]' '[:lower:]'
        return

    fi

    if [[ -r /proc/sys/kernel/random/uuid ]]; then

        cat /proc/sys/kernel/random/uuid
        return

    fi

    die "无法生成 UUID"

}

# ============================================================
# Port
# ============================================================

gen_port() {

    local p

    if ! command -v ss >/dev/null 2>&1; then

        echo "443"
        return

    fi

    while true; do

        p=$(
            awk '
            BEGIN {
                srand()
                print int(rand()*55535)+10000
            }'
        )

        if ! ss -lnt 2>/dev/null |
            awk '{print $4}' |
            grep -Eq "[:.]${p}$"; then

            echo "$p"
            return

        fi

    done

}

validate_port() {

    [[ "$PORT" =~ ^[0-9]+$ ]] ||
        die "端口必须是数字"

    (( PORT >= 1 && PORT <= 65535 )) ||
        die "端口范围必须为 1-65535"

}

# ============================================================
# Swap
# ============================================================

setup_swap() {

    info "检查 Swap..."

    if command -v swapon >/dev/null 2>&1; then

        if swapon --show 2>/dev/null |
            grep -q .; then

            ok "检测到已有 Swap"
            return 0

        fi

    fi

    warn "没有可用 Swap"

    # 不强制创建 Swap
    # 很多 NAT/OpenVZ/LXC 无法创建 Swap
    # 避免安装阶段 dd/fallocate 产生额外 I/O 和内存压力

    warn "跳过创建 Swap，使用纯低内存模式"

}

# ============================================================
# Xray installation
# Official installer + without geodata
# ============================================================

install_xray() {

    info "开始安装 Xray..."

    local installer="/tmp/xray-install.sh"

    rm -f "$installer"

    curl \
        -fL \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 10 \
        --max-time 120 \
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
        -o "$installer"

    chmod 700 "$installer"

    # 关键：
    # --without-geodata
    #
    # 避免下载 geoip.dat / geosite.dat
    # 降低安装时间、磁盘占用以及运行时内存压力

    if ! bash "$installer" install --without-geodata; then

        warn "Xray 安装失败"

        echo ""
        echo "最近的安装日志:"
        journalctl -n 30 --no-pager 2>/dev/null || true

        die "Xray 安装失败，请检查网络或系统环境"

    fi

    rm -f "$installer"

    [[ -x /usr/local/bin/xray ]] ||
        die "Xray 二进制文件不存在"

    ok "Xray 安装完成"

}

# ============================================================
# Generate Reality keys
# ============================================================

gen_keys() {

    info "生成 REALITY 密钥..."

    local tmp

    tmp=$(
        /usr/local/bin/xray x25519 2>/dev/null
    ) || die "REALITY 密钥生成失败"

    PRIVATE_KEY=$(
        echo "$tmp" |
        awk '/Private/ {print $NF; exit}'
    )

    PUBLIC_KEY=$(
        echo "$tmp" |
        awk '/Public/ {print $NF; exit}'
    )

    [[ -n "$PRIVATE_KEY" ]] ||
        die "Private Key 生成失败"

    [[ -n "$PUBLIC_KEY" ]] ||
        die "Public Key 生成失败"

    if command -v openssl >/dev/null 2>&1; then

        SHORT_ID=$(
            openssl rand -hex 8
        )

    else

        SHORT_ID=$(
            od -An -N8 -tx1 /dev/urandom |
            tr -d ' \n'
        )

    fi

    ok "REALITY 密钥生成完成"

}

# ============================================================
# Config
# ============================================================

write_config() {

    info "生成 Xray 配置..."

    [[ -n "$UUID" ]] || UUID=$(gen_uuid)

    [[ -n "$PORT" ]] || PORT=$(gen_port)

    validate_port

    gen_keys

    mkdir -p /usr/local/etc/xray

    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "none"
  },

  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",

      "settings": {
        "clients": [
          {
            "id": "${UUID}",
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
          "serverNames": [
            "${DOMAIN}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },

      "sniffing": {
        "enabled": false
      }
    }
  ],

  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },

    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

    chmod 600 /usr/local/etc/xray/config.json

    ok "Xray 配置完成"

}

# ============================================================
# Validate Xray config
# ============================================================

validate_config() {

    info "检查 Xray 配置..."

    if ! /usr/local/bin/xray \
        run \
        -test \
        -config /usr/local/etc/xray/config.json; then

        die "Xray 配置检查失败"

    fi

    ok "Xray 配置检查通过"

}

# ============================================================
# systemd memory protection
# ============================================================

write_systemd_override() {

    if ! command -v systemctl >/dev/null 2>&1; then

        warn "没有 systemctl，跳过 systemd 内存保护"

        return 0

    fi

    if [[ ! -d /run/systemd/system ]]; then

        warn "当前系统不是 systemd，跳过内存限制"

        return 0

    fi

    info "配置 Xray 内存保护..."

    mkdir -p /etc/systemd/system/xray.service.d

    cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]

# 自动重启
Restart=always
RestartSec=2

# 尽量保护整台 VPS
MemoryHigh=44M
MemoryMax=48M

# Xray 超过限制后不要影响 systemd
OOMPolicy=stop

# 限制文件句柄
LimitNOFILE=32768
EOF

    systemctl daemon-reload

    ok "Xray 内存保护已配置"

}

# ============================================================
# Start service
# ============================================================

start_service() {

    info "启动 Xray..."

    if ! command -v systemctl >/dev/null 2>&1; then

        die "当前系统没有 systemctl"

    fi

    systemctl daemon-reload

    systemctl enable xray >/dev/null 2>&1 || true

    systemctl restart xray

    sleep 1

    if systemctl is-active --quiet xray; then

        ok "Xray 已启动"

    else

        echo ""

        journalctl \
            -u xray \
            -n 30 \
            --no-pager \
            2>/dev/null || true

        die "Xray 启动失败"

    fi

}

# ============================================================
# BBR
# ============================================================

enable_bbr() {

    info "检查 BBR..."

    local current=""

    current=$(
        sysctl \
            -n \
            net.ipv4.tcp_congestion_control \
            2>/dev/null || true
    )

    if [[ "$current" == "bbr" ]]; then

        ok "BBR 已启用"
        return

    fi

    if sysctl \
        -w \
        net.ipv4.tcp_congestion_control=bbr \
        >/dev/null 2>&1; then

        echo \
            'net.ipv4.tcp_congestion_control=bbr' \
            >> /etc/sysctl.conf 2>/dev/null || true

        ok "BBR 已启用"

    else

        warn "当前 VPS/容器不允许启用 BBR，跳过"

    fi

}

# ============================================================
# Firewall
# ============================================================

open_firewall() {

    info "检查防火墙..."

    if command -v ufw >/dev/null 2>&1; then

        if ufw status 2>/dev/null |
            grep -q "Status: active"; then

            ufw allow "${PORT}/tcp" \
                >/dev/null 2>&1 || true

            ok "UFW 已放行 ${PORT}/tcp"

            return

        fi

    fi

    if command -v firewall-cmd >/dev/null 2>&1; then

        if firewall-cmd --state >/dev/null 2>&1; then

            firewall-cmd \
                --permanent \
                --add-port="${PORT}/tcp" \
                >/dev/null 2>&1 || true

            firewall-cmd \
                --reload \
                >/dev/null 2>&1 || true

            ok "Firewalld 已放行 ${PORT}/tcp"

            return

        fi

    fi

    if command -v iptables >/dev/null 2>&1; then

        iptables \
            -C INPUT \
            -p tcp \
            --dport "$PORT" \
            -j ACCEPT \
            >/dev/null 2>&1 || {

            iptables \
                -I INPUT \
                -p tcp \
                --dport "$PORT" \
                -j ACCEPT \
                >/dev/null 2>&1 || true

        }

        ok "iptables 已处理 ${PORT}/tcp"

        return

    fi

    warn "没有检测到可用防火墙"

}

# ============================================================
# Get IP
# ============================================================

get_ip() {

    SERVER_IP=$(
        curl \
            -4fsSL \
            --connect-timeout 5 \
            --max-time 10 \
            https://api.ipify.org \
            2>/dev/null || true
    )

    if [[ -z "$SERVER_IP" ]]; then

        SERVER_IP=$(
            hostname -I 2>/dev/null |
            awk '{print $1}'
        )

    fi

    [[ -n "$SERVER_IP" ]] ||
        SERVER_IP="YOUR_SERVER_IP"

}

# ============================================================
# Share link
# ============================================================

gen_share_link() {

    get_ip

    SHARE_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#REALITY-${SERVER_IP}"

}

# ============================================================
# Service memory
# ============================================================

show_memory() {

    if command -v systemctl >/dev/null 2>&1; then

        echo ""

        info "Xray 当前资源占用:"

        systemctl \
            show xray \
            -p MemoryCurrent \
            -p MemoryPeak \
            -p TasksCurrent \
            2>/dev/null || true

    fi

}

# ============================================================
# Result
# ============================================================

print_result() {

    local elapsed

    elapsed=$(
        echo "$(date +%s) - ${START_TIME}" |
        bc 2>/dev/null || echo "N/A"
    )

    echo ""

    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}              Xray 安装完成${NC}"
    echo -e "${GREEN}==================================================${NC}"

    echo ""

    echo "服务器地址 : $SERVER_IP"
    echo "端口       : $PORT"
    echo "UUID       : $UUID"
    echo "Flow       : xtls-rprx-vision"
    echo "SNI        : $DOMAIN"
    echo "Public Key : $PUBLIC_KEY"
    echo "Short ID   : $SHORT_ID"

    echo ""

    echo -e "${BOLD}VLESS 分享链接:${NC}"
    echo ""

    echo "$SHARE_LINK"

    echo ""

    echo -e "${GREEN}==================================================${NC}"
    echo "低内存模式 : ENABLED"
    echo "GeoIP      : DISABLED"
    echo "GeoSite    : DISABLED"
    echo "Xray 日志  : DISABLED"
    echo "Swap       : 不强制创建"
    echo "自动重启   : ENABLED"
    echo "MemoryMax  : 48M (best effort)"
    echo -e "${GREEN}==================================================${NC}"

    echo ""

    show_memory

    echo ""

    echo "安装完成。"
    echo ""

}

# ============================================================
# Uninstall
# ============================================================

do_uninstall() {

    banner

    echo ""

    warn "开始卸载 Xray..."

    if command -v systemctl >/dev/null 2>&1; then

        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true

    fi

    local installer="/tmp/xray-remove.sh"

    if curl \
        -fL \
        --retry 2 \
        --connect-timeout 10 \
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
        -o "$installer" 2>/dev/null; then

        bash "$installer" remove --purge || true

        rm -f "$installer"

    fi

    rm -rf \
        /etc/systemd/system/xray.service.d \
        /usr/local/etc/xray \
        /var/log/xray

    systemctl daemon-reload 2>/dev/null || true

    ok "Xray 已卸载"

    exit 0

}

# ============================================================
# Main
# ============================================================

main() {

    require_root

    banner

    echo ""

    if [[ "$UNINSTALL" == true ]]; then

        do_uninstall

    fi

    memory_check

    check_tools

    setup_swap

    install_xray

    write_config

    validate_config

    write_systemd_override

    start_service

    enable_bbr

    open_firewall

    gen_share_link

    print_result

}

main "$@"
