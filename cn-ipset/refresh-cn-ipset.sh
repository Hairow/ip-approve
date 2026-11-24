#!/bin/sh
set -eu
# refresh-cn-ipset.sh
# 目的：让 fw4 里的 cn_ipv4 / cn_ipv6 集合跟着国内 IP 数据一起更新。
#
# 数据流：PassWall 的 chnroute{,6}（最新） --> /etc/cn-ipset/chnroute{,6}（随配置保留的独立副本）
#         --> fw4 reload-sets 重新读取 loadfile 指向的那份副本
#
# 关键设计：/etc/cn-ipset/ 是系统升级后依然存在的那份。PassWall 文件不存在时（插件被移除或未重装），
#           脚本会沿用旧副本，绝不把集合刷成空的 —— 否则 `ip saddr @空集合` 会拒绝所有人，
#           连国内的 SSH 都进不来。v4/v6 保护对称：两集合都预检、两副本都校验、两集合都过规模阈值。
#
# 用法：cron 定时调用（每 6 小时），或手动执行。

V4_SRC="/usr/share/passwall/rules/chnroute"
V6_SRC="/usr/share/passwall/rules/chnroute6"
V4="/etc/cn-ipset/chnroute"
V6="/etc/cn-ipset/chnroute6"
STAMP="/etc/cn-ipset/.cn-ipset.md5"
TAG="cn-ipset"

# 规模阈值：集合元素数（网段条数）低于此值视为加载失败，不写 stamp、下次重试
MIN_ELEMENTS=1000
# 副本/源最小行数，低于此值视为损坏
MIN_LINES=1000

# cron 环境 PATH 往往很窄，显式固定，避免找不到 nft / fw4 / logger
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# 两个集合任一已被删除（例如回滚过）就静默退出，不打扰日志
nft list set inet fw4 cn_ipv4 >/dev/null 2>&1 || exit 0
nft list set inet fw4 cn_ipv6 >/dev/null 2>&1 || exit 0

mkdir -p /etc/cn-ipset

# 校验路由表文件：非空、行数达标、非空行均为 CIDR（含 '/'）
valid_route_file() {
	f="$1"
	[ -s "$f" ] || return 1
	lines=$(grep -cve '^[ \t]*$' "$f" || true)
	[ "$lines" -ge "$MIN_LINES" ] || return 1
	bad=$(grep -vE '^[ \t]*$' "$f" | grep -vc '/' || true)
	[ "$bad" -eq 0 ]
}

# 把 PassWall 的最新数据同步到副本；先写 mktemp 临时文件再 mv，避免 reload 读到半个文件
sync_file() {
	src="$1" dst="$2"
	[ -s "$src" ] || return 0
	valid_route_file "$src" || { logger -t "$TAG" "WARN: invalid source $(basename "$src"), keep old copy"; return 0; }

	old=$(md5sum "$dst" 2>/dev/null | awk '{print $1}' || true)
	[ "$(md5sum "$src" | awk '{print $1}')" = "$old" ] && return 0

	tmp=$(mktemp "$dst.tmp.XXXXXX") || { logger -t "$TAG" "WARN: mktemp failed for $dst"; return 0; }
	if cp "$src" "$tmp" 2>/dev/null && mv "$tmp" "$dst" 2>/dev/null; then
		logger -t "$TAG" "synced $(basename "$dst") from PassWall"
	else
		rm -f "$tmp"
		logger -t "$TAG" "WARN: sync $(basename "$dst") failed"
	fi
	return 0
}

sync_file "$V4_SRC" "$V4"
sync_file "$V6_SRC" "$V6"

# 副本 v4/v6 都必须有效，否则不 reload，避免把任一集合刷成空的
for f in "$V4" "$V6"; do
	valid_route_file "$f" || { logger -t "$TAG" "skip: $f missing/empty/invalid"; exit 0; }
done

CUR=$(cat "$V4" "$V6" 2>/dev/null | md5sum | awk '{print $1}')
[ -n "$CUR" ] || { logger -t "$TAG" "skip: md5 failed"; exit 0; }

# 数据没变直接退出
if [ "$CUR" = "$(cat "$STAMP" 2>/dev/null || true)" ]; then
	exit 0
fi

fw4 reload-sets >/dev/null 2>&1
RC=$?

# 统计集合内网段条数（CIDR 含 '/'），作为加载是否成功的依据
count_set() {
	nft list set inet fw4 "$1" 2>/dev/null | grep -cE '[0-9a-f:.]+/[0-9]+' || true
}
N4=$(count_set cn_ipv4)
N6=$(count_set cn_ipv6)

if [ "$RC" -eq 0 ] && [ "$N4" -ge "$MIN_ELEMENTS" ] && [ "$N6" -ge "$MIN_ELEMENTS" ]; then
	echo "$CUR" > "$STAMP"
	logger -t "$TAG" "refreshed: cn_ipv4=$N4 cn_ipv6=$N6 md5=$CUR"
else
	logger -t "$TAG" "FAILED rc=$RC cn_ipv4=$N4 cn_ipv6=$N6 (stamp kept, will retry)"
	exit 1
fi
