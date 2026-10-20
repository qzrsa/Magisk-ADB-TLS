#!/system/bin/sh
#
# adb_tls5555 / customize.sh
# 安装阶段：提示信息 + 冲突检测 + 首次落地默认配置 + 建立公钥目录。
# ui_print 由 Magisk / KernelSU 管理器提供。
#

KEYS_DIR=/data/adb/adb_tls5555/keys

ui_print " "
ui_print "*******************************"
ui_print "  ADB TLS 5555 开机自启  v1.2.1"
ui_print "*******************************"
ui_print "  - adbd 以 TLS 模式监听"
ui_print "  - adbd 的端口由系统随机分配，"
ui_print "    模块用 NAT 把 5555 转发过去"
ui_print "  - 明文 TCP 通道会被关闭"
ui_print "  - 认证 = TLS 客户端证书校验"
ui_print "    把控制端的 adbkey.pub 放进"
ui_print "    $KEYS_DIR"
ui_print "    不需要 6 位配对码"
ui_print "  - 请【重启手机】生效"
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

# 与旧的明文模块冲突检测
# 这两个模块的 system.prop 会打开明文 5555 并把 ro.adb.secure 置 0，
# 直接绕过本项目的认证层，必须在重启前卸掉。
for _m in adb_tcp5555 adbd_tcpip_unsec; do
    if [ -d "/data/adb/modules/$_m" ]; then
        ui_print " "
        ui_print " !! 检测到 $_m"
        ui_print " !! 它会打开明文 5555 并设 ro.adb.secure=0，"
        ui_print " !! 直接绕过本项目的认证。请先卸载它再重启。"
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
ui_print "  - 连接：adb connect <手机IP>:5555"
ui_print "  - 详见 README 的「认证」一节"
ui_print " "
