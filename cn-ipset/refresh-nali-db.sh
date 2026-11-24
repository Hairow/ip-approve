#!/bin/sh
# refresh-nali-db.sh
# 先备份现有归属地 / CDN 库，再调用 nali update 刷新；更新后逐库校验，
# 缺失或空文件自动从本次备份回滚；保留最近几份备份。
#
# 背景：nali v0.8.1 写入非原子（先删旧库再直写目标），且 ip2region 不做内容校验，
#       下载中断 / 超时 / 落坏库时旧库可能已被移除，因此更新前先留一份可还原副本。
#
# 用法：cron 定时调用，或手动执行。

NALI_HOME=/etc/cn-ipset
NALI="$NALI_HOME/nali"
BK_ROOT="$NALI_HOME/backup"
TAG=nali-refresh
# 需要备份 / 刷新 / 校验的库文件名（与 config.yaml 各条目 file 对应）
DBS="qqwry.dat zxipv6wry.db ip2region_v4.xdb cdn.yml"
# 保留最近几份备份，更早的自动清理
KEEP=3

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

log() { logger -t "$TAG" "$*"; }

# 把当前已存在的库复制进指定备份目录（不存在的库不备份）
backup_into() {
    dir="$1"
    mkdir -p "$dir"
    for db in $DBS; do
        [ -f "$NALI_HOME/$db" ] && cp -a "$NALI_HOME/$db" "$dir/$db"
    done
}

# 逐库校验：存在且非空；否则从备份回滚
check_and_rollback() {
    dir="$1"
    for db in $DBS; do
        dst="$NALI_HOME/$db"
        if [ -s "$dst" ]; then
            continue
        fi
        if [ -f "$dir/$db" ]; then
            cp -a "$dir/$db" "$dst"
            log "ROLLBACK $db: 更新后缺失/为空，已从本次备份还原"
        else
            log "WARN $db: 更新后缺失，且无旧备份可还原"
        fi
    done
}

# 轮转：仅保留最近 KEEP 份时间戳备份（latest 为软链，不在计数内）
prune() {
    [ -d "$BK_ROOT" ] || return 0
    set -- $(ls -1 "$BK_ROOT" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort)
    while [ $# -gt "$KEEP" ]; do
        rm -rf "$BK_ROOT/$1"
        shift
    done
}

[ -x "$NALI" ] || { log "nali 二进制不存在: $NALI"; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
BK_DIR="$BK_ROOT/$STAMP"

# 1) 更新前先备份旧库
backup_into "$BK_DIR"
# latest 指向本次备份
rm -f "$BK_ROOT/latest"
ln -sfn "$BK_DIR" "$BK_ROOT/latest"
log "备份完成: $BK_DIR"

# 2) 调用 nali 刷新四库
NALI_HOME="$NALI_HOME" "$NALI" update --db qqwry,zxipv6wry,ip2region,cdn 2>&1 | logger -t nali-update

# 3) 逐库校验，异常从本次备份自动回滚
check_and_rollback "$BK_DIR"

# 4) 清理超出保留份数的旧备份
prune

log "刷新完成"
