#!/bin/bash
set -e

SERVICE_NAME="anytls"
BINARY_NAME="anytls-server"
BINARY_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
VERSION="v0.0.8"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行"
    exit 1
fi

install_dependencies() {
    apt update -y
    apt install -y wget curl unzip openssl iproute2
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l|armv7*) echo "armv7" ;;
        *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

generate_random_port() {
    while true; do
        PORT=$(shuf -i 20000-60000 -n 1)
        if ! ss -tuln | grep -q ":${PORT} "; then
            echo "$PORT"
            return
        fi
    done
}

generate_password() {
    openssl rand -base64 32 | tr -dc 'A-Za-z0-9_-' | head -c 24
}

get_local_ip() {
    ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1
}

install_anytls() {
    install_dependencies

    ARCH=$(detect_arch)
    DOWNLOAD_URL="https://github.com/anytls/anytls-go/releases/download/${VERSION}/anytls_0.0.8_linux_${ARCH}.zip"
    ZIP_FILE="/tmp/anytls_${ARCH}.zip"

    PORT=$(generate_random_port)
    PASSWORD=$(generate_password)

    echo
    echo "[1/5] 下载 AnyTLS..."
    wget -q -O "$ZIP_FILE" "$DOWNLOAD_URL"

    echo "[2/5] 解压安装..."
    unzip -oq "$ZIP_FILE" -d "$BINARY_DIR"
    chmod +x "$BINARY_DIR/$BINARY_NAME"
    rm -f "$ZIP_FILE"

    echo "[3/5] 创建 systemd 服务..."
    cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=AnyTLS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BINARY_DIR}/${BINARY_NAME} -l 0.0.0.0:${PORT} -p ${PASSWORD}
Restart=always
RestartSec=3
LimitNOFILE=1048576
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF2

    echo "[4/5] 启动服务..."
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
    systemctl restart "$SERVICE_NAME"

    sleep 1

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo
        echo "AnyTLS 启动失败"
        journalctl -u "$SERVICE_NAME" --no-pager -n 30
        exit 1
    fi

    SERVER_IP=$(get_local_ip)

    echo
    echo "======================================"
    echo " AnyTLS 安装完成"
    echo "======================================"
    echo "架构: ${ARCH}"
    echo "随机端口: ${PORT}"
    echo "随机密码: ${PASSWORD}"
    echo

    echo "NekoBox 链接："
    echo "--------------------------------------"
    echo "anytls://${PASSWORD}@${SERVER_IP}:${PORT}/?insecure=1"
    echo "--------------------------------------"
    echo

    echo "Clash / Nikki 配置："
    echo "--------------------------------------"
    cat <<EOF2
- name: 🇸🇬 Johnny AnyTLS
  type: anytls
  server: ${SERVER_IP}
  port: ${PORT}
  password: "${PASSWORD}"
  udp: true
  xudp: true
  skip-cert-verify: true
EOF2
    echo "--------------------------------------"
    echo

    echo "管理命令："
    echo "systemctl status anytls"
    echo "systemctl restart anytls"
    echo "systemctl stop anytls"
    echo

    if command -v ufw >/dev/null 2>&1; then
        echo "自动放行防火墙端口..."
        ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
    fi
}

uninstall_anytls() {
    echo "正在卸载 AnyTLS..."

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    rm -f "$SERVICE_FILE"
    rm -f "$BINARY_DIR/$BINARY_NAME"

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    echo
    echo "AnyTLS 已彻底卸载"
}

status_anytls() {
    systemctl status "$SERVICE_NAME" --no-pager || true
}

show_menu() {
    clear
    echo "======================================"
    echo " AnyTLS 管理脚本"
    echo "======================================"
    echo "1. 安装 AnyTLS（随机端口+随机密码）"
    echo "2. 卸载 AnyTLS"
    echo "3. 查看状态"
    echo "0. 退出"
    echo "======================================"

    read -p "请输入选项 [0-3]: " choice

    case "$choice" in
        1) install_anytls ;;
        2) uninstall_anytls ;;
        3) status_anytls ;;
        0) exit 0 ;;
        *) echo "无效选项"; exit 1 ;;
    esac
}

show_menu
