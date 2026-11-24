#!/bin/sh
# refresh-cn-ipset.sh
# 目的：让 fw4 里的 cn_ipv4 / cn_ipv6 集合跟着国内 IP 数据一起更新。
#
# 数据流：PassWall 的 chnroute{,6}（最新） --> /etc/cn-ipset/chnroute{,6}（随配置保留的独立副本）
#         --> fw4 reload-sets 重新读取 loadfile 指向的那份副本
#
# 关键设计：/etc/cn-ipset/ 是系统升级后依然存在的那份。PassWall 文件不存在时（插件被移除或未重装），
#           脚本会沿用旧副本，绝不把集合刷成空的 —— 否则 `ip saddr @空集合` 会拒绝所有人，
#           连国内的 SSH 都进不来。
#
# 用法：cron 定时调用（每 6 小时），或手动执行。

V4_SRC="/usr/share/passwall/rules/chnroute"
V6_SRC="/usr/share/passwall/rules/chnroute6"
V4="/etc/cn-ipset/chnroute"
V6="/etc/cn-ipset/chnroute6"
STAMP="/etc/cn-ipset/.cn-ipset.md5"
TAG="cn-ipset"

# cron 环境 PATH 往往很窄，显式固定，避免找不到 nft / fw4 / logger
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# 集合已被删除（例如回滚过）就静默退出，不打扰日志
nft list set inet fw4 cn_ipv4 >/dev/null 2>&1 || exit 0

mkdir -p /etc/cn-ipset

# 把 PassWall 的最新数据同步到副本；先写 .tmp 再 mv，避免 reload 读到半个文件
sync_file() {
	local src="$1" dst="$2"
	[ -s "$src" ] || return 0
	if [ "$(md5sum "$src" | awk '{print $1}')" = "$(md5sum "$dst" 2>/dev/null | awk '{print $1}')" ]; then
		return 0
	fi
	if cp "$src" "$dst.tmp" 2>/dev/null && mv "$dst.tmp" "$dst" 2>/dev/null; then
		logger -t "$TAG" "synced $(basename "$dst") from PassWall"
	else
		rm -f "$dst.tmp"
		logger -t "$TAG" "WARN: sync $(basename "$dst") failed"
	fi
}

sync_file "$V4_SRC" "$V4"
sync_file "$V6_SRC" "$V6"

# 副本仍为空则不刷新，避免把集合刷成空的
[ -s "$V4" ] || { logger -t "$TAG" "skip: $V4 missing or empty"; exit 0; }

CUR=$(cat "$V4" "$V6" 2>/dev/null | md5sum | awk '{print $1}')
[ -n "$CUR" ] || { logger -t "$TAG" "skip: md5 failed"; exit 0; }

# 数据没变直接退出
if [ "$CUR" = "$(cat "$STAMP" 2>/dev/null)" ]; then
	exit 0
fi

fw4 reload-sets >/dev/null 2>&1
RC=$?

# 刷新后校验元素规模，太小说明读文件失败，不更新 stamp，下次重试
N4=$(nft list set inet fw4 cn_ipv4 2>/dev/null | grep -o ',' | wc -l)
N6=$(nft list set inet fw4 cn_ipv6 2>/dev/null | grep -o ',' | wc -l)

if [ "$RC" -eq 0 ] && [ "$N4" -gt 1000 ]; then
	echo "$CUR" > "$STAMP"
	logger -t "$TAG" "refreshed: cn_ipv4=$N4 cn_ipv6=$N6 md5=$CUR"
else
	logger -t "$TAG" "FAILED rc=$RC cn_ipv4=$N4 cn_ipv6=$N6 (stamp kept, will retry)"
	exit 1
fi
