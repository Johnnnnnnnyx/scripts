#!/bin/bash

set -e

# ==================================================
# Xray / VLESS Reality 一键安装 + 一键卸载脚本
# 功能：
#   install   安装 VLESS + Reality，默认固定 443 端口
#   uninstall 卸载 Xray 并清理残留
#   status    查看 Xray 状态
#   info      尝试读取当前节点信息
# ==================================================

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_INFO="/root/xray-vless-reality-info.txt"
BBR_CONF="/etc/sysctl.d/99-bbr.conf"

SNI="learn.microsoft.com"
DEST="learn.microsoft.com:443"
NODE_NAME_PREFIX="Johnny"
PORT=443

green() {
  echo -e "\033[32m$1\033[0m"
}

red() {
  echo -e "\033[31m$1\033[0m"
}

yellow() {
  echo -e "\033[33m$1\033[0m"
}

check_root() {
  if [ "$(id -u)" != "0" ]; then
    red "错误：请使用 root 用户执行此脚本。"
    exit 1
  fi
}

check_system() {
  if ! command -v apt >/dev/null 2>&1; then
    red "错误：当前脚本仅支持 Debian / Ubuntu 系统。"
    exit 1
  fi
}

install_dependencies() {
  green "==== 安装基础组件 ===="
  apt update -y
  apt install -y curl unzip socat jq openssl ca-certificates lsof iproute2
}

get_server_ip() {
  SERVER_IP=$(curl -4 -s --max-time 5 https://api.ipify.org || true)

  if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -4 -s --max-time 5 https://ifconfig.me || true)
  fi

  if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
  fi

  if [ -z "$SERVER_IP" ]; then
    red "错误：无法获取公网 IP。"
    exit 1
  fi

  echo "$SERVER_IP"
}

get_country_code() {
  local IP="$1"
  local COUNTRY_CODE=""

  COUNTRY_CODE=$(curl -s --max-time 5 "https://ipinfo.io/${IP}/country" || true)
  COUNTRY_CODE=$(echo "$COUNTRY_CODE" | tr -d '\r\n ' | tr '[:lower:]' '[:upper:]')

  if ! echo "$COUNTRY_CODE" | grep -Eq '^[A-Z]{2}$'; then
    COUNTRY_CODE=$(curl -s --max-time 5 "https://ipapi.co/${IP}/country/" || true)
    COUNTRY_CODE=$(echo "$COUNTRY_CODE" | tr -d '\r\n ' | tr '[:lower:]' '[:upper:]')
  fi

  if ! echo "$COUNTRY_CODE" | grep -Eq '^[A-Z]{2}$'; then
    COUNTRY_CODE="UN"
  fi

  echo "$COUNTRY_CODE"
}

country_code_to_flag() {
  local CODE="$1"

  if [ "$CODE" = "UN" ]; then
    echo "🌐"
    return
  fi

  local OFFSET=127397
  local FIRST
  local SECOND

  FIRST=$(printf "%d" "'${CODE:0:1}")
  SECOND=$(printf "%d" "'${CODE:1:1}")

  printf "%b" "\\U$(printf '%08x' $((FIRST + OFFSET)))\\U$(printf '%08x' $((SECOND + OFFSET)))"
}

get_provider() {
  local ORG=""
  ORG=$(curl -4 -s --max-time 5 "https://ipinfo.io/org" || true)

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
  elif echo "$ORG" | grep -qi "GreenCloud"; then
    PROVIDER="GreenCloud"
  elif echo "$ORG" | grep -qi "Cloudflare"; then
    PROVIDER="Cloudflare"
  else
    PROVIDER="VPS"
  fi

  echo "$PROVIDER"
}

check_port() {
  green "==== 检查 ${PORT} 端口 ===="

  if ss -tulnp 2>/dev/null | grep -q ":${PORT} "; then
    if ss -tulnp 2>/dev/null | grep ":${PORT} " | grep -qi "xray"; then
      yellow "检测到 ${PORT} 端口当前由 Xray 占用，将自动停止旧 Xray 后继续安装。"
      systemctl stop xray 2>/dev/null || true
      sleep 1
    else
      red "错误：${PORT} 端口已被其他服务占用。"
      echo
      echo "当前占用情况："
      ss -tulnp | grep ":${PORT}" || true
      echo
      echo "请先停止占用 ${PORT} 的服务，例如 nginx、apache、3x-ui、NPM 等。"
      exit 1
    fi
  fi

  green "${PORT} 端口可用。"
}

install_xray() {
  green "==== 安装 Xray ===="

  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  if [ ! -x "$XRAY_BIN" ]; then
    red "错误：Xray 安装失败。"
    exit 1
  fi
}

generate_reality_params() {
  green "==== 生成 Reality 参数 ===="

  UUID=$("$XRAY_BIN" uuid)
  KEYS=$("$XRAY_BIN" x25519)

  PRIVATE_KEY=$(echo "$KEYS" | grep -Ei "Private key|PrivateKey" | awk -F': ' '{print $2}' | tr -d ' ')
  PUBLIC_KEY=$(echo "$KEYS" | grep -Ei "Public key|PublicKey|Password \(PublicKey\)" | awk -F': ' '{print $2}' | tr -d ' ')
  SHORT_ID=$(openssl rand -hex 8)

  if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ]; then
    red "错误：Reality 参数生成失败。"
    echo "$KEYS"
    exit 1
  fi

  echo "UUID: ${UUID}"
  echo "PublicKey: ${PUBLIC_KEY}"
  echo "ShortID: ${SHORT_ID}"
}

write_xray_config() {
  green "==== 写入 Xray 配置 ===="

  mkdir -p /usr/local/etc/xray

  if [ -f "$XRAY_CONFIG" ]; then
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    yellow "已备份旧配置。"
  fi

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
}

test_xray_config() {
  green "==== 测试 Xray 配置 ===="
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
}

enable_bbr() {
  green "==== 开启 BBR ===="

  cat > "$BBR_CONF" <<BBREOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBREOF

  sysctl --system >/dev/null 2>&1 || true
}

open_firewall() {
  green "==== 放行防火墙 ===="

  if command -v ufw >/dev/null 2>&1; then
    ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
    green "已尝试放行 ufw TCP ${PORT}"
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    green "已尝试放行 firewalld TCP ${PORT}"
  fi
}

start_xray() {
  green "==== 启动 Xray ===="

  systemctl daemon-reload
  systemctl enable xray
  systemctl restart xray

  sleep 1

  if ! systemctl is-active --quiet xray; then
    red "Xray 启动失败："
    journalctl -u xray -n 80 --no-pager
    exit 1
  fi

  green "Xray 已启动。"
}

write_info() {
  cat > "$XRAY_INFO" <<INFO
节点名称: ${NODE_NAME}
IP: ${SERVER_IP}
端口: ${PORT}
UUID: ${UUID}
SNI: ${SNI}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
国家代码: ${COUNTRY_CODE}
厂商: ${PROVIDER}
INFO
}

print_node() {
  green "=================================================="
  green "VLESS Reality 分享链接"
  green "=================================================="
  echo
  echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&type=tcp&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#${NODE_NAME}"

  echo
  green "=================================================="
  green "Mihomo / Nikki 配置"
  green "=================================================="

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
}

install_reality() {
  check_root
  check_system

  green "=================================================="
  green "VLESS + REALITY 自动安装脚本"
  green "=================================================="

  install_dependencies

  SERVER_IP=$(get_server_ip)
  COUNTRY_CODE=$(get_country_code "$SERVER_IP")
  FLAG=$(country_code_to_flag "$COUNTRY_CODE")
  PROVIDER=$(get_provider)
  NODE_NAME="${FLAG} ${NODE_NAME_PREFIX} ${PROVIDER}"

  echo
  echo "公网 IP：${SERVER_IP}"
  echo "国家代码：${COUNTRY_CODE}"
  echo "厂商识别：${PROVIDER}"
  echo "节点名称：${NODE_NAME}"
  echo "使用端口：${PORT}"

  check_port
  install_xray
  generate_reality_params
  write_xray_config
  test_xray_config
  enable_bbr
  open_firewall
  start_xray
  write_info

  echo
  echo "端口监听："
  ss -tulnp | grep ":${PORT}" || true

  echo
  print_node

  green "=================================================="
  green "安装完成"
  green "=================================================="
  green "查看状态：bash $0 status"
  green "卸载命令：bash $0 uninstall"
}

read_current_port() {
  if [ -f "$XRAY_CONFIG" ]; then
    XRAY_PORT=$(grep -oP '"port"\s*:\s*\K[0-9]+' "$XRAY_CONFIG" | head -n 1 || true)
  else
    XRAY_PORT=""
  fi
}

uninstall_reality() {
  check_root

  green "=================================================="
  green "Xray / VLESS Reality 卸载清理脚本"
  green "=================================================="

  echo
  green "==== 1. 尝试读取当前 Xray 端口 ===="
  read_current_port

  if [ -n "$XRAY_PORT" ]; then
    echo "检测到当前 Xray 端口：$XRAY_PORT"
  else
    echo "未能自动识别端口。"
  fi

  echo
  green "==== 2. 停止并禁用 Xray 服务 ===="
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  echo "Xray 服务已停止并禁用。"

  echo
  green "==== 3. 使用官方脚本卸载 Xray-core ===="
  if command -v curl >/dev/null 2>&1; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  else
    yellow "未安装 curl，跳过官方卸载脚本。"
  fi

  echo
  green "==== 4. 删除 Xray 残留文件 ===="
  rm -rf /usr/local/etc/xray
  rm -rf /usr/local/share/xray
  rm -rf /var/log/xray
  rm -f /usr/local/bin/xray
  rm -f /etc/systemd/system/xray.service
  rm -rf /etc/systemd/system/xray.service.d
  rm -f "$XRAY_INFO"

  systemctl daemon-reload
  systemctl reset-failed xray 2>/dev/null || true

  echo "Xray 配置、二进制、服务文件已清理。"

  echo
  green "==== 5. 删除 BBR 配置 ===="
  if [ -f "$BBR_CONF" ]; then
    rm -f "$BBR_CONF"
    sysctl --system >/dev/null 2>&1 || true
    echo "已删除 $BBR_CONF"
  else
    echo "未发现 $BBR_CONF，跳过。"
  fi

  echo
  green "==== 6. 尝试清理系统防火墙规则 ===="
  if [ -n "$XRAY_PORT" ]; then
    if command -v ufw >/dev/null 2>&1; then
      ufw delete allow ${XRAY_PORT}/tcp >/dev/null 2>&1 || true
      echo "已尝试删除 ufw TCP ${XRAY_PORT} 放行规则。"
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port=${XRAY_PORT}/tcp >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      echo "已尝试删除 firewalld TCP ${XRAY_PORT} 放行规则。"
    fi
  else
    echo "未识别端口，跳过系统防火墙端口清理。"
  fi

  echo
  green "==== 7. 检查残留 ===="

  echo
  echo "Xray 服务状态："
  systemctl status xray --no-pager 2>/dev/null || echo "xray.service 不存在或已卸载。"

  echo
  echo "Xray 进程："
  pgrep -a xray || echo "未发现 Xray 进程。"

  echo
  echo "Xray 端口监听："
  if [ -n "$XRAY_PORT" ]; then
    ss -tulnp | grep ":${XRAY_PORT}" || echo "未发现 ${XRAY_PORT} 端口监听。"
  else
    ss -tulnp | grep xray || echo "未发现 Xray 相关监听。"
  fi

  echo
  green "=================================================="
  green "卸载完成"
  green "=================================================="

  if [ -n "$XRAY_PORT" ]; then
    yellow "如果你在云服务商后台放行过 TCP ${XRAY_PORT}，建议手动去安全组里删除。"
  fi
}

show_status() {
  echo "=================================================="
  echo "Xray 状态"
  echo "=================================================="
  systemctl status xray --no-pager 2>/dev/null || echo "xray.service 不存在或已卸载。"

  echo
  echo "Xray 进程："
  pgrep -a xray || echo "未发现 Xray 进程。"

  echo
  echo "端口监听："
  ss -tulnp | grep -E "xray|:${PORT}" || echo "未发现 Xray 或 ${PORT} 端口监听。"
}

show_info() {
  if [ -f "$XRAY_INFO" ]; then
    cat "$XRAY_INFO"
  else
    yellow "未找到参数备份文件：$XRAY_INFO"
    echo "可以尝试查看当前配置：$XRAY_CONFIG"
  fi
}

show_menu() {
  echo
  echo "请选择操作："
  echo "1) 安装 VLESS + Reality"
  echo "2) 卸载 VLESS + Reality"
  echo "3) 查看 Xray 状态"
  echo "4) 查看参数备份"
  echo "0) 退出"
  echo

  read -rp "请输入选项 [0-4]: " CHOICE

  case "$CHOICE" in
    1)
      install_reality
      ;;
    2)
      uninstall_reality
      ;;
    3)
      show_status
      ;;
    4)
      show_info
      ;;
    0)
      exit 0
      ;;
    *)
      red "无效选项"
      exit 1
      ;;
  esac
}

case "$1" in
  install)
    install_reality
    ;;
  uninstall|remove)
    uninstall_reality
    ;;
  status)
    show_status
    ;;
  info)
    show_info
    ;;
  *)
    show_menu
    ;;
esac
