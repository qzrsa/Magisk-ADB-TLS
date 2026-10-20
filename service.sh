#!/system/bin/sh
#
# adb_tls5555 / service.sh   v1.3.0
#
# ⚠ 本版本**没有 system.prop**，一行都没有。这是刻意的：
#
#   v1.2.x 把 persist.adb.tls_server.enable=1 写进 system.prop，那会在
#   post-fs-data 阶段、开机最早的环节被 Magisk 应用 —— 一旦出问题就卡开机，
#   而这类设备往往只有远程入口，卡开机等于失联。
#
#   真机验证结论（三星 SCG23 盒子，Android 14）：
#     运行时执行 setprop persist.adb.tls_server.enable 1 就能拉起 TLS，
#     不需要重启 adbd，也不会顶掉已有的明文通道。两者可以共存。
#
#   所以本版本的全部动作都放在 late_start（开机完成之后）：
#     · service.sh 崩溃 / 卡死 / 逻辑写错 → 只写日志，**不可能阻止开机**
#     · 最坏结果是「本模块不工作」，而不是「设备起不来」
#
# 三件事，按顺序：
#   0. 电路熔断：上次失败过就自我禁用，绝不再试
#   1. 挂看门狗（在一切危险操作之前）
#   2. 合并公钥 → 开 TLS → NAT 转发 → 校验明文通道没被搞坏
#
# 失败处理：回滚属性 + 写 disable 自我禁用。宁可模块不工作，也不留隐患。
#

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

# 低频复核：只做两件事 —— 跟随 adbd 的端口变化重建 NAT；端口丢了就重新置位属性。
# 不重启 adbd，不碰明文通道。任何一步失败都退出，绝不留半截状态。
verify_loop() {
    while true; do
        sleep "$INTERVAL"
        [ -d "$MODDIR" ] || exit 0
        [ -f "$MODDIR/disable" ] && exit 0

        # 明文通道一旦消失，立刻回滚退出（看门狗也会兜一次）
        if ! plaintext_alive; then
            log "FAIL: 复核发现明文通道没了，回滚"
            revert_props
            bump_fail
            self_disable
            exit 0
        fi

        _p=$(getprop service.adb.tls.port)
        if valid_port "$_p"; then
            if [ "$_p" != "$(cat "$STAMP" 2>/dev/null)" ] || ! nat_ok "$_p"; then
                follow_tls_port "$_p"
            fi
        else
            # TLS 端口丢了：运行时重新置位即可拉回来（已验证不会影响明文通道）
            rm -f "$STAMP"
            log "WARN: TLS 端口消失，重新置位 persist.adb.tls_server.enable"
            setprop persist.adb.tls_server.enable 1
            _np=$(wait_tls_port 15)
            if valid_port "$_np"; then
                follow_tls_port "$_np"
            else
                log "WARN: 仍未取到 TLS 端口，下轮再试"
            fi
        fi
    done
}

main() {
    log "===== service.sh 启动 (v1.3.0) ====="

    # ---- 0. 电路熔断 ----------------------------------------------------
    # 上次运行失败过就不要再试。每次失败都白白消耗一次开机，
    # 而这台设备可能只有远程入口，输不起。
    _fc=$(fail_count)
    if [ -n "$_fc" ] && [ "$_fc" -ge 1 ]; then
        log "FAIL: 上次运行失败过（failcount=$_fc），本次直接自我禁用"
        : > "$MODDIR/disable"
        exit 0
    fi

    # 等开机完成
    _i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$_i" -lt 180 ]; do
        sleep 1
        _i=$((_i + 1))
    done
    sleep 3

    # ---- 1. 记录锚点 + 挂看门狗 -----------------------------------------
    # GUARDPORT = 本模块启动前 adbd 的明文端口。看门狗只保护它。
    _pp=$(plaintext_port)
    printf '%s' "$_pp" > "$GUARDPORT"
    log "conf: port=$PORT interval=$INTERVAL force_secure=$SECURE"
    log "guard: 明文通道=[${_pp:-无}]（本模块不碰它）"

    setsid sh "$MODDIR/watchdog.sh" 90 >/dev/null 2>&1 &
    log "INFO: 看门狗已挂（90 秒后校验明文通道）"

    # ---- 2. 对外端口冲突检查 --------------------------------------------
    # 如果 PORT 正被 adbd 的明文监听占着，禁用 NAT REDIRECT 会把别人的通道顶掉。
    if port_taken_by_plaintext; then
        log "FAIL: 对外端口 $PORT 正被 adbd 明文监听占用，拒绝抢占"
        log "FAIL: 请把 ADB_TLS_PORT 改成别的端口（例如 5556）后重新启用本模块"
        exit 0
    fi

    # ---- 3. 认证层：合并客户端公钥 --------------------------------------
    install_client_keys
    case "$?" in
        0) log "INFO: 新公钥已写入 keystore，本次会重启 adbd 使其生效"
           _need_restart=1 ;;
        *) _need_restart=0 ;;
    esac

    # 认证开关。默认不开（SECURE=0），因为开启后所有通道都要求公钥，
    # 一旦客户端公钥缺失就会把自己也锁在外面。确认 TLS 链路通了再开。
    if [ "$SECURE" = "1" ] && [ "$(getprop ro.adb.secure)" != "1" ]; then
        log "INFO: 按配置开启认证 ro.adb.secure=1"
        resetprop ro.adb.secure 1 2>/dev/null || setprop ro.adb.secure 1
        _need_restart=1
    fi

    # ---- 4. 开 TLS（运行时设置，不重启 adbd）-----------------------------
    setprop persist.adb.tls_server.enable 1
    _tp=$(wait_tls_port 20)

    # 只有「公钥有更新」或「要开认证」才重启 adbd —— 重启会短暂断开所有
    # 连接，能不做就不做。
    if [ "$_need_restart" = "1" ]; then
        log "INFO: 重启 adbd（公钥/认证变更）"
        restart_adbd
        _tp=$(wait_tls_port 20)
    fi

    if ! valid_port "$_tp"; then
        log "FAIL: 20 秒内没拿到 TLS 端口，回滚"
        revert_props
        bump_fail
        self_disable
        exit 0
    fi
    log "INFO: adbd TLS 端口 = $_tp"

    # ---- 5. NAT 转发 + 防火墙 --------------------------------------------
    detect_ipt
    if [ "$IPT_OK" != "1" ]; then
        log "FAIL: iptables 不可用，无法做端口转发，回滚"
        revert_props
        bump_fail
        self_disable
        exit 0
    fi
    follow_tls_port "$_tp"
    apply_guard

    # ---- 6. 校验明文通道没被搞坏 ------------------------------------------
    sleep 2
    if ! plaintext_alive; then
        log "FAIL: 明文通道 $(cat "$GUARDPORT") 被杀，立即回滚"
        revert_props
        setprop ctl.restart adbd 2>/dev/null
        sleep 12
        bump_fail
        self_disable
        exit 0
    fi

    clear_fail
    log "OK: 完成 —— 外部 $PORT → TLS $_tp；明文通道 ${_pp:-无} 正常"

    # ---- 7. 低频复核 -----------------------------------------------------
    if [ "$INTERVAL" -gt 0 ]; then
        verify_loop &
        log "INFO: 已启动后台复核，间隔 ${INTERVAL}s"
    fi
}

main "$@"
