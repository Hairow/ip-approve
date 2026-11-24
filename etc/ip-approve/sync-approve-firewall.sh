#!/bin/sh
# 审批防火墙同步脚本：改 /etc/ip-approve/approved.conf 的 4 个端口变量后运行本脚本
#   INPUT_APPROVE_PORT4/6   外网→路由器本机（input 组，规则 ip4-*/ip6-*）
#   FORWARD_APPROVE_PORT4/6 外网→lan 转发（forward 组，规则 forward-ip4-*/forward-ip6-*）
# 每组规则顺序（fw4 按 UCI 段顺序进链，本脚本每次按此顺序重建本体系规则段）：
#   1 allow-accept   源 ∈ 允许名单      → ACCEPT（allow 优先）
#   2 deny-drop       源 ∈ 拒绝名单      → DROP
#   3 cn-gate        源 ∉ 大陆集合      → DROP（未列名的国外源直接丢弃，不进审核、不记日志）
#   4 pending-reject  源 ∈ 待审批名单    → REJECT（审批中的重复探测，watch 去重）
#   5 probe-log       其余国内源          → LOG + REJECT（新探测源发现，watch 抓取 → pending → 推钉钉）
# 大陆集合 cn_ipv4/cn_ipv6 由 refresh-cn-ipset.sh 维护并保证非空；端口留空 = 该组停用。
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

# input 规则表: name|ipset(可空,!前缀=取反)|target|family|log(1/空)
# 顺序即链内顺序：allow → deny → cn-gate → pending → probe-log
RULES_DEF='ip4-allow-accept|ip_allow|ACCEPT|ipv4|
ip4-deny-drop|ip_deny|DROP|ipv4|
cn-gate-ip4|!cn_ipv4|DROP|ipv4|
ip4-pending-reject|ip_pending|REJECT|ipv4|
ip4-probe-log||REJECT|ipv4|1
ip6-allow-accept|ip_allow6|ACCEPT|ipv6|
ip6-deny-drop|ip_deny6|DROP|ipv6|
cn-gate-ip6|!cn_ipv6|DROP|ipv6|
ip6-pending-reject|ip_pending6|REJECT|ipv6|
ip6-probe-log||REJECT|ipv6|1'

# forward 规则表: 同构，verdict 跳 lan 辅助链
FWD_DEF='forward-ip4-allow-accept|ip_allow|ACCEPT|ipv4|
forward-ip4-deny-drop|ip_deny|DROP|ipv4|
cn-gate-forward-ip4|!cn_ipv4|DROP|ipv4|
forward-ip4-pending-reject|ip_pending|REJECT|ipv4|
forward-ip4-probe-log||REJECT|ipv4|1
forward-ip6-allow-accept|ip_allow6|ACCEPT|ipv6|
forward-ip6-deny-drop|ip_deny6|DROP|ipv6|
cn-gate-forward-ip6|!cn_ipv6|DROP|ipv6|
forward-ip6-pending-reject|ip_pending6|REJECT|ipv6|
forward-ip6-probe-log||REJECT|ipv6|1'

have_ipset() {
  for s in $(uci show firewall 2>/dev/null | grep '=ipset' | cut -d. -f2 | cut -d= -f1); do
    [ "$(uci -q get firewall.$s.name)" = "$1" ] && return 0
  done
  return 1
}

created=''

# --- 清理旧版本体系规则段（gate + 审批规则），随后按 DEF 顺序重建，保证链内顺序 ---
# 先收集匿名段索引再倒序删除：边删边会导致匿名段重新编号、索引漂移，漏删残留
del_idx=''
for s in $(uci show firewall 2>/dev/null | grep '=rule' | cut -d. -f2 | cut -d= -f1); do
  name=$(uci -q get firewall.$s.name)
  case "$name" in
    ip4-*|ip6-*|forward-ip4-*|forward-ip6-*|cn-gate-*)
      n=$(echo "$s" | sed 's/.*\[//; s/\]//')
      del_idx="$del_idx $n" ;;
  esac
done
for n in $(echo "$del_idx" | tr ' ' '\n' | sort -rn); do
  uci delete firewall.@rule[$n]
done

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

# --- 通用规则组重建：kind=input|forward, p4/p6=该组端口 ---
# 配置了端口 → 按 DEF 顺序新建；未配置 → 整组不建
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
    [ -z "$plist" ] && continue
    rid=$(uci add firewall rule) || { echo "错误: 创建规则 $name 失败" >&2; exit 1; }
    uci set firewall.$rid.name="$name"
    uci set firewall.$rid.src='wan'
    [ "$kind" = forward ] && uci set firewall.$rid.dest='lan'
    [ -n "$ipset" ] && uci set firewall.$rid.ipset="$ipset"
    uci set firewall.$rid.target="$target"
    uci set firewall.$rid.family="$fam"
    uci set firewall.$rid.proto='tcp'
    for p in $plist; do uci add_list firewall.$rid.dest_port="$p"; done
    [ "$log" = 1 ] && uci set firewall.$rid.log='1' || uci -q delete firewall.$rid.log
    created="$created $kind:$name"
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
