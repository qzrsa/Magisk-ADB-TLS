#!/system/bin/sh
#
# adb_tls5555 / service.sh
#
# 分工：
#   system.prop 负责开机早期把 persist.adb.tls_server.enable 置 1，
#   让 adbd 一起来就带 TLS 能力；本脚本负责四件事：
#
#     0. 把 KEYS_DIR 里的客户端公钥合并进 adbd 的 keystore（认证层）
#     1. 清掉明文通道（service.adb.tcp.port），避免两条通道并存
#     2. 读 adbd 实际分配的 TLS 端口，用 NAT REDIRECT 把固定端口转发过去
#     3. 防火墙来源控制 + 后台低频复核（端口变化、端口消失自愈、
#        明文回潮、规则丢失、新公钥）
#
# 设计原则：fail-closed。
# 拿不到 TLS 端口时不回落到明文 5555 —— 宁可连不上，也不要静默降级。
#

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

verify_loop() {
    _miss=0    # 连续「没有 TLS 端口」的轮数
    _fix=0     # 连续自愈尝试次数，用于退避

    while true; do
        sleep "$INTERVAL"
        [ -d "$MODDIR" ] || exit 0
        [ -f "$MODDIR/disable" ] && exit 0

        # 用户往 keys 目录丢了新公钥 —— 写进 keystore 并重启 adbd 使其生效
        if install_client_keys; then
            log "INFO: 发现新的客户端公钥，重启 adbd 以重新加载 keystore"
            restart_adbd
            _np=$(wait_tls_port 15)
            valid_port "$_np" && follow_tls_port "$_np"
        fi

        if [ -n "$(getprop service.adb.tcp.port)" ]; then
            log "WARN: 明文通道被重新打开，清除并重启 adbd"
            resetprop -n service.adb.tcp.port "" 2>/dev/null || setprop service.adb.tcp.port ""
            restart_adbd
        fi

        _p=$(getprop service.adb.tls.port)
        if valid_port "$_p"; then
            _miss=0
            _fix=0
            if [ "$_p" != "$(cat "$STAMP" 2>/dev/null)" ] || ! nat_ok "$_p"; then
                follow_tls_port "$_p"
            fi
        else
            # 端口消失 = adbd 已经没有 TLS 监听 = 远程此刻连不上。
            # v1.2.1 及以前这里直接放弃（只删 stamp），结果是「无线调试」被
            # 系统关掉一次就永久失联，只能 USB 或重启才能救回来 ——
            # 对一个「部署在公网」的模块来说这是致命缺陷。
            rm -f "$STAMP"
            _miss=$((_miss + 1))

            _due=0
            if [ "$_fix" -lt 3 ]; then
                # 连续 2 轮（≈2×INTERVAL）都拿不到才动手，避开自身重启 adbd
                # 造成的瞬时空窗
                [ "$_miss" -ge 2 ] && _due=1
            else
                # 连续 3 次都救不回来：退避到每 10 轮再试一次，别无限重启 adbd
                if [ "$_miss" -ge 10 ]; then
                    _due=1
                fi
            fi

            if [ "$_due" = "1" ]; then
                _miss=0
                _fix=$((_fix + 1))
                log "WARN: TLS 端口消失，自愈尝试第 $_fix 次"
                if ensure_tls_alive; then
                    log "OK: 自愈成功，转发已恢复"
                    _fix=0
                else
                    log "FAIL: 自愈失败（第 $_fix 次），adbd 未提供 TLS 端口"
                fi
            fi
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

    _need=0

    # 0. 认证层：把客户端公钥合并进 adbd 的 keystore
    #    必须在等 TLS 端口之前做，这样下面的 restart_adbd 能一次同时生效。
    install_client_keys
    [ "$?" = "0" ] && _need=1

    _as=$(getprop ro.adb.secure)
    log "auth: ro.adb.secure=${_as:-?} keystore=$(keystore_count) 条 keys_dir=$KEYS_DIR"
    case "$_as" in
        0) log "WARN: ro.adb.secure=0 —— TLS 只加密不认证，任何客户端都能连" ;;
        *) log "INFO: 认证开启，只有公钥在 keystore 里的客户端才能连" ;;
    esac

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
