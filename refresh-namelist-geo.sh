#!/bin/sh
# refresh-namelist-geo.sh
# 遍历 allow/deny 四份名单，逐条用 nali 离线库查询归属地，覆盖刷新紧随条目后的
# `# <ip> <geo>` 注释行；文件头/分组独立注释原样保留，查不到归属地的条目不写注释。
#
# 用法：
#   refresh-namelist-geo.sh [--apply] [allow|deny|all]
#   不带 --apply 为 dry-run，只打印重建后的名单，不改动文件；--apply 才落盘。
#   落盘前先把选中的名单备份到 /etc/ip-approve/backup/geo-<时间戳>/（保留最近 3 份）。

CN=/etc/ip-approve
GEO_NALI=/etc/cn-ipset/nali
GEO_HOME=/etc/cn-ipset
PIDF_LOCK=/tmp/.pending.lock
BK_ROOT="$CN/backup"
KEEP=3
TAG=ip-geo-refresh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

FILES_ALLOW="ip-allow.list ip-allow6.list"
FILES_DENY="ip-deny.list ip-deny6.list"

APPLY=0
SET=all
for a in "$@"; do
	case "$a" in
		--apply) APPLY=1 ;;
		allow|deny|all) SET="$a" ;;
		*) echo "未知参数: $a" >&2; exit 2 ;;
	esac
done

log() { echo "[$TAG] $*"; }

# ---- 归属地查询（与 approved-ip-watch.sh 同一套）----
_geo_text() {
	printf '%s' "$1" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p'
}
_geo_clean() {
	local s
	# nali -j 的 JSON 文本里 tab/换行被转义成字面 \t \n \r，先还原成空格；竖线分段转空格
	s=$(printf '%s' "$1" | sed 's/\\t/ /g; s/\\n/ /g; s/\\r/ /g; s/|/ /g')
	s=$(printf '%s' "$s" | sed -E 's/[[:space:]]+[A-Za-z]{2}$//')
	printf '%s' "$s" | awk '{$1=$1; print}'
}
geoip() {
	local ip="$1" out text
	[ -x "$GEO_NALI" ] || return 0
	case "$ip" in
		*:*)
			out=$(NALI_HOME="$GEO_HOME" "$GEO_NALI" -j "$ip" 2>/dev/null) ;;
		*)
			out=$(NALI_HOME="$GEO_HOME" "$GEO_NALI" -j "$ip" 2>/dev/null)
			text=$(_geo_text "$out")
			if [ -z "$text" ]; then
				out=$(NALI_HOME="$GEO_HOME" NALI_DB_IP4=ip2region "$GEO_NALI" -j "$ip" 2>/dev/null)
			fi ;;
	esac
	text=$(_geo_text "$out")
	[ -n "$text" ] && _geo_clean "$text"
}

# ---- 条目校验（识别旧 geo 注释行）----
valid_ip4() { echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
valid_ip6() { echo "$1" | grep -qE '^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F:.]{1,4}$'; }
valid_entry() {
	case "$1" in
		*/*)
			local addr="${1%/*}" prefix="${1##*/}"
			echo "$prefix" | grep -qE '^[0-9]+$' || return 1
			case "$addr" in
				*:*) valid_ip6 "$addr" || return 1 ;;
				*)   valid_ip4 "$addr" || return 1 ;;
			esac ;;
		*:*) valid_ip6 "$1" || return 1 ;;
		*)   valid_ip4 "$1" || return 1 ;;
	esac
}

# 查询用地址：CIDR 取网段首地址
query_addr() { case "$1" in */*) printf '%s' "${1%/*}" ;; *) printf '%s' "$1" ;; esac; }

# 判断注释行是否为旧 `# <ip> <geo>`：去 # 后首字段是合法条目
is_geo_comment() {
	local rest="${1#\#}"; rest="${rest# }"
	set -- $rest
	[ $# -ge 1 ] && valid_entry "$1"
}

backup_file() {
	local f="$1" dir="$2"
	[ -f "$CN/$f" ] && cp -a "$CN/$f" "$dir/$f"
}

# 重建单个名单文件：$1=文件名；结果输出到 stdout
rebuild() {
	local f="$1" line entry qaddr geo
	[ -f "$CN/$f" ] || { log "缺失: $CN/$f"; return 0; }
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && { echo; continue; }
		case "$line" in
			\#*|';'*)
				if is_geo_comment "$line"; then
					# 旧归属地注释：丢弃，稍后按最新查询结果重写
					continue
				fi
				printf '%s\n' "$line"	# 文件头/分组注释，原样保留
				;;
			*)
				entry="$line"
				qaddr=$(query_addr "$entry")
				geo=$(geoip "$qaddr")
				printf '%s\n' "$entry"
				[ -n "$geo" ] && printf '# %s %s\n' "$entry" "$geo"
				;;
		esac
	done < "$CN/$f"
}

case "$SET" in
	allow) FILES="$FILES_ALLOW" ;;
	deny)  FILES="$FILES_DENY" ;;
	all)   FILES="$FILES_ALLOW $FILES_DENY" ;;
esac

[ -x "$GEO_NALI" ] || { log "nali 不存在或不可执行: $GEO_NALI"; exit 1; }

if [ "$APPLY" -eq 1 ]; then
	STAMP=$(date +%Y%m%d-%H%M%S)
	BK_DIR="$BK_ROOT/geo-$STAMP"
	mkdir -p "$BK_DIR"
	for f in $FILES; do backup_file "$f" "$BK_DIR"; done
	log "已备份到 $BK_DIR"

	# 轮转：仅清理本脚本产生的 geo- 备份，保留最近 KEEP 份
	set -- $(ls -1 "$BK_ROOT" 2>/dev/null | grep -E '^geo-[0-9]{8}-[0-9]{6}$' | sort)
	while [ $# -gt "$KEEP" ]; do rm -rf "$BK_ROOT/$1"; shift; done

	(
		flock -n 9 || { log "无法获取锁 $PIDF_LOCK"; exit 1; }
		for f in $FILES; do
			[ -f "$CN/$f" ] || continue
			rebuild "$f" > "/tmp/.geo-$f.new"
			mv "/tmp/.geo-$f.new" "$CN/$f"
			log "已更新 $f"
		done
	) 9>"$PIDF_LOCK"
	rm -f /tmp/.geo-*.new
else
	log "dry-run（加 --apply 落盘），将处理: $FILES"
	for f in $FILES; do
		echo "===== $f ====="
		rebuild "$f"
	done
fi
