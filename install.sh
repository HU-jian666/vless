#!/bin/bash
# VLESS + XTLS-Reality 一键安装脚本 / One-command VLESS+REALITY installer
# https://github.com/<YOUR_GH_USER>/<YOUR_REPO>
set -uo pipefail

# ---------------------------------------------------------------------------
# 常量 / Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly CONFIG_PATH="/usr/local/etc/xray/config.json"
readonly SERVICE_NAME="xray"
readonly DEFAULT_SNI="www.microsoft.com"
readonly LOG_FILE="/var/log/vless-installer.log"

port=""
uuid=""
sni="$DEFAULT_SNI"
netstack="auto"
dry_run=0

if [[ -t 1 ]]; then
    red='\e[91m'; green='\e[92m'; yellow='\e[93m'; cyan='\e[96m'; magenta='\e[95m'; none='\e[0m'
else
    red=''; green=''; yellow=''; cyan=''; magenta=''; none=''
fi

# ---------------------------------------------------------------------------
# 输出辅助函数 / Output helpers (matches the [OK] step style)
# ---------------------------------------------------------------------------
task_start() { echo -n -e "${yellow}$1${none} ... " | tee -a "$LOG_FILE"; }
task_done()  { echo -e "[${green}OK${none}]" | tee -a "$LOG_FILE"; }
task_fail()  { echo -e "[${red}FAILED${none}]" | tee -a "$LOG_FILE"; }
info()       { echo -e "${cyan}$1${none}" | tee -a "$LOG_FILE"; }
die()        { echo -e "\n${red}$1${none}\n" | tee -a "$LOG_FILE"; exit 1; }

banner() {
    echo -e "${cyan}https://github.com/<YOUR_GH_USER>/<YOUR_REPO>${none}"
    echo "本脚本支持带参数执行，不带参数将直接安装 / See --help for parameters"
}

show_help() {
    cat <<EOF
用法 / Usage: $0 [options]
  --port=NUMBER     指定端口 (默认: 随机) / Set port (default: random)
  --uuid=STRING     指定UUID (默认: 自动生成) / Set UUID (default: auto)
  --sni=DOMAIN      指定REALITY SNI (默认: ${DEFAULT_SNI}) / Set REALITY SNI
  --netstack=4|6    强制IPv4或IPv6 (默认: 自动) / Force IPv4/IPv6
  --dry-run         仅预览，不做任何更改 / Preview only, no changes
  --help            显示本帮助 / Show this help
EOF
    exit 0
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --port=*) port="${arg#*=}" ;;
            --uuid=*) uuid="${arg#*=}" ;;
            --sni=*) sni="${arg#*=}" ;;
            --netstack=*) netstack="${arg#*=}" ;;
            --dry-run) dry_run=1 ;;
            --help) show_help ;;
            *) die "未知参数: $arg / Unknown option: $arg" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 步骤1：工具链检查 / Tool check
# ---------------------------------------------------------------------------
step_tool_check() {
    task_start "工具链检查 / Tool check"
    [[ "$EUID" -ne 0 ]] && { task_fail; die "请以root身份运行 / Please run as root"; }
    for tool in curl systemctl; do
        command -v "$tool" >/dev/null 2>&1 || { task_fail; die "缺少依赖: $tool / Missing dependency: $tool"; }
    done
    command -v jq >/dev/null 2>&1 || {
        apt-get update -y >>"$LOG_FILE" 2>&1 || yum install -y jq >>"$LOG_FILE" 2>&1 || true
        apt-get install -y jq curl uuid-runtime >>"$LOG_FILE" 2>&1 || true
    }
    task_done
}

# ---------------------------------------------------------------------------
# 步骤2：安装 XRAY / Install XRAY
# ---------------------------------------------------------------------------
step_install_xray() {
    task_start "开始，安装 XRAY / Install XRAY"
    bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ install >>"$LOG_FILE" 2>&1 \
        || { task_fail; die "Xray安装失败，查看 $LOG_FILE / Xray install failed, see $LOG_FILE"; }
    task_done
}

# ---------------------------------------------------------------------------
# 步骤3：更新 geodata / Update geodata
# ---------------------------------------------------------------------------
step_update_geodata() {
    task_start "加速，更新geodata / Updating geodata"
    bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ install-geodata >>"$LOG_FILE" 2>&1 \
        || { task_fail; die "geodata更新失败 / geodata update failed"; }
    task_done
}

# ---------------------------------------------------------------------------
# 步骤4：配置 config.json / Configuring config.json
# ---------------------------------------------------------------------------
detect_ip() {
    ip=$(curl -4s -m 3 https://api.ipify.org || true)
    ip6=$(curl -6s -m 3 https://api64.ipify.org || true)
    if [[ "$netstack" == "6" ]]; then
        [[ -z "$ip6" ]] && die "未检测到公网IPv6 / No public IPv6 detected"
        server_ip="$ip6"; url_ip="[$ip6]"
    else
        [[ -z "$ip" ]] && { [[ -n "$ip6" ]] && { server_ip="$ip6"; url_ip="[$ip6]"; } || die "未检测到公网IP / No public IP detected"; }
        [[ -n "$ip" ]] && { server_ip="$ip"; url_ip="$ip"; }
    fi
}

step_configure() {
    task_start "快好了，手搓 / Configuring $CONFIG_PATH"

    [[ -z "$port" ]] && port=$(shuf -i 20000-60000 -n 1)
    [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)

    keys=$(/usr/local/bin/xray x25519)
    private_key=$(echo "$keys" | awk -F': ' '/Private/ {print $2}')
    public_key=$(echo "$keys" | awk -F': ' '/Password|Public/ {print $2}')
    short_id=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

    mkdir -p "$(dirname "$CONFIG_PATH")"
    cat > "$CONFIG_PATH" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${sni}:443",
          "xver": 0,
          "serverNames": ["${sni}"],
          "privateKey": "${private_key}",
          "shortIds": ["${short_id}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
    task_done
}

# ---------------------------------------------------------------------------
# 步骤5：启动服务 / Starting Service
# ---------------------------------------------------------------------------
step_start_service() {
    task_start "冲刺，开启服务 / Starting Service"
    systemctl restart "$SERVICE_NAME" >>"$LOG_FILE" 2>&1
    systemctl enable "$SERVICE_NAME" >>"$LOG_FILE" 2>&1
    task_done
}

# ---------------------------------------------------------------------------
# 步骤6：打开 BBR / Enabling BBR
# ---------------------------------------------------------------------------
step_enable_bbr() {
    task_start "最后，打开BBR / Finishing, Enabling BBR"
    if [[ -w /etc/sysctl.conf ]]; then
        sed -i '/net.ipv4.tcp_congestion_control/d;/net.core.default_qdisc/d' /etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        sysctl -p >>"$LOG_FILE" 2>&1 || true
    fi
    task_done
}

# ---------------------------------------------------------------------------
# 步骤7：检查服务状态 / Checking Service
# ---------------------------------------------------------------------------
step_check_status() {
    task_start "检查服务状态 / Checking Service"
    systemctl is-active --quiet "$SERVICE_NAME" || { task_fail; die "服务未运行，查看 $LOG_FILE / Service not running, see $LOG_FILE"; }
    task_done
}

# ---------------------------------------------------------------------------
# 输出结果 / Done
# ---------------------------------------------------------------------------
step_output() {
    detect_ip
    link="vless://${uuid}@${url_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#$(hostname)"

    echo ""
    echo "舒服了 / Done:"
    echo ""
    echo -e "${magenta}${link}${none}"
    echo ""
    echo "总用时 / Elapsed Time:  ${green}${SECONDS} 秒${none}"
    echo -e "---------- ${cyan}live free or die hard${none} -------------"
}

dry_run_preview() {
    echo "预览模式，不做任何更改 / Dry run — no changes will be made:"
    echo "  1. 工具链检查 / Tool check"
    echo "  2. 安装 XRAY / Install XRAY (${XRAY_INSTALL_URL})"
    echo "  3. 更新 geodata / Update geodata"
    echo "  4. 写入配置 / Write ${CONFIG_PATH} (port=${port:-random}, sni=${sni})"
    echo "  5. 启动服务 / Start ${SERVICE_NAME}.service"
    echo "  6. 启用 BBR / Enable BBR"
    echo "  7. 检查状态 / Check service status"
}

main() {
    SECONDS=0
    banner
    parse_args "$@"
    : > "$LOG_FILE"

    if [[ $dry_run -eq 1 ]]; then
        dry_run_preview
        exit 0
    fi

    step_tool_check
    step_install_xray
    step_update_geodata
    step_configure
    step_start_service
    step_enable_bbr
    step_check_status
    step_output
}

main "$@"
