#!/bin/bash
# 极简 Xray VLESS + Reality 一键脚本（完全自动化，无交互）
# 支持 Ubuntu/Debian/CentOS/Rocky/Alma/Fedora 等 systemd 系统
# 用法：bash install.sh
# 可选参数：--port=443 --sni=www.microsoft.com --uuid=你的UUID

set -e
SECONDS=0

# 颜色
red='\e[91m'; green='\e[92m'; yellow='\e[93m'; cyan='\e[96m'; magenta='\e[95m'; none='\e[0m'

info()  { echo -e "${yellow}$1${none}"; }
ok()    { echo -e "[${green}OK${none}]"; }
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

# 1. 工具链检查
task "工具链检查 / Tool check"
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl >/dev/null 2>&1 || yum install -y -q curl >/dev/null 2>&1; }
command -v jq   >/dev/null 2>&1 || { apt-get install -y -qq jq >/dev/null 2>&1 || yum install -y -q jq >/dev/null 2>&1; }
ok

# 2. 安装 Xray（官方脚本）
task "开始，安装XRAY / Install XRAY"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /tmp/xray-install.log 2>&1
ok

# 3. 更新 geodata（可选，快速跳过也可）
task "加速，更新geodata / Updating geodata"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata > /dev/null 2>&1 || true
ok

# 4. 生成密钥与 UUID
task "快好了，手搓 / Configuring /usr/local/etc/xray/config.json"
[[ -z "$UUID" ]] && UUID=$(xray uuid)
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/{print $3}')
PUBLIC_KEY=$(echo "$KEYS"  | awk '/Public/{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# 自动选一个空闲端口（默认随机，优先 443）
if [[ $PORT -eq 0 ]]; then
    for p in 443 8443 2053 2083 2087 2096 $(shuf -i 10000-60000 -n 20); do
        if ! ss -tuln | grep -q ":$p "; then
            PORT=$p
            break
        fi
    done
fi

# 获取公网 IP
IP=$(curl -4s --max-time 3 https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2)
[[ -z "$IP" ]] && IP=$(curl -4s --max-time 3 https://ip.sb)

# 写入配置
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
ok

# 5. 启动服务
task "冲刺，开启服务 / Starting Service"
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
ok

# 6. 开启 BBR
task "最后，打开BBR / Finishing, Enabling BBR"
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1
fi
ok

# 7. 检查服务
task "检查服务状态 / Checking Service"
systemctl is-active --quiet xray && ok || { echo -e "[${red}FAILED${none}]"; exit 1; }

# 输出结果
echo -e "${green}舒服了 / Done${none}"
echo
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#$(hostname)"
echo -e "${magenta}${LINK}${none}"
echo
info "总用时 / Elapsed Time:  ${green}${SECONDS} 秒${none}"
echo -e "---------- ${cyan}live free or die hard${none} -------------"
