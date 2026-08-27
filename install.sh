#!/usr/bin/env bash
# https://github.com/YOURNAME/xray-vless-reality-nokey
# VLESS + XTLS-REALITY one-click installer (no cert / no domain needed)
# 本脚本支持带参数执行，不带参数将直接使用推荐默认值 / See --help for parameters
set -euo pipefail

# ---------- colors ----------
C_G='\033[1;32m'; C_C='\033[1;36m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_N='\033[0m'
ok()   { echo -e "${C_G}[OK]${C_N}"; }
step() { echo -ne "${C_C}$1${C_N} ... "; }
die()  { echo -e "${C_R}[FAIL]${C_N} $1"; exit 1; }

START_TS=$(date +%s)

# ---------- defaults ----------
rand_port() {
  local p
  while :; do
    p=$(( (RANDOM << 4 | RANDOM) % 55536 + 10000 ))   # 10000-65535
    if command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}\$" && continue
    elif command -v netstat >/dev/null 2>&1; then
      netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}\$" && continue
    else
      (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null && { exec 3>&-; continue; }
    fi
    echo "$p"; return
  done
}
PORT=$(rand_port)
SNI="www.microsoft.com"
UUID=""
TAG="vless-reality"

usage() {
  cat <<EOF
Usage: $0 [--port 443] [--sni www.microsoft.com] [--uuid <uuid>] [--tag name]
  --port    监听端口 / listen port      (default: random 10000-65535)
  --sni     伪装域名 / camouflage SNI    (default: $SNI)
  --uuid    自定义 UUID / custom UUID    (default: auto-generated)
  --tag     节点备注 / node remark       (default: $TAG)
  -h --help 显示帮助 / show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --sni) SNI="$2"; shift 2 ;;
    --uuid) UUID="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "请以 root 运行 / must run as root"

# ---------- 1. tool check ----------
step "工具链检查 / Tool check"
for bin in curl jq openssl systemctl; do
  command -v "$bin" >/dev/null 2>&1 || (command -v apt-get >/dev/null && apt-get install -y "$bin" -qq >/dev/null 2>&1) || true
done
command -v curl >/dev/null && command -v openssl >/dev/null || die "missing dependencies"
ok

# ---------- 2. install xray ----------
step "开始，安装 XRAY / Install XRAY"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
  || die "xray install failed"
ok

# ---------- 3. update geodata ----------
step "加速，更新 geodata / Updating geodata"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata >/dev/null 2>&1 || true
ok

# ---------- 4. generate keys/uuid ----------
step "快好了，手搓 / Configuring /usr/local/etc/xray/config.json"
[[ -z "$UUID" ]] && UUID=$(xray uuid)
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i 'private' | sed -E 's/^[^:]*:[[:space:]]*//')
PUBLIC_KEY=$(echo "$KEYS"  | grep -Ei 'public|password' | sed -E 's/^[^:]*:[[:space:]]*//')
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { echo "$KEYS"; die "failed to parse xray x25519 output"; }
SHORT_ID=$(openssl rand -hex 8)

mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
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
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
ok

# ---------- 5. start service ----------
step "冲刺，开启服务 / Starting Service"
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || {
  echo -e "${C_R}[FAIL]${C_N}"
  echo "---- journalctl -u xray -n 30 ----"
  journalctl -u xray -n 30 --no-pager || true
  echo "---- xray config test ----"
  /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json || true
  die "xray failed to start"
}
ok

# ---------- 6. BBR ----------
step "最后，打开 BBR / Finishing, Enabling BBR"
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
fi
ok

# ---------- 7. check service ----------
step "检查服务状态 / Checking Service"
systemctl is-active --quiet xray && ok || die "service not running"

echo -e "${C_G}舒服了 / Done:${C_N}"
echo

IP=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s6 --max-time 5 https://api64.ipify.org)
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${TAG}"

echo -e "${C_Y}${LINK}${C_N}"
echo

END_TS=$(date +%s)
echo "总用时 / Elapsed Time:  $((END_TS-START_TS)) 秒"
echo "---------- live free or die hard --------------"
