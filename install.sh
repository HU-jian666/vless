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
CONF=/usr/local/etc/xray/config.json
PORT=""
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

# 有些终端/输入法/剪贴板工具会把裸域名自动转成 markdown 链接
# [www.x.com](https://www.x.com)，导致写进 config.json 后 REALITY 握手失败。
# 这里统一净化：命中该模式就取方括号内的纯文本，其余不变。
strip_md_link() {
  echo "$1" | sed -E 's/\[([^]]+)\]\([^)]*\)/\1/g'
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

SNI=$(strip_md_link "$SNI")

# 端口/UUID 若未显式指定，优先复用上次生成的 config.json 里的值——
# 避免重跑脚本随机换端口，导致跟面板/NAT 里已经配好的端口转发对不上（表现就是“连不上”）。
if [[ -f "$CONF" ]]; then
  OLD_PORT=$(grep -oE '"port":[[:space:]]*[0-9]+' "$CONF" | head -1 | grep -oE '[0-9]+' || true)
  OLD_UUID=$(grep -oE '"id":[[:space:]]*"[0-9a-fA-F-]+"' "$CONF" | head -1 | grep -oE '[0-9a-fA-F-]{36}' || true)
  if [[ -z "$PORT" && -n "$OLD_PORT" ]]; then
    PORT="$OLD_PORT"
    echo -e "${C_Y}[INFO]${C_N} 复用已有端口 ${PORT}（避免打乱已配置的端口转发）。要换端口显式传 --port"
  fi
  if [[ -z "$UUID" && -n "$OLD_UUID" ]]; then
    UUID="$OLD_UUID"
  fi
fi
[[ -z "$PORT" ]] && PORT=$(rand_port)

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

# ---------- 4b. sanitize config.json against markdown-link corruption ----------
if grep -qE '\[[^]]+\]\([^)]*\)' /usr/local/etc/xray/config.json; then
  echo -e "${C_Y}[WARN]${C_N} 检测到 config.json 被污染成 markdown 链接格式（多半是粘贴通道自动转链接导致），已自动修复"
  sed -i -E 's/\[([^]]+)\]\([^)]*\)/\1/g' /usr/local/etc/xray/config.json
fi

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
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
if [[ "$CURRENT_CC" == "bbr" ]]; then
  ok
else
  AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
  if [[ "$AVAILABLE_CC" != *bbr* ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
  fi
  if [[ "$AVAILABLE_CC" != *bbr* ]]; then
    echo -e "${C_Y}[WARN]${C_N} 内核不支持 BBR 模块（tcp_bbr 不可用），跳过——这不影响连通性，只影响吞吐"
  else
    grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    SYSCTL_ERR=$(sysctl -p 2>&1 >/dev/null || true)
    NEW_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$NEW_CC" == "bbr" ]]; then
      ok
    else
      echo -e "${C_Y}[WARN]${C_N} sysctl 写入未生效（多半是容器化 NAT VPS，/proc 只读或无 CAP_NET_ADMIN），BBR 开不了：${SYSCTL_ERR:-写入被拒绝}"
      echo -e "${C_Y}      不影响连通性，只是没有 BBR 加速${C_N}"
    fi
  fi
fi

# ---------- 7. check service ----------
step "检查服务状态 / Checking Service"
systemctl is-active --quiet xray && ok || die "service not running"

# ---------- 7b. verify the REALITY fallback target actually supports what REALITY needs ----------
# 光 TCP 三次握手通是不够的：REALITY 要求目标必须能完整走 TLS1.3 握手。
# www.microsoft.com 走 Azure Front Door，边缘节点行为不稳定，是已知对 REALITY
# 不太友好的目标（容易被按 ClientHello 指纹拒绝），所以这里做真实 TLS1.3 探测，
# 不行就自动换一个更稳的目标并重写 config.json。
step "校验回落目标 TLS1.3 可达性 / Verifying dest TLS1.3 handshake"
check_tls13() {
  echo | timeout 6 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 2>/dev/null \
    | grep -q "Protocol.*TLSv1.3"
}
if check_tls13 "$SNI"; then
  ok
else
  echo -e "${C_Y}[WARN]${C_N} ${SNI}:443 TLS1.3 握手失败，REALITY 会连不上。尝试自动切换伪装域名..."
  FALLBACKS=(www.bing.com www.amazon.com gateway.icloud.com swdist.apple.com www.cloudflare.com)
  NEW_SNI=""
  for cand in "${FALLBACKS[@]}"; do
    [[ "$cand" == "$SNI" ]] && continue
    step "  尝试 ${cand}"
    if check_tls13 "$cand"; then
      ok
      NEW_SNI="$cand"
      break
    else
      echo -e "${C_R}[FAIL]${C_N}"
    fi
  done
  if [[ -n "$NEW_SNI" ]]; then
    echo -e "${C_Y}[INFO]${C_N} 切换伪装域名: ${SNI} -> ${NEW_SNI}，重写 config.json"
    SNI="$NEW_SNI"
    sed -i "s#\"dest\": \".*\"#\"dest\": \"${SNI}:443\"#" "$CONF"
    sed -i "s#\"serverNames\": \[.*\]#\"serverNames\": [\"${SNI}\"]#" "$CONF"
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray || die "xray restart failed after SNI switch"
  else
    echo -e "${C_R}[WARN]${C_N} 候选伪装域名全部 TLS1.3 探测失败，服务器出站可能被限制。保留 ${SNI}，但大概率仍连不上，建议人工换一个你确认可达的域名用 --sni 指定"
  fi
fi

echo -e "${C_G}舒服了 / Done:${C_N}"
echo -e "监听端口 / Listening port: ${C_Y}${PORT}${C_N}  ${C_R}（NAT/面板端口转发必须转发这个端口，TCP+UDP 都要放）${C_N}"
echo

IP=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s6 --max-time 5 https://api64.ipify.org)
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${TAG}"

echo -e "${C_Y}${LINK}${C_N}"
echo

END_TS=$(date +%s)
echo "总用时 / Elapsed Time:  $((END_TS-START_TS)) 秒"
echo "---------- live free or die hard --------------"
