#!/bin/bash
set -e

# ==================================================
# VLESS + REALITY 一体化管理脚本（无 Vision）
# ==================================================

SNI="learn.microsoft.com"
DEST="learn.microsoft.com:443"
NODE_NAME_PREFIX="Johnny"
EMOJI="🌐"
PORT_MIN=20000
PORT_MAX=50000

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

# Root 检查
if [ "$(id -u)" != "0" ]; then
  echo "❌ 错误：请使用 root 用户或使用 sudo 执行此脚本。"
  exit 1
fi

# ==================================================
# 安装逻辑
# ==================================================
do_install() {
  echo
  echo "==== 1. 安装基础组件 ===="
  apt update && apt install -y curl unzip socat jq openssl ca-certificates lsof iproute2

  echo
  echo "==== 2. 获取服务器信息 ===="
  SERVER_IP=$(curl -4 -s --connect-timeout 5 https://api.ipify.org || \
              curl -4 -s --connect-timeout 5 https://icanhazip.com || \
              curl -4 -s --connect-timeout 5 https://ip.sb || true)

  if [ -z "$SERVER_IP" ]; then
    echo "❌ 错误：无法获取公网 IP，请检查网络连接。"
    exit 1
  fi
  echo "公网 IP: ${SERVER_IP}"

  # 自动识别厂商
  ORG=$(curl -4 -s --connect-timeout 5 "https://ipinfo.io/org" || true)
  if echo "$ORG" | grep -qi "Gomami"; then
    PROVIDER="Gomami"
  elif echo "$ORG" | grep -qi "DMIT"; then
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

  echo
  echo "==== 3. 随机选择端口 ===="
  choose_port() {
    for i in $(seq 1 50); do
      CANDIDATE_PORT=$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)
      if ! ss -tulnp 2>/dev/null | grep -q ":${CANDIDATE_PORT} "; then
        echo "$CANDIDATE_PORT"
        return 0
      fi
    done
    echo "❌ 错误：尝试50次后未找到可用空闲端口。"
    exit 1
  }
  PORT=$(choose_port)
  echo "已选择端口：${PORT}"

  echo
  echo "==== 4. 安装 Xray ===="
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  if [ ! -x "$XRAY_BIN" ]; then
    echo "❌ 错误：Xray 二进制文件未成功安装。"
    exit 1
  fi

  echo
  echo "==== 5. 生成 Reality 参数 ===="
  UUID=$($XRAY_BIN uuid)
  KEYS=$($XRAY_BIN x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep -Ei "Private key|PrivateKey" | awk -F': ' '{print $2}' | tr -d ' ')
  PUBLIC_KEY=$(echo "$KEYS" | grep -Ei "Public key|PublicKey|Password \(PublicKey\)" | awk -F': ' '{print $2}' | tr -d ' ')
  SHORT_ID=$(openssl rand -hex 8)

  echo "UUID: ${UUID}"
  echo "PublicKey: ${PUBLIC_KEY}"

  echo
  echo "==== 6. 写入 Xray 配置 ===="
  mkdir -p /usr/local/etc/xray
  # 注意：这里使用了 'XRAYEOF' 加单引号，防止 EOF 块内部的变量在运行前被外部过度解析导致 unexpected EOF 报错
  cat > "$XRAY_CONFIG" << 'XRAYEOF'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": PORT_PLACEHOLDER,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "UUID_PLACEHOLDER"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "DEST_PLACEHOLDER",
          "xver": 0,
          "serverNames": [
            "SNI_PLACEHOLDER"
          ],
          "privateKey": "PRIVATE_KEY_PLACEHOLDER",
          "shortIds": [
            "SHORT_ID_PLACEHOLDER"
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
XRAYEOF

  # 通过 sed 动态安全替换占位符，完美避开 Bash 管道嵌套的转义大坑
  sed -i "s/PORT_PLACEHOLDER/${PORT}/g" "$XRAY_CONFIG"
  sed -i "s/UUID_PLACEHOLDER/${UUID}/g" "$XRAY_CONFIG"
  sed -i "s|DEST_PLACEHOLDER|${DEST}|g" "$XRAY_CONFIG"
  sed -i "s/SNI_PLACEHOLDER/${SNI}/g" "$XRAY_CONFIG"
  sed -i "s|PRIVATE_KEY_PLACEHOLDER|${PRIVATE_KEY}|g" "$XRAY_CONFIG"
  sed -i "s/SHORT_ID_PLACEHOLDER/${SHORT_ID}/g" "$XRAY_CONFIG"

  echo
  echo "==== 7. 测试配置 ===="
  $XRAY_BIN run -test -config "$XRAY_CONFIG"

  echo
  echo "==== 8. 开启 BBR ===="
  if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "系统已启用 BBR，跳过配置。"
  else
    cat > /etc/sysctl.d/99-bbr.conf <<BBREOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBREOF
    sysctl --system >/dev/null 2>&1 || true
    echo "BBR 拥塞控制算法已成功开启。"
  fi

  echo
  echo "==== 9. 放行防火墙 ===="
  if command -v ufw >/dev/null 2>&1; then
    ufw allow ${PORT}/tcp || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=${PORT}/tcp || true
    firewall-cmd --reload || true
  fi

  echo
  echo "==== 10. 启动 Xray ===="
  systemctl daemon-reload
  systemctl enable xray
  systemctl restart xray
  sleep 1.5

  if ! systemctl is-active --quiet xray; then
    echo "❌ 错误：Xray 启动失败，查看最近50行日志："
    journalctl -u xray -n 50 --no-pager
    exit 1
  fi

  echo
  echo "端口监听状态："
  ss -tulnp | grep ":${PORT}" || true

  echo
  echo "=================================================="
  echo "🎉 VLESS Reality 分享链接"
  echo "=================================================="
  echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&type=tcp&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#${NODE_NAME}"

  echo
  echo "=================================================="
  echo "⚙️ Mihomo / Nikki 配置"
  echo "=================================================="
  cat <<MIHOMOEOF
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
MIHOMOEOF

  echo
  echo "=================================================="
  echo "💾 参数明文备份"
  echo "=================================================="
  echo "节点名称: ${NODE_NAME}"
  echo "IP: ${SERVER_IP}"
  echo "端口: ${PORT}"
  echo "UUID: ${UUID}"
  echo "SNI: ${SNI}"
  echo "PublicKey: ${PUBLIC_KEY}"
  echo "ShortID: ${SHORT_ID}"
  echo "厂商: ${PROVIDER}"
  echo "=================================================="
  echo "安装完成。"
}

# ==================================================
# 卸载逻辑
# ==================================================
do_uninstall() {
  echo
  echo "==== 1. 尝试读取当前 Xray 端口 ===="
  if [ -f "$XRAY_CONFIG" ]; then
    XRAY_PORT=$(grep -oP '"port"\s*:\s*\K[0-9]+' "$XRAY_CONFIG" | head -n 1 || true)
    if [ -n "$XRAY_PORT" ]; then
      echo "⚙️ 检测到当前 Xray 正在使用端口：$XRAY_PORT"
    else
      echo "未能自动识别端口。"
    fi
  else
    echo "未发现配置文件 $XRAY_CONFIG"
    XRAY_PORT=""
  fi

  echo
  echo "==== 2. 停止并禁用 Xray 服务 ===="
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  echo "Xray 服务已停止并禁用。"

  echo
  echo "==== 3. 使用官方脚本卸载 Xray-core ===="
  if ! command -v curl >/dev/null 2>&1; then
    echo "检测到系统缺失 curl，正在尝试自动补齐以执行官方卸载脚本..."
    apt update && apt install -y curl || true
  fi

  if command -v curl >/dev/null 2>&1; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  else
    echo "依旧未找到 curl，将跳过官方卸载阶段，直接进行强制残留清理。"
  fi

  echo
  echo "==== 4. 清理 Xray 残留文件 ===="
  rm -rf /usr/local/etc/xray
  rm -rf /usr/local/share/xray
  rm -rf /var/log/xray
  rm -f /usr/local/bin/xray
  rm -f /etc/systemd/system/xray.service
  rm -rf /etc/systemd/system/xray.service.d

  systemctl daemon-reload
  systemctl reset-failed xray 2>/dev/null || true
  echo "Xray 相关文件及服务项已全部清理。"

  echo
  echo "==== 5. 删除 sysctl 中的 BBR 独立配置 ===="
  if [ -f /etc/sysctl.d/99-bbr.conf ]; then
    rm -f /etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null 2>&1 || true
    echo "已成功移除 /etc/sysctl.d/99-bbr.conf 并刷新内核参数。"
  else
    echo "未发现专属 BBR 配置文件，跳过。"
  fi

  echo
  echo "==== 6. 尝试清理系统防火墙规则 ===="
  if [ -n "$XRAY_PORT" ]; then
    if command -v ufw >/dev/null 2>&1; then
      ufw delete allow ${XRAY_PORT}/tcp 2>/dev/null || true
      echo "已尝试从 ufw 中移除 TCP ${XRAY_PORT} 的放行规则。"
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port=${XRAY_PORT}/tcp 2>/dev/null || true
      firewall-cmd --reload 2>/dev/null || true
      echo "已尝试从 firewalld 中移除 TCP ${XRAY_PORT} 的放行规则。"
    fi
  else
    echo "未识别到先前运行端口，跳过防火墙规则清理。"
  fi

  echo
  echo "==== 7. 最终残留状态检查 ===="
  echo "--------------------------------------------------"
  echo "1. 服务状态:"
  systemctl status xray --no-pager 2>/dev/null || echo "   xray.service 不存在或已成功卸载。"
  
  echo "2. 进程状态:"
  pgrep -a xray || echo "   未发现正在运行的 Xray 进程。"
  
  echo "3. 端口监听:"
  if [ -n "$XRAY_PORT" ]; then
    ss -tulnp | grep ":${XRAY_PORT}" || echo "   未发现端口 ${XRAY_PORT} 被占用。"
  else
    ss -tulnp | grep xray || echo "   未发现 Xray 相关的端口监听。"
  fi
  echo "--------------------------------------------------"
  echo "=================================================="
  echo "👋 卸载清理完成！"
  echo "=================================================="
  if [ -n "$XRAY_PORT" ]; then
    echo "提示：若之前在服务商后台（如云安全组/防火墙）手动放行过 TCP ${XRAY_PORT}，请记得前往面板手动关闭。"
  fi
}

# ==================================================
# 交互菜单主循环
# ==================================================
clear
echo "=================================================="
echo "    Xray VLESS + REALITY 工具箱 (无 Vision)"
echo "=================================================="
echo "  1. 自动化全新安装 (含有 Mihomo/Nikki 配置输出)"
echo "  2. 彻底卸载清理残留"
echo "  3. 退出脚本"
echo "=================================================="
read -p "请输入数字选择功能 [1-3] (默认3退出): " CHOICE

case "$CHOICE" in
  1)
    do_install
    ;;
  2)
    do_uninstall
    ;;
  3|"")
    echo "已安全退出脚本。"
    exit 0
    ;;
  *)
    echo "❌ 输入错误，请输入数字 1, 2 或 3。"
    exit 1
    ;;
esac
