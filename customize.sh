#!/system/bin/sh
#
# adb_tls5555 / customize.sh
# 安装阶段：提示信息 + 冲突检测 + 首次落地默认配置。
# ui_print 由 Magisk / KernelSU 管理器提供。
#

ui_print " "
ui_print "*******************************"
ui_print "  ADB TLS 5555 开机自启  v1.1.0"
ui_print "*******************************"
ui_print "  - adbd 以 TLS 模式监听"
ui_print "  - adbd 的端口由系统随机分配，"
ui_print "    模块用 NAT 把 5555 转发过去"
ui_print "  - 明文 TCP 通道会被关闭"
ui_print "  - 认证 = adbd 内置 TLS 配对"
ui_print "    (adb pair 一次，长期有效)"
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

# 与旧的明文模块冲突检测
if [ -d /data/adb/modules/adb_tcp5555 ]; then
    ui_print " "
    ui_print " !! 检测到 adb_tcp5555（明文 5555 模块）"
    ui_print " !! 它会打开明文通道，本项目会主动关掉"
    ui_print " !! 请先卸载那个模块再重启"
    ui_print " "
fi

ui_print "  - 首次使用需在控制端执行："
ui_print "      adb pair <手机IP>:<配对端口>"
ui_print "      adb connect <手机IP>:5555"
ui_print "  - 配对端口在 开发者选项→无线调试 里"
ui_print "  - 装完点模块卡片「操作」可查看实际端口"
ui_print "  - 详见 README 的「首次配对」一节"
ui_print " "
