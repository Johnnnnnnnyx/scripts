#!/bin/bash

set -e

CONTAINER_NAME="shadowsocks"
IMAGE_NAME="ghcr.io/shadowsocks/ssserver-rust:latest"
METHOD="2022-blake3-aes-256-gcm"
INFO_FILE="/root/shadowsocks-2022-info.yaml"
RAW_URL="https://raw.githubusercontent.com/Johnnnnnnnyx/scripts/main/ss2022.sh"

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
    if [ "$(id -u)" -ne 0 ]; then
        red "请使用 root 用户运行此脚本"
        exit 1
    fi
}

check_system() {
    if ! command -v apt >/dev/null 2>&1; then
        red "当前脚本仅支持 Debian / Ubuntu 系统"
        exit 1
    fi
}

install_base_dependencies() {
    green "==== 安装基础依赖 ===="

    apt update -y

    apt install -y \
        ca-certificates \
        curl \
        gnupg \
        openssl \
        iproute2 \
        apparmor \
        apparmor-utils

    green "基础依赖安装完成"
}

install_docker_if_needed() {
    if command -v docker >/dev/null 2>&1; then
        green "检测到 Docker 已安装，跳过 Docker 安装"

        systemctl enable docker >/dev/null 2>&1 || true
        systemctl restart docker >/dev/null 2>&1 || true

        if docker info >/dev/null 2>&1; then
            green "Docker 运行正常"
        else
            yellow "Docker 已安装，但当前运行状态可能异常，请检查：systemctl status docker"
        fi

        return
    fi

    green "==== 未检测到 Docker，开始安装 Docker 官方版 ===="

    # 清理可能冲突的 Debian 自带 docker.io / containerd / runc
    apt remove -y docker.io docker-doc docker-compose podman-docker containerd runc >/dev/null 2>&1 || true

    install -m 0755 -d /etc/apt/keyrings

    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    ARCH="$(dpkg --print-architecture)"
    CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt update -y

    apt install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable docker
    systemctl restart docker

    green "Docker 官方版安装完成"
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
    # 2022-blake3-aes-256-gcm 需要 32 字节 PSK
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
        COUNTRY_CODE="US"
    fi

    echo "$COUNTRY_CODE"
}

country_code_to_flag() {
    local CODE="$1"
    local OFFSET=127397
    local FIRST
    local SECOND

    FIRST=$(printf "%d" "'${CODE:0:1}")
    SECOND=$(printf "%d" "'${CODE:1:1}")

    printf "%b" "\\U$(printf '%08x' $((FIRST + OFFSET)))\\U$(printf '%08x' $((SECOND + OFFSET)))"
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

write_node_info() {
    COUNTRY_CODE=$(get_country_code "$SERVER_IP")
    FLAG=$(country_code_to_flag "$COUNTRY_CODE")

    cat > "$INFO_FILE" <<INFO
- name: ${FLAG} Johnny SS2022
  type: ss
  server: ${SERVER_IP}
  port: ${PORT}
  cipher: ${METHOD}
  password: "${PASSWORD}"
  udp: true
  udp-over-tcp: false
INFO
}

install_ss2022() {
    check_root
    check_system

    green "=================================================="
    green "Shadowsocks 2022 Docker 一键安装脚本"
    green "=================================================="

    install_base_dependencies
    install_docker_if_needed

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
    write_node_info

    green "=================================================="
    green "安装完成"
    green "=================================================="
    echo
    echo "Sub-Store / Mihomo 节点格式："
    echo
    cat "$INFO_FILE"
    echo
    green "查看日志：docker logs -f ${CONTAINER_NAME}"
    green "卸载命令：bash <(curl -fsSL ${RAW_URL}) uninstall"
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
    if command -v docker >/dev/null 2>&1; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    else
        yellow "未检测到 Docker，跳过容器删除"
    fi

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
    if command -v docker >/dev/null 2>&1; then
        docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
    fi

    green "卸载完成"
    yellow "注意：本脚本不会卸载 Docker 本身，避免影响你机器上其他 Docker 服务"
}

show_info() {
    if [ -f "$INFO_FILE" ]; then
        cat "$INFO_FILE"
    else
        red "未找到节点信息文件：$INFO_FILE"
        exit 1
    fi
}

show_menu() {
    echo
    echo "请选择操作："
    echo "1) 安装 Shadowsocks 2022"
    echo "2) 卸载 Shadowsocks 2022"
    echo "3) 查看节点信息"
    echo "0) 退出"
    echo

    read -rp "请输入选项 [0-3]: " CHOICE

    case "$CHOICE" in
        1)
            install_ss2022
            ;;
        2)
            uninstall_ss2022
            ;;
        3)
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
        install_ss2022
        ;;
    uninstall)
        uninstall_ss2022
        ;;
    info)
        show_info
        ;;
    *)
        show_menu
        ;;
esac
