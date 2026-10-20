#!/system/bin/sh
#
# adb_tls5555 / lib.sh
# 共用函数。被 service.sh 与 action.sh source。
#
# 设计背景（v1.1 起）：
#   `service.adb.tls.port` 不是可写的输入 —— adbd 在 framework 触发
#   enable_wifi_debugging() 后自己挑一个随机端口绑定 TLS，再把实际端口
#   写进这个属性。所以"注入固定端口"无效，只能**消费**它：
#   读实际端口 → 用 NAT REDIRECT 把固定端口转发过去。
#

MODDIR=${MODDIR:-${0%/*}}
LOG="$MODDIR/adb_tls.log"
STAMP="$MODDIR/.tls_port"
CONF_USER=/data/adb/adb_tls5555.conf
CONF_DEF="$MODDIR/module.conf"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# cfg KEY DEFAULT —— 从配置取值，缺失或空则用默认。
# 不用 source，避免配置文件里的内容被当成命令执行。
cfg() {
    _conf="$CONF_USER"
    [ -f "$_conf" ] || _conf="$CONF_DEF"
    _v=$(sed -n "s/^[[:space:]]*$1=//p" "$_conf" 2>/dev/null | tail -n 1)
    _v=$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')
    if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "$2"; fi
}

# 外部固定端口（用户连接用的那个）
PORT=$(cfg ADB_TLS_PORT 5555)
MODE=$(cfg GUARD_MODE all)
ALLOW4=$(cfg ALLOW4_CIDR "")
ALLOW6=$(cfg ALLOW6_CIDR "")
INTERVAL=$(cfg VERIFY_INTERVAL 60)
ENSURE=$(cfg ENSURE_WIFI_DEBUG 0)

case "$PORT" in
    ''|*[!0-9]*) log "WARN: ADB_TLS_PORT 非法，回落 5555"; PORT=5555 ;;
esac
case "$INTERVAL" in
    ''|*[!0-9]*) INTERVAL=60 ;;
esac
[ "$MODE" = "strict" ] && { ALLOW4=""; ALLOW6=""; }

valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 0=已监听  1=未监听  2=无法检测
listening() {
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -q "[:.]$1[[:space:]]"
        return $?
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q "[:.]$1[[:space:]]"
        return $?
    fi
    return 2
}

restart_adbd() {
    setprop ctl.restart adbd 2>/dev/null || {
        stop adbd 2>/dev/null
        sleep 1
        start adbd 2>/dev/null
    }
    sleep 3
}

# 等 adbd 把 TLS 端口写进属性（它自己随机挑，我们只能等）
# 成功时把端口打印到 stdout
wait_tls_port() {
    _n=0
    while [ "$_n" -lt "$1" ]; do
        _p=$(getprop service.adb.tls.port)
        if valid_port "$_p"; then
            printf '%s' "$_p"
            return 0
        fi
        sleep 1
        _n=$((_n + 1))
    done
    return 1
}

# ---- iptables 兼容层 ----------------------------------------------------
# 锁等待参数不是所有 Android 版本都支持「-w 秒数」，逐级降级，
# 避免命令整体报错导致规则静默失效。
IPT_W=""
IPT_OK=0

detect_ipt() {
    if iptables -w 2 -L -n >/dev/null 2>&1; then
        IPT_W="-w 2"
        IPT_OK=1
    elif iptables -w -L -n >/dev/null 2>&1; then
        IPT_W="-w"
        IPT_OK=1
    elif iptables -L -n >/dev/null 2>&1; then
        IPT_W=""
        IPT_OK=1
    else
        IPT_OK=0
    fi
}

ipt() { iptables $IPT_W "$@"; }
ip6t() { ip6tables $IPT_W "$@"; }
iptn() { iptables $IPT_W -t nat "$@"; }
ip6n() { ip6tables $IPT_W -t nat "$@"; }

# ---- NAT：固定端口 → adbd 实际端口 --------------------------------------

flush_nat() {
    iptn -D PREROUTING -p tcp --dport "$PORT" -j ADB_TLS_NAT 2>/dev/null
    iptn -F ADB_TLS_NAT 2>/dev/null
    iptn -X ADB_TLS_NAT 2>/dev/null
    ip6n -D PREROUTING -p tcp --dport "$PORT" -j ADB_TLS_NAT6 2>/dev/null
    ip6n -F ADB_TLS_NAT6 2>/dev/null
    ip6n -X ADB_TLS_NAT6 2>/dev/null
}

apply_nat() {
    _int=$1
    flush_nat

    # adbd 恰好挑中同一个端口时不需要转发，但仍记录，避免复核时反复重建
    if [ "$_int" = "$PORT" ]; then
        printf '%s' "$_int" > "$STAMP"
        return 0
    fi

    iptn -N ADB_TLS_NAT 2>/dev/null
    iptn -A ADB_TLS_NAT -j REDIRECT --to-ports "$_int" 2>/dev/null
    iptn -I PREROUTING 1 -p tcp --dport "$PORT" -j ADB_TLS_NAT 2>/dev/null

    if command -v ip6tables >/dev/null 2>&1; then
        ip6n -N ADB_TLS_NAT6 2>/dev/null
        ip6n -A ADB_TLS_NAT6 -j REDIRECT --to-ports "$_int" 2>/dev/null
        ip6n -I PREROUTING 1 -p tcp --dport "$PORT" -j ADB_TLS_NAT6 2>/dev/null
    fi

    printf '%s' "$_int" > "$STAMP"
}

# 端口变化时重建 NAT，并把新端口记进 stamp。service.sh 与 action.sh 共用。
follow_tls_port() {
    _p=$1
    _old=$(cat "$STAMP" 2>/dev/null)
    apply_nat "$_p"
    if [ "$_p" != "$_old" ]; then
        log "INFO: TLS 端口 ${_old:-无} → $_p，NAT 已重建（外部 $PORT）"
    fi
    if nat_ok "$_p"; then
        log "OK: $PORT → $_p 转发就绪"
    else
        log "FAIL: NAT 规则未生效（$PORT → $_p）"
    fi
}

nat_ok() {
    _int=$1
    [ "$_int" = "$PORT" ] && return 0
    iptn -C PREROUTING -p tcp --dport "$PORT" -j ADB_TLS_NAT 2>/dev/null || return 1
    iptn -S ADB_TLS_NAT 2>/dev/null | grep -q -- "--to-ports $_int" || return 1
    if command -v ip6tables >/dev/null 2>&1; then
        ip6n -C PREROUTING -p tcp --dport "$PORT" -j ADB_TLS_NAT6 2>/dev/null || return 1
    fi
    return 0
}

# ---- 防火墙：来源白名单 -------------------------------------------------

guard_v4() {
    ipt -N ADB_GUARD 2>/dev/null
    ipt -F ADB_GUARD 2>/dev/null || return 1
    ipt -A ADB_GUARD -i lo -j RETURN 2>/dev/null
    for _c in $ALLOW4; do
        ipt -A ADB_GUARD -s "$_c" -j RETURN 2>/dev/null
    done
    ipt -A ADB_GUARD -j DROP 2>/dev/null
    ipt -D INPUT -p tcp --dport "$PORT" -j ADB_GUARD 2>/dev/null
    ipt -I INPUT 1 -p tcp --dport "$PORT" -j ADB_GUARD 2>/dev/null
}

guard_v6() {
    command -v ip6tables >/dev/null 2>&1 || return 0
    ip6t -N ADB_GUARD6 2>/dev/null
    ip6t -F ADB_GUARD6 2>/dev/null || return 1
    ip6t -A ADB_GUARD6 -i lo -j RETURN 2>/dev/null
    for _c in $ALLOW6; do
        ip6t -A ADB_GUARD6 -s "$_c" -j RETURN 2>/dev/null
    done
    ip6t -A ADB_GUARD6 -j DROP 2>/dev/null
    ip6t -D INPUT -p tcp --dport "$PORT" -j ADB_GUARD6 2>/dev/null
    ip6t -I INPUT 1 -p tcp --dport "$PORT" -j ADB_GUARD6 2>/dev/null
}

flush_guard() {
    ipt -D INPUT -p tcp --dport "$PORT" -j ADB_GUARD 2>/dev/null
    ipt -F ADB_GUARD 2>/dev/null
    ipt -X ADB_GUARD 2>/dev/null
    ip6t -D INPUT -p tcp --dport "$PORT" -j ADB_GUARD6 2>/dev/null
    ip6t -F ADB_GUARD6 2>/dev/null
    ip6t -X ADB_GUARD6 2>/dev/null
}

apply_guard() {
    case "$MODE" in
        strict|lan)
            flush_guard
            guard_v4
            guard_v6
            ;;
        *)
            flush_guard
            ;;
    esac
}

guard_ok() {
    [ "$MODE" = "all" ] && return 0
    ipt -C INPUT -p tcp --dport "$PORT" -j ADB_GUARD 2>/dev/null || return 1
    if command -v ip6tables >/dev/null 2>&1; then
        ip6t -C INPUT -p tcp --dport "$PORT" -j ADB_GUARD6 2>/dev/null || return 1
    fi
    return 0
}
