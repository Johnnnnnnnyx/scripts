#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================================
# Xray VLESS + Reality 管理脚本（安装 / 卸载 / 退出）
# 修复点：不再使用官方 service 里的 User=nobody，直接重写 systemd service，避免 config.json permission denied
# ==================================================

SNI="learn.microsoft.com"
DEST="learn.microsoft.com:443"
NODE_NAME_PREFIX="Johnny"
EMOJI="🌐"
PORT_MIN=20000
PORT_MAX=50000
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_PARAM_FILE="/usr/local/etc/xray/reality-info.txt"
XRAY_SERVICE="/etc/systemd/system/xray.service"

red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

require_root() {
  if [ "$(id -u)" != "0" ]; then
    red "错误：请使用 root 用户执行。"
    exit 1
  fi
}

install_deps() {
  echo "==== 安装基础组件 ===="
  apt update -y
  apt install -y curl unzip socat jq openssl ca-certificates lsof iproute2 procps coreutils
}

get_ip() {
  SERVER_IP="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || true)"
  if [ -z "${SERVER_IP}" ]; then
    SERVER_IP="$(hostname -I | awk '{print $1}')"
  fi
  if [ -z "${SERVER_IP}" ]; then
    red "错误：无法获取公网 IP。"
    exit 1
  fi
}

get_provider() {
  ORG="$(curl -4 -fsSL https://ipinfo.io/org 2>/dev/null || true)"
  if echo "$ORG" | grep -qi "Gomami"; then PROVIDER="Gomami"
  elif echo "$ORG" | grep -qi "DMIT"; then PROVIDER="DMIT"
  elif echo "$ORG" | grep -qi "RackNerd"; then PROVIDER="RackNerd"
  elif echo "$ORG" | grep -qi "Oracle"; then PROVIDER="Oracle"
  elif echo "$ORG" | grep -qi "Tencent"; then PROVIDER="Tencent"
  elif echo "$ORG" | grep -qi "Alibaba"; then PROVIDER="Alibaba"
  else PROVIDER="VPS"
  fi
}

choose_port() {
  for _ in $(seq 1 100); do
    CANDIDATE_PORT="$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)"
    if ! ss -tuln | awk '{print $5}' | grep -Eq "(^|:)${CANDIDATE_PORT}$"; then
      echo "$CANDIDATE_PORT"
      return 0
    fi
  done
  red "错误：未找到可用端口。"
  exit 1
}

install_xray_core() {
  echo "==== 安装 Xray ===="
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  if [ ! -x "$XRAY_BIN" ]; then
    red "错误：Xray 安装失败。"
    exit 1
  fi
}

write_root_service() {
  echo "==== 重写 systemd 服务，避免 nobody 权限问题 ===="
  systemctl stop xray 2>/dev/null || true

  mkdir -p /etc/systemd/system/xray.service.d
  rm -f /etc/systemd/system/xray.service.d/*.conf 2>/dev/null || true

  cat > "$XRAY_SERVICE" <<'SERVICEEOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SERVICEEOF

  chmod 644 "$XRAY_SERVICE"
  systemctl daemon-reload
}

fix_permissions() {
  echo "==== 修复 Xray 文件权限 ===="
  mkdir -p "$XRAY_CONFIG_DIR" /var/log/xray /usr/local/share/xray

  chmod 755 /usr /usr/local /usr/local/etc "$XRAY_CONFIG_DIR" /var/log/xray /usr/local/share/xray 2>/dev/null || true
  [ -f "$XRAY_CONFIG" ] && chmod 644 "$XRAY_CONFIG"
  [ -f "$XRAY_BIN" ] && chmod 755 "$XRAY_BIN"
  chown root:root "$XRAY_CONFIG_DIR" "$XRAY_CONFIG" 2>/dev/null || true
  chown root:root "$XRAY_SERVICE" 2>/dev/null || true
}

write_config() {
  echo "==== 生成 Reality 参数 ===="
  UUID="$($XRAY_BIN uuid)"
  KEYS="$($XRAY_BIN x25519)"
  PRIVATE_KEY="$(echo "$KEYS" | awk -F': ' '/Private key|PrivateKey/ {print $2}' | tr -d ' ' | head -n1)"
  PUBLIC_KEY="$(echo "$KEYS" | awk -F': ' '/Public key|PublicKey|Password \(PublicKey\)/ {print $2}' | tr -d ' ' | head -n1)"
  SHORT_ID="$(openssl rand -hex 8)"

  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    red "错误：Reality 密钥生成失败。"
    exit 1
  fi

  mkdir -p "$XRAY_CONFIG_DIR"
  if [ -f "$XRAY_CONFIG" ]; then
    cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    echo "已备份旧配置。"
  fi

  echo "==== 写入 Xray 配置 ===="
  umask 022
  cat > "$XRAY_CONFIG" <<XRAYEOF
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
XRAYEOF

  fix_permissions
}

test_config() {
  echo "==== 测试 Xray 配置 ===="
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
}

enable_bbr() {
  echo "==== 开启 BBR ===="
  cat > /etc/sysctl.d/99-bbr.conf <<'BBREOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBREOF
  sysctl --system >/dev/null 2>&1 || true
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo "BBR 已启用。"
  else
    yellow "BBR 未确认启用，可能是内核不支持。"
  fi
}

open_firewall() {
  echo "==== 放行防火墙 ===="
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" || true
    firewall-cmd --reload || true
  fi
  echo "如果 VPS 云厂商有安全组，也要手动放行 TCP ${PORT}。"
}

start_xray() {
  echo "==== 启动 Xray ===="
  write_root_service
  fix_permissions
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 2

  if ! systemctl is-active --quiet xray; then
    red "Xray 启动失败，最近日志如下："
    journalctl -u xray -n 80 --no-pager
    echo
    yellow "当前权限检查："
    namei -l "$XRAY_CONFIG" || true
    ls -l "$XRAY_CONFIG" || true
    exit 1
  fi

  green "Xray 已启动成功。"
}

show_result() {
  NODE_NAME="${EMOJI} ${NODE_NAME_PREFIX} ${PROVIDER}"
  SHARE_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&type=tcp&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#${NODE_NAME}"

  cat > "$XRAY_PARAM_FILE" <<INFOEOF
节点名称: ${NODE_NAME}
IP: ${SERVER_IP}
端口: ${PORT}
UUID: ${UUID}
SNI: ${SNI}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
厂商: ${PROVIDER}
分享链接: ${SHARE_LINK}
INFOEOF
  chmod 600 "$XRAY_PARAM_FILE" || true

  echo
  echo "=================================================="
  echo "VLESS Reality 分享链接"
  echo "=================================================="
  echo "$SHARE_LINK"

  echo
  echo "=================================================="
  echo "Mihomo / Nikki 配置"
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
  echo "参数已保存到：${XRAY_PARAM_FILE}"
}

install_vless_reality() {
  require_root
  echo "=================================================="
  echo "VLESS + REALITY 安装脚本（无 Vision）"
  echo "=================================================="
  install_deps
  echo "==== 获取服务器信息 ===="
  get_ip
  get_provider
  NODE_NAME="${EMOJI} ${NODE_NAME_PREFIX} ${PROVIDER}"
  PORT="$(choose_port)"
  echo "公网 IP：${SERVER_IP}"
  echo "厂商识别：${PROVIDER}"
  echo "节点名称：${NODE_NAME}"
  echo "随机端口：${PORT}"
  install_xray_core
  write_root_service
  write_config
  test_config
  enable_bbr
  open_firewall
  start_xray
  show_result
  green "安装完成。"
}

uninstall_xray() {
  require_root
  echo "=================================================="
  echo "Xray / VLESS Reality 卸载清理脚本"
  echo "=================================================="

  XRAY_PORT=""
  if [ -f "$XRAY_CONFIG" ]; then
    XRAY_PORT="$(grep -oP '"port"\s*:\s*\K[0-9]+' "$XRAY_CONFIG" | head -n1 || true)"
    [ -n "$XRAY_PORT" ] && echo "检测到当前 Xray 端口：$XRAY_PORT"
  fi

  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true

  if command -v curl >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  fi

  rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  rm -f /usr/local/bin/xray
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
  rm -f /etc/sysctl.d/99-bbr.conf
  sysctl --system >/dev/null 2>&1 || true

  if [ -n "$XRAY_PORT" ]; then
    if command -v ufw >/dev/null 2>&1; then
      ufw delete allow "${XRAY_PORT}/tcp" 2>/dev/null || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port="${XRAY_PORT}/tcp" 2>/dev/null || true
      firewall-cmd --reload 2>/dev/null || true
    fi
  fi

  systemctl daemon-reload
  systemctl reset-failed xray 2>/dev/null || true
  green "卸载完成。"
}

main_menu() {
  require_root
  while true; do
    echo
    echo "=================================================="
    echo "Xray VLESS Reality 管理脚本"
    echo "=================================================="
    echo "1. 安装 VLESS + Reality"
    echo "2. 卸载 Xray / VLESS Reality"
    echo "3. 退出"
    echo "=================================================="
    read -rp "请输入选项 [1-3]: " choice
    case "$choice" in
      1) install_vless_reality ;;
      2) uninstall_xray ;;
      3) echo "已退出。"; exit 0 ;;
      *) red "无效选项，请输入 1、2 或 3。" ;;
    esac
  done
}

main_menu
