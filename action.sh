#!/system/bin/sh
#
# adb_tls5555 / action.sh
# 模块卡片「操作」按钮：预置新公钥、重新读一次 adbd 的 TLS 端口，
# 重建 NAT 与防火墙，并打印当前状态（含认证链路）。
#

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

echo "--- adb_tls5555 v$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null) ---"

# 0. 认证层：新公钥必须先落盘再重启 adbd 才生效
if install_client_keys; then
    log "action: 已写入新的客户端公钥，重启 adbd"
    echo "已写入新的客户端公钥 → 重启 adbd"
    restart_adbd
fi

# 1. 清掉明文通道
if [ -n "$(getprop service.adb.tcp.port)" ]; then
    resetprop -n service.adb.tcp.port "" 2>/dev/null || setprop service.adb.tcp.port ""
    log "action: 已清除明文通道"
fi

# 2. 确保 TLS 能力开关
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

echo "--- 属性 ---"
echo "service.adb.tls.port          = ${_int:-（空）}"
echo "service.adb.tcp.port          = $(getprop service.adb.tcp.port)"
echo "persist.adb.tls_server.enable = $(getprop persist.adb.tls_server.enable)"
echo "persist.sys.usb.config        = $(getprop persist.sys.usb.config)"
echo "对外端口 ADB_TLS_PORT         = $PORT（NAT 转发到上面的实际端口）"

echo "--- 认证 ---"
_as=$(getprop ro.adb.secure)
echo "ro.adb.secure                 = ${_as:-（空）}"
echo "ro.secure                     = $(getprop ro.secure)"
echo "keystore $KEYSTORE = $(keystore_count) 条"
if [ "$_as" = "0" ]; then
    echo "状态: 只加密、不认证 —— 任何会说 TLS 的客户端都能连（不建议公网使用）"
else
    echo "状态: 认证开启 —— 客户端公钥必须在 keystore 里，否则 TLS 握手失败"
fi
if [ "$(keystore_count)" != "0" ]; then
    echo "已授权客户端:"
    list_keystore
else
    echo "已授权客户端: （无）"
fi
echo "待预置公钥目录                = $KEYS_DIR"
echo "  （把控制端的 ~/.android/adbkey.pub 复制进去，再点一次「操作」）"

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
    if [ "$GUARD_PLAINTEXT" = "1" ]; then
        _pp=$(plaintext_guard_port)
        if [ -n "$_pp" ]; then
            echo "--- 明文端口 $_pp 白名单 ---"
            ipt -S ADB_GUARD_P 2>/dev/null || echo "(规则未生效)"
        else
            echo "--- 明文端口白名单：无明文端口，跳过 ---"
        fi
    fi
else
    echo "--- iptables 不可用 ---"
fi

echo "--- listening ---"
if command -v netstat >/dev/null 2>&1; then
    # adbd 只在随机端口上监听；外部 $PORT 由内核 NAT 转发而来，netstat 不会显示它
    netstat -ltn 2>/dev/null | grep -E "[:.]${_int:-0}[[:space:]]" || echo "(${_int:-?} 未监听)"
fi
echo "（$PORT 由 NAT 转发，不占独立监听 socket，netstat 查不到是正常的）"
