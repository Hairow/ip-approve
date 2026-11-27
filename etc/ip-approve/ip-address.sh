#!/bin/sh

valid_ip4() {
    local addr="$1" old_ifs octet
    case "$addr" in
        ''|*[!0-9.]*|.*|*.|*..*) return 1;;
    esac
    [ "${#addr}" -le 15 ] || return 1
    old_ifs=$IFS
    IFS=.
    set -- $addr
    IFS=$old_ifs
    [ "$#" -eq 4 ] || return 1
    for octet in "$@"; do
        case "$octet" in ''|*[!0-9]*) return 1;; esac
        [ "${#octet}" -le 3 ] || return 1
        [ "${#octet}" -eq 1 ] || [ "${octet#0}" = "$octet" ] || return 1
        [ "$octet" -le 255 ] 2>/dev/null || return 1
    done
}

valid_ip6() {
    local addr="$1" group count rest
    addr=$(ip6_hex_tail "$addr") || return 1
    [ "${#addr}" -le 39 ] || return 1
    case "$addr" in ''|*[!0123456789ABCDEFabcdef:]*|*:::*) return 1;; esac
    case "$addr" in
        *::*)
            case "$addr" in :*) case "$addr" in ::*) ;; *) return 1;; esac;; esac
            case "$addr" in *:) case "$addr" in *::) ;; *) return 1;; esac;; esac
            rest=${addr#*::}
            case "$rest" in *::* ) return 1;; esac
            old_ifs=$IFS
            IFS=:
            set -- $addr
            IFS=$old_ifs
            count=0
            for group in "$@"; do
                [ -n "$group" ] || continue
                [ "${#group}" -le 4 ] || return 1
                count=$((count + 1))
            done
            [ "$count" -lt 8 ] || return 1
            ;;
        *)
            case "$addr" in :*|*:) return 1;; esac
            old_ifs=$IFS
            IFS=:
            set -- $addr
            IFS=$old_ifs
            [ "$#" -eq 8 ] || return 1
            for group in "$@"; do
                [ "${#group}" -le 4 ] || return 1
            done
            ;;
    esac
}

ip6_hex_tail() {
    local addr="$1" v4 prefix old_ifs a b c d
    case "$addr" in
        *.*)
            case "$addr" in *:*) ;; *) return 1;; esac
            v4=${addr##*:}
            prefix=${addr%:*}
            [ "$prefix" != "$addr" ] || return 1
            valid_ip4 "$v4" || return 1
            old_ifs=$IFS
            IFS=.
            set -- $v4
            IFS=$old_ifs
            a=$(( $1 * 256 + $2 ))
            b=$(( $3 * 256 + $4 ))
            printf '%s:%x:%x' "$prefix" "$a" "$b"
            ;;
        *) printf '%s' "$addr";;
    esac
}

valid_ip() {
    case "$1" in
        *:*) valid_ip6 "$1";;
        *)   valid_ip4 "$1";;
    esac
}

valid_entry() {
    local addr prefix max
    case "$1" in
        */*)
            addr=${1%/*}
            prefix=${1##*/}
            case "$addr" in ''|*/*) return 1;; esac
            case "$prefix" in ''|*[!0-9]*) return 1;; esac
            [ "${#prefix}" -le 3 ] || return 1
            [ "${#prefix}" -eq 1 ] || [ "${prefix#0}" = "$prefix" ] || return 1
            case "$addr" in
                *:*) valid_ip6 "$addr" || return 1; max=128;;
                *)   valid_ip4 "$addr" || return 1; max=32;;
            esac
            [ "$prefix" -le "$max" ] 2>/dev/null
            ;;
        *) valid_ip "$1";;
    esac
}
