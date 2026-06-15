#!/usr/bin/env bash

RULE_FILE="/etc/port-forward-manager.conf"

check_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请使用 root 权限运行：sudo $0"
    exit 1
  fi
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local a b c d
  IFS='.' read -r a b c d <<< "$1"

  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    [ "$n" -ge 0 ] && [ "$n" -le 255 ] || return 1
  done
}

normalize_proto() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

valid_proto() {
  [ "$1" = "tcp" ] || [ "$1" = "udp" ] || [ "$1" = "all" ]
}

valid_rule_num() {
  local num="$1"

  [[ "$num" =~ ^[0-9]+$ ]] || return 1
  [ "$num" -ge 1 ] || return 1
  [ -s "$RULE_FILE" ] || return 1
  [ "$num" -le "$(wc -l < "$RULE_FILE")" ] || return 1
}

init_env() {
  echo "[初始化] 开启 IPv4 转发..."

  if grep -qE '^\s*#?\s*net\.ipv4\.ip_forward\s*=' /etc/sysctl.conf; then
    sed -i 's/^\s*#\?\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
  else
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
  fi

  if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null; then
    echo "错误：开启 IPv4 转发失败。"
    exit 1
  fi

  if ! command -v iptables >/dev/null 2>&1; then
    echo "错误：系统未安装 iptables。"
    exit 1
  fi

  if ! command -v netfilter-persistent >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      echo "[初始化] 安装 iptables-persistent..."
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent
    else
      echo "错误：未找到 netfilter-persistent，且当前系统不是 apt 系。"
      echo "请手动安装 iptables-persistent/netfilter-persistent 后再运行。"
      exit 1
    fi
  fi

  touch "$RULE_FILE"
  chmod 600 "$RULE_FILE"
}

save_rules() {
  if netfilter-persistent save; then
    echo "iptables 规则已保存，重启后仍然生效。"
  else
    echo "错误：保存 iptables 规则失败。"
    return 1
  fi
}

ensure_prerouting_rule() {
  local local_port="$1"
  local target_ip="$2"
  local target_port="$3"
  local proto="$4"

  iptables -t nat -C PREROUTING -p "$proto" --dport "$local_port" \
    -j DNAT --to-destination "$target_ip:$target_port" 2>/dev/null || \
  iptables -t nat -A PREROUTING -p "$proto" --dport "$local_port" \
    -j DNAT --to-destination "$target_ip:$target_port"
}

ensure_postrouting_rule() {
  local target_ip="$1"
  local target_port="$2"
  local proto="$3"

  iptables -t nat -C POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" \
    -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" \
    -j MASQUERADE
}

ensure_forward_rule() {
  local target_ip="$1"
  local target_port="$2"
  local proto="$3"

  iptables -C FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" \
    -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" \
    -j ACCEPT
}

ensure_established_rule() {
  iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED \
    -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED \
    -j ACCEPT
}

ensure_rule_file_line() {
  local local_port="$1"
  local target_ip="$2"
  local target_port="$3"
  local proto="$4"
  local line="$local_port $target_ip $target_port $proto"

  if ! grep -qxF "$line" "$RULE_FILE"; then
    echo "$line" >> "$RULE_FILE"
  fi
}

apply_one_proto() {
  local local_port="$1"
  local target_ip="$2"
  local target_port="$3"
  local proto="$4"
  local write_file="${5:-yes}"

  ensure_prerouting_rule "$local_port" "$target_ip" "$target_port" "$proto"
  ensure_postrouting_rule "$target_ip" "$target_port" "$proto"
  ensure_forward_rule "$target_ip" "$target_port" "$proto"
  ensure_established_rule

  if [ "$write_file" = "yes" ]; then
    ensure_rule_file_line "$local_port" "$target_ip" "$target_port" "$proto"
  fi
}

delete_rule_by_values() {
  local local_port="$1"
  local target_ip="$2"
  local target_port="$3"
  local proto="$4"

  while iptables -t nat -C PREROUTING -p "$proto" --dport "$local_port" \
    -j DNAT --to-destination "$target_ip:$target_port" 2>/dev/null; do
    iptables -t nat -D PREROUTING -p "$proto" --dport "$local_port" \
      -j DNAT --to-destination "$target_ip:$target_port"
  done

  while iptables -t nat -C POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" \
    -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" \
      -j MASQUERADE
  done

  while iptables -C FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" \
    -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" \
      -j ACCEPT
  done
}

validate_rule_values() {
  local local_port="$1"
  local target_ip="$2"
  local target_port="$3"
  local proto="$4"

  if ! valid_port "$local_port"; then
    echo "错误：线路机器监听端口必须是 1-65535 的数字。"
    return 1
  fi

  if ! valid_ipv4 "$target_ip"; then
    echo "错误：落地机器 IP 格式不正确。"
    return 1
  fi

  if ! valid_port "$target_port"; then
    echo "错误：落地机器端口必须是 1-65535 的数字。"
    return 1
  fi

  if ! valid_proto "$proto"; then
    echo "错误：协议只能是 tcp、udp 或 all。"
    return 1
  fi
}

add_forward_rule() {
  echo
  read -r -p "请输入线路机器监听端口，例如 38888: " local_port
  read -r -p "请输入落地机器 IP，例如 103.177.163.98: " target_ip
  read -r -p "请输入落地机器端口，例如 38888: " target_port
  read -r -p "协议类型 tcp/udp/all，默认 tcp: " proto

  proto=$(normalize_proto "${proto:-tcp}")

  validate_rule_values "$local_port" "$target_ip" "$target_port" "$proto" || return 1

  if [ "$proto" = "all" ]; then
    apply_one_proto "$local_port" "$target_ip" "$target_port" "tcp" "yes"
    apply_one_proto "$local_port" "$target_ip" "$target_port" "udp" "yes"
  else
    apply_one_proto "$local_port" "$target_ip" "$target_port" "$proto" "yes"
  fi

  save_rules || return 1

  echo
  echo "新增转发成功："
  echo "线路机器端口 $local_port -> $target_ip:$target_port [$proto]"
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

  local num local_port target_ip target_port proto
  num=1

  while read -r local_port target_ip target_port proto; do
    [ -z "$local_port" ] && continue
    echo "$num. 线路端口 $local_port -> $target_ip:$target_port [$proto]"
    num=$((num + 1))
  done < "$RULE_FILE"

  echo "----------------------------------------"
}

delete_forward_rule() {
  list_forward_rules

  if [ ! -s "$RULE_FILE" ]; then
    return
  fi

  read -r -p "请输入要删除的规则编号: " rule_num

  if ! valid_rule_num "$rule_num"; then
    echo "无效编号。"
    return 1
  fi

  local line local_port target_ip target_port proto
  line=$(sed -n "${rule_num}p" "$RULE_FILE")

  read -r local_port target_ip target_port proto <<< "$line"

  delete_rule_by_values "$local_port" "$target_ip" "$target_port" "$proto"
  sed -i "${rule_num}d" "$RULE_FILE"

  save_rules || return 1

  echo
  echo "已删除转发："
  echo "线路机器端口 $local_port -> $target_ip:$target_port [$proto]"
}

modify_forward_rule() {
  list_forward_rules

  if [ ! -s "$RULE_FILE" ]; then
    return
  fi

  read -r -p "请输入要修改的规则编号: " rule_num

  if ! valid_rule_num "$rule_num"; then
    echo "无效编号。"
    return 1
  fi

  local old_line old_local_port old_target_ip old_target_port old_proto
  old_line=$(sed -n "${rule_num}p" "$RULE_FILE")
  read -r old_local_port old_target_ip old_target_port old_proto <<< "$old_line"

  echo
  echo "当前规则："
  echo "线路机器端口 $old_local_port -> $old_target_ip:$old_target_port [$old_proto]"
  echo

  local new_local_port new_target_ip new_target_port new_proto
  read -r -p "新的线路机器监听端口，回车保持 $old_local_port: " new_local_port
  read -r -p "新的落地机器 IP，回车保持 $old_target_ip: " new_target_ip
  read -r -p "新的落地机器端口，回车保持 $old_target_port: " new_target_port
  read -r -p "新的协议 tcp/udp，回车保持 $old_proto: " new_proto

  new_local_port=${new_local_port:-$old_local_port}
  new_target_ip=${new_target_ip:-$old_target_ip}
  new_target_port=${new_target_port:-$old_target_port}
  new_proto=$(normalize_proto "${new_proto:-$old_proto}")

  if [ "$new_proto" = "all" ]; then
    echo "修改单条规则时协议只能是 tcp 或 udp。"
    echo "如果想要 all，请分别添加 tcp 和 udp 两条规则。"
    return 1
  fi

  validate_rule_values "$new_local_port" "$new_target_ip" "$new_target_port" "$new_proto" || return 1

  delete_rule_by_values "$old_local_port" "$old_target_ip" "$old_target_port" "$old_proto"

  apply_one_proto "$new_local_port" "$new_target_ip" "$new_target_port" "$new_proto" "no"

  sed -i "${rule_num}c\\$new_local_port $new_target_ip $new_target_port $new_proto" "$RULE_FILE"

  save_rules || return 1

  echo
  echo "修改完成："
  echo "线路机器端口 $new_local_port -> $new_target_ip:$new_target_port [$new_proto]"
}

reload_rules_from_file() {
  if [ ! -s "$RULE_FILE" ]; then
    echo "暂无配置文件规则可重载。"
    return
  fi

  local local_port target_ip target_port proto

  while read -r local_port target_ip target_port proto; do
    [ -z "$local_port" ] && continue

    if validate_rule_values "$local_port" "$target_ip" "$target_port" "$proto"; then
      apply_one_proto "$local_port" "$target_ip" "$target_port" "$proto" "no"
    else
      echo "跳过无效规则：$local_port $target_ip $target_port $proto"
    fi
  done < "$RULE_FILE"

  save_rules || return 1
  echo "已根据配置文件重新应用规则。"
}

show_iptables_rules() {
  echo
  echo "iptables NAT PREROUTING 规则："
  iptables -t nat -L PREROUTING -n -v --line-numbers

  echo
  echo "iptables NAT POSTROUTING 规则："
  iptables -t nat -L POSTROUTING -n -v --line-numbers

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
    echo "7. 从配置文件重载规则"
    echo "0. 退出"
    echo "=================================="

    read -r -p "请选择: " choice

    case "$choice" in
      1) add_forward_rule ;;
      2) list_forward_rules ;;
      3) modify_forward_rule ;;
      4) delete_forward_rule ;;
      5) show_iptables_rules ;;
      6) save_rules ;;
      7) reload_rules_from_file ;;
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
