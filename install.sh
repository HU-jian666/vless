#!/usr/bin/env bash
#
# https://github.com/YOURNAME/vless-reality-64mb
# VLESS+REALITY 64MB内存优化一键安装 / 64MB RAM optimized one-click installer
# 本脚本支持带参数执行，不带参数将使用默认配置 / See --help for parameters
#
set -euo pipefail

# ---------- 颜色 / Colors ----------
C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_B='\033[0;34m'; C_N='\033[0m'
ok()   { echo -e "${C_G}[OK]${C_N}"; }
fail() { echo -e "${C_R}[FAIL]${C_N}"; echo -e "${C_R}$1${C_N}"; exit 1; }
step() { echo -ne "$1 ... "; }

START_TS=$(date +%s)

# ---------- 默认参数 / Defaults ----------
PORT=443
UUID=""
SNI="www.microsoft.com"
SHORT_ID=""
SWAP_MB=256
WORKDIR="/usr/local/etc/xray"
BIN="/usr/local/bin/xray"

usage() {
cat <<EOF
用法 / Usage: $0 [options]
  -p, --port <port>       监听端口 / listen port (default: 443)
  -s, --sni <domain>      伪装域名 / camouflage SNI (default: www.microsoft.com)
  -u, --uuid <uuid>       指定UUID / fixed UUID (default: random)
  --no-swap               不创建swap / skip swapfile creation
  -h, --help              显示帮助 / show this help
EOF
exit 0
}

NO_SWAP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port) PORT="$2"; shift 2 ;;
    -s|--sni) SNI="$2"; shift 2 ;;
    -u|--uuid) UUID="$2"; shift 2 ;;
    --no-swap) NO_SWAP=1; shift ;;
    -h|--help) usage ;;
    *) fail "未知参数 / unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || fail "请以root运行 / must run as root"

# ---------- 工具链检查 / Tool check ----------
step "工具链检查 / Tool check"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) XARCH="64" ;;
  aarch64) XARCH="arm64-v8a" ;;
  armv7l) XARCH="arm32-v7a" ;;
  *) fail "不支持的架构 / unsupported arch: $ARCH" ;;
esac
for c in curl unzip systemctl openssl; do
  command -v "$c" >/dev/null 2>&1 || {
    (command -v apt-get >/dev/null && apt-get update -qq && apt-get install -y -qq curl unzip openssl >/dev/null 2>&1) || \
    (command -v yum >/dev/null && yum install -y -q curl unzip openssl >/dev/null 2>&1) || \
    fail "缺少依赖且无法自动安装 / missing dep, auto-install failed: $c"
    break
  }
done
ok

# ---------- 内存不足时创建 swap / Create swap on low-RAM systems ----------
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
IS_CONTAINER=0
[[ -f /.dockerenv ]] && IS_CONTAINER=1
grep -qaE '(lxc|docker|container)' /proc/1/cgroup 2>/dev/null && IS_CONTAINER=1
[[ "$(systemd-detect-virt 2>/dev/null)" =~ ^(lxc|docker|openvz)$ ]] && IS_CONTAINER=1

if [[ $NO_SWAP -eq 0 && $TOTAL_MEM_MB -lt 512 && ! -f /swapfile && $IS_CONTAINER -eq 0 ]]; then
  step "低内存，创建 ${SWAP_MB}MB swap / low RAM, creating ${SWAP_MB}MB swap"
  fallocate -l ${SWAP_MB}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_MB status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  if swapon /swapfile 2>/dev/null; then
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok
  else
    rm -f /swapfile
    echo -e "${C_Y}[SKIP]${C_N} 宿主机禁止swap（容器环境） / host disallows swap (container), skipping"
  fi
elif [[ $NO_SWAP -eq 0 && $TOTAL_MEM_MB -lt 512 && ! -f /swapfile && $IS_CONTAINER -eq 1 ]]; then
  echo -e "${C_Y}[SKIP]${C_N} 检测到容器环境，跳过swap创建 / container detected, skipping swap"
fi

# ---------- 安装 XRAY / Install XRAY (无GeoIP精简版 / no-geoip slim) ----------
step "开始，安装XRAY / Install XRAY"
mkdir -p "$WORKDIR" /usr/local/share/xray
LATEST=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
curl -fsSL -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${LATEST}/Xray-linux-${XARCH}.zip"
unzip -oq /tmp/xray.zip -d /tmp/xray-extract xray
install -m 755 /tmp/xray-extract/xray "$BIN"
rm -rf /tmp/xray.zip /tmp/xray-extract
ok

# ---------- geodata / Updating geodata (mini版，节省内存 / mini, saves RAM) ----------
step "加速，更新geodata / Updating geodata"
curl -fsSL -o /usr/local/share/xray/geoip.dat \
  https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip-only-cn-private.dat
curl -fsSL -o /usr/local/share/xray/geosite.dat \
  https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
ok

# ---------- 生成密钥/UUID / Generate keys ----------
step "快好了，手搓 / Configuring ${WORKDIR}/config.json"
[[ -z "$UUID" ]] && UUID=$("$BIN" uuid)
[[ -z "$SHORT_ID" ]] && SHORT_ID=$(openssl rand -hex 8)
KEYPAIR=$("$BIN" x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/Private/{print $3}')
PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/Public/{print $3}')

cat > "$WORKDIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
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
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
ok

# ---------- systemd (内存硬限制 / hard memory cap) ----------
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
User=root
ExecStart=${BIN} run -config ${WORKDIR}/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=32768
MemoryMax=48M
MemoryHigh=40M
TasksMax=64
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

step "冲刺，开启服务 / Starting Service"
systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || fail "服务启动失败，查看 / service failed, check: journalctl -u xray -e"
ok

# ---------- BBR ----------
step "最后，打开BBR / Finishing, Enabling BBR"
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
fi
ok

# ---------- 检查服务状态 / Checking Service ----------
step "检查服务状态 / Checking Service"
systemctl is-active --quiet xray && ok || fail "xray未运行 / xray not running"

echo "舒服了 / Done:"
echo ""

IP=$(curl -fsSL -4 https://api.ipify.org || curl -fsSL -6 https://api64.ipify.org)
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VLESS-REALITY-64MB"

echo -e "${C_Y}${LINK}${C_N}"
echo ""
echo "内存占用限制 / Memory cap: 48MB (MemoryMax)"
echo "配置文件 / Config: ${WORKDIR}/config.json"

END_TS=$(date +%s)
echo ""
echo "总用时 / Elapsed Time:  $((END_TS - START_TS)) 秒"
echo "---------- live free or die hard --------------"
