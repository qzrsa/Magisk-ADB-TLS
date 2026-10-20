#!/system/bin/sh
#
# adb_tls5555 / action.sh
# 模块卡片「操作」按钮：重新读一次 adbd 的 TLS 端口，重建 NAT 与防火墙，
# 并打印当前状态。无需重启手机，也无需重启 adbd（除非属性有问题）。
#

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

# 清掉明文通道
if [ -n "$(getprop service.adb.tcp.port)" ]; then
    resetprop -n service.adb.tcp.port "" 2>/dev/null || setprop service.adb.tcp.port ""
    log "action: 已清除明文通道"
fi

# 确保 TLS 能力开关
if [ "$(getprop persist.adb.tls_server.enable)" != "1" ]; then
    setprop persist.adb.tls_server.enable 1
fi

_int=$(getprop service.adb.tls.port)
if ! valid_port "$_int"; then
    restart_adbd
    _int=$(wait_tls_port 15)
fi

detect_ipt

if [ -n "$_int" ]; then
    follow_tls_port "$_int"
else
    log "action: 未取到 TLS 端口"
fi

apply_guard

echo "--- adb_tls5555 ---"
echo "service.adb.tls.port          = ${_int:-（空）}"
echo "service.adb.tcp.port          = $(getprop service.adb.tcp.port)"
echo "persist.adb.tls_server.enable = $(getprop persist.adb.tls_server.enable)"
echo "persist.sys.usb.config        = $(getprop persist.sys.usb.config)"
echo "对外端口 ADB_TLS_PORT         = $PORT（NAT 转发到上面的实际端口）"
echo "GUARD_MODE                    = $MODE"

if [ "$IPT_OK" = "1" ]; then
    echo "--- nat ---"
    _rules=$(iptn -S PREROUTING 2>/dev/null | grep -iE "REDIRECT|ADB_TLS_NAT")
    if [ -n "$_rules" ]; then
        echo "$_rules"
    else
        echo "(无转发规则)"
    fi
    if nat_ok "${_int:-}"; then
        echo "转发状态: 就绪（$PORT → ${_int:-?}）"
    else
        echo "转发状态: 未就绪"
    fi
    if [ "$MODE" != "all" ]; then
        echo "--- filter ---"
        ipt -S ADB_GUARD 2>/dev/null || echo "(无防火墙链)"
    fi
else
    echo "--- iptables 不可用 ---"
fi

echo "--- listening ---"
if command -v netstat >/dev/null 2>&1; then
    # adbd 只在随机端口上监听；外部 5555 由内核 NAT 转发而来，netstat 不会显示它
    netstat -ltn 2>/dev/null | grep -E "[:.]${_int:-0}[[:space:]]" || echo "(${_int:-?} 未监听)"
fi
echo "（$PORT 由 NAT 转发，不占独立监听 socket，netstat 查不到是正常的）"
