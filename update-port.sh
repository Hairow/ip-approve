#!/bin/sh
# 修改审批生效端口（支持多端口）
# 用法: 先改 /etc/ip-approve/approved.conf 里的 APPROVE_PORT='端口1 端口2 ...'，再运行本脚本
CONF=/etc/ip-approve/approved.conf
PORTS=$(sed -n "s/^APPROVE_PORT='\\?\\([^']*\\)'\\?;/\\1/p; s/^APPROVE_PORT=\\([^']*\\)$/\\1/p" "$CONF" | sed 's/,/ /g')
RULES='ip-deny-drop ip-allow-accept ip-pending-reject ip-deny-drop6 ip-allow-accept6 ip-pending-reject6'

n=0
for p in $PORTS; do
  case "$p" in *[!0-9]*|'') echo "错误: 非法端口 '$p'" >&2; exit 1;; esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "错误: 端口越界 '$p'" >&2; exit 1; }
  n=$((n+1))
done
[ "$n" -gt 0 ] || { echo "错误: APPROVE_PORT 未配置或为空" >&2; exit 1; }

ok=0
for s in $(uci show firewall | grep '=rule' | cut -d. -f2 | cut -d= -f1); do
  name=$(uci -q get firewall.$s.name)
  case " $RULES " in *" $name "*)
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
[ "$ok" = 6 ] || { echo "警告: 只匹配到 $ok/6 条审批规则" >&2; exit 1; }
uci commit firewall
echo "已同步 6 条规则到端口集合: $PORTS，重启防火墙..."
/etc/init.d/firewall restart >/dev/null 2>&1
echo 'OK'
