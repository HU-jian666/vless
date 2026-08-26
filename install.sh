#!/usr/bin/env bash
# ============================================================
# Xray VLESS + REALITY 一键安装
# LOW MEMORY / RANDOM PORT / FULL AUTO
# ============================================================

set -Eeuo pipefail

START_TIME="$(date +%s)"

# ============================================================
# 基础变量
# ============================================================

DOMAIN="www.apple.com"

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_INFO="/root/xray-info.txt"

PORT=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SERVER_IP=""

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

die() {
    msg "${FAIL} $1"
    exit 1
}

# ============================================================
# Root
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 用户运行"
fi

# ============================================================
# Banner
# ============================================================

clear 2>/dev/null || true

echo
echo "============================================================"
echo "        VLESS + REALITY / XRAY / LOW MEMORY"
echo "        RANDOM PORT / FULL AUTO"
echo "============================================================"
echo

# ============================================================
# 内存检测
# ============================================================

msg "内存检测 / Checking Memory ..."

MEM_MB="$(
    awk '/MemTotal/ {
        printf "%d\n",$2/1024
    }' /proc/meminfo
)"

if [[ -z "${MEM_MB}" ]]; then
    die "无法读取内存"
fi

msg "${OK} ${MEM_MB} MB"

# ============================================================
# 架构检测
# ============================================================

msg "架构检测 / Detecting Architecture ..."

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
        die "不支持的架构: $(uname -m)"
        ;;

esac

msg "${OK} ${ARCH}"

# ============================================================
# 系统检测
# ============================================================

msg "系统检测 / Detecting OS ..."

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
else
    die "无法识别系统"
fi

OS_ID="${ID:-unknown}"

msg "${OK} ${OS_ID}"

# ============================================================
# 工具链
# ============================================================

msg "工具链检查 / Tool Check ..."

export DEBIAN_FRONTEND=noninteractive

case "${OS_ID}" in

    debian|ubuntu)

        apt-get update -y \
            >/dev/null 2>&1 \
            || true

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
            >/dev/null 2>&1 \
            || true

        ;;

    *)

        msg "${WARN} 未识别系统，继续尝试"

        ;;

esac

msg "${OK}"

# ============================================================
# 随机端口
# ============================================================

msg "随机生成端口 / Generating Random Port ..."

port_used() {

    local P="$1"

    if command -v ss >/dev/null 2>&1; then

        ss -H -lnt 2>/dev/null |
        awk '{print $4}' |
        grep -qE "([.:])${P}$"

    else

        return 1

    fi
}

for _ in $(seq 1 100); do

    if command -v shuf >/dev/null 2>&1; then

        TEST_PORT="$(
            shuf -i 10000-60000 -n 1
        )"

    else

        TEST_PORT="$(
            awk 'BEGIN {
                srand();
                print int(10000+rand()*50001)
            }'
        )"

    fi

    if ! port_used "${TEST_PORT}"; then
        PORT="${TEST_PORT}"
        break
    fi

done

[[ -n "${PORT}" ]] || die "无法生成随机端口"

msg "${OK} Random Port: ${PORT}"

# ============================================================
# 停止旧服务
# ============================================================

msg "检查旧服务 / Checking Existing Xray ..."

systemctl stop xray.service \
    >/dev/null 2>&1 \
    || true

msg "${OK}"

# ============================================================
# 安装 Xray
# ============================================================

msg "开始，安装 XRAY / Installing XRAY ..."

# 使用 Xray 官方推荐方式
bash -c "$(
    curl -fsSL \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh
)" @ install --without-geodata \
    >/tmp/xray-install.log 2>&1 \
    || {
        cat /tmp/xray-install.log
        die "Xray 安装失败"
    }

[[ -x "${XRAY_BIN}" ]] \
    || die "Xray 二进制文件不存在"

msg "${OK}"

# ============================================================
# 创建目录
# ============================================================

mkdir -p "${XRAY_DIR}"

chmod 755 "${XRAY_DIR}"

# ============================================================
# UUID
# ============================================================

msg "生成 UUID / Generating UUID ..."

UUID="$(
    cat /proc/sys/kernel/random/uuid
)"

[[ -n "${UUID}" ]] || die "UUID 生成失败"

msg "${OK}"

# ============================================================
# Reality Key
# ============================================================

msg "生成 Reality Key / Generating Reality Key ..."

KEY_OUTPUT="$(
    "${XRAY_BIN}" x25519 2>/dev/null
)"

PRIVATE_KEY="$(
    printf '%s\n' "${KEY_OUTPUT}" |
    sed -n 's/^Private key: //p' |
    head -n 1
)"

PUBLIC_KEY="$(
    printf '%s\n' "${KEY_OUTPUT}" |
    sed -n 's/^Public key: //p' |
    head -n 1
)"

[[ -n "${PRIVATE_KEY}" ]] || die "Private Key 生成失败"

[[ -n "${PUBLIC_KEY}" ]] || die "Public Key 生成失败"

msg "${OK}"

# ============================================================
# Short ID
# ============================================================

msg "生成 Short ID / Generating Short ID ..."

SHORT_ID="$(
    openssl rand -hex 8
)"

[[ -n "${SHORT_ID}" ]] || die "Short ID 生成失败"

msg "${OK}"

# ============================================================
# 公网 IP
# ============================================================

msg "检测公网 IP / Detecting Public IP ..."

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

msg "快速配置，手搓 / Configuring ${XRAY_CONFIG} ..."

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
# 检查配置
# ============================================================

msg "配置检查 / Checking Config ..."

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
# systemd 低内存优化
# ============================================================

msg "低内存优化 / Optimizing Memory ..."

mkdir -p /etc/systemd/system/xray.service.d

cat > /etc/systemd/system/xray.service.d/override.conf <<EOF
[Service]
MemoryHigh=40M
MemoryMax=48M
Restart=always
RestartSec=2
LimitNOFILE=65535
LimitCORE=0
OOMScoreAdjust=-500
EOF

systemctl daemon-reload

msg "${OK}"

# ============================================================
# BBR
# ============================================================

msg "最后，打开 BBR / Finishing, Enabling BBR ..."

if command -v sysctl >/dev/null 2>&1; then

    modprobe tcp_bbr \
        >/dev/null 2>&1 \
        || true

    sysctl -w \
        net.core.default_qdisc=fq \
        >/dev/null 2>&1 \
        || true

    sysctl -w \
        net.ipv4.tcp_congestion_control=bbr \
        >/dev/null 2>&1 \
        || true

fi

BBR_STATUS="$(
    sysctl -n \
    net.ipv4.tcp_congestion_control \
    2>/dev/null \
    || echo "unknown"
)"

msg "${OK}"

# ============================================================
# 防火墙
# ============================================================

msg "放行随机端口 / Opening Random Port ..."

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
# 启动服务
# ============================================================

msg "启动服务 / Starting Service ..."

systemctl enable xray.service \
    >/dev/null 2>&1 \
    || true

systemctl restart xray.service

sleep 2

msg "${OK}"

# ============================================================
# 检查服务状态
# ============================================================

msg "检查服务状态 / Checking Service ..."

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
# 检查端口
# ============================================================

if command -v ss >/dev/null 2>&1; then

    if ss -lnt 2>/dev/null |
       grep -qE ":${PORT}[[:space:]]"; then

        msg "${OK} Listening: ${PORT}"

    else

        msg "${WARN} 未检测到 ${PORT} 监听"

    fi

fi

# ============================================================
# 生成 VLESS
# ============================================================

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Xray-Reality"

# ============================================================
# 保存配置
# ============================================================

cat > "${XRAY_INFO}" <<EOF
============================================================
Xray VLESS REALITY
============================================================

IP:
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
# 时间
# ============================================================

END_TIME="$(date +%s)"

ELAPSED=$((END_TIME - START_TIME))

# ============================================================
# Done
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
