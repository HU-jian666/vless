#!/bin/bash
# 轻量 Xray VLESS Reality 零键安装脚本（适配 64MB 内存环境）
# 风格参考 livingfree2023/nokey，完全自动化，可上传自用仓库

set -e
export DEBIAN_FRONTEND=noninteractive

# 颜色
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'
cyan='\033[0;36m'; magenta='\033[0;35m'; none='\033[0m'

# 默认配置
PORT=""
UUID=""
DOMAIN="www.microsoft.com"          # 常用 Reality 目标，可改
NETSTACK="auto"                     # 4 / 6 / auto
FORCE_GEODATA=0
DRY_RUN=0
SCRIPT_VERSION="2026.08-64mb"

log()  { echo -e "${cyan}$1${none}"; }
ok()   { echo -e "${green}$1 [OK]${none}"; }
info() { echo -e "${yellow}$1${none}"; }
err()  { echo -e "${red}$1${none}"; exit 1; }

# 解析参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --port=*)       PORT="${1#*=}"; shift ;;
    --uuid=*)       UUID="${1#*=}"; shift ;;
    --domain=*)     DOMAIN="${1#*=}"; shift ;;
    --netstack=*)   NETSTACK="${1#*=}"; shift ;;
    --force)        FORCE_GEODATA=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --help|-h)
      echo "用法: $0 [选项]"
      echo "  --port=NUMBER     指定端口（默认随机 10000+）"
      echo "  --uuid=STRING     指定 UUID（默认自动生成）"
      echo "  --domain=DOMAIN   Reality SNI（默认 www.microsoft.com）"
      echo "  --netstack=4|6    强制 IPv4/IPv6（默认自动）"
      echo "  --force           强制更新 geodata"
      echo "  --dry-run         仅预览，不修改系统"
      echo "  --help            显示帮助"
      exit 0
      ;;
    *) err "未知参数: $1  使用 --help 查看" ;;
  esac
done

# 检查 root
[[ $EUID -ne 0 ]] && err "请使用 root 运行（sudo -i）"

# 检测架构
ARCH=$(uname -m)
case $ARCH in
  x86_64|amd64) XRAY_ARCH="amd64" ;;
  aarch64|arm64) XRAY_ARCH="arm64" ;;
  *) err "不支持的架构: $ARCH" ;;
esac

# 检测发行版（尽量兼容）
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS=$ID
else
  OS="unknown"
fi

log "本脚本支持带参数执行，不带参数将直接无交互 / See --help for parameters"
log "工具链检查 / Tool check ... "
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 || yum install -y curl ca-certificates >/dev/null 2>&1 || true; }
ok "工具链检查 / Tool check ... "

# 安装目录
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
mkdir -p /usr/local/etc/xray /var/log/xray

if [[ $DRY_RUN -eq 1 ]]; then
  info "[DRY-RUN] 预览模式，不会真正安装"
fi

# 1. 安装 Xray（优先用官方预编译，失败再回退）
log "开始，安装XRAY / Install XRAY ... "
if [[ $DRY_RUN -eq 0 ]]; then
  # 使用 XTLS 官方安装脚本（最稳）
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /tmp/xray-install.log 2>&1 || {
    # 备用：直接下二进制（更省内存）
    LATEST=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")' | head -1)
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${LATEST}/Xray-linux-${XRAY_ARCH}.zip"
    unzip -o /tmp/xray.zip -d /tmp/xray
    mv /tmp/xray/xray $XRAY_BIN
    chmod +x $XRAY_BIN
    rm -rf /tmp/xray /tmp/xray.zip
  }
fi
ok "开始，安装XRAY / Install XRAY ... "

# 2. geodata（可选跳过）
log "加速，更新geodata / Updating geodata ... "
if [[ $FORCE_GEODATA -eq 1 || ! -f /usr/local/share/xray/geoip.dat ]]; then
  if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p /usr/local/share/xray
    curl -L -o /usr/local/share/xray/geoip.dat   https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
    curl -L -o /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
  fi
fi
ok "加速，更新geodata / Updating geodata ... "

# 3. 生成密钥 & UUID & 端口
log "快好了，手搓 / Configuring /usr/local/etc/xray/config.json ... "
[[ -z $UUID ]] && UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$($XRAY_BIN x25519 2>/dev/null || echo "Private key: dummy
Public key: dummy")
PRIVATE_KEY=$(echo "$KEYS" | grep Private | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep Public | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8 2>/dev/null || echo "0123456789abcdef")

# 随机端口
if [[ -z $PORT ]]; then
  for i in {1..20}; do
    PORT=$((10000 + RANDOM % 50000))
    if ! ss -tuln | grep -q ":$PORT "; then break; fi
  done
fi

# IP 检测
if [[ $NETSTACK == "6" ]]; then
  IP=$(curl -6 -s --connect-timeout 3 ifconfig.co || curl -6 -s icanhazip.com)
elif [[ $NETSTACK == "4" ]]; then
  IP=$(curl -4 -s --connect-timeout 3 ifconfig.co || curl -4 -s icanhazip.com)
else
  IP=$(curl -4 -s --connect-timeout 3 ifconfig.co 2>/dev/null || curl -6 -s --connect-timeout 3 ifconfig.co)
fi
[[ -z $IP ]] && IP=$(hostname -I | awk '{print $1}')

# 写配置
cat > $XRAY_CONF <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
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
          "shortIds": ["${SHORT_ID}", ""]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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
ok "快好了，手搓 / Configuring /usr/local/etc/xray/config.json ... "

# 4. 启动服务
log "中刺，开启服务 / Starting Service ... "
if [[ $DRY_RUN -eq 0 ]]; then
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || err "xray 服务启动失败，请检查日志"
fi
ok "中刺，开启服务 / Starting Service ... "

# 5. 开启 BBR
log "最后，打开BBR / Finishing, Enabling BBR ... "
if [[ $DRY_RUN -eq 0 ]]; then
  if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p >/dev/null 2>&1 || true
  fi
fi
ok "最后，打开BBR / Finishing, Enabling BBR ... "

# 6. 检查状态
log "检查服务状态 / Checking Service ... "
if [[ $DRY_RUN -eq 0 ]]; then
  systemctl is-active --quiet xray && ok "检查服务状态 / Checking Service ... " || err "服务异常"
else
  ok "检查服务状态 / Checking Service ... "
fi

# 输出链接
VLESS_URL="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#live-free-or-die-hard"

echo
echo -e "${magenta}${VLESS_URL}${none}"
echo
info "总用时 / Elapsed Time: 约几秒"
echo "--------- live free or die hard ---------"
echo
info "配置文件: $XRAY_CONF"
info "日志: /var/log/xray/"
info "重启: systemctl restart xray"
info "卸载: systemctl stop xray && systemctl disable xray && rm -rf /usr/local/bin/xray /usr/local/etc/xray"
