#!/usr/bin/env bash
#
# https://github.com/yourname/xray-vless-reality-nokey
# 全自动安装 Xray (VLESS + XTLS-Reality)
# 无需域名、无需证书、无需交互、不创建 swap（适配小硬盘 NAT VPS）
# Fully automatic Xray (VLESS + XTLS-Reality) installer
# No domain, no cert, no prompts, no swap file (for tiny-disk NAT VPS)
#
# 用法 / Usage:
#   bash install.sh          直接运行，全自动完成安装 / just run it, fully automatic
#
set -euo pipefail

# ---------- 颜色 / Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()  { echo -e "${GREEN}[OK]${NC}"; }
err() { echo -e "${RED}$1${NC}"; exit 1; }

START_TS=$(date +%s)

# ---------- 参数（全部自动生成，无需输入） / All auto-generated, no input needed ----------
PORT=$(shuf -i 20000-60000 -n 1)      # NAT VPS 随机高位端口 / random high port for NAT VPS
SNI="www.microsoft.com"
UUID=""
XRAY_DIR="/usr/local/etc/xray"
SERVICE_NAME="xray"

[[ $EUID -ne 0 ]] && err "请使用 root 运行此脚本 / Please run this script as root"

# ---------- 1. 工具链检查 / Tool check ----------
echo "工具链检查 / Tool check ..."
for cmd in curl systemctl openssl shuf; do
  command -v "$cmd" >/dev/null 2>&1 || err "缺少依赖: $cmd / Missing dependency: $cmd"
done
ok

# ---------- 2. 安装 XRAY / Install XRAY ----------
echo "开始，安装 XRAY / Install XRAY ..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
  || err "Xray 安装失败 / Xray install failed"
ok

# ---------- 3. 生成参数 / Generate parameters ----------
# 跳过 geodata 下载：本配置不使用 geoip/geosite 路由规则，省磁盘 / geodata skipped, saves disk, not used by this minimal config
echo "生成密钥与参数 / Generating keys & parameters ..."
UUID=$(xray uuid)
KEYPAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/Private/{print $3}')
PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/Public/{print $3}')
SHORT_ID=$(openssl rand -hex 8)
ok

# ---------- 4. 配置 config.json / Configuring config.json ----------
echo "快到了，手搓 / Configuring ${XRAY_DIR}/config.json ..."
mkdir -p "$XRAY_DIR"
cat > "${XRAY_DIR}/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
ok

# ---------- 5. 启动服务 / Starting service ----------
echo "冲刺，开启服务 / Starting Service ..."
# 小内存机器加内存上限保护，防止进程异常占满内存拖死系统（不占用磁盘）
# Memory cap for low-RAM boxes so a runaway process can't take the system down (costs no disk)
mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"
cat > "/etc/systemd/system/${SERVICE_NAME}.service.d/override.conf" <<EOF
[Service]
MemoryMax=48M
MemoryHigh=40M
Restart=on-failure
RestartSec=3
EOF
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
systemctl restart "$SERVICE_NAME"
sleep 1
ok

# ---------- 6. 开启 BBR / Enabling BBR ----------
echo "最后，打开 BBR / Finishing, Enabling BBR ..."
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  {
    echo "net.core.default_qdisc=fq"
    echo "net.ipv4.tcp_congestion_control=bbr"
  } >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
fi
ok

# ---------- 7. 检查服务状态 / Checking service status ----------
echo "检查服务状态 / Checking Service ..."
systemctl is-active --quiet "$SERVICE_NAME" && ok || err "服务未运行 / Service is not running"

# ---------- 完成 / Done ----------
PUBLIC_IP=$(curl -fsSL4 https://api.ipify.org || curl -fsSL https://ifconfig.me) \
  || err "无法探测公网 IP / Could not detect public IP"

LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality-${PUBLIC_IP}"

echo ""
echo "舒服了 / Done:"
echo ""
echo "$LINK"
echo ""
echo -e "${YELLOW}若为 NAT VPS，请到服务商后台把上面端口 ${PORT} 做端口转发（外部端口->本机 ${PORT}），并把分享链接中的端口换成对外映射端口${NC}"
echo -e "${YELLOW}If this is a NAT VPS, forward the port above (${PORT}) at your provider's panel, and replace the port in the share link with the mapped public port${NC}"
echo ""

END_TS=$(date +%s)
echo "总用时 / Elapsed Time: $((END_TS - START_TS)) 秒"
echo "---------- live free or die hard --------------"
