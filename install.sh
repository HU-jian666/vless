#!/bin/bash
# 极简 Xray VLESS + Reality 一键脚本（完全自动化）
# 支持 Ubuntu/Debian/CentOS/Rocky/Alma/Fedora 等
# 用法：bash install.sh
# 可选：--port=443 --sni=www.microsoft.com --uuid=你的UUID

SECONDS=0

# 颜色
red='\e[91m'; green='\e[92m'; yellow='\e[93m'; cyan='\e[96m'; magenta='\e[95m'; none='\e[0m'

info()  { echo -e "${yellow}$1${none}"; }
ok()    { echo -e "[${green}OK${none}]"; }
fail()  { echo -e "[${red}FAILED${none}]"; }
task()  { echo -n -e "${yellow}$1 ... ${none}"; }

# 解析参数
PORT=0
SNI="www.microsoft.com"
UUID=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --port=*) PORT="${1#*=}"; shift ;;
        --sni=*)  SNI="${1#*=}"; shift ;;
        --uuid=*) UUID="${1#*=}"; shift ;;
        --help|-h)
            echo "用法: $0 [--port=端口] [--sni=域名] [--uuid=UUID]"
            exit 0
            ;;
        *) shift ;;
    esac
done

# 必须 root
if [[ $EUID -ne 0 ]]; then
    echo -e "${red}请以 root 身份运行 / Please run as root${none}"
    exit 1
fi

echo -e "${cyan}本脚本支持带参数执行，不带参数将直接无脑 / See --help for parameters${none}"

# ---------- 1. 工具链检查 ----------
task "工具链检查 / Tool check"

# 检测包管理器
PKG=""
if command -v apt-get >/dev/null 2>&1; then
    PKG="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
elif command -v apk >/dev/null 2>&1; then
    PKG="apk"
fi

install_pkg() {
    local pkg=$1
    case $PKG in
        apt)  apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1 ;;
        dnf)  dnf install -y -q "$pkg" >/dev/null 2>&1 ;;
        yum)  yum install -y -q "$pkg" >/dev/null 2>&1 ;;
        apk)  apk add --no-cache "$pkg" >/dev/null 2>&1 ;;
        *)    return 1 ;;
    esac
}

# 必要工具
for cmd in curl openssl; do
    if ! command -v $cmd >/dev/null 2>&1; then
        install_pkg $cmd || { fail; echo -e "${red}无法安装 $cmd，请手动安装后重试${none}"; exit 1; }
    fi
done

# 可选但推荐
command -v jq >/dev/null 2>&1 || install_pkg jq || true
command -v ss  >/dev/null 2>&1 || install_pkg iproute2 || install_pkg iproute || true

ok

# ---------- 2. 安装 Xray ----------
task "开始，安装XRAY / Install XRAY"
if ! command -v xray >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /tmp/xray-install.log 2>&1
    if ! command -v xray >/dev/null 2>&1; then
        fail
        echo -e "${red}Xray 安装失败，请查看 /tmp/xray-install.log${none}"
        cat /tmp/xray-install.log | tail -20
        exit 1
    fi
fi
ok

# ---------- 3. 更新 geodata ----------
task "加速，更新geodata / Updating geodata"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata > /dev/null 2>&1 || true
ok

# ---------- 4. 生成配置 ----------
task "快好了，手搓 / Configuring /usr/local/etc/xray/config.json"

[[ -z "$UUID" ]] && UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)

KEYS=$(xray x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$KEYS" | grep -i Private | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS"  | grep -i Public  | awk '{print $NF}')

# 兼容不同版本输出格式
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    PRIVATE_KEY=$(echo "$KEYS" | sed -n 's/.*Private key: *//p' | head -1)
    PUBLIC_KEY=$(echo "$KEYS"  | sed -n 's/.*Public key: *//p'  | head -1)
fi

SHORT_ID=$(openssl rand -hex 8)

# 自动选空闲端口
if [[ $PORT -eq 0 ]]; then
    for p in 443 8443 2053 2083 2087 2096 $(shuf -i 10000-60000 -n 15 2>/dev/null || echo 10000 20000 30000); do
        if command -v ss >/dev/null 2>&1; then
            ss -tuln 2>/dev/null | grep -q ":$p " && continue
        else
            netstat -tuln 2>/dev/null | grep -q ":$p " && continue
        fi
        PORT=$p
        break
    done
    [[ $PORT -eq 0 ]] && PORT=443
fi

# 公网 IP
IP=$(curl -4s --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2)
[[ -z "$IP" ]] && IP=$(curl -4s --max-time 4 https://ip.sb 2>/dev/null)
[[ -z "$IP" ]] && IP=$(curl -4s --max-time 4 https://api.ipify.org 2>/dev/null)
[[ -z "$IP" ]] && IP="你的服务器IP"

mkdir -p /usr/local/etc/xray /var/log/xray

cat > /usr/local/etc/xray/config.json <<EOF
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
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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

# ---------- 5. 启动服务 ----------
task "冲刺，开启服务 / Starting Service"

if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service >/dev/null 2>&1; then
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        ok
    else
        fail
        echo -e "${red}systemctl 启动失败，尝试直接运行查看错误：${none}"
        /usr/local/bin/xray run -config /usr/local/etc/xray/config.json -test
        exit 1
    fi
else
    # 无 systemd 环境（容器等）直接后台运行
    pkill -f "xray run" >/dev/null 2>&1 || true
    nohup /usr/local/bin/xray run -config /usr/local/etc/xray/config.json > /var/log/xray/nohup.log 2>&1 &
    sleep 1
    if pgrep -f "xray run" >/dev/null; then
        ok
        echo -e "${yellow}（当前环境无 systemd，已使用 nohup 后台运行）${none}"
    else
        fail
        cat /var/log/xray/nohup.log
        exit 1
    fi
fi

# ---------- 6. 开启 BBR ----------
task "最后，打开BBR / Finishing, Enabling BBR"
if [[ -f /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    if ! grep -q bbr /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
        mkdir -p /etc/sysctl.d
        cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
    fi
fi
ok

# ---------- 7. 最终检查 ----------
task "检查服务状态 / Checking Service"
if pgrep -f "xray" >/dev/null || (command -v systemctl >/dev/null && systemctl is-active --quiet xray); then
    ok
else
    fail
    exit 1
fi

# ---------- 输出结果 ----------
echo -e "${green}舒服了 / Done${none}"
echo
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#$(hostname)"
echo -e "${magenta}${LINK}${none}"
echo
info "总用时 / Elapsed Time:  ${green}${SECONDS} 秒${none}"
echo -e "---------- ${cyan}live free or die hard${none} -------------"
