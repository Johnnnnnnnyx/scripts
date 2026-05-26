#!/bin/bash

set -e

# ==================================================
# Xray Reality 管理脚本
# 1. 安装
# 2. 卸载
# 3. 退出
# ==================================================

SNI="learn.microsoft.com"
DEST="learn.microsoft.com:443"

NODE_NAME_PREFIX="Johnny"
EMOJI="🌐"

PORT_MIN=20000
PORT_MAX=50000

XRAY_CONFIG="/usr/local/etc/xray/config.json"

# ==================================================
# Root 检查
# ==================================================

if [ "$(id -u)" != "0" ]; then
  echo "请使用 root 运行"
  exit 1
fi

# ==================================================
# 随机端口
# ==================================================

choose_port() {
  for i in $(seq 1 50); do
    PORT=$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)

    if ! ss -tulnp | grep -q ":${PORT} "; then
      echo "${PORT}"
      return
    fi
  done

  echo "找不到可用端口"
  exit 1
}

# ==================================================
# 安装
# ==================================================

install_xray() {

echo "=================================================="
echo "开始安装 Xray Reality"
echo "=================================================="

apt update

apt install -y \
curl \
unzip \
jq \
openssl \
ca-certificates \
lsof \
iproute2 \
socat

echo
echo "==== 获取服务器信息 ===="

SERVER_IP=$(curl -4 -s https://api.ipify.org)

if [ -z "$SERVER_IP" ]; then
  echo "无法获取公网 IP"
  exit 1
fi

echo "公网 IP：${SERVER_IP}"

ORG=$(curl -4 -s https://ipinfo.io/org || true)

if echo "$ORG" | grep -qi "DMIT"; then
  PROVIDER="DMIT"
elif echo "$ORG" | grep -qi "RackNerd"; then
  PROVIDER="RackNerd"
elif echo "$ORG" | grep -qi "Oracle"; then
  PROVIDER="Oracle"
elif echo "$ORG" | grep -qi "Tencent"; then
  PROVIDER="Tencent"
elif echo "$ORG" | grep -qi "Alibaba"; then
  PROVIDER="Alibaba"
else
  PROVIDER="VPS"
fi

echo "厂商识别：${PROVIDER}"

NODE_NAME="${EMOJI} ${NODE_NAME_PREFIX} ${PROVIDER}"

echo "节点名称：${NODE_NAME}"

PORT=$(choose_port)

echo "随机端口：${PORT}"

echo
echo "==== 安装 Xray ===="

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

XRAY_BIN="/usr/local/bin/xray"

if [ ! -x "$XRAY_BIN" ]; then
  echo "Xray 安装失败"
  exit 1
fi

echo
echo "==== 生成 Reality 参数 ===="

UUID=$($XRAY_BIN uuid)

KEYS=$($XRAY_BIN x25519)

PRIVATE_KEY=$(echo "$KEYS" | grep Private | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep Public | awk '{print $3}')

SHORT_ID=$(openssl rand -hex 8)

echo
echo "==== 写入 Xray 配置 ===="

mkdir -p /usr/local/etc/xray

if [ -f "$XRAY_CONFIG" ]; then
  cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
  echo "已备份旧配置。"
fi

cat > ${XRAY_CONFIG} <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

chmod 755 /usr/local
chmod 755 /usr/local/etc
chmod 755 /usr/local/etc/xray
chmod 644 ${XRAY_CONFIG}

echo
echo "==== 测试 Xray 配置 ===="

$XRAY_BIN run -test -config ${XRAY_CONFIG}

echo "Configuration OK."

echo
echo "==== 开启 BBR ===="

cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl --system >/dev/null 2>&1 || true

echo "BBR 已启用。"

echo
echo "==== 放行防火墙 ===="

if command -v ufw >/dev/null 2>&1; then
  ufw allow ${PORT}/tcp || true
fi

if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=${PORT}/tcp || true
  firewall-cmd --reload || true
fi

echo "如果 VPS 云厂商有安全组，也要手动放行 TCP ${PORT}。"

echo
echo "==== 启动 Xray ===="

systemctl daemon-reload
systemctl enable xray

# 不再 restart！
sleep 2

if ! systemctl is-active --quiet xray; then
  echo "Xray 未运行，尝试启动一次..."

  systemctl start xray

  sleep 2
fi

if ! systemctl is-active --quiet xray; then
  echo "Xray 启动失败，最近日志如下："

  journalctl -u xray -n 50 --no-pager

  exit 1
fi

echo
echo "=================================================="
echo "安装成功"
echo "=================================================="

echo
echo "VLESS 分享链接："
echo

echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&type=tcp&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#${NODE_NAME}"

echo
echo "Mihomo / Nikki 配置："
echo

cat <<EOF

- name: ${NODE_NAME}
  type: vless
  server: ${SERVER_IP}
  port: ${PORT}
  uuid: ${UUID}
  network: tcp
  udp: true
  tls: true
  servername: ${SNI}
  client-fingerprint: chrome
  reality-opts:
    public-key: "${PUBLIC_KEY}"
    short-id: "${SHORT_ID}"
  tfo: false
  skip-cert-verify: false

EOF

}

# ==================================================
# 卸载
# ==================================================

uninstall_xray() {

echo "=================================================="
echo "开始卸载 Xray"
echo "=================================================="

if [ -f "$XRAY_CONFIG" ]; then
  XRAY_PORT=$(grep -oP '"port"\s*:\s*\K[0-9]+' "$XRAY_CONFIG" | head -n 1 || true)
else
  XRAY_PORT=""
fi

systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true

rm -rf /usr/local/etc/xray
rm -rf /usr/local/share/xray
rm -rf /var/log/xray

rm -f /usr/local/bin/xray

rm -rf /etc/systemd/system/xray.service
rm -rf /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d
rm -rf /etc/systemd/system/xray@.service.d

rm -f /etc/sysctl.d/99-bbr.conf

systemctl daemon-reload
systemctl reset-failed

if [ -n "$XRAY_PORT" ]; then

  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow ${XRAY_PORT}/tcp 2>/dev/null || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port=${XRAY_PORT}/tcp || true
    firewall-cmd --reload || true
  fi

fi

pkill -9 xray 2>/dev/null || true

echo
echo "=================================================="
echo "卸载完成"
echo "=================================================="

}

# ==================================================
# 菜单
# ==================================================

while true; do

echo
echo "=================================================="
echo "Xray Reality 管理脚本"
echo "=================================================="
echo "1. 安装"
echo "2. 卸载"
echo "3. 退出"
echo "=================================================="

read -p "请输入选项 [1-3]: " CHOICE

case "$CHOICE" in
  1)
    install_xray
    break
    ;;
  2)
    uninstall_xray
    break
    ;;
  3)
    exit 0
    ;;
  *)
    echo "输入错误"
    ;;
esac

done
