#!/usr/bin/env bash
#
# https://github.com/yourname/xray-vless-reality-nokey
# 一键安装 Xray (VLESS + XTLS-Reality)，无需域名、无需证书
# 适配 NAT VPS（随机端口）+ 64MB 小内存机器
# One-click installer for Xray with VLESS + XTLS-Reality (no domain / no cert needed)
# Tuned for NAT VPS (random port) + 64MB low-memory instances
#
# 用法 / Usage:
#   bash install.sh                          # 全自动随机端口 / fully automatic, random port
#   bash install.sh --pub-ip 1.2.3.4 --pub-port 51234 --port 21234
#   bash install.sh --help                   # 查看参数 / show parameters
#
set -euo pipefail

# ---------- 颜色 / Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}"; }
info() { echo -e "${BLUE}$1${NC}"; }
err()  { echo -e "${RED}$1${NC}"; exit 1; }

START_TS=$(date +%s)

# ---------- 默认参数 / Defaults ----------
PORT=""            # 本机(内网)监听端口 / local listen port inside the NAT box
PUB_IP=""          # NAT 映射后对外的公网 IP / public-facing IP after NAT mapping
PUB_PORT=""        # NAT 映射后对外的端口 / public-facing port after NAT mapping
SNI="www.microsoft.com"
UUID=""
XRAY_DIR="/usr/local/etc/xray"
SERVICE_NAME="xray"
SWAP_FILE="/swapfile"
SWAP_SIZE_MB=256    # 64MB 机器强烈建议开 swap / strongly recommended on 64MB boxes

usage() {
  cat <<EOF
参数 / Parameters:
  --port <port>       本机监听端口 (默认随机 20000-60000)   Local listen port (default: random 20000-60000)
  --pub-ip <ip>       NAT 对外公网 IP (默认自动探测本机出口IP)  Public IP after NAT (default: auto-detect)
  --pub-port <port>   NAT 对外映射端口 (默认与 --port 相同)   Public port after NAT (default: same as --port)
  --sni <domain>      伪装目标域名 (默认 www.microsoft.com)   Camouflage SNI (default www.microsoft.com)
  --uuid <uuid>       指定 UUID (默认随机生成)                Specify UUID (default: random)
  --no-swap           跳过创建 swap (不推荐用于 <=128MB 机器)  Skip swap creation (not recommended on <=128MB)
  -h, --help          显示帮助                                Show this help

说明 / Notes:
  NAT VPS 场景下，宿主机把某个外部端口转发到你这台机器的某个内部端口，
  二者通常不同。--port 是 Xray 实际监听的端口，--pub-ip/--pub-port
  是客户端连接时应该填写的地址，脚本会分别处理并把正确的信息写进分享链接。
  In a NAT VPS setup, the host forwards an external port to a different
  internal port on your box. --port is what Xray actually listens on;
  --pub-ip/--pub-port is what clients should connect to. The script keeps
  these separate and puts the correct values into the generated share link.
EOF
  exit 0
}

NO_SWAP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --pub-ip) PUB_IP="$2"; shift 2;;
    --pub-port) PUB_PORT="$2"; shift 2;;
    --sni) SNI="$2"; shift 2;;
    --uuid) UUID="$2"; shift 2;;
    --no-swap) NO_SWAP=1; shift;;
    -h|--help) usage;;
    *) err "未知参数 / Unknown parameter: $1";;
  esac
done

[[ $EUID -ne 0 ]] && err "请使用 root 运行此脚本 / Please run this script as root"

# 随机端口：NAT VPS 通常不能用 443，改用高位随机端口 / random high port, 443 usually unusable on NAT VPS
[[ -z "$PORT" ]] && PORT=$(shuf -i 20000-60000 -n 1)
[[ -z "$PUB_PORT" ]] && PUB_PORT="$PORT"

# ---------- 1. 工具链检查 / Tool check ----------
echo "工具链检查 / Tool check ..."
for cmd in curl wget tar systemctl openssl shuf; do
  command -v "$cmd" >/dev/null 2>&1 || err "缺少依赖: $cmd / Missing dependency: $cmd"
done
ok

# ---------- 1.5 小内存机器加 swap / Add swap for low-memory boxes ----------
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [[ "$NO_SWAP" -eq 0 && "$TOTAL_MEM_MB" -le 256 ]]; then
  echo "内存 ${TOTAL_MEM_MB}MB 偏小，创建 swap / Low memory detected, creating swap ..."
  if ! swapon --show | grep -q "$SWAP_FILE"; then
    fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" >/dev/null 2>&1
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
    swapon "$SWAP_FILE"
    grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    # 64MB 机器 swappiness 调高一点，减少被 OOM kill 的概率
    sysctl -w vm.swappiness=25 >/dev/null 2>&1 || true
  fi
  ok
else
  echo "内存充足或已跳过 / Sufficient memory or skipped, no swap needed"
fi

# ---------- 2. 安装 XRAY / Install XRAY ----------
echo "开始，安装 XRAY / Install XRAY ..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
  || err "Xray 安装失败 / Xray install failed"
ok

# ---------- 3. 更新 geodata / Updating geodata ----------
echo "加速，更新 geodata / Updating geodata ..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata >/dev/null 2>&1 || true
ok

# ---------- 4. 生成参数 / Generate parameters ----------
[[ -z "$UUID" ]] && UUID=$(xray uuid)
KEYPAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/Private/{print $3}')
PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/Public/{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# ---------- 5. 配置 config.json / Configuring config.json ----------
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

# ---------- 6. 启动服务 / Starting service ----------
echo "冲刺，开启服务 / Starting Service ..."
# 64MB 机器加内存上限保护，防止 xray 异常占满内存把系统拖死
# Cap memory on tiny boxes so a runaway xray process can't take the whole system down
mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d
cat > /etc/systemd/system/${SERVICE_NAME}.service.d/override.conf <<EOF
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

# ---------- 7. 开启 BBR / Enabling BBR ----------
echo "最后，打开 BBR / Finishing, Enabling BBR ..."
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  {
    echo "net.core.default_qdisc=fq"
    echo "net.ipv4.tcp_congestion_control=bbr"
  } >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
fi
ok

# ---------- 8. 检查服务状态 / Checking service status ----------
echo "检查服务状态 / Checking Service ..."
systemctl is-active --quiet "$SERVICE_NAME" && ok || err "服务未运行 / Service is not running"

# ---------- 完成 / Done ----------
# 自动探测公网 IP（仅在未通过 --pub-ip 指定时）/ auto-detect public IP only if --pub-ip wasn't given
if [[ -z "$PUB_IP" ]]; then
  PUB_IP=$(curl -fsSL4 https://api.ipify.org || curl -fsSL https://ifconfig.me) \
    || err "无法探测公网 IP，请用 --pub-ip 手动指定 / Could not detect public IP, pass --pub-ip manually"
fi

LINK="vless://${UUID}@${PUB_IP}:${PUB_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality-NAT-${PUB_IP}"

echo ""
echo "舒服了 / Done:"
echo ""
echo "本机监听端口 / Local listen port : ${PORT}"
echo "对外连接地址   / Connect address  : ${PUB_IP}:${PUB_PORT}"
echo ""
echo "$LINK"
echo ""
if [[ "$PORT" != "$PUB_PORT" ]]; then
  echo -e "${YELLOW}提醒：NAT 转发需在服务商后台把外部端口 ${PUB_PORT} 转发到本机 ${PORT} 端口${NC}"
  echo -e "${YELLOW}Reminder: configure NAT forwarding at your provider from public port ${PUB_PORT} to local port ${PORT}${NC}"
  echo ""
fi

END_TS=$(date +%s)
echo "总用时 / Elapsed Time: $((END_TS - START_TS)) 秒"
echo "---------- live free or die hard --------------"
