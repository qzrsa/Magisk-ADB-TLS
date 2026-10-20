#!/usr/bin/env bash
#
# emergency_disable.sh —— 开机循环时抢窗口禁用模块
#
# 背景：
#   设备卡在开机动画循环时，系统其实每一轮都会把 adbd 拉起来（USB 传输，
#   不走 TLS，不受本模块的 persist.adb.tls_server.enable 影响）。窗口只有
#   几秒，但足够写两个文件。
#
# 原理：
#   Magisk 在 post-fs-data 阶段会检查 /data/adb/modules/<id>/disable，
#   存在则整个模块跳过（不挂载、不执行 system.prop、不跑 service.sh）。
#   所以只要趁窗口 touch 一个 disable 文件，下一轮启动就不再加载它。
#
# 用法：
#   bash tools/emergency_disable.sh              # 默认守 180 秒
#   bash tools/emergency_disable.sh 300          # 守 300 秒
#
# 需要：手机用 USB 连到这台电脑，且这台电脑的 adb 公钥已在手机的
#       /data/misc/adb/adb_keys 里（否则会卡在 unauthorized）。
#

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

LIMIT=${1:-180}
ADB=${ADB:-adb}

# 要禁用的模块，按优先级排列。前两个是跟本模块抢 5555 的老模块，
# 一起禁掉，避免它们把明文通道重新打开。
MODULES="adb_tls5555 adb_tcp5555 adbd_tcpip_unsec adb_tcp_5555"

say() { printf '%s\n' "$*"; }

say "=============================================="
say " 紧急禁用模块（开机循环救援）"
say " 监听 ${LIMIT}s，一旦 adb 出现就写 disable"
say "=============================================="
say ""

if ! command -v "$ADB" >/dev/null 2>&1; then
    say "错误：找不到 adb。把 platform-tools 加进 PATH，或用 ADB=/path/to/adb 指定。"
    exit 1
fi

"$ADB" start-server >/dev/null 2>&1

# 生成要在设备上执行的脚本。TWRP 下 adb shell 本身就是 root，所以先试 su，
# 失败就直连执行。
build_payload() {
    cat <<'EOS'
set -e
for m in adb_tls5555 adb_tcp5555 adbd_tcpip_unsec adb_tcp_5555; do
    d=/data/adb/modules/$m
    if [ -d "$d" ]; then
        : > "$d/disable"
        echo "DISABLED:$m"
    else
        # 模块目录不在（可能已被移除），但残留的 enable 标记要清掉
        echo "ABSENT:$m"
    fi
done
# 顺手把 TLS 开关落回 0，避免 adbd 在下一轮仍去找 TLS 服务端
setprop persist.adb.tls_server.enable 0 2>/dev/null || true
setprop service.adb.tcp.port "" 2>/dev/null || true
echo "DONE"
EOS
}

PAYLOAD=$(build_payload)
DONE=0
START=$(date +%s)
LAST_STATE=""
TICK=0

while :; do
    NOW=$(date +%s)
    if [ $((NOW - START)) -ge "$LIMIT" ]; then break; fi

    # 只取 USB 设备（序列号不含冒号），网络连接在这时候帮不上忙。
    # 只认真正的状态字，否则表头 "List of devices attached" 会被当成一台设备。
    LISTING=$("$ADB" devices 2>/dev/null \
        | awk '$2 ~ /^(device|offline|unauthorized|recovery|sideload|rescue|bootloader)$/ && $1 !~ /:/ {print $1" "$2}')
    STATE=$(printf '%s' "$LISTING" | awk '{print $2}' | head -n 1)

    if [ "$STATE" != "$LAST_STATE" ] && [ -n "$STATE" ]; then
        say "  [$(date '+%H:%M:%S')] adb 状态: $STATE"
        case "$STATE" in
            unauthorized)
                say "    ⚠ 设备未信任这台电脑。USB 上会弹「允许调试」，但开机循环里基本点不到。"
                say "      只能换安全模式或 recovery 的办法。"
                ;;
        esac
        LAST_STATE=$STATE
    fi

    SERIAL=""
    for s in $(printf '%s' "$LISTING" | awk '$2=="device"||$2=="recovery"{print $1}'); do
        SERIAL=$s
        break
    done

    if [ -n "$SERIAL" ]; then
        say "  [$(date '+%H:%M:%S')] 抓到窗口: $SERIAL —— 立刻写 disable"

        # 先试 su（正常系统），不行就直接跑（TWRP 等已 root 的 recovery）
        OUT=$("$ADB" -s "$SERIAL" shell "su -c 'sh -s'" <<<"$PAYLOAD" 2>&1)
        if ! printf '%s' "$OUT" | grep -q 'DONE'; then
            OUT=$("$ADB" -s "$SERIAL" shell "sh -s" <<<"$PAYLOAD" 2>&1)
        fi

        printf '%s\n' "$OUT" | sed 's/^/    /'

        if printf '%s' "$OUT" | grep -q 'DISABLED:'; then
            DONE=1
            say ""
            say "  ✔ 已写入 disable 标记。现在长按电源键强制重启，模块不会再加载。"
            break
        fi

        if printf '%s' "$OUT" | grep -q 'DONE'; then
            say ""
            say "  命令执行了，但没找到任何模块目录 —— 可能已经不在 /data/adb/modules 下。"
            DONE=1
            break
        fi

        # 窗口太短，命令没跑完；等下一轮
        say "    窗口内没跑完，等下一轮…"
        sleep 1
    else
        TICK=$((TICK + 1))
        if [ $((TICK % 12)) = "0" ]; then
            printf '.'
            if [ $((TICK % 120)) = "0" ]; then printf ' %ss\n' $((NOW - START)); fi
        fi
    fi
    sleep 0.4
done

say ""
if [ "$DONE" = "1" ]; then
    say "结果：已处理。接下来："
    say "  1) 长按电源 10~15 秒强制重启"
    say "  2) 起来后进 Magisk，确认 adb_tls5555 显示「已禁用」"
    say "  3) 用 USB adb 进去，读 /data/adb/modules/adb_tls5555/adb_tls.log 看最后一轮发生了什么"
    exit 0
fi

say "结果：${LIMIT}s 内没拿到可用的 adb 窗口。"
say ""
say "常见原因："
say "  · 手机没插 USB，或插的是充电器不是电脑"
say "  · 数据线只有充电功能（换一根）"
say "  · Windows 设备管理器里显示「未知 USB 设备(设备描述符请求失败)」→ 换口/换线"
say "  · 手机在循环里根本没跑到 adbd 启动那一步"
say ""
say "下一步建议："
say "  · 试 Android 安全模式：开机动画时长按「音量下」不放，进系统后 Magisk 会跳过所有模块"
say "  · 有 TWRP 的话：挂载 /data → 文件管理器删掉 /data/adb/modules/adb_tls5555"
exit 1
