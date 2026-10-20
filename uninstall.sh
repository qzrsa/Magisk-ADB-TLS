#!/system/bin/sh
#
# adb_tls5555 / uninstall.sh
# 卸载：拆掉 NAT 转发与防火墙链、清掉 TLS 属性、重启 adbd 回纯 USB 模式。
#
# 注意：
#   * NAT / INPUT 的跳转规则都带 --dport，必须按同一端口删；
#     端口从用户配置读，读不到按 5555 处理。
#   * persist.adb.tls_server.enable 是持久属性，优先用 resetprop --delete 删除。
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

# 拆 NAT
# 1) 按 stamp 里记录的实际端口删 REDIRECT 规则（端口是 adbd 随机选的，不能猜）
STAMP="$MODDIR/.tls_port"
if [ -f "$STAMP" ]; then
    _int=$(tr -d '[:space:]' < "$STAMP")
    case "$_int" in
        ''|*[!0-9]*) ;;
        *)
            _i=0
            while [ "$_i" -lt 4 ]; do
                iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-ports "$_int" 2>/dev/null || break
                _i=$((_i + 1))
            done
            _i=0
            while [ "$_i" -lt 4 ]; do
                ip6tables -t nat -D PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-ports "$_int" 2>/dev/null || break
                _i=$((_i + 1))
            done
            ;;
    esac
fi

# 2) 清掉 v1.1.0 遗留的中间链
_i=0
while [ "$_i" -lt 4 ]; do
    iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j ADB_TLS_NAT 2>/dev/null || break
    _i=$((_i + 1))
done
iptables -t nat -F ADB_TLS_NAT 2>/dev/null
iptables -t nat -X ADB_TLS_NAT 2>/dev/null

_i=0
while [ "$_i" -lt 4 ]; do
    ip6tables -t nat -D PREROUTING -p tcp --dport "$PORT" -j ADB_TLS_NAT6 2>/dev/null || break
    _i=$((_i + 1))
done
ip6tables -t nat -F ADB_TLS_NAT6 2>/dev/null
ip6tables -t nat -X ADB_TLS_NAT6 2>/dev/null

# 拆防火墙
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
# 注意：**不要**清 service.adb.tcp.port。那是别的模块（如 adbd_tcpip_unsec）
# 或用户自己开的明文通道，本模块从来没设置过它。清掉它会让对方的通道失效，
# 在只有远程入口的设备上等于直接失联。
resetprop -n service.adb.tls.port "" 2>/dev/null || setprop service.adb.tls.port ""
resetprop --delete persist.adb.tls_server.enable 2>/dev/null || setprop persist.adb.tls_server.enable 0

setprop ctl.restart adbd 2>/dev/null || {
    stop adbd 2>/dev/null
    sleep 1
    start adbd 2>/dev/null
}

rm -f "$MODDIR/adb_tls.log" "$MODDIR/.tls_port" 2>/dev/null
# 看门狗与自我禁用留下的痕迹
rm -f "$MODDIR/.failcount" "$MODDIR/.guard_port" 2>/dev/null

echo "adb_tls5555 已移除：NAT 与防火墙已拆除，adbd 已回 USB 模式"
echo "配置保留在 $CONF，如需彻底清理可手动删除"
echo ""
echo "注意：本模块预置进 /data/misc/adb/adb_keys 的客户端公钥**不会**被删除"
echo "      （那是系统文件，可能还有其他来源的公钥）。"
echo "      要撤销某个客户端的授权，编辑该文件删掉对应行后重启 adbd。"
