#!/bin/sh
# 修改审批生效端口（支持多端口）+ 缺失的 ipset/规则自动重建
# 用法: 先改 /etc/ip-approve/approved.conf 里的 APPROVE_PORT='端口1 端口2 ...'，再运行本脚本
# 功能:
#   1) 4+2 个 ipset 定义缺失时自动重建（含 loadfile 关联）
#   2) 6 条审批规则缺失时自动重建（src=wan, proto=tcp）
#   3) 把 6 条规则的 dest_port 同步为 APPROVE_PORT，pending 规则带 log
CONF=/etc/ip-approve/approved.conf
PORTS=$(awk -F= '/^APPROVE_PORT=/{v=$2; gsub(/[;'"'"']/,"",v); gsub(/,/," ",v); gsub(/^ +| +$/,"",v); print v}' "$CONF")

n=0
for p in $PORTS; do
  case "$p" in *[!0-9]*|'') echo "错误: 非法端口 '$p'" >&2; exit 1;; esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "错误: 端口越界 '$p'" >&2; exit 1; }
  n=$((n+1))
done
[ "$n" -gt 0 ] || { echo "错误: APPROVE_PORT 未配置或为空" >&2; exit 1; }

# ipset 定义表: name|family|comment|loadfile(可空)
IPSETS='ip_allow|ipv4|允许的ip(审批通过+默认放行)|/etc/ip-approve/ip-allow.list
ip_deny|ipv4|拒绝的ip|/etc/ip-approve/ip-deny.list
ip_pending|ipv4|待审批ip(运行时,重启清空)|
ip_allow6|ipv6|允许的ip(v6)|/etc/ip-approve/ip-allow6.list
ip_deny6|ipv6|拒绝的ip(v6)|/etc/ip-approve/ip-deny6.list
ip_pending6|ipv6|待审批ip(v6,运行时)|'

# 规则定义表: name|ipset|target|family|log(可空)
RULES_DEF='ip-deny-drop|ip_deny|DROP|ipv4|
ip-allow-accept|ip_allow|ACCEPT|ipv4|
ip-pending-reject|ip_pending|REJECT|ipv4|1
ip-deny-drop6|ip_deny6|DROP|ipv6|
ip-allow-accept6|ip_allow6|ACCEPT|ipv6|
ip-pending-reject6|ip_pending6|REJECT|ipv6|1'

have_ipset() {
  for s in $(uci show firewall 2>/dev/null | grep '=ipset' | cut -d. -f2 | cut -d= -f1); do
    [ "$(uci -q get firewall.$s.name)" = "$1" ] && return 0
  done
  return 1
}
have_rule() {
  for s in $(uci show firewall 2>/dev/null | grep '=rule' | cut -d. -f2 | cut -d= -f1); do
    [ "$(uci -q get firewall.$s.name)" = "$1" ] && return 0
  done
  return 1
}

created=''

# --- 重建缺失 ipset ---
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

# --- 重建缺失规则 ---
while IFS='|' read -r name ipset target fam log; do
  [ -n "$name" ] || continue
  have_rule "$name" && continue
  rid=$(uci add firewall rule) || { echo "错误: 创建规则 $name 失败" >&2; exit 1; }
  uci set firewall.$rid.name="$name"
  uci set firewall.$rid.src='wan'
  uci set firewall.$rid.ipset="$ipset"
  uci set firewall.$rid.target="$target"
  uci set firewall.$rid.family="$fam"
  uci set firewall.$rid.proto='tcp'
  [ -n "$log" ] && uci set firewall.$rid.log='1'
  created="$created rule:$name"
done <<EOF2
$RULES_DEF
EOF2

# --- 同步 6 条规则的端口（补建后必然全部存在）---
ok=0
for s in $(uci show firewall | grep '=rule' | cut -d. -f2 | cut -d= -f1); do
  name=$(uci -q get firewall.$s.name)
  case "
$RULES_DEF
" in *"
$name|"*)
    uci -q delete firewall.$s.dest_port
    for p in $PORTS; do uci add_list firewall.$s.dest_port="$p"; done
    case "$name" in
      ip-pending*) uci set firewall.$s.log='1' ;;
      *)           uci -q delete firewall.$s.log ;;
    esac
    ok=$((ok+1))
  ;;
  esac
done
[ "$ok" = 6 ] || { echo "错误: 规则同步异常，只匹配到 $ok/6 条" >&2; exit 1; }

uci commit firewall
[ -n "$created" ] && echo "已重建:$created"
echo "已同步 6 条规则到端口集合: $PORTS，重启防火墙..."
/etc/init.d/firewall restart >/dev/null 2>&1
echo 'OK'
