#!/usr/bin/env bash
#
# https://github.com/yourname/hysteria2-nokey
# 全自动安装 Hysteria2 (HY2)
# 无需域名（自签证书）、无需交互、不创建 swap，适配 NAT VPS 随机端口 + 小内存/小硬盘
# Fully automatic Hysteria2 (HY2) installer
# No domain (self-signed cert), no prompts, no swap file — for NAT VPS random port + low RAM/disk
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
SNI="www.bing.com"                    # 仅用于证书 CN、客户端 SNI 与伪装站点 / cert CN, client SNI & masquerade site
MASQ_URL="https://www.bing.com"
PASSWORD=""
CONFIG_DIR="/usr/local/etc/hysteria"
CERT_DIR="${CONFIG_DIR}/cert"
BIN_PATH="/usr/local/bin/hysteria"
SERVICE_NAME="hysteria-server"

[[ $EUID -ne 0 ]] && err "请使用 root 运行此脚本 / Please run this script as root"

# ---------- 1. 工具链检查 / Tool check ----------
echo "工具链检查 / Tool check ..."
for cmd in curl systemctl openssl shuf; do
  command -v "$cmd" >/dev/null 2>&1 || err "缺少依赖: $cmd / Missing dependency: $cmd"
done
ok

# ---------- 2. 安装 Hysteria2 / Install Hysteria2 ----------
echo "开始，安装 Hysteria2 / Install Hysteria2 ..."
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l) ARCH="arm" ;;
  *) err "不支持的架构: $(uname -m) / Unsupported architecture" ;;
esac

curl -fsSL "https://download.hysteria.network/app/latest/hysteria-linux-${ARCH}" -o "$BIN_PATH" \
  || err "Hysteria2 下载失败 / Hysteria2 download failed"
chmod +x "$BIN_PATH"
ok

# ---------- 3. 生成参数 / Generate parameters ----------
echo "生成密钥与参数 / Generating keys & parameters ..."
PASSWORD=$(openssl rand -hex 16)

mkdir -p "$CERT_DIR"
openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/private.key" >/dev/null 2>&1
openssl req -new -x509 -days 3650 -key "${CERT_DIR}/private.key" \
  -out "${CERT_DIR}/cert.pem" -subj "/CN=${SNI}" >/dev/null 2>&1
ok

# ---------- 4. 配置 config.yaml / Configuring config.yaml ----------
echo "快到了，手搓 / Configuring ${CONFIG_DIR}/config.yaml ..."
mkdir -p "$CONFIG_DIR"
cat > "${CONFIG_DIR}/config.yaml" <<EOF
listen: :${PORT}

tls:
  cert: ${CERT_DIR}/cert.pem
  key: ${CERT_DIR}/private.key

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASQ_URL}
    rewriteHost: true

bandwidth:
  up: 200 mbps
  down: 200 mbps
EOF
ok

# ---------- 5. 启动服务 / Starting service ----------
echo "冲刺，开启服务 / Starting Service ..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Hysteria2 Server Service
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} server -c ${CONFIG_DIR}/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity
MemoryMax=48M
MemoryHigh=40M

[Install]
WantedBy=multi-user.target
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

LINK="hysteria2://${PASSWORD}@${PUBLIC_IP}:${PORT}/?insecure=1&sni=${SNI}#HY2-${PUBLIC_IP}"

echo ""
echo "舒服了 / Done:"
echo ""
echo "$LINK"
echo ""
echo -e "${YELLOW}证书为自签，客户端必须开启 \"跳过证书验证 / insecure\" 才能连接${NC}"
echo -e "${YELLOW}Certificate is self-signed — client must enable \"skip cert verify / insecure\" to connect${NC}"
echo -e "${YELLOW}HY2 基于 QUIC，走 UDP。若为 NAT VPS，请到服务商后台把端口 ${PORT}（UDP）做转发，并把链接里的端口换成对外映射端口${NC}"
echo -e "${YELLOW}HY2 runs over QUIC/UDP. If this is a NAT VPS, forward port ${PORT} (UDP) at your provider's panel and replace the port in the link with the mapped public port${NC}"
echo ""

END_TS=$(date +%s)
echo "总用时 / Elapsed Time: $((END_TS - START_TS)) 秒"
echo "---------- live free or die hard --------------"
