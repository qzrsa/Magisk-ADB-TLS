#!/system/bin/sh
#
# adb_tls5555 / service.sh
#
# 主力仍然是 system.prop —— 它在 post-fs-data 阶段注入，早于 adbd 首次启动，
# 所以正常开机时 adbd 一出生就是 TLS 模式。本脚本只做四件事：
#
#   1. 清掉明文通道（service.adb.tcp.port），避免两条通道并存
#   2. 校验 TLS 端口是否真的在监听；不监听就补救一次
#   3. 按 module.conf 的 GUARD_MODE 应用设备侧防火墙
#   4. 启动低频后台复核（端口、明文回潮、防火墙规则）
#
# 设计原则：**fail-closed**。
# TLS 起不来时不会回落到明文 5555 —— 宁可连不上，也不要静默降级到无加密通道。
#

MODDIR=${0%/*}
LOG="$MODDIR/adb_tls.log"
CONF_USER=/data/adb/adb_tls5555.conf
CONF_DEF="$MODDIR/module.conf"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# cfg KEY DEFAULT —— 从配置里取值，缺失或空则用默认值。
# 不用 source，避免配置文件里的内容被当成命令执行。
cfg() {
    _conf="$CONF_USER"
    [ -f "$_conf" ] || _conf="$CONF_DEF"
    _v=$(sed -n "s/^[[:space:]]*$1=//p" "$_conf" 2>/dev/null | tail -n 1)
    _v=$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')
    if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "$2"; fi
}

PORT=$(cfg ADB_TLS_PORT 5555)
MODE=$(cfg GUARD_MODE all)
ALLOW4=$(cfg ALLOW4_CIDR "")
ALLOW6=$(cfg ALLOW6_CIDR "")
INTERVAL=$(cfg VERIFY_INTERVAL 60)

case "$PORT" in
    ''|*[!0-9]*) log "WARN: ADB_TLS_PORT 非法，回落 5555"; PORT=5555 ;;
esac
case "$INTERVAL" in
    ''|*[!0-9]*) INTERVAL=60 ;;
esac
[ "$MODE" = "strict" ] && { ALLOW4=""; ALLOW6=""; }

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

# iptables 的锁等待参数不是所有 Android 版本都支持「-w 秒数」，
# 逐级降级，避免命令整体报错导致防火墙静默失效。
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
        strict)
            flush_guard
            guard_v4
            guard_v6
            ;;
        lan)
            flush_guard
            guard_v4
            guard_v6
            ;;
        *)
            flush_guard
            ;;
    esac
}

# 防火墙规则是否还在（非 all 模式才有意义）
guard_ok() {
    [ "$MODE" = "all" ] && return 0
    ipt -C INPUT -p tcp --dport "$PORT" -j ADB_GUARD 2>/dev/null || return 1
    if command -v ip6tables >/dev/null 2>&1; then
        ip6t -C INPUT -p tcp --dport "$PORT" -j ADB_GUARD6 2>/dev/null || return 1
    fi
    return 0
}

verify_loop() {
    while true; do
        sleep "$INTERVAL"
        [ -d "$MODDIR" ] || exit 0
        [ -f "$MODDIR/disable" ] && exit 0

        if [ -n "$(getprop service.adb.tcp.port)" ]; then
            log "WARN: 明文通道被重新打开（$(getprop service.adb.tcp.port)），清除并重启 adbd"
            resetprop -n service.adb.tcp.port "" 2>/dev/null || setprop service.adb.tcp.port ""
            restart_adbd
        fi

        listening "$PORT"
        if [ $? -eq 1 ]; then
            log "WARN: tcp:$PORT 消失，尝试恢复"
            setprop service.adb.tls.port "$PORT"
            restart_adbd
            listening "$PORT" && log "OK: 已恢复监听" || log "FAIL: 恢复失败"
        fi

        if ! guard_ok; then
            log "WARN: 防火墙规则缺失，重新应用"
            apply_guard
        fi
    done
}

main() {
    log "===== service.sh 启动 ====="

    _i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$_i" -lt 180 ]; do
        sleep 1
        _i=$((_i + 1))
    done
    sleep 3

    log "conf: port=$PORT mode=$MODE allow4=\"$ALLOW4\" allow6=\"$ALLOW6\" interval=$INTERVAL"

    # 1. 清明文通道
    _old=$(getprop service.adb.tcp.port)
    if [ -n "$_old" ]; then
        log "WARN: 明文通道开启中（service.adb.tcp.port=$_old），清除"
        resetprop -n service.adb.tcp.port "" 2>/dev/null || setprop service.adb.tcp.port ""
        _need=1
    fi

    # 2. 确保 TLS 相关属性到位
    if [ "$(getprop service.adb.tls.port)" != "$PORT" ]; then
        log "INFO: 注入 service.adb.tls.port=$PORT"
        resetprop -n service.adb.tls.port "$PORT" 2>/dev/null || setprop service.adb.tls.port "$PORT"
        _need=1
    fi
    if [ "$(getprop persist.adb.tls_server.enable)" != "1" ]; then
        log "INFO: 注入 persist.adb.tls_server.enable=1"
        setprop persist.adb.tls_server.enable 1
        _need=1
    fi

    if [ "$_need" = "1" ]; then
        log "INFO: 属性有变动，重启 adbd 使其生效"
        restart_adbd
    fi

    # 3. 校验监听
    listening "$PORT"
    _st=$?
    if [ "$_st" -eq 1 ]; then
        log "WARN: tcp:$PORT 未监听，重启 adbd 重试一次"
        restart_adbd
        listening "$PORT"
        _st=$?
    fi

    case "$_st" in
        0)
            log "OK: tcp:$PORT 已监听"
            ;;
        2)
            log "SKIP: 设备缺 netstat/ss，无法判定端口状态"
            ;;
        *)
            log "FAIL: tcp:$PORT 仍未监听 —— 本机可能不支持 service.adb.tls.port"
            log "FAIL: 已放弃，**不会**回落明文通道。排错见 README「属性不生效」一节"
            exit 0
            ;;
    esac

    # 4. 防火墙
    detect_ipt
    if [ "$IPT_OK" = "0" ]; then
        if [ "$MODE" = "all" ]; then
            log "WARN: iptables 不可用，跳过防火墙（GUARD_MODE=all，不影响）"
        else
            log "FAIL: iptables 不可用，GUARD_MODE=$MODE 无法生效 —— 端口对所有人可见"
            log "FAIL: 请改用 GUARD_MODE=all（依赖 TLS），或换一台带 iptables 的设备"
        fi
    else
        apply_guard
        if [ "$MODE" = "all" ]; then
            log "guard: mode=all（不做来源限制，安全性依赖 TLS 认证）"
        elif guard_ok; then
            log "guard: mode=$MODE 已应用（allow4=\"$ALLOW4\" allow6=\"$ALLOW6\"）"
        else
            log "FAIL: guard 规则应用失败，GUARD_MODE=$MODE 未生效"
        fi
    fi

    # 5. 后台复核
    if [ "$INTERVAL" -gt 0 ]; then
        verify_loop &
        log "INFO: 已启动后台复核，间隔 ${INTERVAL}s"
    fi
}

main "$@"
