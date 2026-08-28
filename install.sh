#!/bin/bash

# Constants and Configuration

readonly SCRIPT_VERSION="2026.20"
readonly LOG_FILE="nokey.log"
readonly URL_FILE="nokey.url"
readonly DEFAULT_DOMAIN="www.amd.com"
# REALITY target candidate pool for the automated SNI scan.
readonly REALITY_TARGET_CANDIDATES=(
    "www.amazon.com"
    "aws.amazon.com"
    "www.samsung.com"
    "www.nvidia.com"
    "www.amd.com"
    "www.intel.com"
    "www.sony.com"
    "dl.google.com"
)
readonly REALITY_SCAN_TIMEOUT=5
readonly GITHUB_URL="https://github.com/livingfree2023/nokey"
readonly SERVICE_NAME="xray.service"
readonly SERVICE_NAME_ALPINE="xray"
readonly GITHUB_RELEASE_BASE_URL="https://github.com/livingfree2023/nokey/releases/latest/download"
readonly GITHUB_XRAY_RC_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/xray.rc"
readonly GITHUB_XRAY_SERVICE_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/xray.service"

current_hostname=$(hostname)
reality_dest_port=443
xray_config_path="/usr/local/etc/xray/config.json"

# REALITY probe latency in ms (set by probe_reality_target; read by pick_default_domain)
probe_latency_ms=""

# Color definitions (suppressed when stdout is not a TTY)
if [[ -t 1 ]]; then
    readonly red='\e[91m'
    readonly green='\e[92m'
    readonly yellow='\e[93m'
    readonly magenta='\e[95m'
    readonly cyan='\e[96m'
    readonly none='\e[0m'
else
    readonly red=''
    readonly green=''
    readonly yellow=''
    readonly magenta=''
    readonly cyan=''
    readonly none=''
fi

init_output_files() {
    : > "$LOG_FILE"
    : > "$URL_FILE"
}

# Helper functions
error() {
    echo -e "\n${red}$1${none}\n" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "\n${yellow}$1${none}\n" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${yellow}$1${none}" | tee -a "$LOG_FILE"
}

task_start() {
    echo -n -e "${yellow}$1 ... ${none}" | tee -a "$LOG_FILE"
}

task_done() {
    echo -e "[${green}OK${none}]" | tee -a "$LOG_FILE"
}

task_done_with_info() {
    echo -e "${cyan}$1${none} [${green}OK${none}]" | tee -a "$LOG_FILE"
}

task_fail() {
    echo -e "[${red}FAILED${none}]" | tee -a "$LOG_FILE"
}

log_verbose() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_info() {
    echo -e "${yellow}$1${none}" >> "$LOG_FILE"
}

separator() {
    echo -e "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${none}"
}

resolve_arch_binary_name() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "xray_amd64" ;;
        aarch64|arm64) echo "xray_arm64" ;;
        *) return 1 ;;
    esac
}

resolve_arch_name() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

resolve_os_family() {
    if [ "${ID:-}" = "alpine" ] || [ "${ID_LIKE:-}" = "alpine" ]; then
        echo "alpine"
    else
        echo "debian/systemd-compatible"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请以root身份运行此脚本 / Please run as root: ${red}sudo -i${none}"
        exit 1
    fi
}

detect_network_interfaces() {
    Public_IPv4=$(curl -4s -m 2 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
    Public_IPv6=$(curl -6s -m 2 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
    if [[ -z "$Public_IPv6" ]]; then
        Public_IPv6=$(curl -6s -m 2 https://ip.sb)
    fi
    [[ -n "$Public_IPv4" ]] && IPv4="$Public_IPv4"
    [[ -n "$Public_IPv6" ]] && IPv6="$Public_IPv6"
    echo "Detected interface / 找到网卡: $Public_IPv4 $Public_IPv6" >> "$LOG_FILE"
}

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

generate_shortid() {
    head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

extract_public_key_from_x25519_output() {
    local x25519_output="$1"
    echo "$x25519_output" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | awk '
        {
            line = $0
            lower = tolower(line)
            if (lower ~ /public[[:space:]]*key/) {
                sub(/^[^:]*:[[:space:]]*/, "", line)
                print line
                exit
            }
        }
    '
}

extract_private_key_from_x25519_output() {
    local x25519_output="$1"
    echo "$x25519_output" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | awk '
        {
            line = $0
            lower = tolower(line)
            if (lower ~ /private[[:space:]]*key/) {
                sub(/^[^:]*:[[:space:]]*/, "", line)
                print line
                exit
            }
        }
    '
}

install_dependencies() {
    task_start "工具链检查 / Tool check"

    local tools=("curl" "netstat")

    declare -A os_package_command=(
        [apt]="apt install -y"
        [yum]="yum install -y"
        [dnf]="dnf install -y"
        [pacman]="pacman -Sy --noconfirm"
        [apk]="apk add --no-cache"
        [zypper]="zypper install -y"
        [xbps-install]="xbps-install -Sy"
    )

    local manager=""
    for candidate in "${!os_package_command[@]}"; do
        if command -v "$candidate" > /dev/null 2>&1; then
            manager=$candidate
            break
        fi
    done

    if [[ -z "$manager" ]]; then
        task_fail
        error "无法识别包管理器 / Cannot detect package manager"
        exit 1
    fi

    local install_cmd="${os_package_command[$manager]}"

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            local package_name="$tool"
            [[ "$tool" == "netstat" ]] && package_name="net-tools"
            eval "$install_cmd" "$package_name" >> "$LOG_FILE" 2>&1
            if ! command -v "$tool" > /dev/null 2>&1; then
                task_fail
                error "安装$tool失败，请手动安装后重新运行脚本 / Failed to install '$tool'. Please install it manually and re-run the script."
                exit 1
            fi
        fi
    done

    task_done
}

initialize_ip_from_netstack() {
    task_start "监测IP / Detect IP"
    if [[ -z "${IPv4:-}" && -z "${IPv6:-}" ]]; then
        detect_network_interfaces
    fi
    if [[ -n "$IPv4" ]]; then
        netstack=4
    elif [[ -n "$IPv6" ]]; then
        netstack=6
    else
        task_fail
        error "没有获取到公共IP / No public IP detected"
        exit 1
    fi

    if [[ "$netstack" == "4" ]]; then
        ip=${IPv4}
    else
        ip=${IPv6}
    fi
    task_done_with_info "$ip"
}

is_port_reusable() {
    local check_port="$1"
    local process_name="$2"
    local systemd_service="$3"
    local openrc_service="$4"
    local port_in_use=0

    if command -v ss >/dev/null 2>&1; then
        if ss -ltn "sport = :$check_port" 2>/dev/null | grep -q .; then
            port_in_use=1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ltn 2>/dev/null | grep -qE "[:]$check_port($| )"; then
            port_in_use=1
        fi
    else
        if (echo > /dev/tcp/127.0.0.1/"$check_port") >/dev/null 2>&1; then
            port_in_use=1
        fi
    fi

    if [[ $port_in_use -eq 0 ]]; then
        return 0
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -ltnp "sport = :$check_port" 2>/dev/null | grep -q "$process_name"; then
            return 0
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ltnp 2>/dev/null | grep -E "[:.]$check_port($| )" | grep -q "$process_name"; then
            return 0
        fi
    else
        if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            if rc-service "$openrc_service" status >/dev/null 2>&1; then
                return 0
            fi
        else
            if systemctl is-active --quiet "$systemd_service"; then
                return 0
            fi
        fi
    fi
    return 1
}

# Probe a REALITY target candidate: must negotiate TLS 1.3 + ALPN h2 with a
# verifying cert chain. Records handshake latency into probe_latency_ms.
probe_reality_target() {
    local candidate="$1"
    local probe_out=""
    local curl_rc=0
    probe_latency_ms=""
    probe_out="$(curl -sSI --max-time "$REALITY_SCAN_TIMEOUT" --tlsv1.3 --http2 -o /dev/null -w '%{http_version}|%{time_appconnect}' "https://$candidate/" 2>/dev/null)" || curl_rc=$?
    local http_version="${probe_out%%|*}"
    local latency_sec="${probe_out#*|}"
    if [[ -n "$latency_sec" && "$latency_sec" != "$http_version" ]]; then
        probe_latency_ms="$(awk -v t="$latency_sec" 'BEGIN { printf "%.0f", t * 1000 }')"
    fi
    if [[ "$http_version" == "2" ]]; then
        log_info "REALITY probe: $candidate -> feasible (TLS 1.3 + h2 verified, ${probe_latency_ms}ms)"
        return 0
    fi
    if [[ $curl_rc -ne 0 ]]; then
        log_info "REALITY probe: $candidate -> rejected (curl rc=$curl_rc: connect/TLS/cert failure)"
    else
        log_info "REALITY probe: $candidate -> rejected (negotiated HTTP/$http_version, need h2)"
    fi
    return 1
}

# Auto-pick an SNI by probing the candidate pool; falls back to DEFAULT_DOMAIN.
pick_default_domain() {
    [[ -n $domain ]] && return 0
    local candidate
    local shuffled=("${REALITY_TARGET_CANDIDATES[@]}")
    local i j tmp
    for ((i = ${#shuffled[@]} - 1; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        tmp="${shuffled[i]}"
        shuffled[i]="${shuffled[j]}"
        shuffled[j]="$tmp"
    done
    info "自动探测REALITY目标SNI / Auto-probing REALITY target SNI:"
    for candidate in "${shuffled[@]}"; do
        if probe_reality_target "$candidate"; then
            domain="$candidate"
            info "  ${candidate} -> ${green}可用 / feasible${none} (TLS 1.3 + h2 验证通过 / verified, ${probe_latency_ms}ms)"
            info "自动选择REALITY目标 / Auto-selected REALITY target: ${cyan}${domain}${none}"
            return 0
        fi
        info "  ${candidate} -> 不可用 / not feasible (原因见日志 / reason in log)"
    done
    domain="$DEFAULT_DOMAIN"
    warn "所有候选均不可用，使用默认SNI / No feasible target probed; using default SNI: ${cyan}${domain}${none}"
    return 1
}

initialize_variables() {
    initialize_ip_from_netstack

    task_start "寻找一个合适的端口 / Find an Available Port"
    if is_port_reusable 443 xray "$SERVICE_NAME" "$SERVICE_NAME_ALPINE"; then
        port=443
    else
        base=$((10000 + RANDOM % 50000))
        port_found=0
        for i in $(seq 0 1000); do
            port=$((base + i))
            if ! (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
                port_found=1
                break
            fi
        done
        if [[ $port_found -eq 0 ]]; then
            task_fail
            error "没有找到可用端口 / Could not find an unused port."
            exit 1
        fi
    fi
    task_done_with_info "$port"

    pick_default_domain || true
}

generate_crypto() {
    task_start "生成一个UUID / Generate UUID"
    uuid=$(generate_uuid)
    task_done

    keys=$(xray x25519)
    if [[ -z "$keys" ]]; then
        task_fail
        error "生成x25519密钥失败，xray是否安装正确？ / Failed to generate x25519 keys. Is xray installed correctly?"
        exit 1
    fi
    task_start "生成一个私钥 / Generate Private Key"
    private_key=$(extract_private_key_from_x25519_output "$keys")
    if [[ -z "$private_key" ]]; then
        task_fail
        error "无法从x25519输出解析私钥 / Failed to parse PrivateKey from x25519 output."
        exit 1
    fi
    task_done_with_info "${private_key}"

    task_start "生成一个公钥 / Generate Public Key"
    public_key=$(extract_public_key_from_x25519_output "$keys")
    if [[ -z "$public_key" ]]; then
        task_fail
        error "无法从x25519输出解析公钥 / Failed to parse PublicKey from x25519 output."
        exit 1
    fi
    task_done_with_info "${public_key}"

    task_start "生成一个shortid / Generate shortid"
    shortid=$(generate_shortid)
    task_done_with_info "${shortid}"
}

build_xray_config() {
    # Randomize the REALITY fallback rate limit (~1 Mbps sustained / 2 Mbps burst)
    # to avoid a fixed-rate fingerprint across installs.
    fallback_bytes_per_sec=$((125000 * (85 + RANDOM % 31) / 100))
    fallback_burst_bytes_per_sec=$((250000 * (85 + RANDOM % 31) / 100))

    reality_template=$(cat <<-EOF
      {
        "log": {
          "access": "/tmp/xray_access.log",
          "error": "/tmp/xray_error.log",
          "loglevel": "warning"
        },
        "inbounds": [
          {
            "port": ${port},
            "protocol": "vless",
            "settings": {
              "clients": [
                {
                  "id": "${uuid}",
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
                "minClientVer": "0.0.0",
                "dest": "${domain}:${reality_dest_port}",
                "xver": 0,
                "serverNames": ["${domain}"],
                "privateKey": "${private_key}",
                "shortIds": ["${shortid}"],
                "limitFallbackUpload": {
                  "afterBytes": 0,
                  "bytesPerSec": ${fallback_bytes_per_sec},
                  "burstBytesPerSec": ${fallback_burst_bytes_per_sec}
                },
                "limitFallbackDownload": {
                  "afterBytes": 0,
                  "bytesPerSec": ${fallback_bytes_per_sec},
                  "burstBytesPerSec": ${fallback_burst_bytes_per_sec}
                }
              }
            },
            "sniffing": {
              "enabled": true,
              "destOverride": ["http", "tls", "quic"],
              "routeOnly": true
            }
          }
        ],
        "outbounds": [
          {
            "protocol": "freedom",
            "settings": {
            },
            "tag": "direct"
          },
          {
            "protocol": "blackhole",
            "tag": "block"
          }
        ],
        "dns": {
          "servers": [
            "8.8.8.8",
            "1.1.1.1",
            "2001:4860:4860::8888",
            "2606:4700:4700::1111",
            "localhost"
          ]
        },
        "routing": {
          "domainStrategy": "IPIfNonMatch",
          "rules": [
            {
              "type": "field",
              "ip": ["geoip:private"],
              "outboundTag": "block"
            },
            {
              "type": "field",
              "outboundTag": "block",
              "protocol": [
                "bittorrent"
              ]
            }
          ]
        }
      }
EOF
    )

    local config_path="$xray_config_path"
    local config_dir=""
    task_start "快好了，手搓 / Configuring $config_path"

    config_dir=$(dirname "$config_path")

    if [[ ! -d "$config_dir" ]]; then
        if ! mkdir -p "$config_dir"; then
            task_fail
            error "创建配置目录失败: $config_dir / Failed to create config directory: $config_dir"
            exit 1
        fi
    fi

    if ! echo "$reality_template" > "$config_path"; then
        task_fail
        error "写入xray配置文件失败: $config_path / Failed to write xray config to $config_path."
        [[ -f "$config_path" ]] && rm -f "$config_path"
        error "已删除不完整的配置文件，请检查权限、磁盘空间和$LOG_FILE获取详情 / Partial config file removed. Check permissions, disk space, and $LOG_FILE for details."
        exit 1
    fi
    task_done

    log_info "--- ${config_path} ---"
    cat "$config_path" >> "$LOG_FILE"
}

install_xray() {
    task_start "开始，安装XRAY / Install XRAY"

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        rc-service "$SERVICE_NAME_ALPINE" stop 2>/dev/null || true
    else
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    fi

    local arch_binary_name=""
    local arch_name=""
    arch_binary_name="$(resolve_arch_binary_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }
    arch_name="$(resolve_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }

    log_info "检测到系统 / Detected OS: $(resolve_os_family) | 架构 / Architecture: ${arch_name}"

    mkdir -p /usr/local/bin /usr/local/share/xray /usr/local/etc/xray /var/log/xray || { task_fail; error "创建xray目录失败 / Failed to create xray directories"; exit 1; }

    curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/${arch_binary_name}" -o /usr/local/bin/xray >> "$LOG_FILE" 2>&1 || { task_fail; error "下载${arch_binary_name}失败 / Failed to download ${arch_binary_name}"; exit 1; }
    chmod 755 /usr/local/bin/xray

    local xray_rc_tmp
    local xray_service_tmp
    xray_rc_tmp="$(mktemp /tmp/nokey.xray.rc.XXXXXX)" || { task_fail; error "创建xray.rc临时文件失败 / Failed to create temporary file for xray.rc"; exit 1; }
    xray_service_tmp="$(mktemp /tmp/nokey.xray.service.XXXXXX)" || { task_fail; error "创建xray.service临时文件失败 / Failed to create temporary file for xray.service"; exit 1; }

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        curl -fSL "${GITHUB_XRAY_RC_URL}" -o "${xray_rc_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "下载xray.rc失败 / Failed to download xray.rc"; exit 1; }
        install -m 755 "${xray_rc_tmp}" /etc/init.d/"$SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "安装/etc/init.d/$SERVICE_NAME_ALPINE失败 / Failed to install /etc/init.d/$SERVICE_NAME_ALPINE"; exit 1; }
        rm -f "${xray_rc_tmp}" >> "$LOG_FILE" 2>&1
        rc-update add "$SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用OpenRC服务$SERVICE_NAME_ALPINE失败 / Failed to enable OpenRC service $SERVICE_NAME_ALPINE"; exit 1; }
    else
        curl -fSL "${GITHUB_XRAY_SERVICE_URL}" -o "${xray_service_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "下载xray.service失败 / Failed to download xray.service"; exit 1; }
        # shellcheck disable=SC2016
        sed -e 's/\$INSTALL_USER/nobody/g' \
            -e '/\${temp_CapabilityBoundingSet}/d' \
            -e '/\${temp_AmbientCapabilities}/d' \
            -e '/\${temp_NoNewPrivileges}/d' \
            "${xray_service_tmp}" > /etc/systemd/system/"$SERVICE_NAME" || { task_fail; error "写入/etc/systemd/system/$SERVICE_NAME失败 / Failed to write /etc/systemd/system/$SERVICE_NAME"; exit 1; }
        rm -f "${xray_service_tmp}" >> "$LOG_FILE" 2>&1
        systemctl daemon-reload >> "$LOG_FILE" 2>&1 || { task_fail; error "systemctl daemon-reload失败 / systemctl daemon-reload failed"; exit 1; }
        systemctl enable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用systemd服务$SERVICE_NAME失败 / Failed to enable systemd service $SERVICE_NAME"; exit 1; }
    fi

    task_done

    task_start "加速，更新geodata / Updating geodata"
    curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/geoip.dat" -o /usr/local/share/xray/geoip.dat >> "$LOG_FILE" 2>&1 || { task_fail; error "下载geoip.dat失败 / Failed to download geoip.dat"; exit 1; }
    curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/geosite.dat" -o /usr/local/share/xray/geosite.dat >> "$LOG_FILE" 2>&1 || { task_fail; error "下载geosite.dat失败 / Failed to download geosite.dat"; exit 1; }
    task_done
}

restart_xray_service() {
    task_start "冲刺，开启服务 / Starting Service"
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        restart_cmd=(rc-service "$SERVICE_NAME_ALPINE" restart)
    else
        restart_cmd=(systemctl restart "$SERVICE_NAME")
    fi
    if ! "${restart_cmd[@]}" >> "$LOG_FILE" 2>&1; then
        task_fail
        error "重启xray服务失败，请查看$LOG_FILE获取详情 / Failed to restart xray service. Check $LOG_FILE for details."
        exit 1
    fi
    task_done
}

configure_xray() {
    initialize_variables
    generate_crypto
    build_xray_config
    restart_xray_service
}

enable_bbr() {
    task_start "最后，打开BBR / Finishing, Enabling BBR"

    if [[ ! -w /etc/sysctl.conf ]]; then
        task_done_with_info "跳过BBR：/etc/sysctl.conf不可写 / Skip BBR: /etc/sysctl.conf is not writable"
        return
    fi

    if [[ ! -e /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        task_done_with_info "跳过BBR：内核未暴露tcp_congestion_control / Skip BBR: kernel does not expose tcp_congestion_control"
        return
    fi

    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf

    if [[ -e /proc/sys/net/core/default_qdisc ]]; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    fi

    sysctl -p >> "$LOG_FILE" 2>&1 || true
    local current_cc=""
    current_cc="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)"
    if [[ "$current_cc" == *bbr* ]]; then
        task_done
    else
        warn "BBR未生效：当前拥塞算法为 ${current_cc:-unknown} / BBR not active: current congestion control is ${current_cc:-unknown}"
    fi
}

show_banner() {
    echo -e "      ___         ___         ___         ___               "
    echo -e "     /__/\\       /  /\\       /__/|       /  /\\        ___   "
    echo -e "     \\  \\:\\     /  /::\\     |  |:|      /  /:/_      /__/|  "
    echo -e "      \\  \\:\\   /  /:/\\:\\    |  |:|     /  /:/ /\\    |  |:|  "
    echo -e "  _____\\__\\:\\ /  /:/  \\:\\ __|  |:|    /  /:/ /:/_   |  |:|  "
    echo -e " /__/::::::::/__/:/ \\__\\:/__/\_|:|___/__/:/ /:/ /\\__|__|:|  "
    echo -e " \\  \\:\\~~\\~~\\\\  \\:\\ /  /:\\  \\:\\/:::::\\  \\:\\/:/ /:/__/::::\\  "
    echo -e "  \\  \\:\\  ~~~ \\  \\:\\  /:/ \\  \\::/~~~~ \\  \\::/ /:/   ~\\~~\\:\\ "
    echo -e "   \\  \\:\\      \\  \\:\\/:/   \\  \\:\\      \\  \\:\\/:/      \\  \\:\\"
    echo -e "    \\  \\:\\      \\  \\::/     \\  \\:\\      \\  \\::/        \\__\\/"
    echo -e "     \\__\\/       \\__\\/       \\__\\/       \\__\\/              "

    echo "项目地址，欢迎点点点点星 / STAR ME PLEEEEEAAAASE"
    echo -e "${cyan}$GITHUB_URL${none}"
}

check_service_status() {
    task_start "检查服务状态 / Checking Service"
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        if rc-service "$SERVICE_NAME_ALPINE" status >> "$LOG_FILE" 2>&1; then
            info "Xray服务运行中 / Xray is running"
        else
            error "Xray服务未运行 / Xray service is not active"
            rc-service "$SERVICE_NAME_ALPINE" status | tee -a "$LOG_FILE"
            error "详细日志记录在 $LOG_FILE / See complete logs"
            exit 1
        fi
    else
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            info "Xray服务运行中 / Xray is running"
        else
            error "Xray服务未运行 / Xray service is not active"
            systemctl status "$SERVICE_NAME" | tee -a "$LOG_FILE"
            error "详细日志记录在 $LOG_FILE / See complete logs"
            exit 1
        fi
    fi
    task_done
}

generate_share_links() {
    local link_ip="$ip"
    [[ $netstack == "6" ]] && link_ip="[$ip]"

    vless_reality_url="vless://${uuid}@${link_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=random&pbk=${public_key}&sid=${shortid}#${current_hostname}"

    info "分享链接 / Share Link:"
    echo -e "${magenta}${vless_reality_url}${none}" | tee -a "$LOG_FILE"
    echo "$vless_reality_url" >> "$URL_FILE"
}

generate_clash_config() {
    local server_ip_for_clash="$ip"
    [[ $netstack == "6" ]] && server_ip_for_clash=${ip:1:-1}

    clash_meta_config=$(cat <<-EOF
- name: ${current_hostname}
  type: vless
  server: ${server_ip_for_clash}
  port: ${port}
  client-fingerprint: random
  tls: true
  servername: ${domain}
  flow: xtls-rprx-vision
  network: tcp
  reality-opts:
    public-key: ${public_key}
    short-id: ${shortid}
  uuid: ${uuid}
EOF
)
    info "Clash.meta 配置 / Clash.meta config:"
    echo -e "${cyan}${clash_meta_config}${none}" | tee -a "$LOG_FILE"
    echo "$clash_meta_config" >> "$URL_FILE"
}

# Emit an extra IPv6 share URL + clash entry when the box is dual-stack but the
# primary netstack is IPv4.
generate_ipv6_variants() {
    [[ $netstack == "4" && -n "${IPv6:-}" ]] || return 0

    local ipv6_link
    ipv6_link="vless://${uuid}@[${IPv6}]:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=random&pbk=${public_key}&sid=${shortid}#${current_hostname}-ipv6"
    info "分享链接 (IPv6) / Share Link (IPv6):"
    echo -e "${magenta}${ipv6_link}${none}" | tee -a "$LOG_FILE"
    echo "$ipv6_link" >> "$URL_FILE"

    local ipv6_clash
    ipv6_clash=$(cat <<-EOF
- name: ${current_hostname}-ipv6
  type: vless
  server: ${IPv6}
  port: ${port}
  client-fingerprint: random
  tls: true
  servername: ${domain}
  flow: xtls-rprx-vision
  network: tcp
  reality-opts:
    public-key: ${public_key}
    short-id: ${shortid}
  uuid: ${uuid}
EOF
)
    info "Clash.meta 配置 (IPv6) / Clash.meta config (IPv6):"
    echo -e "${cyan}${ipv6_clash}${none}" | tee -a "$LOG_FILE"
    echo "$ipv6_clash" >> "$URL_FILE"
}

output_results() {
    check_service_status

    echo -e "${green}舒服了 / Done:${none}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    separator | tee -a "$LOG_FILE"
    echo -e "  ${green}✓${none} Xray VLESS Reality" | tee -a "$LOG_FILE"
    echo -e "  ${cyan}IP:Port${none} → ${ip}:${port}" | tee -a "$LOG_FILE"
    echo -e "  ${cyan}UUID${none} → ${uuid}" | tee -a "$LOG_FILE"
    separator | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    generate_share_links
    generate_clash_config
    generate_ipv6_variants
}

# Main function
main() {
    SECONDS=0

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    else
        error "无法识别的OS / Cannot determine OS."
        exit 1
    fi

    show_banner
    init_output_files
    echo -e "当前版本 / Version: ${cyan}${SCRIPT_VERSION}${none} " | tee -a "$LOG_FILE"

    check_root
    install_dependencies
    detect_network_interfaces

    install_xray
    configure_xray
    enable_bbr

    output_results
    info "总用时 / Elapsed Time:  ${green}$SECONDS 秒${none}"
    echo -e "---------- ${cyan}live free or die hard${none} -------------" | tee -a "$LOG_FILE"
}

main "$@"
