#!/bin/sh
# 修改审批生效端口（v4/v6 分离，可独立停用）+ 缺失的 ipset/规则自动重建
# 用法: 先改 /etc/ip-approve/approved.conf 里的
#         APPROVE_PORT='端口1 端口2 ...'    ← IPv4 input 审批端口；留空 = 不创建 v4 审批规则（流量走 wan 兜底拒绝）
#         APPROVE_PORT6='端口1 端口2 ...'   ← IPv6 审批端口；留空 = v6 审批停用
#       再运行本脚本
# 功能:
#   1) 4+2 个 ipset 定义缺失时自动重建（含 loadfile 关联）
#   2) input 审批规则（src=wan，目标=路由器本机）：按协议族补建/同步端口/移除
#   3) fnOS 转发审批组（wan→lan, IPv6, 端口 5666 5667）：
#      非 cn 来源访问 fnOS Web 走 pending→钉钉审批，随 APPROVE_PORT6 启停
#      注意：若保留 Allow-fnos-Web6（cn 白名单 accept），cn 来源不经审批
CONF=/etc/ip-approve/approved.conf

# 解析变量值：去引号/分号，逗号转空格；未配置返回空
parse_ports() {
  awk -F= -v key="$1" '$0 ~ "^"key"=" {v=substr($0, index($0,"=")+1); gsub(/[;'"'"']/,"",v); gsub(/,/," ",v); gsub(/^ +| +$/,"",v); print v}' "$CONF"
}
PORTS=$(parse_ports APPROVE_PORT)
PORTS6=$(parse_ports APPROVE_PORT6)

# 端口合法性校验（空列表合法 = 该族停用）
check_ports() {
  local list="$1" label="$2" p
  for p in $list; do
    case "$p" in *[!0-9]*|'') echo "错误: $label 非法端口 '$p'" >&2; exit 1;; esac
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "错误: $label 端口越界 '$p'" >&2; exit 1; }
  done
}
check_ports "$PORTS" "APPROVE_PORT(v4)"
check_ports "$PORTS6" "APPROVE_PORT6(v6)"

# ipset 定义表: name|family|comment|loadfile(可空)
IPSETS='ip_allow|ipv4|允许的ip(审批通过+默认放行)|/etc/ip-approve/ip-allow.list
ip_deny|ipv4|拒绝的ip|/etc/ip-approve/ip-deny.list
ip_pending|ipv4|待审批ip(运行时,重启清空)|
ip_allow6|ipv6|允许的ip(v6)|/etc/ip-approve/ip-allow6.list
ip_deny6|ipv6|拒绝的ip(v6)|/etc/ip-approve/ip-deny6.list
ip_pending6|ipv6|待审批ip(v6,运行时)|'

# input 审批规则表: name|ipset|target|family|log(可空)
RULES_DEF='ip-deny-drop|ip_deny|DROP|ipv4|
ip-allow-accept|ip_allow|ACCEPT|ipv4|
ip-pending-reject|ip_pending|REJECT|ipv4|1
ip-deny-drop6|ip_deny6|DROP|ipv6|
ip-allow-accept6|ip_allow6|ACCEPT|ipv6|
ip-pending-reject6|ip_pending6|REJECT|ipv6|1'

# fnOS 转发审批组（src=wan dest=lan, family=ipv6, dest_port 固定）: name|ipset(可空)|target|log(可空)
# 渲染顺序必须在 Allow-fnos-Web6 等 cn 白名单 accept 之后（append 到 uci 末尾自然满足）
FWD_DEF='fnos-deny-drop6|ip_deny6|DROP|
fnos-approve-accept6|ip_allow6|ACCEPT|
fnos-pending-reject6|ip_pending6|REJECT|
fnos-probe-log6||REJECT|1'
FWD_PORT='5666 5667'

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

# --- input 审批规则：配置了端口 → 补建+同步；未配置 → 删除已有 ---
while IFS='|' read -r name ipset target fam log; do
  [ -n "$name" ] || continue
  case "$fam" in
    ipv4) plist="$PORTS" ;;
    ipv6) plist="$PORTS6" ;;
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
    uci set firewall.$rid.ipset="$ipset"
    uci set firewall.$rid.target="$target"
    uci set firewall.$rid.family="$fam"
    uci set firewall.$rid.proto='tcp'
    created="$created rule:$name"
    sid="$rid"
  fi
  uci -q delete firewall.$sid.dest_port
  for p in $plist; do uci add_list firewall.$sid.dest_port="$p"; done
  [ -n "$log" ] && uci set firewall.$sid.log='1' || uci -q delete firewall.$sid.log
done <<EOF2
$RULES_DEF
EOF2

# --- fnOS 转发审批组：随 APPROVE_PORT6 启停 ---
while IFS='|' read -r name ipset target log; do
  [ -n "$name" ] || continue
  sid=$(rule_sid "$name") || sid=''
  if [ -z "$PORTS6" ]; then
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
    uci set firewall.$rid.dest='lan'
    uci set firewall.$rid.proto='tcp'
    uci set firewall.$rid.family='ipv6'
    [ -n "$ipset" ] && uci set firewall.$rid.ipset="$ipset"
    uci set firewall.$rid.target="$target"
    [ -n "$log" ] && uci set firewall.$rid.log='1'
    created="$created fwd:$name"
    sid="$rid"
  fi
  uci -q delete firewall.$sid.dest_port
  for p in $FWD_PORT; do uci add_list firewall.$sid.dest_port="$p"; done
done <<EOF2
$FWD_DEF
EOF2

uci commit firewall
[ -n "$created" ] && echo "变更:$created"
echo "v4 端口: ${PORTS:-<未配置，v4 审批已停用>}  |  v6 端口: ${PORTS6:-<未配置，v6 审批已停用>}"
/etc/init.d/firewall restart >/dev/null 2>&1
echo 'OK'
