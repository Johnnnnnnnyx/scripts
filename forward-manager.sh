#!/bin/bash

set -e

RULE_FILE="/etc/port-forward-manager.conf"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请使用 root 权限运行：sudo $0"
        exit 1
    fi
}

init_env() {
    echo "[初始化] 开启 IPv4 转发..."

    if grep -q "^#*net.ipv4.ip_forward" /etc/sysctl.conf; then
        sed -i 's/^#*net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi

    sysctl -p >/dev/null

    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        echo "[初始化] 安装 iptables-persistent..."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent
    fi

    touch "$RULE_FILE"
}

save_rules() {
    netfilter-persistent save
    echo "iptables 规则已保存，重启后仍然生效。"
}

add_forward_rule() {
    echo
    read -p "请输入线路机器监听端口，例如 38888: " LOCAL_PORT
    read -p "请输入落地机器 IP，例如 103.177.163.98: " TARGET_IP
    read -p "请输入落地机器端口，例如 38888: " TARGET_PORT
    read -p "协议类型 tcp/udp/all，默认 tcp: " PROTO

    PROTO=${PROTO:-tcp}

    if [ -z "$LOCAL_PORT" ] || [ -z "$TARGET_IP" ] || [ -z "$TARGET_PORT" ]; then
        echo "错误：端口和 IP 不能为空。"
        return
    fi

    add_one_proto() {
        local P="$1"

        iptables -t nat -A PREROUTING -p "$P" --dport "$LOCAL_PORT" -j DNAT --to-destination "$TARGET_IP:$TARGET_PORT"
        iptables -t nat -A POSTROUTING -p "$P" -d "$TARGET_IP" --dport "$TARGET_PORT" -j MASQUERADE
        iptables -A FORWARD -p "$P" -d "$TARGET_IP" --dport "$TARGET_PORT" -j ACCEPT

        echo "$LOCAL_PORT $TARGET_IP $TARGET_PORT $P" >> "$RULE_FILE"
    }

    if [ "$PROTO" = "all" ]; then
        add_one_proto tcp
        add_one_proto udp
    elif [ "$PROTO" = "tcp" ] || [ "$PROTO" = "udp" ]; then
        add_one_proto "$PROTO"
    else
        echo "协议只能是 tcp、udp 或 all。"
        return
    fi

    iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

    save_rules

    echo
    echo "新增转发成功："
    echo "线路机器端口 $LOCAL_PORT -> $TARGET_IP:$TARGET_PORT [$PROTO]"
}

list_forward_rules() {
    echo
    echo "当前由脚本管理的转发规则："
    echo "----------------------------------------"

    if [ ! -s "$RULE_FILE" ]; then
        echo "暂无转发规则。"
        echo "----------------------------------------"
        return
    fi

    nl -w 2 -s ". " "$RULE_FILE" | while read line; do
        NUM=$(echo "$line" | awk '{print $1}' | sed 's/\.//')
        LOCAL_PORT=$(echo "$line" | awk '{print $2}')
        TARGET_IP=$(echo "$line" | awk '{print $3}')
        TARGET_PORT=$(echo "$line" | awk '{print $4}')
        PROTO=$(echo "$line" | awk '{print $5}')

        echo "$NUM. 线路端口 $LOCAL_PORT -> $TARGET_IP:$TARGET_PORT [$PROTO]"
    done

    echo "----------------------------------------"
}

delete_rule_by_values() {
    local LOCAL_PORT="$1"
    local TARGET_IP="$2"
    local TARGET_PORT="$3"
    local PROTO="$4"

    iptables -t nat -D PREROUTING -p "$PROTO" --dport "$LOCAL_PORT" -j DNAT --to-destination "$TARGET_IP:$TARGET_PORT" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -p "$PROTO" -d "$TARGET_IP" --dport "$TARGET_PORT" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$TARGET_PORT" -j ACCEPT 2>/dev/null || true
}

delete_forward_rule() {
    list_forward_rules

    if [ ! -s "$RULE_FILE" ]; then
        return
    fi

    read -p "请输入要删除的规则编号: " RULE_NUM

    LINE=$(sed -n "${RULE_NUM}p" "$RULE_FILE")

    if [ -z "$LINE" ]; then
        echo "无效编号。"
        return
    fi

    LOCAL_PORT=$(echo "$LINE" | awk '{print $1}')
    TARGET_IP=$(echo "$LINE" | awk '{print $2}')
    TARGET_PORT=$(echo "$LINE" | awk '{print $3}')
    PROTO=$(echo "$LINE" | awk '{print $4}')

    delete_rule_by_values "$LOCAL_PORT" "$TARGET_IP" "$TARGET_PORT" "$PROTO"

    sed -i "${RULE_NUM}d" "$RULE_FILE"

    save_rules

    echo
    echo "已删除转发："
    echo "线路机器端口 $LOCAL_PORT -> $TARGET_IP:$TARGET_PORT [$PROTO]"
}

modify_forward_rule() {
    list_forward_rules

    if [ ! -s "$RULE_FILE" ]; then
        return
    fi

    read -p "请输入要修改的规则编号: " RULE_NUM

    OLD_LINE=$(sed -n "${RULE_NUM}p" "$RULE_FILE")

    if [ -z "$OLD_LINE" ]; then
        echo "无效编号。"
        return
    fi

    OLD_LOCAL_PORT=$(echo "$OLD_LINE" | awk '{print $1}')
    OLD_TARGET_IP=$(echo "$OLD_LINE" | awk '{print $2}')
    OLD_TARGET_PORT=$(echo "$OLD_LINE" | awk '{print $3}')
    OLD_PROTO=$(echo "$OLD_LINE" | awk '{print $4}')

    echo
    echo "当前规则："
    echo "线路机器端口 $OLD_LOCAL_PORT -> $OLD_TARGET_IP:$OLD_TARGET_PORT [$OLD_PROTO]"
    echo

    read -p "新的线路机器监听端口，回车保持 $OLD_LOCAL_PORT: " NEW_LOCAL_PORT
    read -p "新的落地机器 IP，回车保持 $OLD_TARGET_IP: " NEW_TARGET_IP
    read -p "新的落地机器端口，回车保持 $OLD_TARGET_PORT: " NEW_TARGET_PORT
    read -p "新的协议 tcp/udp，回车保持 $OLD_PROTO: " NEW_PROTO

    NEW_LOCAL_PORT=${NEW_LOCAL_PORT:-$OLD_LOCAL_PORT}
    NEW_TARGET_IP=${NEW_TARGET_IP:-$OLD_TARGET_IP}
    NEW_TARGET_PORT=${NEW_TARGET_PORT:-$OLD_TARGET_PORT}
    NEW_PROTO=${NEW_PROTO:-$OLD_PROTO}

    if [ "$NEW_PROTO" != "tcp" ] && [ "$NEW_PROTO" != "udp" ]; then
        echo "修改时协议只能是 tcp 或 udp。"
        return
    fi

    delete_rule_by_values "$OLD_LOCAL_PORT" "$OLD_TARGET_IP" "$OLD_TARGET_PORT" "$OLD_PROTO"

    iptables -t nat -A PREROUTING -p "$NEW_PROTO" --dport "$NEW_LOCAL_PORT" -j DNAT --to-destination "$NEW_TARGET_IP:$NEW_TARGET_PORT"
    iptables -t nat -A POSTROUTING -p "$NEW_PROTO" -d "$NEW_TARGET_IP" --dport "$NEW_TARGET_PORT" -j MASQUERADE
    iptables -A FORWARD -p "$NEW_PROTO" -d "$NEW_TARGET_IP" --dport "$NEW_TARGET_PORT" -j ACCEPT

    sed -i "${RULE_NUM}c\\$NEW_LOCAL_PORT $NEW_TARGET_IP $NEW_TARGET_PORT $NEW_PROTO" "$RULE_FILE"

    save_rules

    echo
    echo "修改完成："
    echo "线路机器端口 $NEW_LOCAL_PORT -> $NEW_TARGET_IP:$NEW_TARGET_PORT [$NEW_PROTO]"
}

show_iptables_rules() {
    echo
    echo "iptables NAT 规则："
    iptables -t nat -L PREROUTING -n -v --line-numbers

    echo
    echo "iptables FORWARD 规则："
    iptables -L FORWARD -n -v --line-numbers
}

main_menu() {
    while true; do
        echo
        echo "========== 端口转发管理 =========="
        echo "1. 新增转发"
        echo "2. 查看已有转发"
        echo "3. 修改已有转发"
        echo "4. 删除已有转发"
        echo "5. 查看 iptables 原始规则"
        echo "6. 保存规则"
        echo "0. 退出"
        echo "=================================="
        read -p "请选择: " CHOICE

        case "$CHOICE" in
            1)
                add_forward_rule
                ;;
            2)
                list_forward_rules
                ;;
            3)
                modify_forward_rule
                ;;
            4)
                delete_forward_rule
                ;;
            5)
                show_iptables_rules
                ;;
            6)
                save_rules
                ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                echo "无效选择。"
                ;;
        esac
    done
}

check_root
init_env
main_menu
