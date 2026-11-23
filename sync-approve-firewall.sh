#!/bin/sh
# 审批防火墙同步脚本：input/forward 两组端口独立配置 + 缺失的 ipset/规则自动重建
# 用法: 先改 /etc/ip-approve/approved.conf 里的 4 个端口变量（均可留空 = 该组停用）：
#         INPUT_APPROVE_PORT4='端口1 端口2 ...'    ← input(v4) 审批端口：外网→路由器本机
#         INPUT_APPROVE_PORT6='端口1 端口2 ...'    ← input(v6) 审批端口
#         FORWARD_APPROVE_PORT4='端口1 ...'        ← forward(v4) 审批端口：外网→lan 转发流量
#         FORWARD_APPROVE_PORT6='端口1 ...'        ← forward(v6) 审批端口（fnOS Web 等）
#       再运行本脚本
# 功能:
#   1) 6 个 ipset 定义缺失时自动重建（含 loadfile 关联）
#   2) input 审批规则（src=wan，目标=路由器本机）：ip4-*/ip6-* 各 4 条，随 INPUT_APPROVE_PORT* 启停
#   3) forward 审批规则（src=wan dest=lan，转发流量）：fnos-ip4-*/fnos-ip6-* 各 4 条，
#      随 FORWARD_APPROVE_PORT* 启停；注意 forward 规则不限定目标主机，仅按端口匹配——
#      端口应只给单一目标服务使用（如 fnOS Web 5666/5667）
# 规则结构（每组 4 条）：deny(set)→drop / allow(set)→accept / pending(set)→reject /
#   probe-log(无集合,兜底)→log+reject ← watch 靠 probe-log 日志发现新探测源
# 其他:
#   - nft 日志前缀 = fw4 取自规则名（如 ip4-probe-log: ），approved-ip-watch.sh 用泛匹配
#     *pending-reject* / *probe-log* 兜住所有前缀，规则改名无需同步 watch
#   - 末尾 uci commit 并重启防火墙使全部变更生效；ip_pending 为运行时集合，重启后清空
CONF=/etc/ip-approve/approved.conf

# 解析变量值：去引号/分号，逗号转空格；未配置返回空
parse_ports() {
  awk -F= -v key="$1" '$0 ~ "^"key"=" {v=substr($0, index($0,"=")+1); gsub(/[;'"'"']/,"",v); gsub(/,/," ",v); gsub(/^ +| +$/,"",v); print v}' "$CONF"
}
IN_P4=$(parse_ports INPUT_APPROVE_PORT4)
IN_P6=$(parse_ports INPUT_APPROVE_PORT6)
FWD_P4=$(parse_ports FORWARD_APPROVE_PORT4)
FWD_P6=$(parse_ports FORWARD_APPROVE_PORT6)

# 端口合法性校验（空列表合法 = 该组停用）
check_ports() {
  local list="$1" label="$2" p
  for p in $list; do
    case "$p" in *[!0-9]*|'') echo "错误: $label 非法端口 '$p'" >&2; exit 1;; esac
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "错误: $label 端口越界 '$p'" >&2; exit 1; }
  done
}
check_ports "$IN_P4" "INPUT_APPROVE_PORT4"
check_ports "$IN_P6" "INPUT_APPROVE_PORT6"
check_ports "$FWD_P4" "FORWARD_APPROVE_PORT4"
check_ports "$FWD_P6" "FORWARD_APPROVE_PORT6"

# ipset 定义表: name|family|comment|loadfile(可空)
IPSETS='ip_allow|ipv4|允许的ip(审批通过+默认放行)|/etc/ip-approve/ip-allow.list
ip_deny|ipv4|拒绝的ip|/etc/ip-approve/ip-deny.list
ip_pending|ipv4|待审批ip(运行时,重启清空)|
ip_allow6|ipv6|允许的ip(v6)|/etc/ip-approve/ip-allow6.list
ip_deny6|ipv6|拒绝的ip(v6)|/etc/ip-approve/ip-deny6.list
ip_pending6|ipv6|待审批ip(v6,运行时)|'

# input 审批规则表: name|ipset(可空)|target|family|log(可空)
RULES_DEF='ip4-deny-drop|ip_deny|DROP|ipv4|
ip4-allow-accept|ip_allow|ACCEPT|ipv4|
ip4-pending-reject|ip_pending|REJECT|ipv4|1
ip4-probe-log||REJECT|ipv4|1
ip6-deny-drop|ip_deny6|DROP|ipv6|
ip6-allow-accept|ip_allow6|ACCEPT|ipv6|
ip6-pending-reject|ip_pending6|REJECT|ipv6|1
ip6-probe-log||REJECT|ipv6|1'

# forward 审批规则表: name|ipset(可空)|target|family|log(可空)
FWD_DEF='fnos-ip4-deny-drop|ip_deny|DROP|ipv4|
fnos-ip4-allow-accept|ip_allow|ACCEPT|ipv4|
fnos-ip4-pending-reject|ip_pending|REJECT|ipv4|1
fnos-ip4-probe-log||REJECT|ipv4|1
fnos-ip6-deny-drop|ip_deny6|DROP|ipv6|
fnos-ip6-allow-accept|ip_allow6|ACCEPT|ipv6|
fnos-ip6-pending-reject|ip_pending6|REJECT|ipv6|1
fnos-ip6-probe-log||REJECT|ipv6|1'

have_ipset() {
  for s in $(uci show firewall 2>/dev/null | grep '=ipset' | cut -d. -f2 | cut -d= -f1); do
    [ "$(uci -q get firewall.$s.name)" = "$1" ] && return 0
  done
  return 1
}
rule_sid() {
  for s in $(uci show firewall 2>/dev/null | grep '=rule' | cut -d. -f2 | cut -d= -f1); do
    [ "$(uci -q get firewall.$s.name)" = "$1" ] && { echo "$s"; return 0; }
  done
  return 1
}

created=''

# --- 重建缺失 ipset（始终重建，无规则引用时无害）---
while IFS='|' read -r name fam cmt load; do
  [ -n "$name" ] || continue
  have_ipset "$name" && continue
  sid=$(uci add firewall ipset) || { echo "错误: 创建 ipset $name 失败" >&2; exit 1; }
  uci set firewall.$sid.name="$name"
  uci set firewall.$sid.family="$fam"
  uci set firewall.$sid.match='src_net'
  [ -n "$cmt" ] && uci set firewall.$sid.comment="$cmt"
  [ -n "$load" ] && uci set firewall.$sid.loadfile="$load"
  created="$created ipset:$name"
done <<EOF2
$IPSETS
EOF2

# --- 通用规则组同步：kind=input|forward, p4/p6=该组端口 ---
# 配置了端口 → 缺失补建 + dest_port 同步；未配置 → 删除该组全部规则
sync_rules() {
  kind="$1" p4="$2" p6="$3"
  case "$kind" in
    input)   DEF="$RULES_DEF" ;;
    forward) DEF="$FWD_DEF" ;;
    *) return 1 ;;
  esac
  while IFS='|' read -r name ipset target fam log; do
    [ -n "$name" ] || continue
    case "$fam" in
      ipv4) plist="$p4" ;;
      ipv6) plist="$p6" ;;
    esac
    sid=$(rule_sid "$name") || sid=''
    if [ -z "$plist" ]; then
      if [ -n "$sid" ]; then
        uci delete firewall.$sid || exit 1
        created="$created 移除:$name"
      fi
      continue
    fi
    if [ -z "$sid" ]; then
      rid=$(uci add firewall rule) || { echo "错误: 创建规则 $name 失败" >&2; exit 1; }
      uci set firewall.$rid.name="$name"
      uci set firewall.$rid.src='wan'
      [ "$kind" = forward ] && uci set firewall.$rid.dest='lan'
      [ -n "$ipset" ] && uci set firewall.$rid.ipset="$ipset"
      uci set firewall.$rid.target="$target"
      uci set firewall.$rid.family="$fam"
      uci set firewall.$rid.proto='tcp'
      created="$created $kind:$name"
      sid="$rid"
    fi
    uci -q delete firewall.$sid.dest_port
    for p in $plist; do uci add_list firewall.$sid.dest_port="$p"; done
    [ -n "$log" ] && uci set firewall.$sid.log='1' || uci -q delete firewall.$sid.log
  done <<EOF2
$DEF
EOF2
}

sync_rules input "$IN_P4" "$IN_P6"
sync_rules forward "$FWD_P4" "$FWD_P6"

uci commit firewall
[ -n "$created" ] && echo "变更:$created"
echo "input   v4: ${IN_P4:-未配置，停用}  |  input   v6: ${IN_P6:-未配置，停用}"
echo "forward v4: ${FWD_P4:-未配置，停用}  |  forward v6: ${FWD_P6:-未配置，停用}"
/etc/init.d/firewall restart >/dev/null 2>&1
echo 'OK'
