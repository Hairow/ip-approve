#!/bin/sh
set -eu
# refresh-ip-geoip.sh
# 目的：定时刷新离线 IP 归属地库 qqwry.dat（国内 IP → 省市归属），供审批面板/钉钉推送查询归属地。
#
# 数据流：
#   1. 读 version.json 取 latest（YYYYMMDD），与本地版本戳比对，无新版本直接退出
#   2. 有新版本才下载 release 最新 qqwry.dat，先写临时文件，大小校验通过后原子替换
#   3. 下载/校验失败一律沿用旧库，不覆盖、不更新版本戳，下次 cron 重试
#
# 设备无 jq，版本号用 awk 从 JSON 文本提取；curl 带超时与重试。
# 用法：cron 定时调用（IP 库按周更新，每天一次即可），或手动执行。

VER_URL="https://raw.githubusercontent.com/metowolf/qqwry.dat/main/version.json"
DAT_URL="https://github.com/metowolf/qqwry.dat/releases/latest/download/qqwry.dat"
DAT="/etc/cn-ipset/qqwry.dat"
STAMP="/etc/cn-ipset/.qqwry.version"
TAG="geoip"

# 库文件最小字节数（约 1MB），低于此值视为下载损坏
MIN_SIZE=1000000
# 下载前所需最小可用空间（KB，约 35MB 余量）
MIN_AVAIL_KB=35000

# cron 环境 PATH 往往很窄，显式固定
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p "$(dirname "$DAT")"

# 取最新版本号，必须是 8 位数字（YYYYMMDD）
# 先读入变量再解析，避免 curl 直连 awk 管道时 awk 提前退出导致 EPIPE（curl 23）
# raw 域名间歇超时，带重试；失败保留旧库，等下次 cron 重试
if ! ver_json=$(curl -fsSL --max-time 20 --retry 2 --retry-delay 3 "$VER_URL"); then
	logger -t "$TAG" "FAILED: fetch version.json timeout/error, keep old lib"
	exit 1
fi
latest=$(echo "$ver_json" | awk -F'"' '/"latest"/{print $4; exit}')
case "$latest" in
	[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
	*) logger -t "$TAG" "FAILED: cannot parse latest version (got '${latest:-empty}')"; exit 1 ;;
esac

# 版本没变直接退出
cur=$(cat "$STAMP" 2>/dev/null || true)
if [ "$latest" = "$cur" ]; then
	exit 0
fi

# 磁盘空间预检
avail=$(df -k "$(dirname "$DAT")" | awk 'NR==2{print $4}')
if [ -z "$avail" ] || [ "$avail" -lt "$MIN_AVAIL_KB" ]; then
	logger -t "$TAG" "FAILED: insufficient disk space (avail ${avail:-?} KB), keep old lib"
	exit 1
fi

tmp=$(mktemp "$DAT.tmp.XXXXXX") || { logger -t "$TAG" "FAILED: mktemp failed"; exit 1; }

if ! curl -fsSL --max-time 180 --retry 2 --retry-delay 3 -o "$tmp" "$DAT_URL"; then
	rm -f "$tmp"
	logger -t "$TAG" "FAILED: download qqwry.dat failed (version $latest), keep old lib"
	exit 1
fi

size=$(wc -c < "$tmp" | tr -d ' ')
if [ -z "$size" ] || [ "$size" -lt "$MIN_SIZE" ]; then
	rm -f "$tmp"
	logger -t "$TAG" "FAILED: qqwry.dat too small (${size:-0} bytes), keep old lib"
	exit 1
fi

# 校验通过，原子替换并记录版本戳
mv "$tmp" "$DAT"
chmod 644 "$DAT"
echo "$latest" > "$STAMP"
logger -t "$TAG" "updated: qqwry.dat version=$latest size=$size"
