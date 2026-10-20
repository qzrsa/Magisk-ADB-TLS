#!/system/bin/sh
#
# adb_tls5555 / watchdog.sh
#
# 独立看门狗。由 service.sh 用 setsid 拉起，**脱离 adbd 与 Magisk 的进程树**，
# 所以 adbd 重启、service.sh 退出都杀不掉它。
#
# 唯一职责：确认本模块没有把 adb 入口搞没。搞没了就回滚 + 自我禁用。
#
# 为什么要独立：service.sh 自己可能卡死（等端口、跑 iptables 卡住），
# 那种情况下它自己没法执行回滚。看门狗是最后一道保险。
#
# 用法：watchdog.sh [延迟秒数]
#

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

DELAY=${1:-90}
sleep "$DELAY"

[ -f "$MODDIR/disable" ] && exit 0

_guard=$(cat "$GUARDPORT" 2>/dev/null)
if [ -z "$_guard" ]; then
    # 本来就没有明文通道可保护（纯手机场景），不做事
    exit 0
fi

if plaintext_alive; then
    log "WATCHDOG: 明文通道 $_guard 正常"
    exit 0
fi

log "WATCHDOG: 明文通道 $_guard 不在监听，开始回滚"

revert_props
setprop ctl.restart adbd 2>/dev/null
sleep 14

if plaintext_alive; then
    log "WATCHDOG: 回滚成功，明文通道已恢复"
    bump_fail
    self_disable
    log "WATCHDOG: 已禁用本模块，下次启动不再加载。修好配置后在 Magisk 里重新启用"
else
    log "WATCHDOG: 回滚后明文通道仍未恢复 —— 需要物理断电重启"
    self_disable
fi
