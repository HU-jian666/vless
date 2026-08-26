#!/usr/bin/env bash
# ============================================================
# Xray VLESS + REALITY 一键安装脚本
# 64MB 超低内存 / 随机端口 / 全自动
#
# Usage:
#   bash install.sh
#   bash install.sh --domain www.apple.com
# ============================================================

set -Eeuo pipefail

# ============================================================
# 基础变量
# ============================================================

START_TIME="$(date +%s)"

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_INFO="/root/xray-info.txt"
XRAY_INSTALL="/tmp/xray-install.sh"

DOMAIN="www.apple.com"

PORT=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SERVER_IP=""
ARCH=""
OS_ID=""
MEM_MB=""
BBR_STATUS="unknown"

# ============================================================
# 颜色
# ============================================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

OK="${GREEN}[OK]${RESET}"
WARN="${YELLOW}[WARN]${RESET}"
FAIL="${RED}[FAIL]${RESET}"

# ============================================================
# 输出函数
# ============================================================

msg() {
    echo -e "$*"
}

step() {
    msg "$1"
}

die() {
    msg "${FAIL} $1"
    exit 1
}

# ============================================================
# 错误处理
# ============================================================

trap '
echo
msg "${FAIL} 安装失败"
msg "错误行号: ${LINENO}"
exit 1
' ERR

# ============================================================
# 参数
# ============================================================

while [[ $# -gt 0 ]]; do

    case "$1" in

        --domain)
            DOMAIN="${2:-}"
            shift 2
            ;;

        --help|-h)
            echo
            echo "VLESS + REALITY 64MB 自动安装"
            echo
            echo "用法:"
            echo
            echo "bash install.sh"
            echo
            echo "bash install.sh --domain www.apple.com"
            echo
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

[[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行"

# ============================================================
# Banner
# ============================================================

clear 2>/dev/null || true

echo
echo "============================================================"
echo "      VLESS + REALITY / XRAY / LOW MEMORY"
echo "      64MB / RANDOM PORT / FULL AUTO"
echo "============================================================"
echo

# ============================================================
# 内存检测
# ============================================================

step "内存检测 / Checking Memory ..."

MEM_MB="$(
    awk '/MemTotal/ {
        printf "%d\n",$2/1024
    }' /proc/meminfo
)"

if [[ -z "${MEM_MB}" ]]; then
    die "无法检测服务器内存"
fi

if (( MEM_MB <= 80 )); then
    msg "${OK} ${MEM_MB} MB / Low Memory Mode"
else
    msg "${OK} ${MEM_MB} MB"
fi

# ============================================================
# 架构检测
# ============================================================

step "架构检测 / Detecting Architecture ..."

case "$(uname -m)" in

    x86_64|amd64)
        ARCH="amd64"
        ;;

    aarch64|arm64)
        ARCH="arm64-v8a"
        ;;

    armv7l)
        ARCH="arm32-v7a"
        ;;

    *)
        die "不支持的 CPU 架构: $(uname -m)"
        ;;

esac

msg "${OK} ${ARCH}"

# ============================================================
# 系统检测
# ============================================================

step "系统检测 / Detecting OS ..."

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
else
    OS_ID="unknown"
fi

msg "${OK} ${OS_ID}"

# ============================================================
# 安装基础工具
# ============================================================

step "工具链检查 / Tool Check ..."

export DEBIAN_FRONTEND=noninteractive

case "${OS_ID}" in

    ubuntu|debian)

        apt-get update -y >/dev/null 2>&1 || true

        apt-get install -y \
            curl \
            ca-certificates \
            openssl \
            iproute2 \
            procps \
            >/dev/null 2>&1

        ;;

    centos|rhel|rocky|almalinux|fedora)

        if command -v dnf >/dev/null 2>&1; then
            PKG="dnf"
        else
            PKG="yum"
        fi

        "${PKG}" install -y \
            curl \
            ca-certificates \
            openssl \
            iproute \
            procps \
            >/dev/null 2>&1 || true

        ;;

    *)

        msg "${WARN} 未识别发行版，继续尝试"

        ;;

esac

msg "${OK}"

# ============================================================
# systemd
# ============================================================

command -v systemctl >/dev/null 2>&1 \
    || die "当前系统没有 systemd"

# ============================================================
# 检查端口占用
# ============================================================

port_in_use() {

    local p="$1"

    if command -v ss >/dev/null 2>&1; then

        ss -H -lnt 2>/dev/null |
            awk '{print $4}' |
            grep -qE "[:.]${p}$"

    else
        return 1
    fi
}

# ============================================================
# 随机生成端口
# ============================================================

step "随机生成端口 / Generating Random Port ..."

PORT=""

for _ in $(seq 1 50); do

    if command -v shuf >/dev/null 2>&1; then

        CANDIDATE="$(
            shuf -i 10000-60000 -n 1
        )"

    else

        CANDIDATE="$(
            awk 'BEGIN {
                srand();
                print int(10000 + rand()*50001)
            }'
        )"

    fi

    case "${CANDIDATE}" in
        10000|20000|30000|40000|50000)
            continue
            ;;
    esac

    if ! port_in_use "${CANDIDATE}"; then
        PORT="${CANDIDATE}"
        break
    fi

done

[[ -n "${PORT}" ]] \
    || die "无法生成可用随机端口"

msg "${OK} Random Port: ${PORT}"

# ============================================================
# 停止旧 Xray
# ============================================================

step "检查旧服务 / Checking Existing Xray ..."

systemctl stop xray.service >/dev/null 2>&1 || true

msg "${OK}"

# ============================================================
# 安装 Xray
# ============================================================

step "开始，安装 XRAY / Installing XRAY ..."

curl -fsSL \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
    -o "${XRAY_INSTALL}"

chmod +x "${XRAY_INSTALL}"

bash "${XRAY_INSTALL}" @ install --without-geodata \
    >/tmp/xray-install.log 2>&1 \
    || {
        cat /tmp/xray-install.log
        die "Xray 安装失败"
    }

rm -f "${XRAY_INSTALL}"

[[ -x "${XRAY_BIN}" ]] \
    || die "Xray 安装成功但没有找到二进制文件"

msg "${OK}"

# ============================================================
# 创建目录
# ============================================================

mkdir -p "${XRAY_DIR}"

chmod 755 "${XRAY_DIR}"

# ============================================================
# UUID
# ============================================================

step "生成 UUID / Generating UUID ..."

UUID="$(
    cat /proc/sys/kernel/random/uuid
)"

[[ -n "${UUID}" ]] \
    || die "UUID 生成失败"

msg "${OK}"

# ============================================================
# Reality Key
# ============================================================

step "生成 Reality Key / Generating Reality Key ..."

KEY_OUTPUT="$(
    "${XRAY_BIN}" x25519 2>/dev/null
)"

PRIVATE_KEY="$(
    echo "${KEY_OUTPUT}" |
    sed -n 's/^Private key: //p' |
    head -n1
)"

PUBLIC_KEY="$(
    echo "${KEY_OUTPUT}" |
    sed -n 's/^Public key: //p' |
    head -n1
)"

[[ -n "${PRIVATE_KEY}" ]] \
    || die "Private Key 生成失败"

[[ -n "${PUBLIC_KEY}" ]] \
    || die "Public Key 生成失败"

msg "${OK}"

# ============================================================
# Short ID
# ============================================================

step "生成 Short ID / Generating Short ID ..."

SHORT_ID="$(
    openssl rand -hex 8
)"

[[ -n "${SHORT_ID}" ]] \
    || die "Short ID 生成失败"

msg "${OK}"

# ============================================================
# 获取公网 IP
# ============================================================

step "检测公网 IP / Detecting Public IP ..."

SERVER_IP="$(
    curl -4fsSL \
        --connect-timeout 3 \
        --max-time 5 \
        https://api.ipify.org \
        2>/dev/null \
        || true
)"

if [[ -z "${SERVER_IP}" ]]; then

    SERVER_IP="$(
        curl -4fsSL \
            --connect-timeout 3 \
            --max-time 5 \
            https://ifconfig.me \
            2>/dev/null \
            || true
    )"

fi

if [[ -z "${SERVER_IP}" ]]; then

    SERVER_IP="$(
        hostname -I 2>/dev/null |
        awk '{print $1}'
    )"

fi

[[ -n "${SERVER_IP}" ]] \
    || die "无法获取服务器 IP"

msg "${OK} ${SERVER_IP}"

# ============================================================
# 配置 Xray
# ============================================================

step "快速配置，手搓 / Configuring ${XRAY_CONFIG} ..."

cat > "${XRAY_CONFIG}" <<EOF
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
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],

  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

chmod 600 "${XRAY_CONFIG}"

msg "${OK}"

# ============================================================
# 检查 Xray 配置
# ============================================================

step "配置检查 / Checking Config ..."

"${XRAY_BIN}" run \
    -test \
    -config "${XRAY_CONFIG}" \
    >/tmp/xray-config-test.log 2>&1 \
    || {
        cat /tmp/xray-config-test.log
        die "Xray 配置检查失败"
    }

msg "${OK}"

# ============================================================
# 低内存 Systemd
# ============================================================

step "低内存优化 / Optimizing Memory ..."

mkdir -p /etc/systemd/system/xray.service.d

cat > /etc/systemd/system/xray.service.d/override.conf <<EOF
[Service]

# 限制 Xray 内存
MemoryHigh=40M
MemoryMax=48M

# 自动重启
Restart=always
RestartSec=2

# 限制文件句柄
LimitNOFILE=65535

# 禁止生成 core
LimitCORE=0

# 降低被 OOM 优先杀死概率
OOMScoreAdjust=-500
EOF

systemctl daemon-reload

msg "${OK}"

# ============================================================
# BBR
# ============================================================

step "最后，打开 BBR / Finishing, Enabling BBR ..."

if command -v sysctl >/dev/null 2>&1; then

    modprobe tcp_bbr >/dev/null 2>&1 || true

    sysctl -w \
        net.core.default_qdisc=fq \
        >/dev/null 2>&1 || true

    sysctl -w \
        net.ipv4.tcp_congestion_control=bbr \
        >/dev/null 2>&1 || true

fi

if command -v sysctl >/dev/null 2>&1; then

    BBR_STATUS="$(
        sysctl -n \
        net.ipv4.tcp_congestion_control \
        2>/dev/null \
        || echo "unknown"
    )"

fi

msg "${OK}"

# ============================================================
# 防火墙
# ============================================================

step "放行随机端口 / Opening Random Port ..."

if command -v ufw >/dev/null 2>&1; then

    ufw allow "${PORT}/tcp" \
        >/dev/null 2>&1 \
        || true

fi

if command -v firewall-cmd >/dev/null 2>&1; then

    firewall-cmd \
        --permanent \
        --add-port="${PORT}/tcp" \
        >/dev/null 2>&1 \
        || true

    firewall-cmd \
        --reload \
        >/dev/null 2>&1 \
        || true

fi

msg "${OK}"

# ============================================================
# 启动 Xray
# ============================================================

step "启动服务 / Starting Service ..."

systemctl enable xray.service \
    >/dev/null 2>&1 \
    || true

systemctl restart xray.service

sleep 2

msg "${OK}"

# ============================================================
# 检查服务
# ============================================================

step "检查服务状态 / Checking Service ..."

if systemctl is-active --quiet xray.service; then

    msg "${OK}"

else

    echo
    journalctl \
        -u xray.service \
        --no-pager \
        -n 30 \
        || true

    die "Xray 服务启动失败"

fi

# ============================================================
# 检测监听
# ============================================================

if command -v ss >/dev/null 2>&1; then

    if ss -lnt 2>/dev/null |
        grep -qE ":${PORT}[[:space:]]"; then

        msg "${OK} Listening: ${PORT}"

    else

        msg "${WARN} 未检测到端口监听"
    fi

fi

# ============================================================
# 生成 VLESS
# ============================================================

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Xray-Reality"

# ============================================================
# 保存信息
# ============================================================

cat > "${XRAY_INFO}" <<EOF
============================================================
Xray VLESS REALITY
============================================================

Server IP:
${SERVER_IP}

Port:
${PORT}

UUID:
${UUID}

SNI:
${DOMAIN}

Public Key:
${PUBLIC_KEY}

Private Key:
${PRIVATE_KEY}

Short ID:
${SHORT_ID}

Flow:
xtls-rprx-vision

BBR:
${BBR_STATUS}

VLESS:
${VLESS_LINK}

============================================================
EOF

chmod 600 "${XRAY_INFO}"

# ============================================================
# 最终时间
# ============================================================

END_TIME="$(date +%s)"

ELAPSED="$(
    (( END_TIME - START_TIME )) || true
)"

# ============================================================
# 最终输出
# ============================================================

echo
echo "============================================================"
echo "舒服了 / Done:"
echo "============================================================"
echo

echo "IP       : ${SERVER_IP}"
echo "PORT     : ${PORT}"
echo "UUID     : ${UUID}"
echo "SNI      : ${DOMAIN}"
echo "PublicKey: ${PUBLIC_KEY}"
echo "Short ID : ${SHORT_ID}"
echo "BBR      : ${BBR_STATUS}"

echo
echo "------------------------------------------------------------"
echo "VLESS:"
echo "------------------------------------------------------------"
echo

echo "${VLESS_LINK}"

echo
echo "------------------------------------------------------------"
echo "配置保存:"
echo "${XRAY_INFO}"
echo "------------------------------------------------------------"

echo
echo "总用时 / Elapsed Time: ${ELAPSED} 秒"
echo
echo "-------------- Live free or die hard --------------"
echo
