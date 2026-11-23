#!/bin/sh
# approved-ip-watch.sh
# 监听 wan 入站被拒流量(v4/v6)：新源 IP+目标端口 -> ip_pending{,6} + pending.list + 钉钉推送
# 单实例：pidfile 记录主进程，启动时精确清理旧实例进程树(主进程->子shell->logread)
# 用法：approved-ip-watch.sh test <IP> | backfill

CONF='/etc/ip-approve/approved.conf'
PENDING='/etc/ip-approve/pending.list'
PIDF='/tmp/.approved-ip-watch.pid'
LASTNOT='/tmp/.approved-ip-lastnot'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

[ -f "$CONF" ] && . "$CONF"

notify() {
    local ip="$1" port="$2" now last
    [ -n "$DING_WEBHOOK" ] || return 0
    case "$DING_WEBHOOK" in *access_token=) return 0;; esac
    now=$(date +%s)
    last=$(cat "$LASTNOT" 2>/dev/null || echo 0)
    [ $((now - last)) -lt 10 ] && return 0
    echo "$now" > "$LASTNOT"
    url="$DING_WEBHOOK"
    if [ -n "$DING_SECRET" ]; then
        ts=$((now * 1000))
        sign=$(printf '%s\n%s' "$ts" "$DING_SECRET" | openssl dgst -sha256 -hmac "$DING_SECRET" -binary | openssl base64)
        enc=$(printf '%s' "$sign" | awk '{gsub(/\+/,"%2B"); gsub(/\//,"%2F"); gsub(/=/,"%3D"); print}')
        url="$url&timestamp=$ts&sign=$enc"
    fi
    local stamp
    stamp=$(date '+%F %T')
    local pinfo=""
    case "$port" in ''|'-') pinfo="" ;; *) pinfo="目标端口 $port" ;; esac

    # 快捷按钮：HMAC 签名链接（30 分钟有效），无 QUICK_SECRET 时退回纯文本
    if [ -n "$QUICK_SECRET" ] && [ -n "$QUICK_URL" ]; then
        local qts sa sd
        qts=$now
        sa=$(printf '%s' "approve|$ip|$qts" | openssl dgst -sha256 -hmac "$QUICK_SECRET" -hex 2>/dev/null | awk '{print $NF}')
        sd=$(printf '%s' "deny|$ip|$qts" | openssl dgst -sha256 -hmac "$QUICK_SECRET" -hex 2>/dev/null | awk '{print $NF}')
        local uok uno
        uok="$QUICK_URL/cgi-bin/ip-approve-quick?a=approve&ip=$ip&ts=$qts&sign=$sa"
        uno="$QUICK_URL/cgi-bin/ip-approve-quick?a=deny&ip=$ip&ts=$qts&sign=$sd"
        curl -s -m 5 -H 'Content-Type: application/json' \
            -d '{"msgtype":"actionCard","actionCard":{"title":"【待审批IP】'"$ip"'","text":"#### 【待审批IP】'"$ip"'\n\n于 '"$stamp"' 探测进入待审批队列'"${pinfo:+ · $pinfo}"'\n\n> 点下方按钮完成审批，链接 30 分钟内有效","hideAvatar":"0","btnOrientation":"1","btns":[{"title":"✅ 批准","actionURL":"'"$uok"'"},{"title":"🚫 拒绝","actionURL":"'"$uno"'"}]}}' \
            "$url" >/dev/null
    else
        curl -s -m 5 -H 'Content-Type: application/json' \
            -d '{"msgtype":"text","text":{"content":"【待审批IP】'"$ip"' 于 '"$stamp"' 探测进入待审批队列'"${pinfo:+（$pinfo）}"'，请及时审批"}}' \
            "$url" >/dev/null
    fi
}


# 源 IP 字符集白名单：v4 仅数字与点，v6 仅十六进制与冒号；
# 拦截日志解析出的异物，避免污染钉钉 JSON 与 nft 命令行
valid_src() {
    case "$1" in
        *:*) echo "$1" | grep -qE '^[0-9a-fA-F:]+$' ;;
        *)   echo "$1" | grep -qE '^[0-9.]+$' ;;
    esac
}

new_ip() {
    local ip="$2" port="$3"
    valid_src "$ip" || return
    grep -qF "$ip " "$PENDING" 2>/dev/null && return
    nft add element inet fw4 "$1" "{ $ip }" >/dev/null 2>&1 || return
    echo "$ip $(date '+%F %T') ${port:--}" >> "$PENDING"
    notify "$ip" "$port"
}

by_type() {
    local ip="$1" port="$2"
    case "$ip" in
        192.168.*|10.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|0.0.0.0|255.255.255.255) return;;
        [fF][eE]8*|::1|::) return;;
    esac
    valid_src "$ip" || return
    case "$ip" in
        *:*) new_ip ip_pending6 "$ip" "$port";;
        *.*.*.*) new_ip ip_pending "$ip" "$port";;
    esac
}

backfill() {
    [ -s "$PENDING" ] || return 0
    nft flush set inet fw4 ip_pending 2>/dev/null
    nft flush set inet fw4 ip_pending6 2>/dev/null
    awk '!seen[$1]++' "$PENDING" > /tmp/.pending-uniq 2>/dev/null || return 1
    {
        while read -r ip _; do
            [ -n "$ip" ] || continue
            case "$ip" in
                192.168.*|10.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|0.0.0.0) continue;;
                [fF][eE]8*|::1|::) continue;;
            esac
            valid_src "$ip" || continue
            case "$ip" in
                *:*) echo "add element inet fw4 ip_pending6 { $ip }";;
                *.*.*.*) echo "add element inet fw4 ip_pending { $ip }";;
            esac
        done < /tmp/.pending-uniq
    } | nft -f - 2>/tmp/.nft-err
    if grep -q Error /tmp/.nft-err 2>/dev/null; then
        grep -oE '\{ [0-9a-fA-F:.]+ \}' /tmp/.nft-err | tr -d '{}' | tr -d ' ' | while read -r ip; do
            case "$ip" in
                *:*) nft add element inet fw4 ip_pending6 "{ $ip }" >/dev/null 2>&1;;
                *) nft add element inet fw4 ip_pending "{ $ip }" >/dev/null 2>&1;;
            esac
        done
        rm -f /tmp/.nft-err
    fi
    rm -f /tmp/.pending-uniq
}

if [ "$1" = "test" ]; then by_type "$2" "$3"; exit $?; fi
if [ "$1" = "backfill" ]; then backfill; exit $?; fi

# --- 单实例：清掉 pidfile 记录的旧实例进程树 ---
kill_tree() {
    local pid="$1" c1 c2
    [ -n "$pid" ] || return 0
    for c1 in $(pgrep -P "$pid" 2>/dev/null); do
        for c2 in $(pgrep -P "$c1" 2>/dev/null); do kill -9 "$c2" 2>/dev/null; done
        kill -9 "$c1" 2>/dev/null
    done
    kill -9 "$pid" 2>/dev/null
}
if [ -s "$PIDF" ]; then
    old=$(cat "$PIDF" 2>/dev/null)
    [ -n "$old" ] && [ "$old" != "$$" ] && { kill_tree "$old"; sleep 1; }
fi
echo $$ > "$PIDF"

# --- 主循环 + 信号清理 ---
LOOP_PID=""
cleanup() {
    [ -n "$LOOP_PID" ] && kill_tree "$LOOP_PID"
    rm -f "$PIDF"
    exit 0
}
trap cleanup TERM INT

(
    logread -f | while read -r line; do
        case "$line" in
            *pending-reject*|*probe-log*) ;;
            *) continue;;
        esac
        ip=$(printf '%s' "$line" | sed -n 's/.*SRC=\([^ ]*\).*/\1/p')
        port=$(printf '%s' "$line" | sed -n 's/.*DPT=\([0-9]*\).*/\1/p')
        [ -n "$ip" ] && by_type "$ip" "$port"
    done
) &
LOOP_PID=$!

backfill
wait $LOOP_PID
