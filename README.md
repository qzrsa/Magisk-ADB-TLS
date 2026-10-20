# Magisk-ADB-TLS

**当前版本 v1.3.2** ｜ [Releases](https://github.com/qzrsa/Magisk-ADB-TLS/releases)

Magisk 模块：**开机确保 `adbd` 以 TLS 模式监听，并把固定的 `5555` 端口转发到它的实际端口。**

认证走 `adbd` 的 **TLS 客户端证书校验**：把控制端的 `adbkey.pub` 放进 `/data/adb/adb_tls5555/keys/` 即可，不需要 6 位配对码，也不需要同一局域网。模块本身**不含任何密码逻辑**，也不加任何二进制。

> 本项目是 [Magisk-ADB-TCP-5555](https://github.com/qzrsa/Magisk-ADB-TCP-5555) 的安全向变体。那个模块解决"开机即用"，本项目解决"开机即用 **且** 可以放到公网"。

**最常翻的三节：** [路径速查](#路径速查) ｜ [认证：让控制端进来](#认证让控制端进来) ｜ [排错](#排错)

---

## ⚠️ 无按键设备：不要用 `adb reboot`

如果你的设备是**没有屏幕、没有音量键、只有一颗电源键**的盒子/电视棒（本项目实测机型：三星 SCG23），
那么 `adb reboot` 有很高概率**退化成关机**，而不是热重启：

```
$ adb shell getprop ro.boot.bootreason
shutdown,lpm          # ← lpm = Low Power Mode，三星的低功耗黑屏/充电状态
```

盒子会停在 LPM 状态、屏幕全黑、**不会自己起来**，必须有人去按那颗电源键。
远程操作时这意味着：一条 `adb reboot` 换来一次"必须到现场按按钮"。

**规则：**

- 不要在无按键设备上执行 `adb reboot` / `reboot` / `setprop sys.powerctl reboot`。
- 需要重启时，明确告诉在场的人"现在断电重上电"或"按一下电源键"。
- 本模块自身在任何情况下**只重启 `adbd`（`setprop ctl.restart adbd`），绝不重启整机**；
  自愈逻辑、看门狗、验证循环都遵守这条。请保持这个性质。

顺带一个实测数据：本机内核起到 TLS 就绪只要 **26–34 秒**。如果"开机很慢"，先怀疑设备压根没上电，
而不是怀疑模块卡住了。

---

## 公网只留 TLS 端口，明文端口限内网

很多机器上同时装着明文模块（`adbd_tcpip_unsec` 之类），会长期开着一个**不需要认证**的 5555。
如果上游把 5555 映射到了公网，那等于给全世界开了一个 shell —— 就算开了 `FORCE_SECURE=1`，
没预置公钥的客户端也会被反复推到「请求调试设备」弹窗，而无屏设备根本点不了。

推荐的分工：

| 端口 | 谁在用 | 暴露范围 | 拒绝方式 |
|---|---|---|---|
| **5556**（`ADB_TLS_PORT`） | TLS + 客户端证书 | 可以放到公网 | 握手阶段直接断，**不惊动系统** |
| **5555**（`service.adb.tcp.port`） | 明文 + 无认证 | **只给内网 / mesh** | 未预置会被推到弹窗，无屏设备等于死路 |

打开明文端口白名单：

```ini
# /data/adb/adb_tls5555.conf
GUARD_PLAINTEXT=1
PLAINTEXT_ALLOW4="192.168.0.0/16 10.0.0.0/8 172.16.0.0/12"
```

生效后 `iptables -S ADB_GUARD_P` 大致长这样：

```
-N ADB_GUARD_P
-A ADB_GUARD_P -i lo -j RETURN
-A ADB_GUARD_P -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
-A ADB_GUARD_P -s 192.168.0.0/16 -j RETURN
-A ADB_GUARD_P -s 10.0.0.0/8 -j RETURN
-A ADB_GUARD_P -s 172.16.0.0/12 -j RETURN
-A ADB_GUARD_P -j DROP
```

`ADB_TLS_PORT` 不受这个开关影响，仍按 `GUARD_MODE` 走，所以「明文限内网 + TLS 走公网」可以同时成立。

### 这条规则的覆盖边界

它在 `late_start` 阶段才加上，**盖不住开机的头几十秒**。那段时间明文端口仍然是敞开的。

要彻底关掉，得在**上游**动手 —— 路由器 / 中转机上把 `公网:5555 → 盒子:5555` 的映射删掉，
或者改成 `公网:5556 → 盒子:5556`。这比任何盒子侧的规则都干净，而且连开机窗口一起解决。

### 一个会让白名单失效的网络前提：路由器做了 SNAT

实测遇到过这种情况：路由器把 `公网:5555` 转发到盒子时**顺手做了源地址转换**，
于是盒子抓包看到的来源不是公网 IP，而是**路由器自己的内网地址**：

```
wlan0 In  IP 192.168.111.1.42773 > 192.168.111.111.5555
             ^^^^^^^^^^^^^ 这是网关，不是真实客户端
```

更麻烦的是：如果客户端和管理机不在盒子同一个网段（比如盒在 `192.168.111.0/24`、
PC 在 `192.168.11.0/24`），**PC 的流量也会经过同一个网关被 SNAT 成同一个地址**。
结果就是——内网和公网在盒子上看起来完全一样，任何基于源 IP 的白名单都失去区分能力。

判断方法：

```sh
# 在盒子上抓包，看 5555 的真实来源
su -c 'tcpdump -i any -nn -c 6 "tcp port 5555"'
```

- 来源是客户端的**真实地址**（公网 IP 或各自的内网 IP）→ 白名单有效
- 来源永远只有**网关地址**一个 → 路由器在做 SNAT，白名单无效，只能改上游映射

这种情况下唯一的解法是改上游端口映射，盒子侧做什么都没用。

---

## v1.3.0：为什么模块里没有 `system.prop`

v1.2.x 把 `persist.adb.tls_server.enable=1` 写在 `system.prop` 里。那是 `post-fs-data` 阶段、开机最早的环节，**一旦出问题就是卡开机**。对手机可能只是重刷一次模块，对只能远程访问的设备（机顶盒、电视盒子、无屏幕机型）等于失联。

真机实测后发现这一步完全是多余的：

```sh
# 三星 SCG23 盒子 / Android 14，运行时直接设置
setprop persist.adb.tls_server.enable 1

before: tcp.port=5555  enable=(空)  tls.port=(空)  明文监听=4 条
after : tls.port=37293              明文监听=4 条   ← 一条都没断
RESULT=COEXIST_OK
```

**运行时设置就能拉起 TLS，不需要重启 adbd，也不会顶掉已有的明文通道，两者可以共存。**

所以 v1.3.0 把 `system.prop` 整个删掉了：

| | v1.2.x | **v1.3.0** |
|---|---|---|
| `system.prop` | 有（开机最早生效） | **无** |
| `post-fs-data.sh` | 无 | 无 |
| `system/` 目录 | 无 | 无 |
| 属性设置时机 | `post-fs-data` | `late_start`（开机完成后） |
| 模块能否阻止开机 | **能**（属性触发 init 行为） | **不能**，`post-fs-data` 阶段零操作 |
| 最坏结果 | 卡开机 | 模块不工作，设备照常启动 |

配套三道保底：

1. **看门狗** `watchdog.sh` —— `setsid` 拉起、脱离 adbd 与 Magisk 进程树，90 秒后校验明文通道，没了就回滚 + 自我禁用。`service.sh` 自己卡死也能兜住。
2. **电路熔断** `.failcount` —— 失败过一次，下次启动直接写 `disable` 自我禁用，不会反复拿开机做实验。
3. **不碰别人的端口** —— 对外端口若与 `service.adb.tcp.port` 重合，模块拒绝启动并写日志，不会用 NAT 把已有明文通道顶掉。

---

## 和原模块的差别

| 维度 | Magisk-ADB-TCP-5555 | **本项目** |
|---|---|---|
| 通道 | 明文 TCP | TLS 1.3 |
| 认证 | RSA 挑战应答（`ro.adb.secure=0` 可直接关掉） | TLS 客户端证书校验（不可关，除非显式改回 0） |
| 陌生人能做什么 | 连上、停在 `unauthorized`；认证关掉时直接拿到 root shell | **握手阶段就失败** |
| 传输内容可见 | 是 | 否 |
| 是否需要申请证书 | — | 不需要，两端自签 |
| 端口 | 固定 5555（属性可注入） | adbd 随机选，模块用 NAT 映射回 5555 |
| 额外组件 | 无 | 无 |

一句话：**原模块把门打开；本项目把门换成只有持有私钥的人才能推开的门，而且换了个固定门牌号。**

---

## 三个必须知道的事实

这三条是读 AOSP 源码核对的，也是本项目全部设计的依据。

### 一、`service.adb.tls.port` 是 adbd 的**输出**，不是输入

实际流程：

1. 框架（`AdbDebuggingManager`）判断「无线调试」允许开启；
2. 调用 adbd 的 `enable_wifi_debugging()`；
3. **adbd 自己挑一个随机端口**绑定 TLS；
4. 把实际端口**写进** `service.adb.tls.port`。

所以任何"在 `system.prop` 里指定 5555"的做法都会在 adbd 启动后被覆盖。要让端口固定，厂商得改框架源码（把 `adb_wifi.cpp` 里的随机端口写死），这不是模块能做的。

模块换了个思路——**消费**这个属性：

```
1. persist.adb.tls_server.enable=1        ← 唯一的真实输入，system.prop 注入
2. 等 adbd 起来，读 service.adb.tls.port  ← 比如 39073
3. NAT 把固定的 5555 转发到它：
     iptables -t nat -A PREROUTING -p tcp --dport 5555 -j REDIRECT --to-ports 39073
4. 后台复核端口变化，变了就重建规则
```

> REDIRECT 必须**直接写在 PREROUTING**。Android 的 iptables 走 nft 后端，把 NAT 目标放进用户自定义链会被拒绝，表现为「跳转规则建成功、链里是空的」——看着有规则，流量却不转发。v1.1.1 已改为直写。

**TLS 仍然是端到端的**：NAT 只改目的端口号，不接触内容，所以客户端依然和 adbd 直接完成 TLS 握手，中间没有任何解密环节，也不需要额外进程。

### 二、TLS 端口是 **STARTTLS 升级**，不是"一上来就握手"

`daemon/main.cpp → handle_packet()` 的实际行为：

```
客户端 ──A_CNXN（明文）──► adbd
客户端 ◄──A_STLS（明文）── adbd      ← 服务端说"我们换加密"
        ══ TLS 1.3 握手 ══
客户端 ──A_CNXN（密文）──► adbd
客户端 ◄──A_CNXN / A_AUTH ─ adbd
```

**推论（很重要）**：任何只会处理 `A_CNXN` / `A_AUTH` 的裸协议客户端，在第二步收到 `A_STLS` 就废了——它既不会握手，也不会重发 `CNXN`。这正是"原模块能连、加 TLS 就连不上"的原因：**不是服务端坏了，是客户端不认这条升级指令。** 只有真正的 `adb`（含 TLS 栈）能走完。

### 三、认证 = 客户端证书的公钥要与 `adb_keys` 里的某一条相同

| 环节 | 源码位置 | 行为 |
|---|---|---|
| 客户端出证书 | `client/auth.cpp::adb_auth_tls_handshake()` | 用 `~/.android/adbkey` 现场生成自签 X509，**证书公钥 == adbkey 公钥** |
| 服务端验证书 | `daemon/auth.cpp::adbd_tls_verify_cert()` | `if (!auth_required) return 1;` → 否则逐条 `EVP_PKEY_cmp` 比对 `/data/misc/adb/adb_keys` |
| 客户端验服务端 | `transport.cpp` | 回调直接 `return 1`，即**不校验**设备证书 |

由此得到两个可直接利用的结论：

1. **不需要 CA、不需要域名、不需要配对码**——信任关系就是一行公钥。
2. **`ro.adb.secure=0` 时 `auth_required=false`，TLS 只加密不认证**（源码注释原话：`// Any key will do.`）。所以本模块显式把 `ro.adb.secure` 设为 `1`。

### 失败时不会降级

拿不到 TLS 端口（例如「无线调试」被关闭）时，模块只记 `FAIL` 并继续等待，**不会**回落到明文 5555。宁可连不上，也不要静默变成无加密通道。

---

## 安装

1. 从 Releases 下载 zip（或自行 `python tools/build.py`）
2. Magisk / KernelSU / APatch 管理器 → 模块 → 从本地安装
3. **重启手机**
4. 首次安装会生成配置：`/data/adb/adb_tls5555.conf`

> 如果你装了 `adb_tcp5555` 或 `adbd_tcpip_unsec`（明文版），注意两点：它们的 `system.prop` 会写 `ro.adb.secure=0` + `service.adb.tcp.port=5555`，**每次开机都会把你的认证关掉**，需要靠本模块在 `late_start` 重新置 1（`FORCE_SECURE=1`）；而且它们占着 5555，所以 `ADB_TLS_PORT` 要改成 `5556`，否则模块会因端口冲突拒绝启动。

装完点模块卡片的「操作」按钮，可以看到实际端口、转发状态和认证状态：

```
--- adb_tls5555 v1.2.1 ---
--- 属性 ---
service.adb.tls.port          = 39073
service.adb.tcp.port          =
persist.adb.tls_server.enable = 1
对外端口 ADB_TLS_PORT         = 5555（NAT 转发到上面的实际端口）
--- 认证 ---
ro.adb.secure                 = 1
ro.secure                     = 0
keystore /data/misc/adb/adb_keys = 1 条
状态: 认证开启 —— 客户端公钥必须在 keystore 里，否则 TLS 握手失败
已授权客户端:
    AAAA...（前 16 位）…  user@host
--- nat ---
-A PREROUTING -p tcp -m tcp --dport 5555 -j REDIRECT --to-ports 39073
转发状态: 就绪（5555 → 39073）
```

---

## 路径速查

所有跟密钥有关的路径只有下面几个，其余都是中转。

| 路径 | 作用 | 权限 | 谁写 |
|---|---|---|---|
| 控制端 `~/.android/adbkey.pub`<br>Windows `%USERPROFILE%\.android\adbkey.pub` | 客户端的**公钥**：700 字符 base64 + 一个空格 + 备注 | 普通用户 | `adb` 首次运行时自动生成 |
| 控制端 `~/.android/adbkey`<br>Windows `%USERPROFILE%\.android\adbkey` | 客户端的**私钥**（PEM / PKCS#8）。**不要外传** | 普通用户 | 同上 |
| `/data/adb/adb_tls5555/keys/`<br>读 `*.pub` 与 `keys.txt` | 待授权公钥的**投放目录** | `0700`，仅 root | 你 |
| `/data/misc/adb/adb_keys` | **adbd 真正读的 keystore**，一行一个公钥。所谓"授权"就是往这里追加一行 | `0640`，实测 `system:shell`，SELinux `u:object_r:adb_keys_file:s0` | 模块 / 系统 / `tools/grant_key.sh` |

流转关系：

```
你放进 /data/adb/adb_tls5555/keys/ 的 *.pub
        │  模块开机时、或点「操作」时合并（按公钥本体去重，不覆盖已有条目）
        ▼
/data/misc/adb/adb_keys          ← adbd 只在启动时整份读进内存
        │  所以改完必须重启 adbd
        ▼
adbd 拿客户端证书的公钥逐条比对这一份
```

两个容易踩的点：

- **不要**把密钥放进 `/data/adb/modules/adb_tls5555/`。那是模块目录，升级或重装会被整个替换，密钥随之丢失。
- `adb_keys` 只改权限位，**不要 `chown`**。各 ROM 属主不同（实测三星 OneUI 是 `system:shell`），强改成 `shell:shell` 会让以 `system` 身份运行的 `AdbDebuggingManager` 失去写权限——表现是 USB 授权弹窗点了「允许」也不落盘（v1.2.0 的 bug，v1.2.1 已修）。

---

## 认证：让控制端进来

`adbd` 只认一件事：**客户端的 TLS 证书公钥，是否出现在 `/data/misc/adb/adb_keys` 里**。让某个公钥出现在那里，有两条路。

### 方式一：预置公钥（推荐，不需要配对码）

先记住一条：**网络 ADB 不会弹「允许调试吗」的对话框。** 那个弹窗只在插 USB 时出现。没授权的客户端连上来会直接失败，手机上没有任何提示，所以只能靠预置公钥。顺序必须是「先授权，再连」。

#### 最省事：跑一次 `tools/grant_key.sh`

```bash
ADB_SERIAL=10.126.126.111:5555 bash tools/grant_key.sh her.pub
```

它做四件事：

1. 归一化输入（去掉 `\r`、只取第一条有效公钥行、校验 base64 长度）
2. 幂等检查——公钥已在列表里就直接退出，不重复写
3. 追加进 `/data/misc/adb/adb_keys`，补尾换行、`chmod 0640`、`restorecon`
4. 重启 adbd 并重连校验（USB 会自动回来，网络连接会走 `adb connect` 重试）

**内置防呆**：若当前是网络连接（序列号形如 `IP:端口`）而 `service.adb.tcp.port` 为空，脚本**不会**重启 adbd——那种情况下重启会关掉 TCP 监听且不再恢复，设备直接失联。它只写文件，然后提示「重启手机后自动生效」。

#### 手动四步

**第 1 步：拿到控制端的公钥**

```bash
# 第一次运行 adb 时自动生成，已存在就不要动它
#   Windows:     %USERPROFILE%\.android\adbkey.pub
#   macOS/Linux: ~/.android/adbkey.pub
cat ~/.android/adbkey.pub
# 输出形如：AAAA...（700 字符 base64） user@host
```

**第 2 步：放进手机的公钥目录** `/data/adb/adb_tls5555/keys/`，任选一种：

```bash
# A. 你已经能用 USB adb 连上手机（最简单）
adb push ~/.android/adbkey.pub /data/local/tmp/
adb shell su -c 'mkdir -p /data/adb/adb_tls5555/keys && cp /data/local/tmp/adbkey.pub /data/adb/adb_tls5555/keys/'
```

```
# B. 用带 root 的文件管理器（MT 管理器 / FX / Solid Explorer）
把 adbkey.pub 直接复制到 /data/adb/adb_tls5555/keys/
```

```
# C. 手机上装个 root 终端（Termux + su），把公钥内容粘进去
su -c 'mkdir -p /data/adb/adb_tls5555/keys && cat > /data/adb/adb_tls5555/keys/pc.pub'
# 粘贴那一整行，回车，Ctrl-D
```

**第 3 步：让它生效**

点模块卡片的「操作」按钮即可（后台复核也会在一个周期内发现新公钥并自动处理）。日志里会出现：

```
INFO: 预置 1 个客户端公钥 → /data/misc/adb/adb_keys
INFO: 发现新的客户端公钥，重启 adbd 以重新加载 keystore
```

**第 4 步：连**

```bash
adb connect <手机公网IP>:5555
adb devices     # 应显示 <IP>:5555   device
```

> 公钥目录权限是 `0700`，只有 root 能读。这是故意的——如果改成从 `/sdcard` 读，任何有存储权限的 App 都能塞一个自己的公钥进来拿到 root。

### 方式二：`adb pair`（官方流程，需要同一局域网）

配对端口是**另一个随机端口**，没有固定值，也没法做 NAT，所以只能在局域网内做一次。

1. 手机：开发者选项 → **无线调试** → 打开
2. 点进「使用配对码配对设备」，记下**配对端口**和 6 位码
3. 控制端：

```bash
adb pair <手机局域网IP>:<配对端口>
# 输入手机屏幕上的 6 位数字
adb connect <手机公网IP>:5555      # 注意：这里用 5555，不是配对端口
```

配对关系和方式一写进 `adb_keys` 的东西完全等价，长期有效（换 ROM / 清数据才会丢）。

### 为什么不需要申请证书

两端都是**自签名证书**，信任来自"公钥在不在 `adb_keys` 里"，不来自任何 CA。所以不需要域名、不需要花钱、不需要续期，公网 IP 变了也不影响。

### 千万不要用 `ro.adb.secure=0` 图省事

很多教程让你加 `ro.adb.secure=0` 来"免认证"。在 TLS 语境下它的含义是：

```c
// daemon/auth.cpp
int adbd_tls_verify_cert(X509_STORE_CTX* ctx, std::string* auth_key) {
    if (!auth_required) {
        // Any key will do.
        return 1;
    }
```

**任何人连上来都会被放行。** 通道是加密的，但对面是谁完全不管——等于把 root shell 挂在一个只有 `https://` 前缀的空门上。本模块的 `system.prop` 显式写 `ro.adb.secure=1`。

---

## 验证：确认它真的是 TLS

**最可靠的判据：找一台没配对过的电脑连一下。**

```bash
adb connect <手机IP>:5555
```

| 结果 | 含义 |
|---|---|
| 连不上 / 握手失败 | ✅ 是真 TLS |
| `unauthorized` | ❌ 仍是明文通道，TLS 没生效 |
| 直接 `device`、能进 shell | ❌ 明文 + 认证关闭，最糟 |

设备上自查：

```bash
su -c 'cat /data/adb/modules/adb_tls5555/adb_tls.log'
su -c 'iptables -t nat -S PREROUTING | grep 5555'
su -c 'getprop ro.adb.secure; getprop ro.secure'
su -c 'wc -l /data/misc/adb/adb_keys'
```

正常日志：

```
===== service.sh 启动 =====
conf: port=5555 mode=all ...
INFO: 预置 1 个客户端公钥 → /data/misc/adb/adb_keys
auth: ro.adb.secure=1 keystore=1 条 keys_dir=/data/adb/adb_tls5555/keys
INFO: 认证开启，只有公钥在 keystore 里的客户端才能连
INFO: adbd TLS 端口 = 39073
INFO: TLS 端口 无 → 39073，已重建转发（外部 5555）
OK: 5555 → 39073 转发就绪
guard: mode=all（不做来源限制，安全性依赖 TLS 认证）
INFO: 已启动后台复核，间隔 60s
```

> `netstat` 里查不到 5555 是**正常的**——5555 由内核 NAT 转发，不占独立监听 socket。adbd 只监听那个随机端口。

---

## 配置

编辑 `/data/adb/adb_tls5555.conf`，改完点模块卡片的「操作」按钮（或重启）。

| 键 | 默认 | 说明 |
|---|---|---|
| `ADB_TLS_PORT` | `5555` | 对外端口（你要连的那个），由 NAT 转发到 adbd 实际端口 |
| `GUARD_MODE` | `all` | `all` 不限来源；`lan` 只放行内网；`strict` 只放行 lo |
| `ALLOW4_CIDR` | `192.168.0.0/16 10.0.0.0/8 172.16.0.0/12` | `lan` 模式下放行的 IPv4 网段 |
| `ALLOW6_CIDR` | 空 | `lan` 模式下放行的 IPv6 网段；空表示 v6 只放行 lo |
| `GUARD_PLAINTEXT` | `0` | `1` = 给**明文端口**单独加来源白名单（与 `GUARD_MODE` 管的不是同一个端口） |
| `PLAINTEXT_ALLOW4` | `192.168.0.0/16 10.0.0.0/8 172.16.0.0/12` | `GUARD_PLAINTEXT=1` 时放行的 IPv4 网段；`10.0.0.0/8` 已覆盖 EasyTier mesh；填 `any` 等于关闭该功能 |
| `PLAINTEXT_ALLOW6` | `fe80::/10 fc00::/7` | 同上，IPv6；adbd 是 `[::]` 双栈监听，不配 v6 等于只防一半；填 `any` 表示 v6 不限制 |
| `VERIFY_INTERVAL` | `60` | 后台复核间隔（秒）；`0` 关闭复核 |
| `ENSURE_WIFI_DEBUG` | `0` | 取不到 TLS 端口时是否自动打开系统「无线调试」开关 |
| `KEYS_AUTO_INSTALL` | `1` | 是否自动把 `KEYS_DIR` 里的公钥合并进 `adb_keys`（`0` 关闭，只用 `adb pair`） |
| `KEYS_DIR` | `/data/adb/adb_tls5555/keys` | 待授权公钥目录；读 `*.pub` 与 `keys.txt` |
| `FORCE_SECURE` | `0` | 是否把 `ro.adb.secure` 置 1。`0`=只加密不认证（调试用）；`1`=客户端公钥必须在 `adb_keys` 里 |

> **`ADB_TLS_PORT` 不能填 `service.adb.tcp.port` 正在用的端口。** 那种情况下 NAT REDIRECT 会把别人的明文通道顶掉，模块检测到冲突会拒绝启动。装了 `adbd_tcpip_unsec` 这类明文模块的设备，请填 `5556`。
>
> **`FORCE_SECURE=1` 会让所有通道（含明文端口和 USB）都要求公钥。** 开启前务必确认控制端公钥已在 `/data/misc/adb/adb_keys` 里，否则会把自己也锁在外面。回退方式：改回 `0` 后重启。

三种模式怎么选：

| 场景 | 建议 |
|---|---|
| 公网直连（本项目的设计目标） | `all` |
| 只在内网用，但想要加密 | `lan` |
| 配合 VPS 反向隧道 / WireGuard | `strict` |

> `GUARD_MODE=all` 意味着对外端口对公网可见。安全性**完全依赖 TLS 认证**。不确定是否已配对成功时，先用 `lan` 跑通再切 `all`。

---

## 安全模型

| 层 | 措施 |
|---|---|
| 通道 | TLS 1.3（adbd 内置），端到端，NAT 不解密 |
| 身份 | 客户端证书公钥必须在 `/data/misc/adb/adb_keys`，逐条 `EVP_PKEY_cmp` 比对 |
| 抗扫描 | 没有正确私钥的握手在 TLS 阶段就被丢弃，`adbd` 不会执行任何 ADB 命令 |
| 明文通道 | **v1.3.0 起不再清除**，改为保留作应急退路；它同样受 `FORCE_SECURE=1` 的公钥校验约束 |
| 认证强制 | `FORCE_SECURE=1` 时在 `late_start` 置 `ro.adb.secure=1` 并重启 adbd，不会因 `ro.secure=0` 而被绕过 |
| 暴露面 | `GUARD_MODE` 控制对外端口的来源；`all` 时依赖 TLS |
| 失败行为 | 模块自己失败时回滚属性并自我禁用，绝不把设备留在半截状态 |
| 撤销 | 编辑 `/data/misc/adb/adb_keys` 删掉对应行，重启 adbd（或 `adb shell su -c 'setprop ctl.restart adbd'`） |

### 已知的残留暴露面

「无线调试」开着时，adbd 那个**随机端口**是直接监听在 `[::]` 上的，对公网可见。它受 TLS 保护（陌生人握手失败），但不受 `GUARD_MODE` 约束——`GUARD_MODE` 只管对外端口。

要彻底收口，可以在 `INPUT` 上补两条（目前**未内置**，属于实验性做法）：

```sh
# 放行经 NAT 转发进来的连接
iptables -A INPUT -p tcp --dport 39073 -m conntrack --ctstate DNAT -j ACCEPT
# 丢弃直接打随机端口的连接
iptables -A INPUT -p tcp --dport 39073 -j DROP
```

`--ctstate DNAT` 在部分内核上行为可能有差异，需要实测后再合入。

### 这个方案不解决的问题

- **认证是单向的**：adbd 验客户端，客户端不验设备。中间人没有配对私钥无法完成握手，但"确认对面是你要的那台手机"依赖首次配对时的判断。
- **端口对公网可见**（`all` 模式）。扫描器能看到这里有一个 TLS 端点，但拿不到任何东西。

---

## 排错

### 日志出现 `FAIL: adbd 未提供 TLS 端口`

「无线调试」是关闭状态，adbd 没有启动 TLS 服务端。两种处理：

1. 手动打开开发者选项 → 无线调试；
2. 把 `ENSURE_WIFI_DEBUG` 设为 `1`，模块会自己执行 `settings put global adb_wifi_enabled 1`。

端口起来后，后台复核会在一个间隔内自动建好 NAT，不需要重启。

### 彻底连不上：`Connection refused` + 两个端口属性都是空

这是**最危险**的状态，也是 v1.2.1 的真实事故：`service.adb.tls.port` 和
`service.adb.tcp.port` 同时为空，说明 adbd 只监听 USB，5555 上什么都没有，
连接被内核直接 RST。

判据（能 USB 进去或能在手机上执行时）：

```sh
getprop persist.adb.tls_server.enable   # 期望 1
getprop service.adb.tls.port            # 期望一个随机端口
getprop service.adb.tcp.port            # 期望空
```

`persist.adb.tls_server.enable` 为空就必然是这个状态——adbd 启动时没有
TLS 能力开关，起来就是裸 adbd。

**v1.2.2 起模块会自己救回来**：后台复核发现端口消失会在 2 个间隔内重新
置位属性并重启 adbd，前 3 次每 2 个间隔一次，之后退避到每 10 个间隔一次。
能自愈的前提是 **`service.sh` 还活着**——所以：

- 只改配置、不重启手机 → 能自愈；
- 手滑点了「无线调试」开关关掉 → 能自愈；
- 模块被禁用 / 卸载 / 手机重启后模块没加载 → **不能自愈，必须 USB 或
  物理重启**。

所以公网部署的机器，**别在只有远程的情况下卸载或禁用模块**。

### 连接失败

| 现象 | 排查 |
|---|---|
| `Connection refused` | 对外端口无人转发 → 点「操作」看「转发状态」，查 `iptables -t nat -S PREROUTING \| grep 5555` |
| `failed to authenticate` / `TLS handshake failed` | 客户端公钥不在 `adb_keys` 里 → 按「认证」一节预置公钥，或 `adb pair` |
| `adb connect` 卡住 | adb 版本 < 30，不支持 TLS 客户端；或对面不是真 `adb`（见下节） |
| 连上了但不是 `device` | `ro.adb.secure=0` 之外还有别的认证关闭路径，检查 `getprop ro.adb.secure` |
| 端口一会儿通一会儿不通 | adbd 的随机端口变了而复核还没跟上 → 调小 `VERIFY_INTERVAL`，或点「操作」立即重建 |

判据：**「操作」里 `keystore` 条数 ≥ 1 且 `ro.adb.secure=1`，才算认证链路完整。**

### 「转发状态: 未就绪」

先看 `iptables -t nat -S PREROUTING` 里有没有这一行：

```
-A PREROUTING -p tcp -m tcp --dport 5555 -j REDIRECT --to-ports <实际端口>
```

- **没有** → 规则没建上。日志里会有 `WARN: v4 REDIRECT 添加失败: <iptables 原话>`，按那句话判断（多半是 nat 表被 netd 锁住或内核没编 nat）。
- **有，但连不上** → 转发是好的，问题在 adbd 侧。先用 `nc -z 127.0.0.1 <实际端口>` 在手机上确认 adbd 那个端口能连，再确认它接受 IPv4（netstat 显示 `:::端口` 时通常双栈，若只接受 IPv6 则 IPv4 转发进不去）。

### 官方 ROM 上 REDIRECT 报错

Android 的 iptables 走 nft 后端，**NAT 目标不能放在用户自定义链里**。这就是 v1.1.0 失败的原因：跳转规则建成功、链是空的，看着有规则却不转发。v1.1.1 起直接把 REDIRECT 写进 `PREROUTING`，不再用中间链。

### 控制端是自研 App：为什么它一定连不上

这是本项目最容易踩的坑，也是"原模块能连、加 TLS 就连不上"最常见的原因。

`adbd` 的 TLS 端口是 **STARTTLS 升级**：客户端先发明文 `A_CNXN`，服务端回 `A_STLS`，双方才切 TLS，然后客户端要在隧道里**重发一次** `A_CNXN`。

```java
// 典型自研客户端的握手代码长这样
channel.write(AdbProtocol.generateConnect());       // A_CNXN
AdbMessage message = AdbMessage.parse(channel);     // 期望 A_CNXN 或 A_AUTH
// ← 这里收到的是 A_STLS，解析失败 / 被忽略 / 永远等不到下一步
```

自研客户端通常只实现 `A_CNXN` / `A_AUTH` / `A_OKAY`，**没有 `A_STLS` 分支，也没有 TLS 栈**，所以必定卡在第二个包。

只有三条出路：

1. **换成真正的 `adb`**（PC 上的 platform-tools ≥ 30）。原生支持，零改动。
2. **不用原生 TLS**：设备端跑一个 TLS 网关（固定端口 + 自签证书 + 客户端证书校验），App 里用 `SSLSocket` 包一层，ADB 字节流原样透传。客户端约 30 行代码，服务端需要额外二进制。
3. **放弃加密**：回到明文 + 来源白名单 / WireGuard / SSH 隧道。

模块本身不解决第 2、3 条——它只负责把 `adbd` 的 TLS 端口变成固定端口，并保证认证链路完整。

---

## 卸载

管理器里卸载即可。`uninstall.sh` 会：

- 拆 `ADB_TLS_NAT` / `ADB_TLS_NAT6` 的 NAT 跳转与链
- 拆 `ADB_GUARD` / `ADB_GUARD6` 防火墙链
- 清 `service.adb.tls.port`、`service.adb.tcp.port`、`persist.adb.tls_server.enable`
- 重启 adbd，回到纯 USB 模式

配置 `/data/adb/adb_tls5555.conf` 会保留，需手动删除。

**`/data/misc/adb/adb_keys` 里的公钥不会被删**——那是系统文件，可能还有 USB 授权等其他来源。要撤销某个客户端，编辑该文件删掉对应行后重启 adbd。

---

## 构建

```bash
python tools/build.py           # 产物输出到仓库上一级目录
python tools/build.py --out dist
```

脚本会：统一换行符为 LF 并剥掉 BOM → 把模块必需文件平铺打进 zip 根目录 → 给 `.sh` 显式写入 `0755` → 校验 CRC、根目录结构和权限位。

## 配套工具

`tools/grant_key.sh` —— 在电脑上把一个客户端公钥授权到被控机，不打包进 zip。

```bash
# 单个公钥文件
ADB_SERIAL=10.126.126.111:5555 bash tools/grant_key.sh her.pub

# 从剪贴板/管道来
cat her.pub | ADB_SERIAL=10.126.126.111:5555 bash tools/grant_key.sh -

# 只有一台设备时可以省略 ADB_SERIAL
bash tools/grant_key.sh her.pub
```

行为要点：

| 场景 | 结果 |
|---|---|
| 公钥已在 `adb_keys` | 输出「已在授权列表里」，不做任何修改 |
| 公钥是新的 | 追加一行 + `chmod 0640` + `restorecon`，然后重启 adbd 并重连校验 |
| 网络连接 + `service.adb.tcp.port` 为空 | **只写不重启**（重启会让设备失联），提示重启手机后生效 |
| 被控机没有 root | 明确报错退出，不会留下半截状态 |

已实测四条路径：新增、幂等、防呆、残留清理。测试用临时 keystore 副本，不碰真实文件。

---

## 变更记录

| 版本 | 内容 |
|---|---|
| **v1.3.2** | 新增 `GUARD_PLAINTEXT`：可给**明文端口**（`service.adb.tcp.port`，通常是 5555）单独加 INPUT 来源白名单，实现「明文只走内网 / mesh，公网只留 TLS 端口」；规则幂等且可逆（改成 `0` 会自动拆除），复核循环自动补回被刷掉的规则；v4/v6 双栈都覆盖；`uninstall.sh` 同步清理 `ADB_GUARD_P` / `ADB_GUARD6_P`。**修复 `action.sh` 仍在清 `service.adb.tcp.port` 的老问题** —— 那会让明文通道消失，进而触发复核循环自我禁用模块 |
| **v1.3.1** | 新增 `ensure_keys()`：系统框架每次认证成功后会按自己内存里的 key map 重写 `adb_keys`，把「从没连接过」的公钥清掉。复核循环每 60 s 补回缺失公钥（adbd 每次认证都重读文件，补写无需重启 adbd） |
| **v1.3.0** | **删除 `system.prop`**：实测运行时 `setprop` 即可拉起 TLS 且与明文通道共存，模块从此在 `post-fs-data` 阶段零操作、不可能阻止开机；新增 `watchdog.sh` 独立看门狗、`.failcount` 电路熔断、端口冲突拒绝启动、`FORCE_SECURE` 开关；`uninstall.sh` 不再误清 `service.adb.tcp.port` |
| **v1.2.2** | 修致命缺陷：后台复核发现 `service.adb.tls.port` 消失时会重新置位 `persist.adb.tls_server.enable` 并重启 adbd 自愈（带退避），不再永久失联 |
| **v1.2.1** | 修 `adb_keys` 属主问题（不再无条件 `chown shell:shell`，否则 `AdbDebuggingManager` 失去写权限）；安装提示同时检出 `adbd_tcpip_unsec` |
| **v1.2.0** | 补上认证层：客户端公钥预置（`keys/` → `adb_keys`），`action.sh` 增加认证段，`system.prop` 显式 `ro.adb.secure=1` + `ro.secure=0` |
| v1.1.1 | REDIRECT 直写 `PREROUTING`，修 nft 后端下「跳转规则建成功、链里是空的」 |
| v1.1.0 | 改走 NAT 转发，修 `service.adb.tls.port` 被 adbd 随机覆盖的问题 |
| v1.0.0 | 首版，尝试直接注入 `service.adb.tls.port`（无效，见上文） |

---

## License

[MIT](LICENSE)
