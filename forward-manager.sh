#!/usr/bin/env bash

CONF="/etc/port-forward-manager.conf"
TAG="pfm"
IPT="iptables -w"

check_root() {
  [ "$EUID" -ne 0 ] && echo "请用 root 运行" && exit 1
}

init_env() {
  touch "$CONF"
  chmod 600 "$CONF"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi

  if ! command -v netfilter-persistent >/dev/null 2>&1; then
    echo "安装 iptables-persistent..."
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent netfilter-persistent
  fi
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_ip() {
  local ip="$1"
  local a b c d

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS=. read -r a b c d <<< "$ip"

  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    [ "$n" -ge 0 ] && [ "$n" -le 255 ] || return 1
  done

  return 0
}

valid_host() {
  local host="$1"

  [[ "$host" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
  [[ "$host" == *.* ]] || return 1
  [[ "$host" != .* ]] || return 1
  [[ "$host" != *. ]] || return 1

  return 0
}

resolve_host() {
  getent ahostsv4 "$1" | awk '{print $1; exit}'
}

valid_proto() {
  [ "$1" = "tcp" ] || [ "$1" = "udp" ]
}

sync_save() {
  netfilter-persistent save >/dev/null 2>&1
}

ensure_rule() {
  local table="$1"
  shift

  if [ "$table" = "filter" ]; then
    $IPT -C "$@" 2>/dev/null || $IPT -A "$@"
  else
    $IPT -t "$table" -C "$@" 2>/dev/null || $IPT -t "$table" -A "$@"
  fi
}

delete_rule_loop() {
  local table="$1"
  shift

  if [ "$table" = "filter" ]; then
    while $IPT -C "$@" 2>/dev/null; do
      $IPT -D "$@"
    done
  else
    while $IPT -t "$table" -C "$@" 2>/dev/null; do
      $IPT -t "$table" -D "$@"
    done
  fi
}

add_iptables_rule() {
  local lp="$1"
  local host="$2"
  local ip="$3"
  local tp="$4"
  local proto="$5"
  local comment="${TAG}:${proto}:${lp}->${host}:${tp}"

  ensure_rule nat PREROUTING \
    -p "$proto" --dport "$lp" \
    -m comment --comment "$comment:dnat" \
    -j DNAT --to-destination "$ip:$tp"

  ensure_rule nat POSTROUTING \
    -p "$proto" -d "$ip" --dport "$tp" \
    -m comment --comment "$comment:masq" \
    -j MASQUERADE

  ensure_rule filter FORWARD \
    -p "$proto" -d "$ip" --dport "$tp" \
    -m comment --comment "$comment:fwd-in" \
    -j ACCEPT

  ensure_rule filter FORWARD \
    -m conntrack --ctstate RELATED,ESTABLISHED \
    -m comment --comment "${TAG}:established" \
    -j ACCEPT
}

delete_iptables_rule() {
  local lp="$1"
  local host="$2"
  local ip="$3"
  local tp="$4"
  local proto="$5"
  local comment="${TAG}:${proto}:${lp}->${host}:${tp}"

  delete_rule_loop nat PREROUTING \
    -p "$proto" --dport "$lp" \
    -m comment --comment "$comment:dnat" \
    -j DNAT --to-destination "$ip:$tp"

  delete_rule_loop nat POSTROUTING \
    -p "$proto" -d "$ip" --dport "$tp" \
    -m comment --comment "$comment:masq" \
    -j MASQUERADE

  delete_rule_loop filter FORWARD \
    -p "$proto" -d "$ip" --dport "$tp" \
    -m comment --comment "$comment:fwd-in" \
    -j ACCEPT
}

rule_exists_in_conf() {
  local lp="$1"
  local host="$2"
  local ip="$3"
  local tp="$4"
  local proto="$5"

  grep -qx "$lp $host $ip $tp $proto" "$CONF"
}

add_rule() {
  echo "=== 添加端口转发 ==="

  read -rp "本机端口: " lp
  read -rp "目标IP或域名: " input_host
  read -rp "目标端口: " tp
  read -rp "协议 tcp/udp，默认 tcp: " proto
  proto=${proto:-tcp}

  if ! valid_port "$lp"; then
    echo "本机端口错误"
    return
  fi

  if ! valid_port "$tp"; then
    echo "目标端口错误"
    return
  fi

  if ! valid_proto "$proto"; then
    echo "协议只能是 tcp 或 udp"
    return
  fi

  if valid_ip "$input_host"; then
    target_host="$input_host"
    target_ip="$input_host"
  elif valid_host "$input_host"; then
    target_host="$input_host"
    target_ip=$(resolve_host "$input_host")

    if [ -z "$target_ip" ]; then
      echo "域名解析失败：$input_host"
      return
    fi
  else
    echo "目标IP或域名错误"
    return
  fi

  if rule_exists_in_conf "$lp" "$target_host" "$target_ip" "$tp" "$proto"; then
    echo "配置已存在"
    add_iptables_rule "$lp" "$target_host" "$target_ip" "$tp" "$proto"
    sync_save
    echo "已检查并补齐 iptables 规则"
    return
  fi

  echo "$lp $target_host $target_ip $tp $proto" >> "$CONF"

  add_iptables_rule "$lp" "$target_host" "$target_ip" "$tp" "$proto"
  sync_save

  echo "添加成功：0.0.0.0:${lp}/${proto} -> ${target_host}:${tp}"
  echo "实际转发IP：${target_ip}"
}

list_rule() {
  echo "=== 当前配置 ==="

  if [ ! -s "$CONF" ]; then
    echo "暂无规则"
    return
  fi

  printf "%-6s %-10s %-30s %-18s %-10s %-6s\n" "编号" "本机端口" "目标IP或域名" "实际IP" "目标端口" "协议"

  local i=1
  while read -r lp host ip tp proto; do
    [ -z "$lp" ] && continue
    printf "%-6s %-10s %-30s %-18s %-10s %-6s\n" "$i" "$lp" "$host" "$ip" "$tp" "$proto"
    i=$((i + 1))
  done < "$CONF"
}

del_rule() {
  list_rule

  [ ! -s "$CONF" ] && return

  read -rp "删除第几条: " n

  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "输入错误"
    return
  fi

  line=$(sed -n "${n}p" "$CONF")

  if [ -z "$line" ]; then
    echo "无效编号"
    return
  fi

  read -r lp host ip tp proto <<< "$line"

  delete_iptables_rule "$lp" "$host" "$ip" "$tp" "$proto"

  sed -i "${n}d" "$CONF"

  sync_save
  echo "删除成功：0.0.0.0:${lp}/${proto} -> ${host}:${tp}"
}

reload_all() {
  echo "=== 重建脚本管理的规则 ==="

  while read -r lp host ip tp proto; do
    [ -z "$lp" ] && continue
    delete_iptables_rule "$lp" "$host" "$ip" "$tp" "$proto"
  done < "$CONF"

  delete_rule_loop filter FORWARD \
    -m conntrack --ctstate RELATED,ESTABLISHED \
    -m comment --comment "${TAG}:established" \
    -j ACCEPT

  TMP_CONF=$(mktemp)

  while read -r lp host old_ip tp proto; do
    [ -z "$lp" ] && continue

    if valid_ip "$host"; then
      new_ip="$host"
    else
      new_ip=$(resolve_host "$host")
      if [ -z "$new_ip" ]; then
        echo "跳过：$host 解析失败"
        echo "$lp $host $old_ip $tp $proto" >> "$TMP_CONF"
        continue
      fi
    fi

    echo "$lp $host $new_ip $tp $proto" >> "$TMP_CONF"
    add_iptables_rule "$lp" "$host" "$new_ip" "$tp" "$proto"

    if [ "$old_ip" != "$new_ip" ]; then
      echo "更新解析：$host $old_ip -> $new_ip"
    fi
  done < "$CONF"

  mv "$TMP_CONF" "$CONF"
  chmod 600 "$CONF"

  sync_save
  echo "重建完成"
}

status() {
  echo "=== 配置文件 ==="
  list_rule

  echo ""
  echo "=== IPv4 转发 ==="
  sysctl net.ipv4.ip_forward

  echo ""
  echo "=== NAT PREROUTING DNAT ==="
  $IPT -t nat -L PREROUTING -n -v --line-numbers | grep -E "DNAT|num|Chain|$TAG" || true

  echo ""
  echo "=== NAT POSTROUTING MASQUERADE ==="
  $IPT -t nat -L POSTROUTING -n -v --line-numbers | grep -E "MASQUERADE|num|Chain|$TAG" || true

  echo ""
  echo "=== FORWARD ==="
  $IPT -L FORWARD -n -v --line-numbers | grep -E "ACCEPT|num|Chain|$TAG" || true
}

cleanup_legacy() {
  echo "=== 清理旧版无注释规则 ==="
  echo "会根据配置文件清理旧版无 comment 的 DNAT/FORWARD/MASQUERADE"

  while read -r lp host ip tp proto; do
    [ -z "$lp" ] && continue

    while $IPT -t nat -C PREROUTING -p "$proto" --dport "$lp" -j DNAT --to-destination "$ip:$tp" 2>/dev/null; do
      $IPT -t nat -D PREROUTING -p "$proto" --dport "$lp" -j DNAT --to-destination "$ip:$tp"
    done

    while $IPT -t nat -C POSTROUTING -p "$proto" -d "$ip" --dport "$tp" -j MASQUERADE 2>/dev/null; do
      $IPT -t nat -D POSTROUTING -p "$proto" -d "$ip" --dport "$tp" -j MASQUERADE
    done

    while $IPT -C FORWARD -p "$proto" -d "$ip" --dport "$tp" -j ACCEPT 2>/dev/null; do
      $IPT -D FORWARD -p "$proto" -d "$ip" --dport "$tp" -j ACCEPT
    done
  done < "$CONF"

  sync_save
  echo "旧版规则清理完成。建议再执行一次：4. 重建规则"
}

test_target() {
  echo "=== 测试目标连通性 ==="

  read -rp "目标IP或域名: " input_host
  read -rp "目标端口: " tp

  if ! valid_port "$tp"; then
    echo "端口错误"
    return
  fi

  if valid_ip "$input_host"; then
    target_ip="$input_host"
  elif valid_host "$input_host"; then
    target_ip=$(resolve_host "$input_host")

    if [ -z "$target_ip" ]; then
      echo "域名解析失败：$input_host"
      return
    fi

    echo "解析结果：$input_host -> $target_ip"
  else
    echo "目标IP或域名错误"
    return
  fi

  if command -v nc >/dev/null 2>&1; then
    nc -vz "$target_ip" "$tp"
  else
    echo "未安装 nc，可执行：apt install -y netcat-openbsd"
  fi
}

show_raw() {
  echo "=== iptables 原始规则 ==="
  echo ""
  echo "--- NAT ---"
  $IPT -t nat -S
  echo ""
  echo "--- FORWARD ---"
  $IPT -S FORWARD
}

menu() {
  while true; do
    echo ""
    echo "===== 端口转发管理 ====="
    echo "1. 添加规则"
    echo "2. 查看配置"
    echo "3. 删除规则"
    echo "4. 重建规则"
    echo "5. 状态查看"
    echo "6. 清理旧版无注释规则"
    echo "7. 测试目标端口"
    echo "8. 查看 iptables 原始规则"
    echo "0. 退出"
    echo "======================="

    read -rp "选择: " c

    case "$c" in
      1) add_rule ;;
      2) list_rule ;;
      3) del_rule ;;
      4) reload_all ;;
      5) status ;;
      6) cleanup_legacy ;;
      7) test_target ;;
      8) show_raw ;;
      0) exit 0 ;;
      *) echo "无效选择" ;;
    esac
  done
}

check_root
init_env
menu
