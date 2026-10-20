#!/system/bin/sh
#
# adb_tls5555 / action.sh
# 模块卡片「操作」按钮：立刻重新注入属性并重启 adbd，无需重启手机。
# 防火墙规则由后台复核保证，这里不重复处理。
#

MODDIR=${0%/*}
CONF_USER=/data/adb/adb_tls5555.conf
CONF_DEF="$MODDIR/module.conf"

cfg() {
    _conf="$CONF_USER"
    [ -f "$_conf" ] || _conf="$CONF_DEF"
    _v=$(sed -n "s/^[[:space:]]*$1=//p" "$_conf" 2>/dev/null | tail -n 1)
    _v=$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')
    if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "$2"; fi
}

PORT=$(cfg ADB_TLS_PORT 5555)
case "$PORT" in
    ''|*[!0-9]*) PORT=5555 ;;
esac

# 清掉明文通道
resetprop -n service.adb.tcp.port "" 2>/dev/null || setprop service.adb.tcp.port ""

# 重新注入 TLS 属性
resetprop -n service.adb.tls.port "$PORT" 2>/dev/null || setprop service.adb.tls.port "$PORT"
setprop persist.adb.tls_server.enable 1

setprop ctl.restart adbd 2>/dev/null || {
    stop adbd 2>/dev/null
    sleep 1
    start adbd 2>/dev/null
}

sleep 3

echo "--- adb_tls5555 ---"
echo "service.adb.tls.port        = $(getprop service.adb.tls.port)"
echo "service.adb.tcp.port        = $(getprop service.adb.tcp.port)"
echo "persist.adb.tls_server.enable = $(getprop persist.adb.tls_server.enable)"
echo "persist.sys.usb.config      = $(getprop persist.sys.usb.config)"
if command -v netstat >/dev/null 2>&1; then
    echo "--- listening ---"
    netstat -ltn 2>/dev/null | grep "[:.]$PORT " || echo "($PORT 未监听)"
fi
