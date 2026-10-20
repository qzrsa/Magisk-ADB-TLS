#!/system/bin/sh
#
# adb_tls5555 / uninstall.sh
# 卸载：拆掉防火墙链、清掉 TLS 属性、重启 adbd 回纯 USB 模式。
#
# 注意：
#   * INPUT 里的跳转规则带 --dport，必须按同一个 dport 删，否则删不掉；
#     端口从用户配置里读，读不到就按 5555 处理。
#   * persist.adb.tls_server.enable 是持久属性，优先用 resetprop --delete 删掉。
#

MODDIR=${0%/*}
CONF=/data/adb/adb_tls5555.conf

PORT=5555
if [ -f "$CONF" ]; then
    _p=$(sed -n 's/^[[:space:]]*ADB_TLS_PORT=//p' "$CONF" 2>/dev/null | tail -n 1)
    _p=$(printf '%s' "$_p" | tr -d '"[:space:]')
    case "$_p" in
        ''|*[!0-9]*) ;;
        *) PORT="$_p" ;;
    esac
fi

# 拆防火墙（逐条删，防止 netd 插队导致漏删）
_i=0
while [ "$_i" -lt 4 ]; do
    iptables -D INPUT -p tcp --dport "$PORT" -j ADB_GUARD 2>/dev/null || break
    _i=$((_i + 1))
done
iptables -F ADB_GUARD 2>/dev/null
iptables -X ADB_GUARD 2>/dev/null

_i=0
while [ "$_i" -lt 4 ]; do
    ip6tables -D INPUT -p tcp --dport "$PORT" -j ADB_GUARD6 2>/dev/null || break
    _i=$((_i + 1))
done
ip6tables -F ADB_GUARD6 2>/dev/null
ip6tables -X ADB_GUARD6 2>/dev/null

# 清属性
resetprop -n service.adb.tls.port "" 2>/dev/null || setprop service.adb.tls.port ""
resetprop -n service.adb.tcp.port "" 2>/dev/null || setprop service.adb.tcp.port ""
resetprop --delete persist.adb.tls_server.enable 2>/dev/null || setprop persist.adb.tls_server.enable 0

setprop ctl.restart adbd 2>/dev/null || {
    stop adbd 2>/dev/null
    sleep 1
    start adbd 2>/dev/null
}

rm -f "$MODDIR/adb_tls.log" 2>/dev/null

echo "adb_tls5555 已移除：adbd 已回 USB 模式"
echo "配置保留在 $CONF，如需彻底清理可手动删除"
