#!/usr/bin/env bash
#
# grant_key.sh —— 在电脑上运行：把一个客户端的 ADB 公钥授权到被控机
#
# 原理（AOSP daemon/auth.cpp::adbd_tls_verify_cert / adbd_auth_verify）：
#   被控机的 adbd 把客户端上报的公钥，逐条与 /data/misc/adb/adb_keys 比对。
#   所以"授权" = 把那一行公钥追加进这个文件，再重启 adbd 让它重新加载 keystore。
#   TCP / 网络连接不会弹出"允许 USB 调试吗"的对话框（那只在 USB 下出现），
#   所以预置公钥是网络调试的唯一授权路径。
#
# 用法：
#   ./grant_key.sh her.pub                      # 授权一个公钥文件
#   cat her.pub | ./grant_key.sh -              # 从标准输入读
#   ADB_SERIAL=192.168.1.9:5555 ./grant_key.sh her.pub
#
# 注意：
#   * 只 chmod 0640，不 chown —— 各 ROM 属主不同（实测三星 OneUI 是 system:shell），
#     强改会让以 system 身份运行的 AdbDebuggingManager 失去写权限。
#   * 幂等：公钥已在列表里就什么都不做。
#

set -u

ADB=${ADB:-adb}
HERE=$(cd "$(dirname "$0")" && pwd)
KS_TARGET=${KS_TARGET:-/data/misc/adb/adb_keys}
TMP_KEY=/data/local/tmp/.grant_key.pub
TMP_SH=/data/local/tmp/.grant_key.sh

die() { printf '错误: %s\n' "$*" >&2; exit 1; }

# Git Bash 会把 /data/local/tmp/... 当成 Windows 路径改写掉，必须关掉。
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# 本地路径要转成 Windows 形式才能给 adb.exe 读
if command -v cygpath >/dev/null 2>&1; then
    to_win() { cygpath -w "$1"; }
else
    to_win() { printf '%s' "$1"; }
fi

# ---- 1. 取公钥文本 ------------------------------------------------------
[ $# -ge 1 ] || die "用法: $0 <公钥文件 | ->"

if [ "$1" = "-" ]; then
    RAW=$(cat)
else
    [ -f "$1" ] || die "找不到文件: $1"
    RAW=$(cat "$1")
fi

# 归一化：去 CR、取第一条像公钥的行、剪掉首尾空白
KEY=$(printf '%s\n' "$RAW" | tr -d '\r' \
    | awk '
        { line = $0
          sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
          if (line == "") next
          k = line; sub(/[ \t].*$/, "", k)
          if (length(k) < 300) next
          if (k !~ /^[A-Za-z0-9+\/=]+$/) next
          print line; exit }')

[ -n "$KEY" ] || die "输入里找不到 ADB 公钥（应为 700 字符 base64 + 空格 + 备注）"

BODY=${KEY%% *}
[ "${#BODY}" -eq 700 ] \
    || printf '提示: base64 长度是 %s，标准 ADB 公钥是 700（2048 位 RSA）\n' "${#BODY}" >&2

# ---- 2. 选设备 ----------------------------------------------------------
if [ -z "${ADB_SERIAL:-}" ]; then
    DEVS=$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}' | tr '\n' ' ')
    # shellcheck disable=SC2086
    set -- $DEVS
    [ $# -eq 1 ] || die "检测到 $# 台设备，请用 ADB_SERIAL=<序列号> 指定"
    ADB_SERIAL=$1
fi
printf '设备: %s\n' "$ADB_SERIAL"

"$ADB" -s "$ADB_SERIAL" shell true >/dev/null 2>&1 || die "设备不可用: $ADB_SERIAL"

# ---- 3. 推送公钥与安装脚本 ----------------------------------------------
printf '%s\n' "$KEY" > "$HERE/.grant_key.tmp"
"$ADB" -s "$ADB_SERIAL" push "$(to_win "$HERE/.grant_key.tmp")" "$TMP_KEY" >/dev/null 2>&1
PUSH_RC=$?
rm -f "$HERE/.grant_key.tmp"
[ "$PUSH_RC" = "0" ] || die "推送公钥失败"

cat > "$HERE/.grant_key.sh.tmp" <<'EOS'
#!/system/bin/sh
SRC=$1
KS=$2
NEW=$(head -n 1 "$SRC" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
[ -n "$NEW" ] || { echo EMPTY; exit 2; }
KID=${NEW%% *}

mkdir -p "$(dirname "$KS")" 2>/dev/null
[ -f "$KS" ] || : > "$KS"

if cut -d' ' -f1 "$KS" 2>/dev/null | tr -d '\r' | grep -qxF "$KID"; then
    echo EXISTS
    exit 0
fi

# 末字节不是换行时先补一个，避免两条公钥黏在一起
if [ -s "$KS" ] && [ "$(tail -c 1 "$KS" | wc -l)" = "0" ]; then
    echo >> "$KS"
fi
printf '%s\n' "$NEW" >> "$KS"

chmod 0640 "$KS"
restorecon "$KS" >/dev/null 2>&1 || chcon u:object_r:adb_keys_file:s0 "$KS" 2>/dev/null
echo ADDED
EOS

"$ADB" -s "$ADB_SERIAL" push "$(to_win "$HERE/.grant_key.sh.tmp")" "$TMP_SH" >/dev/null 2>&1
PUSH_RC=$?
rm -f "$HERE/.grant_key.sh.tmp"
[ "$PUSH_RC" = "0" ] || die "推送脚本失败"

# ---- 4. 在设备上执行 ----------------------------------------------------
cleanup() { "$ADB" -s "$ADB_SERIAL" shell "su -c 'rm -f $TMP_KEY $TMP_SH'" >/dev/null 2>&1; }

OUT=$("$ADB" -s "$ADB_SERIAL" shell "su -c 'sh $TMP_SH $TMP_KEY $KS_TARGET'" 2>&1 | tr -d '\r')

case "$OUT" in
    *EXISTS*)
        printf '该公钥已在授权列表里，无需改动\n'
        cleanup
        exit 0
        ;;
    *ADDED*)
        printf '已写入 %s，重启 adbd 使其生效…\n' "$KS_TARGET"
        ;;
    *)
        printf '设备端执行失败: %s\n' "$OUT" >&2
        printf '若提示 su 不可用，被控机必须已 root\n' >&2
        cleanup
        exit 1
        ;;
esac

# ---- 4b. 重启 adbd 前先确认不会把自己弄失联 ------------------------------
#
# 网络连接的设备，重启 adbd 会断开当前 TCP 会话。只有当 adbd 启动时能从
# service.adb.tcp.port 读回端口，监听才会重新建立。该属性为空时重启 =
# 永久失去网络调试入口（只能靠 USB 或重启手机救回来）。
# 所以这种情况不重启，只提示。
IS_TCP=0
case "$ADB_SERIAL" in
    *:*) IS_TCP=1 ;;
esac

if [ "$IS_TCP" = "1" ]; then
    TCPPORT=$("$ADB" -s "$ADB_SERIAL" shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r')
    if [ -z "$TCPPORT" ]; then
        printf '\n注意: 公钥已写入，但**没有**重启 adbd。\n'
        printf '  原因: 该设备是网络连接，且 service.adb.tcp.port 为空。\n'
        printf '  此时重启 adbd 会关掉 TCP 监听且不再恢复，导致设备失联。\n'
        printf '  处理: 重启手机后公钥自动生效（adbd 每次启动都会重读 keystore）。\n'
        cleanup
        exit 0
    fi
fi

"$ADB" -s "$ADB_SERIAL" shell "su -c 'setprop ctl.restart adbd'" >/dev/null 2>&1

# 网络连接需要重连；USB 会自己回来
if [ "$IS_TCP" = "1" ]; then
    printf '重启 adbd，正在重连…\n'
    _ok=0
    for _i in 1 2 3 4 5 6; do
        sleep 2
        "$ADB" connect "$ADB_SERIAL" >/dev/null 2>&1
        if "$ADB" -s "$ADB_SERIAL" shell true >/dev/null 2>&1; then _ok=1; break; fi
    done
    [ "$_ok" = "1" ] || die "重启后无法重连，请用 USB 重新授权（adb tcpip <端口>）"
else
    sleep 4
fi

# ---- 5. 校验 ------------------------------------------------------------
CNT=$("$ADB" -s "$ADB_SERIAL" shell "su -c 'grep -c . $KS_TARGET'" 2>/dev/null | tr -d '\r')
printf '当前 keystore 共 %s 条授权\n' "${CNT:-?}"
printf '本次授权备注: %s\n' "${KEY#* }"
printf '完成。对方现在可以连接 %s\n' "$ADB_SERIAL"
cleanup
