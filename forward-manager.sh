#!/usr/bin/env bash

CONF="/etc/port-forward-manager.conf"

check_root() {
  [ "$EUID" -ne 0 ] && echo "请用root运行" && exit 1
}

init_env() {
  touch "$CONF"
  chmod 600 "$CONF"

  # 开启转发
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  # 安装持久化工具
  command -v netfilter-persistent >/dev/null 2>&1 || {
    echo "安装 iptables-persistent..."
    apt update && apt install -y iptables-persistent netfilter-persistent
  }
}

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_ip() {
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

sync_save() {
  netfilter-persistent save >/dev/null 2>&1
}

add_rule() {
  echo "=== 添加端口转发 ==="

  read -p "本机端口: " lp
  read -p "目标IP: " ip
  read -p "目标端口: " tp
  read -p "协议 tcp/udp(默认tcp): " proto
  proto=${proto:-tcp}

  if ! valid_port "$lp" || ! valid_port "$tp" || ! valid_ip "$ip"; then
    echo "输入错误"
    return
  fi

  # 防重复
  iptables -t nat -C PREROUTING -p "$proto" --dport "$lp" \
    -j DNAT --to "$ip:$tp" 2>/dev/null && {
    echo "规则已存在"
    return
  }

  echo "$lp $ip $tp $proto" >> "$CONF"

  # DNAT
  iptables -t nat -A PREROUTING -p "$proto" --dport "$lp" \
    -j DNAT --to "$ip:$tp"

  # FORWARD
  iptables -A FORWARD -p "$proto" -d "$ip" --dport "$tp" -j ACCEPT

  # 回包
  iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED \
    -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  sync_save

  echo "添加成功"
}

list_rule() {
  echo "=== 当前规则 ==="
  nl -ba "$CONF"
}

del_rule() {
  list_rule
  read -p "删除第几条: " n

  line=$(sed -n "${n}p" "$CONF")
  [ -z "$line" ] && echo "无效" && return

  read lp ip tp proto <<< "$line"

  # 删除iptables（粗匹配）
  iptables -t nat -D PREROUTING -p "$proto" --dport "$lp" \
    -j DNAT --to "$ip:$tp" 2>/dev/null

  iptables -D FORWARD -p "$proto" -d "$ip" --dport "$tp" \
    -j ACCEPT 2>/dev/null

  sed -i "${n}d" "$CONF"

  sync_save
  echo "删除成功"
}

reload_all() {
  echo "=== 重建规则 ==="

  while read lp ip tp proto; do
    [ -z "$lp" ] && continue

    iptables -t nat -A PREROUTING -p "$proto" --dport "$lp" \
      -j DNAT --to "$ip:$tp"

    iptables -A FORWARD -p "$proto" -d "$ip" --dport "$tp" -j ACCEPT

  done < "$CONF"

  sync_save
  echo "重建完成"
}

status() {
  echo "=== NAT ==="
  iptables -t nat -S | grep DNAT
  echo "=== FORWARD ==="
  iptables -S FORWARD
}

menu() {
while true; do
  echo ""
  echo "===== 端口转发管理 ====="
  echo "1. 添加规则"
  echo "2. 查看规则"
  echo "3. 删除规则"
  echo "4. 重建规则"
  echo "5. 状态查看"
  echo "0. 退出"
  echo "======================="

  read -p "选择: " c

  case $c in
    1) add_rule ;;
    2) list_rule ;;
    3) del_rule ;;
    4) reload_all ;;
    5) status ;;
    0) exit 0 ;;
  esac
done
}

check_root
init_env
menu
