#!/bin/bash
#
# Xray VLESS Reality 一键安装脚本
# GitHub: https://github.com/yourname/xray-vless-reality
# Usage: bash install.sh [--help]
#

set -e

# ============================================================
# 颜色定义
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================
# 全局变量
# ============================================================
START_TIME=$(date +%s)
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"
DEFAULT_PORT=443
DEFAULT_DEST="www.microsoft.com:443"
DEFAULT_SERVER_NAMES="www.microsoft.com"
SERVICE_NAME="xray"

# ============================================================
# 帮助信息
# ============================================================
show_help() {
    cat << EOF
Xray VLESS Reality 一键安装脚本

用法:
  bash install.sh [选项]

选项:
  --help              显示此帮助信息
  --port <端口>       指定监听端口 (默认: ${DEFAULT_PORT})
  --dest <地址:端口>  指定 Reality 目标地址 (默认: ${DEFAULT_DEST})
  --sni <域名>        指定 SNI / serverNames (默认: ${DEFAULT_SERVER_NAMES})
  --uninstall         卸载 Xray

示例:
  bash install.sh
  bash install.sh --port 8443 --dest www.amazon.com:443 --sni www.amazon.com
  bash install.sh --uninstall

EOF
    exit 0
}

# ============================================================
# 参数解析
# ============================================================
UNINSTALL=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            show_help
            ;;
        --port)
            DEFAULT_PORT="$2"
            shift 2
            ;;
        --dest)
            DEFAULT_DEST="$2"
            shift 2
            ;;
        --sni)
            DEFAULT_SERVER_NAMES="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"
            show_help
            ;;
    esac
done

# ============================================================
# 工具函数
# ============================================================
print_step() {
    echo -e "${CYAN}$1${NC}"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# 检查命令是否存在
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 获取系统类型
get_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "centos"
    else
        echo "unknown"
    fi
}

# ============================================================
# 卸载功能
# ============================================================
do_uninstall() {
    print_step "正在卸载 Xray ..."

    if systemctl list-units --type=service | grep -q "${SERVICE_NAME}"; then
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
        systemctl disable ${SERVICE_NAME} 2>/dev/null || true
        print_ok "已停止并禁用服务"
    fi

    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    systemctl daemon-reload 2>/dev/null || true

    print_ok "卸载完成"
    exit 0
}

# ============================================================
# 主安装流程
# ============================================================

# 卸载模式
if [ "$UNINSTALL" = true ]; then
    do_uninstall
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}   Xray VLESS Reality 一键安装脚本${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ----------------------------------------------------------
# Step 1: 权限与环境检查
# ----------------------------------------------------------
print_step "工具链检查 / Tool check ..."

if [ "$EUID" -ne 0 ]; then
    print_error "请使用 root 用户运行此脚本"
    exit 1
fi
print_ok "root 权限检查"

OS=$(get_os)
case "$OS" in
    ubuntu|debian)
        PKG_MANAGER="apt"
        ;;
    centos|rhel|fedora|rocky|alma)
        PKG_MANAGER="yum"
        ;;
    alpine)
        PKG_MANAGER="apk"
        ;;
    *)
        print_error "不支持的系统: $OS"
        exit 1
        ;;
esac
print_ok "系统检测: $OS"

# 安装基础依赖
if [ "$PKG_MANAGER" = "apt" ]; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq curl wget unzip jq qrencode >/dev/null 2>&1
elif [ "$PKG_MANAGER" = "yum" ]; then
    yum install -y curl wget unzip jq qrencode >/dev/null 2>&1
elif [ "$PKG_MANAGER" = "apk" ]; then
    apk add --no-cache curl wget unzip jq qrencode >/dev/null 2>&1
fi
print_ok "依赖工具安装 (curl/wget/unzip/jq/qrencode)"

# ----------------------------------------------------------
# Step 2: 安装 Xray
# ----------------------------------------------------------
print_step "开始，安装 XRAY / Install XRAY ..."

if [ -f "$XRAY_BIN" ]; then
    print_ok "Xray 已存在，跳过安装"
else
    # 使用官方安装脚本
    curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install >/dev/null 2>&1
    if [ ! -f "$XRAY_BIN" ]; then
        print_error "Xray 安装失败，请检查网络连接"
        exit 1
    fi
    print_ok "Xray 安装完成"
fi

XRAY_VERSION=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')
print_ok "Xray 版本: ${XRAY_VERSION:-unknown}"

# ----------------------------------------------------------
# Step 3: 更新 Geo 数据
# ----------------------------------------------------------
print_step "加速，更新 geodata / Updating geodata ..."

GEO_DIR="/usr/local/share/xray"
mkdir -p "$GEO_DIR"

# 下载 geoip.dat 和 geosite.dat (使用加速镜像)
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

curl -sL -o "${GEO_DIR}/geoip.dat" "$GEOIP_URL" 2>/dev/null || true
curl -sL -o "${GEO_DIR}/geosite.dat" "$GEOSITE_URL" 2>/dev/null || true

if [ -f "${GEO_DIR}/geoip.dat" ] && [ -f "${GEO_DIR}/geosite.dat" ]; then
    print_ok "geodata 更新完成"
else
    print_info "geodata 下载可能不完整，将使用内置默认数据"
fi

# ----------------------------------------------------------
# Step 4: 生成配置
# ----------------------------------------------------------
print_step "快好了，手搓 / Configuring ${XRAY_CONFIG_FILE} ..."

mkdir -p "$XRAY_CONFIG_DIR"

# 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "$(date +%s%N | md5sum | head -c 8)-$(date +%s%N | md5sum | head -c 4)-$(date +%s%N | md5sum | head -c 4)-$(date +%s%N | md5sum | head -c 4)-$(date +%s%N | md5sum | head -c 12)")

# 生成 Reality 密钥对
KEY_PAIR=$("$XRAY_BIN" x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "Public key:" | awk '{print $3}')

# 生成 shortId (8位十六进制)
SHORT_ID=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | xxd -p 2>/dev/null || echo "0123456789abcdef")

# 获取服务器公网 IP
SERVER_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || curl -s4 https://ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")

# 写入 config.json
cat > "$XRAY_CONFIG_FILE" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${DEFAULT_PORT},
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
          "dest": "${DEFAULT_DEST}",
          "xver": 0,
          "serverNames": [
            "${DEFAULT_SERVER_NAMES}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}",
            ""
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
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

print_ok "UUID: ${UUID:0:8}..."
print_ok "Reality 密钥对已生成"
print_ok "shortId: ${SHORT_ID}"
print_ok "配置文件写入: ${XRAY_CONFIG_FILE}"

# 验证配置
if "$XRAY_BIN" -test -c "$XRAY_CONFIG_FILE" >/dev/null 2>&1; then
    print_ok "配置文件校验通过"
else
    print_error "配置文件校验失败，请检查格式"
    exit 1
fi

# ----------------------------------------------------------
# Step 5: 启动服务
# ----------------------------------------------------------
print_step "冲刺，开启服务 / Starting Service ..."

# systemd 服务文件（如果不存在）
if [ ! -f /etc/systemd/system/${SERVICE_NAME}.service ]; then
    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
fi

systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
systemctl restart ${SERVICE_NAME}
sleep 1

if systemctl is-active --quiet ${SERVICE_NAME}; then
    print_ok "服务已启动并设置开机自启"
else
    print_error "服务启动失败，请检查日志: journalctl -u ${SERVICE_NAME} -e"
    exit 1
fi

# ----------------------------------------------------------
# Step 6: 开启 BBR
# ----------------------------------------------------------
print_step "最后，打开 BBR / Finishing, Enabling BBR ..."

# 检查是否已开启 BBR
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    print_ok "BBR 已开启，跳过"
else
    # 尝试开启 BBR
    if lsmod | grep -q bbr || modprobe tcp_bbr 2>/dev/null; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
            print_ok "BBR 已启用"
        else
            print_info "BBR 启用失败（可能需要内核支持），不影响核心功能"
        fi
    else
        print_info "当前内核不支持 BBR，跳过"
    fi
fi

# ----------------------------------------------------------
# Step 7: 检查服务状态
# ----------------------------------------------------------
print_step "检查服务状态 / Checking Service ..."

sleep 1
if systemctl is-active --quiet ${SERVICE_NAME}; then
    SERVICE_STATUS="running"
    print_ok "服务运行正常"
else
    SERVICE_STATUS="failed"
    print_error "服务异常"
fi

# 检查端口监听
if ss -tlnp 2>/dev/null | grep -q ":${DEFAULT_PORT} " || netstat -tlnp 2>/dev/null | grep -q ":${DEFAULT_PORT} "; then
    print_ok "端口 ${DEFAULT_PORT} 正在监听"
else
    print_info "端口 ${DEFAULT_PORT} 未检测到监听（可能被防火墙拦截）"
fi

# ----------------------------------------------------------
# 输出结果
# ----------------------------------------------------------
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo -e "${GREEN}舒服了 / Done:${NC}"
echo ""

# 生成 VLESS 链接
# 格式: vless://uuid@ip:port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=...&fp=chrome&pbk=...&sid=...&type=tcp#remark
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${DEFAULT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEFAULT_SERVER_NAMES}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Xray-Reality-${SERVER_IP}"

echo -e "${YELLOW}---------- 节点信息 ----------${NC}"
echo -e "  协议:       ${CYAN}VLESS + Reality${NC}"
echo -e "  地址:       ${CYAN}${SERVER_IP}${NC}"
echo -e "  端口:       ${CYAN}${DEFAULT_PORT}${NC}"
echo -e "  UUID:       ${CYAN}${UUID}${NC}"
echo -e "  流控:       ${CYAN}xtls-rprx-vision${NC}"
echo -e "  公钥(PBK):  ${CYAN}${PUBLIC_KEY}${NC}"
echo -e "  短ID(SID):  ${CYAN}${SHORT_ID}${NC}"
echo -e "  SNI:        ${CYAN}${DEFAULT_SERVER_NAMES}${NC}"
echo -e "  指纹:       ${CYAN}chrome${NC}"
echo -e "${YELLOW}------------------------------${NC}"
echo ""
echo -e "${YELLOW}---------- 订阅链接 ----------${NC}"
echo -e "${CYAN}${VLESS_LINK}${NC}"
echo ""

# 生成二维码（如果有 qrencode）
if check_cmd qrencode; then
    echo -e "${YELLOW}---------- 二维码 ----------${NC}"
    echo "$VLESS_LINK" | qrencode -t ANSIUTF8 2>/dev/null || true
    echo ""
fi

# 保存配置信息到文件
INFO_FILE="/root/xray-reality-info.txt"
cat > "$INFO_FILE" << EOF
Xray VLESS Reality 安装信息
============================
安装时间: $(date '+%Y-%m-%d %H:%M:%S')
服务器IP: ${SERVER_IP}
端口: ${DEFAULT_PORT}
UUID: ${UUID}
流控: xtls-rprx-vision
私钥: ${PRIVATE_KEY}
公钥: ${PUBLIC_KEY}
短ID: ${SHORT_ID}
SNI: ${DEFAULT_SERVER_NAMES}
目标: ${DEFAULT_DEST}

订阅链接:
${VLESS_LINK}

配置文件: ${XRAY_CONFIG_FILE}
服务管理: systemctl {start|stop|restart|status} ${SERVICE_NAME}
查看日志: journalctl -u ${SERVICE_NAME} -f
EOF

echo -e "${GREEN}[OK]${NC} 配置信息已保存到: ${INFO_FILE}"
echo ""
echo -e "${YELLOW}总用时 / Elapsed Time: ${ELAPSED} 秒${NC}"
echo ""
echo -e "---------- ${BLUE}live free or die hard${NC} ----------"
echo ""
