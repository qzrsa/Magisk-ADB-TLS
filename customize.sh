#!/system/bin/sh
#
# adb_tls5555 / customize.sh
# 安装阶段：提示信息 + 端口冲突检测 + 首次落地默认配置 + 建立公钥目录。
# ui_print 由 Magisk / KernelSU 管理器提供。
#

KEYS_DIR=/data/adb/adb_tls5555/keys

ui_print " "
ui_print "*******************************"
ui_print "  ADB TLS 固定端口  v1.3.2"
ui_print "*******************************"
ui_print "  - adbd 以 TLS 模式监听"
ui_print "  - adbd 的端口由系统随机分配，"
ui_print "    模块用 NAT 把固定端口转发过去"
ui_print "  - 本版本【不含 system.prop】"
ui_print "    开机最早阶段不做任何事，"
ui_print "    不可能把设备卡在开机画面"
ui_print "  - 认证 = TLS 客户端证书校验"
ui_print "    把控制端的 adbkey.pub 放进"
ui_print "    $KEYS_DIR"
ui_print "    不需要 6 位配对码"
ui_print " "

# 首次安装落地用户配置（升级不覆盖）
if [ ! -f /data/adb/adb_tls5555.conf ]; then
    cp -f "$MODPATH/module.conf" /data/adb/adb_tls5555.conf 2>/dev/null
    chmod 0600 /data/adb/adb_tls5555.conf 2>/dev/null
    ui_print "  - 已生成配置 /data/adb/adb_tls5555.conf"
else
    ui_print "  - 沿用已有配置 /data/adb/adb_tls5555.conf"
fi

# 建立公钥目录
mkdir -p "$KEYS_DIR" 2>/dev/null
chmod 0700 "$KEYS_DIR" 2>/dev/null
ui_print "  - 公钥目录 $KEYS_DIR"

# 端口冲突检测：本模块用 NAT REDIRECT 抢对外端口，不能和 adbd 明文端口重合
_ptcp=$(getprop service.adb.tcp.port 2>/dev/null)
_ptls=$(sed -n 's/^[[:space:]]*ADB_TLS_PORT=//p' /data/adb/adb_tls5555.conf 2>/dev/null | tail -n 1)
[ -z "$_ptls" ] && _ptls=5555

if [ -n "$_ptcp" ] && [ "$_ptcp" = "$_ptls" ]; then
    ui_print " "
    ui_print " !! 端口冲突：ADB_TLS_PORT=$_ptls"
    ui_print " !! 但 adbd 的明文通道已经占用了这个端口"
    ui_print " !! （service.adb.tcp.port=$_ptcp）"
    ui_print " !! NAT 转发会把那条明文通道顶掉。"
    ui_print " !! 请编辑 /data/adb/adb_tls5555.conf，改成 5556 等空闲端口。"
    ui_print " !! 不改的话本模块会拒绝启动（见 adb_tls.log）。"
    ui_print " "
fi

# 明文模块共存提示（v1.3.0 起不再强制卸载，只是说明关系）
for _m in adb_tcp5555 adbd_tcpip_unsec; do
    if [ -d "/data/adb/modules/$_m" ] && [ ! -f "/data/adb/modules/$_m/disable" ]; then
        ui_print " "
        ui_print " 注意：检测到启用的 $_m"
        ui_print " 它会把 ro.adb.secure 置 0，等于关掉本模块的认证层。"
        ui_print " 加密仍然有效，但不会校验客户端身份。"
        ui_print " 想要真正的认证：禁用/卸载它，并删除它的 system.prop 效果后重启。"
        ui_print " "
    fi
done

# 顺手提示：sdcard 上已经有 adbkey.pub 的话，直接用
for _c in /sdcard/adbkey.pub /sdcard/Download/adbkey.pub /sdcard/Documents/adbkey.pub; do
    if [ -f "$_c" ]; then
        ui_print "  - 发现 $_c"
        ui_print "    可复制到公钥目录后点模块「操作」，无需重启"
        break
    fi
done

ui_print " "
ui_print "  - 加入控制端公钥（在电脑上执行）："
ui_print "      adb push ~/.android/adbkey.pub $KEYS_DIR/"
ui_print "    或者直接把 adbkey.pub 复制到该目录"
ui_print "  - 然后点模块卡片的「操作」按钮，会自动生效"
ui_print "  - 连接：adb connect <设备IP>:$_ptls"
ui_print "  - 详见 README 的「认证」一节"
ui_print " "
