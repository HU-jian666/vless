#!/bin/bash
# Xray VLESS Reality 一键安装 | 不带参数直接无敌
set -e

# 颜色
G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; R='\033[0m'
T=$(date +%s)

# 配置（要改直接改这里）
PORT=443
DEST="www.microsoft.com:443"
SNI="www.microsoft.com"

echo ""
echo -e "${C}脚本本支持带参数执行，不带参数将直接无敌 / See --help for parameters${R}"
echo ""

# 1. 工具检查
echo -n -e "工具链检查 / Tool check ... "
[ "$EUID" -ne 0 ] && echo -e "${G}[OK]${R}\n需要 root" && exit 1
OS=$(cat /etc/os-release 2>/dev/null | grep ^ID= | cut -d= -f2 | tr -d '"')
case "$OS" in
  ubuntu|debian) apt-get update -qq && apt-get install -y -qq curl wget unzip jq qrencode openssl >/dev/null 2>&1 ;;
  centos|rhel|fedora|rocky|alma) yum install -y curl wget unzip jq qrencode openssl >/dev/null 2>&1 ;;
  alpine) apk add --no-cache curl wget unzip jq qrencode openssl >/dev/null 2>&1 ;;
esac
echo -e "${G}[OK]${R}"

# 2. 安装 Xray
echo -n -e "开始，安装 XRAY / Install XRAY ... "
if [ ! -f /usr/local/bin/xray ]; then
  curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install >/dev/null 2>&1
fi
echo -e "${G}[OK]${R}"

# 3. 更新 geodata
echo -n -e "加速，更新 geodata / Updating geodata ... "
mkdir -p /usr/local/share/xray
curl -sL -o /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat &
curl -sL -o /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat &
wait
echo -e "${G}[OK]${R}"

# 4. 生成配置
echo -n -e "快好了，手搓 / Configuring /usr/local/etc/xray/config.json ... "
mkdir -p /usr/local/etc/xray
UUID=$(cat /proc/sys/kernel/random/uuid)
KP=$(/usr/local/bin/xray x25519)
PRIK=$(echo "$KP" | grep Private | awk '{print $3}')
PUBK=$(echo "$KP" | grep Public | awk '{print $3}')
SID=$(openssl rand -hex 8)
IP=$(curl -s4 https://api.ipify.org)

cat > /usr/local/etc/xray/config.json << EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "listen":"0.0.0.0","port":${PORT},"protocol":"vless",
    "settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},
    "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
      "show":false,"dest":"${DEST}","xver":0,
      "serverNames":["${SNI}"],"privateKey":"${PRIK}","shortIds":["${SID}",""]
    }},
    "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
  }],
  "outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]
}
EOF
echo -e "${G}[OK]${R}"

# 5. 启动服务
echo -n -e "冲刺，开启服务 / Starting Service ... "
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
echo -e "${G}[OK]${R}"

# 6. 开启 BBR
echo -n -e "最后，打开 BBR / Finishing, Enabling BBR ... "
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  modprobe tcp_bbr 2>/dev/null && {
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
  }
fi
echo -e "${G}[OK]${R}"

# 7. 检查状态
echo -n -e "检查服务状态 / Checking Service ... "
sleep 1
systemctl is-active --quiet xray && echo -e "${G}[OK]${R}" || echo -e "${Y}[WARN]${R}"

# 输出
E=$(( $(date +%s) - T ))
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBK}&sid=${SID}&type=tcp#Xray-${IP}"

echo ""
echo -e "${G}舒服了 / Done:${R}"
echo ""
echo "$LINK"
echo ""
echo "$LINK" | qrencode -t ANSIUTF8 2>/dev/null || true
echo ""
echo -e "${Y}总用时 / Elapsed Time: ${E} 秒${R}"
echo ""
echo "---------- live free or die hard ----------"
echo ""

# 备份信息
cat > /root/xray-info.txt << EOF
IP: ${IP}
PORT: ${PORT}
UUID: ${UUID}
PUBLIC_KEY: ${PUBK}
PRIVATE_KEY: ${PRIK}
SHORT_ID: ${SID}
SNI: ${SNI}
LINK: ${LINK}
EOF
