#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================================
# Xray / VLESS + REALITY 一键安装 / 卸载脚本（无 Vision）
# 菜单：
#   1) 安装
#   2) 卸载
#   3) 退出
# ==================================================

SNI="learn.microsoft.com"
DEST="learn.microsoft.com:443"

NODE_NAME_PREFIX="Johnny"
EMOJI="🌐"

PORT_MIN=20000
PORT_MAX=50000

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_BACKUP="${XRAY_CONFIG_DIR}/install-info.txt"
BBR_CONF="/etc/sysctl.d/99-bbr.conf"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PLAIN="\033[0m"

trap 'echo -e "\n${RED}脚本执行失败，行号：$LINENO${PLAIN}"' ERR

print_line() {
  echo "=================================================="
}

info() {
  echo -e "${BLUE}$*${PLAIN}"
}

ok() {
  echo -e "${GREEN}$*${PLAIN}"
}

warn() {
  echo -e "${YELLOW}$*${PLAIN}"
}

err() {
  echo -e "${RED}$*${PLAIN}"
}

check_root() {
  if [ "$(id -u)" != "0" ]; then
    err "错误：请使用 root 用户执行。"
    exit 1
  fi
}

detect_pkg_manager() {
  if command -v apt >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    err "不支持的系统：未找到 apt / dnf / yum。"
    exit 1
  fi
}

install_dependencies() {
  info "==== 安装基础组件 ===="

  detect_pkg_manager

  if [ "$PKG_MANAGER" = "apt" ]; then
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y curl unzip socat jq openssl ca-certificates lsof iproute2 procps
  elif [ "$PKG_MANAGER" = "dnf" ]; then
    dnf install -y curl unzip socat jq openssl ca-certificates lsof iproute procps-ng
  elif [ "$PKG_MANAGER" = "yum" ]; then
    yum install -y curl unzip socat jq openssl ca-certificates lsof iproute procps-ng
  fi
}

get_public_ip() {
  SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || true)"

  if [ -z "${SERVER_IP}" ]; then
    SERVER_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me || true)"
  fi

  if [ -z "${SERVER_IP}" ]; then
    err "错误：无法获取公网 IPv4。"
    exit 1
  fi
}

detect_provider() {
  ORG="$(curl -4 -fsS --max-time 8 https://ipinfo.io/org || true)"

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

  NODE_NAME="${EMOJI} ${NODE_NAME_PREFIX} ${PROVIDER}"
}

choose_port() {
  for _ in $(seq 1 80); do
    CANDIDATE_PORT="$(shuf -i "${PORT_MIN}-${PORT_MAX}" -n 1)"

    if ! ss -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\\])${CANDIDATE_PORT}$"; then
      echo "$CANDIDATE_PORT"
      return 0
    fi
  done

  err "错误：未找到可用端口。"
  exit 1
}

install_xray() {
  info "==== 安装 Xray ===="
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  if [ ! -x "$XRAY_BIN" ]; then
    err "错误：Xray 安装失败。"
    exit 1
  fi
}

generate_reality_params() {
  info "==== 生成 Reality 参数 ===="

  UUID="$($XRAY_BIN uuid)"
  KEYS="$($XRAY_BIN x25519)"

  PRIVATE_KEY="$(echo "$KEYS" | grep -Ei "Private key|PrivateKey" | awk -F': ' '{print $2}' | tr -d ' ')"
  PUBLIC_KEY="$(echo "$KEYS" | grep -Ei "Public key|PublicKey|Password \(PublicKey\)" | awk -F': ' '{print $2}' | tr -d ' ')"
  SHORT_ID="$(openssl rand -hex 8)"

  if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ]; then
    err "错误：Reality 参数生成失败。"
    exit 1
  fi
}

write_xray_config() {
  info "==== 写入 Xray 配置 ===="

  mkdir -p "$XRAY_CONFIG_DIR"

  if [ -f "$XRAY_CONFIG" ]; then
    cp -f "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    warn "已备份旧配置。"
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

  chmod 600 "$XRAY_CONFIG"
}

test_xray_config() {
  info "==== 测试 Xray 配置 ===="
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
}

enable_bbr() {
  info "==== 开启 BBR ===="

  cat > "$BBR_CONF" <<BBREOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBREOF

  sysctl --system >/dev/null 2>&1 || true

  CURRENT_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [ "$CURRENT_CC" = "bbr" ]; then
    ok "BBR 已启用。"
  else
    warn "BBR 配置已写入，但当前内核可能暂未启用。"
  fi
}

open_firewall() {
  info "==== 放行防火墙 ===="

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" || true
    firewall-cmd --reload || true
  fi

  warn "如果 VPS 云厂商有安全组，也要手动放行 TCP ${PORT}。"
}

start_xray() {
  info "==== 启动 Xray ===="

  systemctl daemon-reload
  systemctl enable xray
  systemctl restart xray

  sleep 1

  if ! systemctl is-active --quiet xray; then
    err "Xray 启动失败，最近日志如下："
    journalctl -u xray -n 60 --no-pager
    exit 1
  fi

  ok "Xray 已启动。"
}

save_install_info() {
  cat > "$XRAY_BACKUP" <<INFOEOF
节点名称: ${NODE_NAME}
IP: ${SERVER_IP}
端口: ${PORT}
UUID: ${UUID}
SNI: ${SNI}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
厂商: ${PROVIDER}

VLESS Reality 分享链接:
vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&type=tcp&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#${NODE_NAME}

Mihomo / Nikki 配置:
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
INFOEOF

  chmod 600 "$XRAY_BACKUP"
}

print_result() {
  print_line
  ok "VLESS Reality 分享链接"
  print_line
  echo
  echo "vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&type=tcp&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#${NODE_NAME}"
  echo
  print_line
  ok "Mihomo / Nikki 配置"
  print_line
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

  print_line
  ok "参数已保存到：${XRAY_BACKUP}"
  print_line
}

read_current_port() {
  XRAY_PORT=""

  if [ -f "$XRAY_CONFIG" ]; then
    if command -v jq >/dev/null 2>&1; then
      XRAY_PORT="$(jq -r '.inbounds[0].port // empty' "$XRAY_CONFIG" 2>/dev/null || true)"
    fi

    if [ -z "$XRAY_PORT" ]; then
      XRAY_PORT="$(grep -oP '"port"\s*:\s*\K[0-9]+' "$XRAY_CONFIG" | head -n 1 || true)"
    fi
  fi
}

remove_firewall_rule() {
  read_current_port

  info "==== 清理防火墙规则 ===="

  if [ -n "$XRAY_PORT" ]; then
    if command -v ufw >/dev/null 2>&1; then
      ufw delete allow "${XRAY_PORT}/tcp" 2>/dev/null || true
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port="${XRAY_PORT}/tcp" 2>/dev/null || true
      firewall-cmd --reload 2>/dev/null || true
    fi

    ok "已尝试清理 TCP ${XRAY_PORT} 的系统防火墙规则。"
  else
    warn "未识别到 Xray 端口，跳过系统防火墙端口清理。"
  fi
}

install_service() {
  print_line
  info "VLESS + REALITY 自动安装脚本（无 Vision）"
  print_line

  check_root
  install_dependencies

  info "==== 获取服务器信息 ===="
  get_public_ip
  detect_provider
  PORT="$(choose_port)"

  echo "公网 IP：${SERVER_IP}"
  echo "厂商识别：${PROVIDER}"
  echo "节点名称：${NODE_NAME}"
  echo "随机端口：${PORT}"

  install_xray
  generate_reality_params
  write_xray_config
  test_xray_config
  enable_bbr
  open_firewall
  start_xray
  save_install_info
  print_result

  ok "安装完成。"
}

uninstall_service() {
  print_line
  info "Xray / VLESS Reality 卸载清理脚本"
  print_line

  check_root
  read_current_port

  if [ -n "$XRAY_PORT" ]; then
    echo "检测到当前 Xray 端口：${XRAY_PORT}"
  else
    warn "未检测到当前 Xray 端口。"
  fi

  info "==== 停止并禁用 Xray 服务 ===="
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true

  info "==== 使用官方脚本卸载 Xray-core ===="
  if command -v curl >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  else
    warn "未安装 curl，跳过官方卸载脚本。"
  fi

  info "==== 删除 Xray 残留文件 ===="
  rm -rf /usr/local/etc/xray
  rm -rf /usr/local/share/xray
  rm -rf /var/log/xray
  rm -f /usr/local/bin/xray
  rm -f /etc/systemd/system/xray.service
  rm -rf /etc/systemd/system/xray.service.d

  systemctl daemon-reload
  systemctl reset-failed xray 2>/dev/null || true

  info "==== 删除脚本添加的 BBR 配置 ===="
  if [ -f "$BBR_CONF" ]; then
    rm -f "$BBR_CONF"
    sysctl --system >/dev/null 2>&1 || true
    ok "已删除 ${BBR_CONF}"
  else
    warn "未发现 ${BBR_CONF}，跳过。"
  fi

  remove_firewall_rule

  info "==== 检查残留 ===="
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

  print_line
  ok "卸载完成。"
  if [ -n "$XRAY_PORT" ]; then
    warn "如果你在云服务商后台放行过 TCP ${XRAY_PORT}，建议手动去安全组里删除。"
  fi
  print_line
}

show_menu() {
  clear
  print_line
  echo " Xray / VLESS + REALITY 管理脚本（无 Vision）"
  print_line
  echo " 1. 安装"
  echo " 2. 卸载"
  echo " 3. 退出"
  print_line
  read -rp "请输入选项 [1-3]: " CHOICE

  case "$CHOICE" in
    1)
      install_service
      ;;
    2)
      uninstall_service
      ;;
    3)
      echo "已退出。"
      exit 0
      ;;
    *)
      err "无效选项。"
      exit 1
      ;;
  esac
}

show_menu
