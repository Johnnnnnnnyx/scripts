#!/bin/bash

set -e

CONTAINER_NAME="shadowsocks"
IMAGE_NAME="ghcr.io/shadowsocks/ssserver-rust:latest"
METHOD="2022-blake3-aes-256-gcm"
INFO_FILE="/root/shadowsocks-2022-info.yaml"

green() {
    echo -e "\033[32m$1\033[0m"
}

red() {
    echo -e "\033[31m$1\033[0m"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        red "请使用 root 用户运行此脚本"
        exit 1
    fi
}

install_dependencies() {
    green "==== 安装依赖 ===="

    apt update -y

    apt install -y \
        docker.io \
        apparmor \
        apparmor-utils \
        openssl \
        curl \
        iproute2

    systemctl enable docker
    systemctl restart docker

    green "依赖安装完成"
}

generate_port() {
    while true; do
        PORT=$(shuf -i 10000-65535 -n 1)

        if ! ss -lntup 2>/dev/null | grep -q ":${PORT} "; then
            echo "$PORT"
            return
        fi
    done
}

generate_password() {
    openssl rand -base64 32 | tr -d '\n'
}

get_server_ip() {
    IP=$(curl -4 -s --max-time 5 https://api.ipify.org || true)

    if [ -z "$IP" ]; then
        IP=$(curl -4 -s --max-time 5 https://ifconfig.me || true)
    fi

    if [ -z "$IP" ]; then
        IP=$(hostname -I | awk '{print $1}')
    fi

    echo "$IP"
}

open_firewall() {
    local PORT="$1"

    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
            ufw allow "${PORT}/udp" >/dev/null 2>&1 || true
            green "已放行 UFW 端口：${PORT}/tcp 和 ${PORT}/udp"
        fi
    fi
}

install_ss2022() {
    check_root

    green "=================================================="
    green "Shadowsocks 2022 Docker 一键安装脚本"
    green "=================================================="

    install_dependencies

    green "==== 拉取 Docker 镜像 ===="
    docker pull "$IMAGE_NAME"

    green "==== 清理旧容器 ===="
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    PORT=$(generate_port)
    PASSWORD=$(generate_password)
    SERVER_IP=$(get_server_ip)

    green "==== 启动 Shadowsocks 2022 ===="

    docker run --entrypoint ssserver \
        -d \
        --name="$CONTAINER_NAME" \
        --net=host \
        --restart=always \
        --dns 1.1.1.1 \
        --ulimit nofile=65535:65535 \
        "$IMAGE_NAME" \
        -s "0.0.0.0:${PORT}" \
        -m "$METHOD" \
        -k "$PASSWORD" \
        --tcp-no-delay \
        -U

    open_firewall "$PORT"

    cat > "$INFO_FILE" <<INFO
- name: 🇺🇸 Johnny SS2022
  type: ss
  server: ${SERVER_IP}
  port: ${PORT}
  cipher: ${METHOD}
  password: "${PASSWORD}"
  udp: true
  udp-over-tcp: false
INFO

    green "=================================================="
    green "安装完成"
    green "=================================================="
    echo
    echo "Sub-Store / Mihomo 节点格式："
    echo
    cat "$INFO_FILE"
    echo
    green "节点信息已保存到：$INFO_FILE"
    echo
    green "查看日志：docker logs -f ${CONTAINER_NAME}"
    green "卸载命令：bash $0 uninstall"
}

uninstall_ss2022() {
    check_root

    green "=================================================="
    green "Shadowsocks 2022 Docker 一键卸载脚本"
    green "=================================================="

    if [ -f "$INFO_FILE" ]; then
        OLD_PORT=$(grep "port:" "$INFO_FILE" | awk '{print $2}' | head -n 1 | tr -d ' ')
    else
        OLD_PORT=""
    fi

    green "==== 停止并删除容器 ===="
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    green "==== 删除节点信息文件 ===="
    rm -f "$INFO_FILE"

    if [ -n "$OLD_PORT" ] && command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            ufw delete allow "${OLD_PORT}/tcp" >/dev/null 2>&1 || true
            ufw delete allow "${OLD_PORT}/udp" >/dev/null 2>&1 || true
            green "已尝试删除 UFW 端口规则：${OLD_PORT}"
        fi
    fi

    green "==== 删除 Docker 镜像 ===="
    docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true

    green "卸载完成"
}

show_menu() {
    echo
    echo "请选择操作："
    echo "1) 安装 Shadowsocks 2022"
    echo "2) 卸载 Shadowsocks 2022"
    echo "0) 退出"
    echo

    read -rp "请输入选项 [1-2]: " CHOICE

    case "$CHOICE" in
        1)
            install_ss2022
            ;;
        2)
            uninstall_ss2022
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
        install_ss2022
        ;;
    uninstall)
        uninstall_ss2022
        ;;
    *)
        show_menu
        ;;
esac
