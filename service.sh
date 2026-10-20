#!/system/bin/sh
#
# adb_tls5555 / service.sh
#
# 分工：
#   system.prop 负责开机早期把 persist.adb.tls_server.enable 置 1，
#   让 adbd 一起来就带 TLS 能力；本脚本负责三件事：
#
#     1. 清掉明文通道（service.adb.tcp.port），避免两条通道并存
#     2. 读 adbd 实际分配的 TLS 端口，用 NAT REDIRECT 把固定端口转发过去
#     3. 防火墙来源控制 + 后台低频复核（端口变化、明文回潮、规则丢失）
#
# 设计原则：fail-closed。
# 拿不到 TLS 端口时不回落到明文 5555 —— 宁可连不上，也不要静默降级。
#

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

verify_loop() {
    while true; do
        sleep "$INTERVAL"
        [ -d "$MODDIR" ] || exit 0
        [ -f "$MODDIR/disable" ] && exit 0

        if [ -n "$(getprop service.adb.tcp.port)" ]; then
            log "WARN: 明文通道被重新打开，清除并重启 adbd"
            resetprop -n service.adb.tcp.port "" 2>/dev/null || setprop service.adb.tcp.port ""
            restart_adbd
        fi

        _p=$(getprop service.adb.tls.port)
        if valid_port "$_p"; then
            if [ "$_p" != "$(cat "$STAMP" 2>/dev/null)" ] || ! nat_ok "$_p"; then
                follow_tls_port "$_p"
            fi
        else
            # 端口消失通常是「无线调试」被关掉，adbd 的 TLS 服务随之停止。
            # 这时 5555 上没有服务可转发，保持现状即可（fail-closed）。
            rm -f "$STAMP"
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

    log "conf: port=$PORT mode=$MODE allow4=\"$ALLOW4\" allow6=\"$ALLOW6\" interval=$INTERVAL ensure_wifi_debug=$ENSURE"

    # 1. 清明文通道
    _old=$(getprop service.adb.tcp.port)
    if [ -n "$_old" ]; then
        log "WARN: 明文通道开启中（service.adb.tcp.port=$_old），清除"
        resetprop -n service.adb.tcp.port "" 2>/dev/null || setprop service.adb.tcp.port ""
        _need=1
    fi

    # 2. 确保 TLS 能力开关（这是真正的输入属性）
    if [ "$(getprop persist.adb.tls_server.enable)" != "1" ]; then
        log "INFO: 注入 persist.adb.tls_server.enable=1"
        setprop persist.adb.tls_server.enable 1
        _need=1
    fi

    if [ "$_need" = "1" ]; then
        log "INFO: 属性有变动，重启 adbd 使其生效"
        restart_adbd
    fi

    # 3. 等 adbd 把随机端口写进 service.adb.tls.port
    _int=$(wait_tls_port 15)
    if [ -z "$_int" ] && [ "$ENSURE" = "1" ]; then
        log "WARN: 未取到 TLS 端口，尝试打开「无线调试」开关"
        settings put global adb_wifi_enabled 1 2>/dev/null
        sleep 3
        _int=$(wait_tls_port 15)
    fi

    if [ -z "$_int" ]; then
        log "FAIL: adbd 未提供 TLS 端口 —— 「无线调试」可能是关闭状态"
        log "FAIL: 已放弃端口转发，**不会**回落明文通道。见 README「排错」一节"
    else
        log "INFO: adbd TLS 端口 = $_int"
        follow_tls_port "$_int"
    fi

    # 4. 防火墙
    detect_ipt
    if [ "$IPT_OK" = "0" ]; then
        if [ "$MODE" = "all" ]; then
            log "WARN: iptables 不可用，跳过防火墙（GUARD_MODE=all，不影响）"
        else
            log "FAIL: iptables 不可用，GUARD_MODE=$MODE 无法生效"
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

    # 5. 后台复核（即使上一步失败也启动，等用户打开无线调试后自愈）
    if [ "$INTERVAL" -gt 0 ]; then
        verify_loop &
        log "INFO: 已启动后台复核，间隔 ${INTERVAL}s"
    fi
}

main "$@"
