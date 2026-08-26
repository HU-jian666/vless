#!/usr/bin/env bash
# ============================================================
# Xray VLESS + REALITY
# LOW MEMORY / RANDOM PORT / FULL AUTO
#
# 适用于：
#   64MB / 128MB VPS
#   Debian / Ubuntu
#   amd64
#
# 特点：
#   1. 不使用 install-release.sh
#   2. 直接下载官方 Xray Release
#   3. 不安装 geodata
#   4. 随机 TCP 端口
#   5. 自动 UUID
#   6. 自动 Reality Key
#   7. 自动 Short ID
#   8. 自动 systemd
#   9. 自动 BBR
#  10. 自动防火墙
#  11. 自动输出 VLESS
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

TMP_DIR="/tmp/xray-lowmem"

PORT=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SERVER_IP=""
MEM_MB=""

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
# 清理旧临时文件
# ============================================================

rm -rf "${TMP_DIR}" 2>/dev/null || true
mkdir -p "${TMP_DIR}"

# ============================================================
# 检查内存
# ============================================================

msg "内存检测 / Checking Memory ..."

MEM_MB="$(
    awk '
    /MemTotal/ {
        printf "%d\n", $2 / 1024
    }
    ' /proc/meminfo
)"

[[ -n "${MEM_MB}" ]] || die "无法获取内存"

msg "${OK} ${MEM_MB} MB"

if (( MEM_MB <= 80 )); then
    msg "${WARN} LOW MEMORY MODE"
fi

# ============================================================
# 架构
# ============================================================

msg "架构检测 / Detecting Architecture ..."

MACHINE="$(uname -m)"

case "${MACHINE}" in

    x86_64|amd64)
        XRAY_ARCH="64"
        ;;

    aarch64|arm64)
        XRAY_ARCH="arm64-v8a"
        ;;

    armv7l)
        XRAY_ARCH="arm32-v7a"
        ;;

    *)
        die "不支持的架构: ${MACHINE}"
        ;;

esac

msg "${OK} ${MACHINE}"

# ============================================================
# 系统
# ============================================================

msg "系统检测 / Detecting OS ..."

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
else
    die "无法读取 /etc/os-release"
fi

OS_ID="${ID:-unknown}"

msg "${OK} ${OS_ID}"

# ============================================================
# 工具检查
# 尽量不执行 apt update，避免低内存环境产生额外压力
# ============================================================

msg "工具链检查 / Tool Check ..."

missing_tools=()

command -v curl >/dev/null 2>&1 || missing_tools+=("curl")
command -v openssl >/dev/null 2>&1 || missing_tools+=("openssl")
command -v unzip >/dev/null 2>&1 || missing_tools+=("unzip")
command -v ss >/dev/null 2>&1 || missing_tools+=("iproute2")

if (( ${#missing_tools[@]} > 0 )); then

    case "${OS_ID}" in

        debian|ubuntu)

            # 仅安装缺失工具，不执行 apt update
            apt-get install -y \
                "${missing_tools[@]}" \
                >/dev/null 2>&1 \
                || die "无法安装必要工具"

            ;;

        *)

            die "缺少必要工具: ${missing_tools[*]}"

            ;;

    esac

fi

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

PORT=""

for _ in $(seq 1 100); do

    if command -v shuf >/dev/null 2>&1; then

        CANDIDATE="$(
            shuf -i 10000-60000 -n 1
        )"

    else

        CANDIDATE="$(
            awk 'BEGIN {
                srand();
                print int(10000 + rand() * 50001)
            }'
        )"

    fi

    if ! port_used "${CANDIDATE}"; then
        PORT="${CANDIDATE}"
        break
    fi

done

[[ -n "${PORT}" ]] || die "随机端口生成失败"

msg "${OK} Random Port: ${PORT}"

# ============================================================
# 检查旧 Xray
# ============================================================

msg "检查旧服务 / Checking Existing Xray ..."

systemctl stop xray.service \
    >/dev/null 2>&1 \
    || true

pkill -x xray \
    >/dev/null 2>&1 \
    || true

msg "${OK}"

# ============================================================
# 直接下载官方 Xray Release
# ============================================================

msg "开始，下载 XRAY / Downloading XRAY ..."

mkdir -p "${TMP_DIR}"

XRAY_ZIP="${TMP_DIR}/xray.zip"

case "${XRAY_ARCH}" in

    64)

        XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"

        ;;

    arm64-v8a)

        XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"

        ;;

    arm32-v7a)

        XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip"

        ;;

    *)

        die "不支持的 Xray 架构"

        ;;

esac

curl -4fL \
    --connect-timeout 10 \
    --retry 2 \
    --max-time 120 \
    "${XRAY_URL}" \
    -o "${XRAY_ZIP}" \
    || die "Xray 下载失败"

[[ -s "${XRAY_ZIP}" ]] \
    || die "Xray 下载文件为空"

msg "${OK}"

# ============================================================
# 解压
# ============================================================

msg "解压 XRAY / Extracting XRAY ..."

unzip -oq \
    "${XRAY_ZIP}" \
    xray \
    -d "${TMP_DIR}" \
    >/dev/null 2>&1 \
    || die "Xray 解压失败"

[[ -f "${TMP_DIR}/xray" ]] \
    || die "解压后没有找到 xray"

# ============================================================
# 安装二进制
# ============================================================

install -m 755 \
    "${TMP_DIR}/xray" \
    "${XRAY_BIN}"

[[ -x "${XRAY_BIN}" ]] \
    || die "Xray 二进制安装失败"

# 删除压缩包
rm -f "${XRAY_ZIP}"

msg "${OK}"

# ============================================================
# 创建目录
# ============================================================

mkdir -p "${XRAY_DIR}"

chmod 755 "${XRAY_DIR}"

# ============================================================
# 获取 Xray 版本
# ============================================================

XRAY_VERSION="$(
    "${XRAY_BIN}" version 2>/dev/null |
    head -n 1 |
    tr -d '\r'
)"

# ============================================================
# UUID
# ============================================================

msg "生成 UUID / Generating UUID ..."

UUID="$(
    cat /proc/sys/kernel/random/uuid
)"

[[ -n "${UUID}" ]] \
    || die "UUID 生成失败"

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

[[ -n "${PRIVATE_KEY}" ]] \
    || die "Private Key 生成失败"

[[ -n "${PUBLIC_KEY}" ]] \
    || die "Public Key 生成失败"

msg "${OK}"

# ============================================================
# Short ID
# ============================================================

msg "生成 Short ID / Generating Short ID ..."

SHORT_ID="$(
    openssl rand -hex 8
)"

[[ -n "${SHORT_ID}" ]] \
    || die "Short ID 生成失败"

msg "${OK}"

# ============================================================
# 获取公网 IP
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
    || die "无法获取公网 IP"

msg "${OK} ${SERVER_IP}"

# ============================================================
# 配置
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
# 配置测试
# ============================================================

msg "检查配置 / Checking Config ..."

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
# systemd 服务
# ============================================================

msg "创建服务 / Creating Service ..."

cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple

User=root
Group=root

ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}

Restart=always
RestartSec=2

MemoryHigh=40M
MemoryMax=48M

LimitNOFILE=65535
LimitCORE=0

OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

msg "${OK}"

# ============================================================
# BBR
# ============================================================

msg "最后，打开 BBR / Finishing, Enabling BBR ..."

if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
fi

if command -v sysctl >/dev/null 2>&1; then

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
    sysctl \
        -n \
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
# 启动
# ============================================================

msg "启动服务 / Starting Service ..."

systemctl enable xray.service \
    >/dev/null 2>&1 \
    || true

systemctl restart xray.service

sleep 2

msg "${OK}"

# ============================================================
# 服务检查
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
# 检查监听
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
# VLESS
# ============================================================

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Xray-Reality"

# ============================================================
# 保存配置
# ============================================================

cat > "${XRAY_INFO}" <<EOF
============================================================
Xray VLESS REALITY
============================================================

Xray:
${XRAY_VERSION}

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
# 删除临时文件
# ============================================================

rm -rf "${TMP_DIR}" 2>/dev/null || true
rm -f /tmp/xray-config-test.log 2>/dev/null || true

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

echo "Xray     : ${XRAY_VERSION}"
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
