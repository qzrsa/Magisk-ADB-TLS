#!/system/bin/sh
#
# adb_tls5555 / lib.sh
# 共用函数。被 service.sh 与 action.sh source。
#
# 设计背景（v1.1 起）：
#   `service.adb.tls.port` 不是可写的输入 —— adbd 在 framework 触发
#   enable_wifi_debugging() 后自己挑一个随机端口绑定 TLS，再把实际端口
#   写进这个属性。所以"注入固定端口"无效，只能**消费**它：
#   读实际端口 → 用 NAT REDIRECT 把固定端口转发过去。
#

MODDIR=${MODDIR:-${0%/*}}
LOG="$MODDIR/adb_tls.log"
STAMP="$MODDIR/.tls_port"
CONF_USER=/data/adb/adb_tls5555.conf
CONF_DEF="$MODDIR/module.conf"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# cfg KEY DEFAULT —— 从配置取值，缺失或空则用默认。
# 不用 source，避免配置文件里的内容被当成命令执行。
cfg() {
    _conf="$CONF_USER"
    [ -f "$_conf" ] || _conf="$CONF_DEF"
    _v=$(sed -n "s/^[[:space:]]*$1=//p" "$_conf" 2>/dev/null | tail -n 1)
    _v=$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')
    if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "$2"; fi
}

# 外部固定端口（用户连接用的那个）
PORT=$(cfg ADB_TLS_PORT 5555)
MODE=$(cfg GUARD_MODE all)
ALLOW4=$(cfg ALLOW4_CIDR "")
ALLOW6=$(cfg ALLOW6_CIDR "")
INTERVAL=$(cfg VERIFY_INTERVAL 60)
ENSURE=$(cfg ENSURE_WIFI_DEBUG 0)
KEYS_DIR=$(cfg KEYS_DIR /data/adb/adb_tls5555/keys)
AUTO_KEY=$(cfg KEYS_AUTO_INSTALL 1)
# 是否强制开启认证（ro.adb.secure=1）。默认 0：先只加密不认证，确认链路通了再开。
# 开启后**所有**通道（含明文 5555 和 USB）都要求公钥在 adb_keys 里，
# 客户端公钥缺失会把自己也锁在外面 —— 所以默认不开。
SECURE=$(cfg FORCE_SECURE 0)

# adbd 的 keystore。TLS 客户端证书的公钥会逐条与这里比对。
KEYSTORE=/data/misc/adb/adb_keys

case "$PORT" in
    ''|*[!0-9]*) log "WARN: ADB_TLS_PORT 非法，回落 5555"; PORT=5555 ;;
esac
case "$INTERVAL" in
    ''|*[!0-9]*) INTERVAL=60 ;;
esac
[ "$MODE" = "strict" ] && { ALLOW4=""; ALLOW6=""; }

valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 0=已监听  1=未监听  2=无法检测
listening() {
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -q "[:.]$1[[:space:]]"
        return $?
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q "[:.]$1[[:space:]]"
        return $?
    fi
    return 2
}

restart_adbd() {
    setprop ctl.restart adbd 2>/dev/null || {
        stop adbd 2>/dev/null
        sleep 1
        start adbd 2>/dev/null
    }
    sleep 3
}

# 等 adbd 把 TLS 端口写进属性（它自己随机挑，我们只能等）
# 成功时把端口打印到 stdout
wait_tls_port() {
    _n=0
    while [ "$_n" -lt "$1" ]; do
        _p=$(getprop service.adb.tls.port)
        if valid_port "$_p"; then
            printf '%s' "$_p"
            return 0
        fi
        sleep 1
        _n=$((_n + 1))
    done
    return 1
}

# 让 adbd 重新带回 TLS 监听。返回 0 = 已恢复且转发已建好。
#
# 为什么需要这个函数：
#   service.adb.tls.port 变空的真实含义是「adbd 根本没有 TLS 监听」，
#   此时 5555 上是空的，连接直接被 RST（Connection refused）。成因通常是
#   persist.adb.tls_server.enable 被清掉，或系统把「无线调试」关掉后 adbd
#   的 TlsServer 停止。adbd 自己不会再把端口要回来，只能外部干预：
#   把开关属性重新置 1，再重启 adbd。
#
#   注意：能走到这里说明远程**已经连不上了**，所以重启 adbd 不会有损失。
#   反过来，端口正常时绝不能重启 —— 那会主动踢掉正在连的客户端。
ensure_tls_alive() {
    if [ "$(getprop persist.adb.tls_server.enable)" != "1" ]; then
        log "INFO: persist.adb.tls_server.enable 缺失，重新置 1"
        setprop persist.adb.tls_server.enable 1
    fi

    restart_adbd

    _p=$(wait_tls_port 20)
    if [ -z "$_p" ] && [ "$ENSURE" = "1" ]; then
        log "WARN: 仍无 TLS 端口，尝试打开「无线调试」设置开关"
        settings put global adb_wifi_enabled 1 2>/dev/null
        sleep 3
        _p=$(wait_tls_port 20)
    fi

    [ -z "$_p" ] && return 1

    log "INFO: adbd 已重新提供 TLS 端口 $_p"
    follow_tls_port "$_p"
    return 0
}

# ---- iptables 兼容层 ----------------------------------------------------
# 锁等待参数不是所有 Android 版本都支持「-w 秒数」，逐级降级，
# 避免命令整体报错导致规则静默失效。
IPT_W=""
IPT_OK=0

detect_ipt() {
    if iptables -w 2 -L -n >/dev/null 2>&1; then
        IPT_W="-w 2"
        IPT_OK=1
    elif iptables -w -L -n >/dev/null 2>&1; then
        IPT_W="-w"
        IPT_OK=1
    elif iptables -L -n >/dev/null 2>&1; then
        IPT_W=""
        IPT_OK=1
    else
        IPT_OK=0
    fi
}

ipt() { iptables $IPT_W "$@"; }
ip6t() { ip6tables $IPT_W "$@"; }
iptn() { iptables $IPT_W -t nat "$@"; }
ip6n() { ip6tables $IPT_W -t nat "$@"; }

# ---- NAT：固定端口 → adbd 实际端口 --------------------------------------
#
# REDIRECT 必须**直接写在 PREROUTING 里**。
# Android 的 iptables 走 nft 后端，NAT 目标放进用户自定义链会被拒绝，
# 表现为「跳转规则建成功、链里是空的」——看起来有规则，流量却不转发。
#

# 清掉 v1.1.0 遗留的 ADB_TLS_NAT / ADB_TLS_NAT6 空链与跳转
flush_nat_legacy() {
    _i=0
    while [ "$_i" -lt 3 ]; do
        iptn -D PREROUTING -p tcp --dport "$PORT" -j ADB_TLS_NAT 2>/dev/null || break
        _i=$((_i + 1))
    done
    iptn -F ADB_TLS_NAT 2>/dev/null
    iptn -X ADB_TLS_NAT 2>/dev/null

    _i=0
    while [ "$_i" -lt 3 ]; do
        ip6n -D PREROUTING -p tcp --dport "$PORT" -j ADB_TLS_NAT6 2>/dev/null || break
        _i=$((_i + 1))
    done
    ip6n -F ADB_TLS_NAT6 2>/dev/null
    ip6n -X ADB_TLS_NAT6 2>/dev/null
}

# 添加失败时把 iptables 的原话记进日志，不再静默吞掉
nat_add() {
    _fam=$1
    _p=$2
    if [ "$_fam" = "v4" ]; then
        _e=$(iptn -A PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-ports "$_p" 2>&1 >/dev/null)
    else
        command -v ip6tables >/dev/null 2>&1 || return 0
        _e=$(ip6n -A PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-ports "$_p" 2>&1 >/dev/null)
    fi
    [ -n "$_e" ] && log "WARN: $_fam REDIRECT 添加失败: $_e"
    return 0
}

nat_del() {
    _fam=$1
    _p=$2
    if [ "$_fam" = "v4" ]; then
        iptn -D PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-ports "$_p" 2>/dev/null
    else
        command -v ip6tables >/dev/null 2>&1 || return 0
        ip6n -D PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-ports "$_p" 2>/dev/null
    fi
}

apply_nat() {
    _int=$1
    _prev=$(cat "$STAMP" 2>/dev/null)

    flush_nat_legacy

    # 端口变了：先删旧端口对应的规则
    if [ -n "$_prev" ] && [ "$_prev" != "$_int" ]; then
        nat_del v4 "$_prev"
        nat_del v6 "$_prev"
    fi

    # adbd 恰好挑中同一个端口：无需转发，但仍记录，避免复核反复重建
    if [ "$_int" = "$PORT" ]; then
        printf '%s' "$_int" > "$STAMP"
        return 0
    fi

    # 幂等：同规格先删后加
    nat_del v4 "$_int"
    nat_del v6 "$_int"
    nat_add v4 "$_int"
    nat_add v6 "$_int"

    printf '%s' "$_int" > "$STAMP"
}

# 端口变化时重建转发，并把新端口记进 stamp。service.sh 与 action.sh 共用。
follow_tls_port() {
    _p=$1
    _was=$(cat "$STAMP" 2>/dev/null)
    apply_nat "$_p"
    if [ "$_p" != "$_was" ]; then
        log "INFO: TLS 端口 ${_was:-无} → $_p，已重建转发（外部 $PORT）"
    fi
    if nat_ok "$_p"; then
        log "OK: $PORT → $_p 转发就绪"
    else
        log "FAIL: 转发规则未生效（$PORT → $_p），见 README「排错」"
    fi
}

nat_ok() {
    _int=$1
    [ -z "$_int" ] && return 1
    [ "$_int" = "$PORT" ] && return 0
    iptn -C PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-ports "$_int" 2>/dev/null || return 1
    return 0
}

# ---- 防火墙：来源白名单 -------------------------------------------------

guard_v4() {
    ipt -N ADB_GUARD 2>/dev/null
    ipt -F ADB_GUARD 2>/dev/null || return 1
    ipt -A ADB_GUARD -i lo -j RETURN 2>/dev/null
    for _c in $ALLOW4; do
        ipt -A ADB_GUARD -s "$_c" -j RETURN 2>/dev/null
    done
    ipt -A ADB_GUARD -j DROP 2>/dev/null
    ipt -D INPUT -p tcp --dport "$PORT" -j ADB_GUARD 2>/dev/null
    ipt -I INPUT 1 -p tcp --dport "$PORT" -j ADB_GUARD 2>/dev/null
}

guard_v6() {
    command -v ip6tables >/dev/null 2>&1 || return 0
    ip6t -N ADB_GUARD6 2>/dev/null
    ip6t -F ADB_GUARD6 2>/dev/null || return 1
    ip6t -A ADB_GUARD6 -i lo -j RETURN 2>/dev/null
    for _c in $ALLOW6; do
        ip6t -A ADB_GUARD6 -s "$_c" -j RETURN 2>/dev/null
    done
    ip6t -A ADB_GUARD6 -j DROP 2>/dev/null
    ip6t -D INPUT -p tcp --dport "$PORT" -j ADB_GUARD6 2>/dev/null
    ip6t -I INPUT 1 -p tcp --dport "$PORT" -j ADB_GUARD6 2>/dev/null
}

flush_guard() {
    ipt -D INPUT -p tcp --dport "$PORT" -j ADB_GUARD 2>/dev/null
    ipt -F ADB_GUARD 2>/dev/null
    ipt -X ADB_GUARD 2>/dev/null
    ip6t -D INPUT -p tcp --dport "$PORT" -j ADB_GUARD6 2>/dev/null
    ip6t -F ADB_GUARD6 2>/dev/null
    ip6t -X ADB_GUARD6 2>/dev/null
}

apply_guard() {
    case "$MODE" in
        strict|lan)
            flush_guard
            guard_v4
            guard_v6
            ;;
        *)
            flush_guard
            ;;
    esac
}

guard_ok() {
    [ "$MODE" = "all" ] && return 0
    ipt -C INPUT -p tcp --dport "$PORT" -j ADB_GUARD 2>/dev/null || return 1
    if command -v ip6tables >/dev/null 2>&1; then
        ip6t -C INPUT -p tcp --dport "$PORT" -j ADB_GUARD6 2>/dev/null || return 1
    fi
    return 0
}

# ---- 失败自愈 / 自我禁用 -------------------------------------------------
#
# 这一节是 v1.3.0 的核心保底。设计前提（已在真机验证）：
#   - persist.adb.tls_server.enable=1 在**运行时**设置就能拉起 TLS，
#     不需要重启 adbd，也不会顶掉已有的明文通道。所以它不该放进 system.prop。
#   - service.sh 跑在 late_start，崩溃/卡死都不会阻止开机。
#   - 由此，模块已经完全失去影响开机的能力，剩下的唯一风险是「把 adb 入口搞没」。
#     下面所有逻辑都在保护同一件事：明文通道必须还在。

FAILFILE="$MODDIR/.failcount"
GUARDPORT="$MODDIR/.guard_port"

# 记录明文通道端口，供 watchdog.sh 校验。空表示本来就没有明文通道可保护。
plaintext_port() {
    getprop service.adb.tcp.port
}

revert_props() {
    log "INFO: 回滚 persist.adb.tls_server.enable=0"
    setprop persist.adb.tls_server.enable 0
}

self_disable() {
    log "FAIL: 自愈失败，写入 disable 自我禁用（下次启动不再加载本模块）"
    : > "$MODDIR/disable"
}

fail_count() {
    cat "$FAILFILE" 2>/dev/null | tr -dc '0-9' | head -c 4
}

bump_fail() {
    _c=$(fail_count)
    [ -z "$_c" ] && _c=0
    echo $((_c + 1)) > "$FAILFILE"
}

clear_fail() {
    rm -f "$FAILFILE"
}

# 明文通道是否还在。只有服务启动时存在明文通道才检查，避免误杀。
plaintext_alive() {
    _gp=$(cat "$GUARDPORT" 2>/dev/null)
    [ -z "$_gp" ] && return 0
    listening "$_gp"
    _r=$?
    [ "$_r" = "0" ] && return 0
    # netstat/ss 都不可用时无法判定，按「活着」处理，不误杀
    [ "$_r" = "2" ] && return 0
    return 1
}

# 对外端口是否正被 adbd 的明文监听占用。
# 是的话不能用 NAT REDIRECT 抢这个端口 —— 那会把别人的明文通道顶掉。
port_taken_by_plaintext() {
    [ "$(getprop service.adb.tcp.port)" = "$PORT" ]
}

# ---- 客户端公钥预置：免 6 位配对码 --------------------------------------
#
# AOSP 事实链（已核对源码，不是推测）：
#
#   client/auth.cpp :: adb_auth_tls_handshake()
#       客户端拿 ~/.android/adbkey 现场生成一张自签 X509
#       （GenerateX509Certificate(EVP_PKEY from adbkey)），
#       所以这张证书的公钥 == 客户端的 ADB 公钥。
#
#   daemon/auth.cpp :: adbd_tls_verify_cert()
#       if (!auth_required) return 1;              // ro.adb.secure=0 时放行一切
#       IteratePublicKeys(...) → EVP_PKEY_cmp()     // 否则逐条比对 keystore
#
#   结论：把客户端的 adbkey.pub **一行**追加进 /data/misc/adb/adb_keys
#         就等于完成配对。不需要 6 位配对码，也不需要同一局域网，
#         更不需要那个没法做 NAT 的随机配对端口。
#
#   代价：adbd 只在启动时加载 keystore，改完必须重启 adbd。
#

# 从 KEYS_DIR 收集待授权公钥，只保留第一条字段形如 base64 的行。
# 一条 ADB 公钥的编码长度是 700 字符（524 字节），阈值取 300 足够宽松。
collect_keys() {
    [ -n "$KEYS_DIR" ] && [ -d "$KEYS_DIR" ] || return 0
    cat "$KEYS_DIR"/*.pub "$KEYS_DIR"/keys.txt 2>/dev/null \
        | tr -d '\r' \
        | awk '
            {
                line = $0
                sub(/^[ \t]+/, "", line)
                sub(/[ \t]+$/, "", line)
                if (line == "") next
                k = line
                sub(/[ \t].*$/, "", k)
                if (length(k) < 300) next
                if (k !~ /^[A-Za-z0-9+\/=]+$/) next
                print line
            }'
}

# 返回值：0=有新公钥写入（需要重启 adbd） 1=无需变更 2=未启用/无配置
install_client_keys() {
    [ "$AUTO_KEY" = "1" ] || return 2

    _want=$(collect_keys)
    [ -z "$_want" ] && return 2

    printf '%s\n' "$_want" > "$MODDIR/.keys.want"
    # awk 的 FNR==NR 判据在「第一个文件为空」时会失效，把第二个文件也当成第一个吃光。
    # 所以 .keys.cur 至少放一行占位。
    : > "$MODDIR/.keys.cur"
    [ -f "$KEYSTORE" ] && tr -d '\r' < "$KEYSTORE" >> "$MODDIR/.keys.cur"
    [ -s "$MODDIR/.keys.cur" ] || printf '#\n' > "$MODDIR/.keys.cur"

    # 按第一条字段（公钥本体）去重，保留已有顺序
    _add=$(awk '
        FNR == NR {
            k = $0
            sub(/^[ \t]+/, "", k)
            sub(/[ \t].*$/, "", k)
            if (k != "") seen[k] = 1
            next
        }
        {
            l = $0
            k = l
            sub(/[ \t].*$/, "", k)
            if (k == "" || (k in seen)) next
            seen[k] = 1
            print l
        }' "$MODDIR/.keys.cur" "$MODDIR/.keys.want")

    rm -f "$MODDIR/.keys.want" "$MODDIR/.keys.cur"
    [ -z "$_add" ] && return 1

    _n=$(printf '%s\n' "$_add" | grep -c .)
    log "INFO: 预置 $_n 个客户端公钥 → $KEYSTORE"

    mkdir -p /data/misc/adb 2>/dev/null
    _created=0
    [ -f "$KEYSTORE" ] || { : > "$KEYSTORE"; _created=1; }

    # 原文件最后一字节不是换行时先补一个，避免两条公钥黏在一行
    if [ -s "$KEYSTORE" ] && [ "$(tail -c 1 "$KEYSTORE" 2>/dev/null | wc -l)" = "0" ]; then
        echo >> "$KEYSTORE"
    fi
    printf '%s\n' "$_add" >> "$KEYSTORE"

    # 只在「自己新建的文件」上设属主。
    # 已有文件的属主各 ROM 不同（AOSP 常见 shell:shell，三星 OneUI 是
    # system:shell）。强行改成 shell:shell 会让以 system 身份运行的
    # AdbDebuggingManager 失去写权限 —— 表现为 USB 授权弹窗点了"允许"
    # 也不生效。权限位与 SELinux 标签则可以安全地修正。
    [ "$_created" = "1" ] && chown shell:shell "$KEYSTORE" 2>/dev/null
    chmod 0640 "$KEYSTORE" 2>/dev/null
    restorecon "$KEYSTORE" >/dev/null 2>&1 \
        || chcon u:object_r:adb_keys_file:s0 "$KEYSTORE" 2>/dev/null

    return 0
}

# keystore 里已授权的客户端数量
keystore_count() {
    if [ -f "$KEYSTORE" ]; then
        _c=$(grep -c '[A-Za-z0-9]' "$KEYSTORE" 2>/dev/null)
        printf '%s' "${_c:-0}"
    else
        printf '0'
    fi
}

# 逐条列出已授权客户端（公钥前 16 位 + user@host 备注）
list_keystore() {
    [ -f "$KEYSTORE" ] || return 0
    awk '
        {
            k = $1
            if (length(k) < 20) next
            c = $2
            if (c == "") c = "(无备注)"
            printf "    %.16s…  %s\n", k, c
        }' "$KEYSTORE" 2>/dev/null
}
