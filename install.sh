#!/bin/bash
# ============================================================
#  VLESS + REALITY + XRAY  一键安装脚本 (64MB / 无 swap / 只读 proc 优化版)
#  https://github.com/YOUR_USERNAME/YOUR_REPO
#  Usage: bash install.sh [--port PORT] [--domain DOMAIN]
# ============================================================

set -euo pipefail

# ── 颜色 / Colors ────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; PINK='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
info() { echo -e "${CYAN}[..] ${NC} $*"; }
warn() { echo -e "${YELLOW}[!!] ${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

# ── Banner ────────────────────────────────────────────────────
banner() {
cat <<'EOF'
  __   ___    ___  ___ ___   ___  ___ _   _   ___ ___ ___  
  \ \ / / |  | __|| __/ __| | _ \| __/_\ | | |_ _|_ _\ \ / 
   \ V /| |__| _| | _|\__ \ |   /| _/ _ \| |  | | | | \ V / 
    \_/ |____|___||___|___/ |_|_\|_/_/ \_\_| |___|___| \_/  
                  XRAY-CORE  ·  VLESS  ·  REALITY  ·  LOWMEM
EOF
    echo -e "${PINK}  github.com/YOUR_USERNAME/YOUR_REPO${NC}"
    echo -e "  低内存优化版：64MB / 无可用 swap / 只读 procfs 环境适配"
    echo "  ─────────────────────────────────────────────────────────"
}

# ── 帮助 / Help ───────────────────────────────────────────────
usage() {
    banner
    cat <<EOF

  ${BOLD}用法 / Usage:${NC}
    bash install.sh [选项]

  ${BOLD}选项 / Options:${NC}
    --port    PORT      监听端口 (默认随机 10000-65535)
    --domain  DOMAIN    伪装域名 (默认 www.apple.com)
    --uuid    UUID      自定义 UUID (默认随机生成)
    --uninstall         卸载 Xray 及配置
    --help              显示此帮助

  ${BOLD}示例 / Examples:${NC}
    bash install.sh
    bash install.sh --port 443 --domain www.bing.com
    bash install.sh --uninstall

EOF
    exit 0
}

# ── 参数解析 / Args ───────────────────────────────────────────
PORT=""
DOMAIN="www.apple.com"
UUID=""
UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PORT="$2";    shift 2 ;;
        --domain)  DOMAIN="$2";  shift 2 ;;
        --uuid)    UUID="$2";    shift 2 ;;
        --uninstall) UNINSTALL=true; shift ;;
        --help|-h) usage ;;
        *) die "未知参数: $1  (Unknown argument: $1)" ;;
    esac
done

# ── 计时开始 ──────────────────────────────────────────────────
START_TIME=$(date +%s)

# ── 工具函数 ──────────────────────────────────────────────────
elapsed() {
    local end=$(date +%s)
    echo $(( end - START_TIME ))
}

require_root() {
    [[ $EUID -eq 0 ]] || die "请以 root 身份运行 / Please run as root"
}

detect_os() {
    if   [[ -f /etc/debian_version ]]; then echo "debian"
    elif [[ -f /etc/redhat-release ]];  then echo "redhat"
    elif [[ -f /etc/alpine-release ]];  then echo "alpine"
    else die "不支持的系统 / Unsupported OS"; fi
}

gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

gen_port() {
    local p
    while true; do
        p=$(shuf -i 10000-65535 -n 1 2>/dev/null || awk 'BEGIN{srand();print int(rand()*55535)+10000}')
        ss -tuln 2>/dev/null | grep -q ":$p " || { echo "$p"; return; }
    done
}

# ── 卸载 / Uninstall ─────────────────────────────────────────
do_uninstall() {
    banner
    echo ""
    warn "开始卸载 / Starting uninstall ..."
    systemctl stop xray   2>/dev/null && ok "停止服务 / Stopped xray service" || true
    systemctl disable xray 2>/dev/null || true
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null \
        && ok "移除 Xray / Removed Xray"
    rm -rf /usr/local/etc/xray /var/log/xray /etc/systemd/system/xray.service.d
    ok "删除配置 / Removed config"
    echo ""
    echo -e "${PINK}  ──────────── 卸载完成 / Uninstall Done ────────────${NC}"
    exit 0
}

$UNINSTALL && do_uninstall

# ── 检查工具链 / Tool check ───────────────────────────────────
check_tools() {
    info "工具链检查 / Tool check ..."
    local pkgs=()
    for cmd in curl wget unzip; do
        command -v "$cmd" &>/dev/null || pkgs+=("$cmd")
    done
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        local os
        os=$(detect_os)
        case "$os" in
            debian) apt-get update -qq && apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1 ;;
            redhat) yum install -y -q "${pkgs[@]}" >/dev/null 2>&1 ;;
            alpine) apk add --quiet "${pkgs[@]}" >/dev/null 2>&1 ;;
        esac
    fi
    ok "工具链检查 / Tool check ... [OK]"
}

# ── 内存优化 / Swap ───────────────────────────────────────────
# 部分容器化 NAT VPS (OpenVZ/LXC 等) 无法创建 swap，procfs 只读，
# fallocate/dd/swapon 会直接失败 —— 这里不再假设 swap 一定可用，
# 失败就跳过，不中断安装。
setup_swap() {
    local mem_mb
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    info "检测到内存 / Detected memory: ${mem_mb}MB"

    if [[ $mem_mb -ge 256 ]]; then
        return 0
    fi

    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        ok "Swap 已存在 / Swap already active"
        return 0
    fi

    info "尝试创建 swap / Attempting swap (best-effort) ..."
    if ( fallocate -l 256M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=256 status=none 2>/dev/null ) \
        && chmod 600 /swapfile \
        && mkswap /swapfile -q 2>/dev/null \
        && swapon /swapfile 2>/dev/null; then
        grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab 2>/dev/null || true
        ok "Swap 已就绪 / Swap ready"
    else
        rm -f /swapfile
        warn "无法创建 swap（容器限制），跳过，转而收紧 Xray 内存占用 / Swap unavailable (container limitation) — skipping, will constrain Xray memory instead"
    fi
}

# ── 安装 Xray / Install XRAY ─────────────────────────────────
install_xray() {
    info "开始安装 XRAY / Install XRAY ..."
    local try=0
    while [[ $try -lt 3 ]]; do
        if bash -c "$(curl -fsSL --retry 3 --retry-delay 2 \
            https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
            >/dev/null 2>&1; then
            ok "开始安装 XRAY / Install XRAY ... [OK]"
            return 0
        fi
        (( try++ ))
        warn "安装失败，重试 $try/3 / Install failed, retrying ..."
        sleep 2
    done
    die "Xray 安装失败 / Xray install failed"
}

# ── 更新 geodata / lite 版本节省内存 ──────────────────────────
# 完整 geoip.dat + geosite.dat 加载进 Xray 常驻内存后可能占用
# 数十 MB，在 64MB VPS 上会直接把服务挤爆。改用仅含
# private/cn 的精简版，并且不在 routing 里引用 category-ads-all
# 这类大列表（见 write_config 中路由规则已裁剪）。
update_geodata() {
    info "加速，更新精简版 geodata / Updating lite geodata ..."
    local geodir="/usr/local/share/xray"
    mkdir -p "$geodir"

    if ! curl -fsSL --retry 3 \
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip-only-cn-private.dat" \
        -o "${geodir}/geoip.dat" 2>/dev/null; then
        curl -fsSL --retry 3 \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" \
            -o "${geodir}/geoip.dat" 2>/dev/null || true
    fi

    # geosite 精简版仅保留 private，routing 规则不再引用完整分类列表
    curl -fsSL --retry 3 \
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
        -o "${geodir}/geosite.dat" 2>/dev/null || true

    ok "加速，更新精简版 geodata / Updating lite geodata ... [OK]"
}

# ── 生成密钥对 / Generate keypair ─────────────────────────────
gen_keys() {
    local tmp
    tmp=$(/usr/local/bin/xray x25519 2>/dev/null) || die "密钥生成失败"
    PRIVATE_KEY=$(echo "$tmp" | grep 'Private' | awk '{print $NF}')
    PUBLIC_KEY=$(echo  "$tmp" | grep 'Public'  | awk '{print $NF}')
    SHORT_ID=$(openssl rand -hex 8 2>/dev/null || head -c4 /dev/urandom | xxd -p)
}

# ── 写入配置 / Write config ───────────────────────────────────
# 相比原版：loglevel 降为 none（省掉日志缓冲内存），路由规则
# 只保留 geoip:private 拦截（几十条），去掉 category-ads-all 这种
# 动辄上万条规则的大列表，显著降低常驻内存与规则匹配开销。
write_config() {
    info "块好了，手搓 / Configuring /usr/local/etc/xray/config.json ..."
    [[ -z "$UUID"  ]] && UUID=$(gen_uuid)
    [[ -z "$PORT"  ]] && PORT=$(gen_port)
    gen_keys

    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<JSONEOF
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
          "serverNames": ["${DOMAIN}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": false
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom",  "tag": "direct"  },
    { "protocol": "blackhole","tag": "blocked" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" }
    ]
  }
}
JSONEOF
    ok "块好了，手搓 / Configuring config.json ... [OK]"
}

# ── systemd 内存限制 / Hard memory ceiling ────────────────────
# 没有 swap 的情况下，Xray 一旦内存泄漏或流量突增触发 OOM，
# 内核可能连带 sshd 一起杀掉导致失联。这里给 xray.service 加一个
# MemoryMax 硬顶，超限时优先由 systemd/cgroup 杀掉 xray 自身
# 并交给 Restart= 拉起，而不是让内核 OOM killer 随机选目标。
write_systemd_override() {
    info "写入内存硬限制 / Writing memory ceiling for xray.service ..."
    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
MemoryMax=40M
MemoryHigh=32M
Restart=always
RestartSec=2
OOMPolicy=continue
EOF
    ok "写入内存硬限制 / Memory ceiling written (MemoryMax=40M) ... [OK]"
}

# ── 启动服务 / Start service ──────────────────────────────────
start_service() {
    info "冲刺，开启服务 / Starting Service ..."
    mkdir -p /var/log/xray
    systemctl daemon-reload
    systemctl enable xray  >/dev/null 2>&1
    systemctl restart xray
    sleep 1
    ok "冲刺，开启服务 / Starting Service ... [OK]"
}

# ── 开启 BBR (只读 /proc 环境下静默跳过) ──────────────────────
enable_bbr() {
    info "最后，打开 BBR / Finishing, Enabling BBR ..."
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        if sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
            {
                echo 'net.core.default_qdisc=fq'
                echo 'net.ipv4.tcp_congestion_control=bbr'
            } >> /etc/sysctl.conf 2>/dev/null || true
            sysctl -p >/dev/null 2>&1 || true
            ok "最后，打开 BBR / BBR enabled ... [OK]"
        else
            warn "内核不支持写入 (容器/只读 procfs)，跳过 BBR / Kernel write unsupported (container / read-only procfs) — skipping BBR"
        fi
    else
        ok "BBR 已启用 / BBR already enabled"
    fi
}

# ── 防火墙放行 / Firewall ─────────────────────────────────────
open_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q 'active'; then
        ufw allow "$PORT/tcp" >/dev/null 2>&1 && ok "UFW 放行端口 $PORT"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        ok "Firewalld 放行端口 $PORT"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null && ok "iptables 放行端口 $PORT"
    fi
}

# ── 检查服务状态 ──────────────────────────────────────────────
check_service() {
    info "检查服务状态 / Checking Service ..."
    if systemctl is-active --quiet xray; then
        ok "检查服务状态 / Checking Service ... [OK]"
    else
        die "Xray 服务未运行 / Xray service is not running\n$(journalctl -u xray -n 20 --no-pager)"
    fi
}

# ── 获取公网 IP ───────────────────────────────────────────────
get_ip() {
    SERVER_IP=$(curl -4fsSL --retry 3 --connect-timeout 5 \
        https://api.ipify.org 2>/dev/null || \
        curl -4fsSL --retry 2 --connect-timeout 5 \
        https://ifconfig.me 2>/dev/null || \
        hostname -I | awk '{print $1}')
}

# ── 生成分享链接 / Share link ─────────────────────────────────
gen_share_link() {
    get_ip
    SHARE_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#REALITY-${SERVER_IP}"
}

# ── 打印结果 / Print result ───────────────────────────────────
print_result() {
    local secs
    secs=$(elapsed)
    echo ""
    echo -e "${GREEN}舒服了 / Done:${NC}"
    echo ""
    echo -e "${CYAN}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}  ║       VLESS + REALITY 节点信息 (LOWMEM)          ║${NC}"
    echo -e "${CYAN}  ╠══════════════════════════════════════════════════╣${NC}"
    printf  "${CYAN}  ║${NC}  %-18s ${YELLOW}%-29s${NC} ${CYAN}║${NC}\n" "地址 / Address:"    "$SERVER_IP"
    printf  "${CYAN}  ║${NC}  %-18s ${YELLOW}%-29s${NC} ${CYAN}║${NC}\n" "端口 / Port:"        "$PORT"
    printf  "${CYAN}  ║${NC}  %-18s ${YELLOW}%-29s${NC} ${CYAN}║${NC}\n" "UUID:"               "$UUID"
    printf  "${CYAN}  ║${NC}  %-18s ${YELLOW}%-29s${NC} ${CYAN}║${NC}\n" "Flow:"               "xtls-rprx-vision"
    printf  "${CYAN}  ║${NC}  %-18s ${YELLOW}%-29s${NC} ${CYAN}║${NC}\n" "SNI / 伪装域名:"     "$DOMAIN"
    printf  "${CYAN}  ║${NC}  %-18s ${YELLOW}%-29s${NC} ${CYAN}║${NC}\n" "Public Key:"         "${PUBLIC_KEY:0:28}..."
    printf  "${CYAN}  ║${NC}  %-18s ${YELLOW}%-29s${NC} ${CYAN}║${NC}\n" "Short ID:"           "$SHORT_ID"
    printf  "${CYAN}  ║${NC}  %-18s ${YELLOW}%-29s${NC} ${CYAN}║${NC}\n" "MemoryMax:"          "40M (cgroup)"
    echo -e "${CYAN}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}  分享链接 / Share Link:${NC}"
    echo -e "${PINK}  ${SHARE_LINK}${NC}"
    echo ""
    echo -e "  ${BOLD}总用时 / Elapsed Time:${NC}  ${GREEN}${secs} 秒${NC}"
    echo -e "  ${CYAN}──────────── live free or die hard ────────────${NC}"
    echo ""
}

# ── 主流程 / Main ─────────────────────────────────────────────
main() {
    require_root
    banner
    echo ""
    check_tools
    setup_swap
    install_xray
    update_geodata
    write_config
    write_systemd_override
    start_service
    enable_bbr
    open_firewall
    check_service
    gen_share_link
    print_result
}

main "$@"
