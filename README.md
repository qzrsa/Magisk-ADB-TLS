# Magisk-ADB-TLS

Magisk 模块：**开机确保 `adbd` 以 TLS 模式监听，并把固定的 `5555` 端口转发到它的实际端口，同时关闭明文 TCP 通道。**

认证走 `adbd` 的 **TLS 客户端证书校验**：把控制端的 `adbkey.pub` 放进指定目录即可，不需要 6 位配对码，也不需要同一局域网。模块本身**不含任何密码逻辑**，也不加任何二进制。

> 本项目是 [Magisk-ADB-TCP-5555](https://github.com/qzrsa/Magisk-ADB-TCP-5555) 的安全向变体。那个模块解决"开机即用"，本项目解决"开机即用 **且** 可以放到公网"。

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

## 两个必须知道的事实

这两条是读 AOSP 源码核对的，也是本项目全部设计的依据。

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

> 如果你装了 `adb_tcp5555`（明文版），**先卸载它**。

装完点模块卡片的「操作」按钮，可以看到实际端口、转发状态和认证状态：

```
--- adb_tls5555 v1.2.0 ---
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

## 认证：让控制端进来

`adbd` 只认一件事：**客户端的 TLS 证书公钥，是否出现在 `/data/misc/adb/adb_keys` 里**。让某个公钥出现在那里，有两条路。

### 方式一：预置公钥（推荐，不需要配对码）

模块会读 `/data/adb/adb_tls5555/keys/` 下的 `*.pub` 和 `keys.txt`，把里面的公钥合并进 `adb_keys`，然后自动重启 adbd 生效。

**第 1 步：拿到控制端的公钥**

```bash
# 路径（第一次运行 adb 时自动生成，已存在就不要动它）
#   Windows:    %USERPROFILE%\.android\adbkey.pub
#   macOS/Linux: ~/.android/adbkey.pub
cat ~/.android/adbkey.pub
# 输出形如：AAAA...（700 字符 base64） user@host
```

**第 2 步：放进手机的公钥目录**

任选一种：

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
| `VERIFY_INTERVAL` | `60` | 后台复核间隔（秒）；`0` 关闭复核 |
| `ENSURE_WIFI_DEBUG` | `0` | 取不到 TLS 端口时是否自动打开系统「无线调试」开关 |
| `KEYS_AUTO_INSTALL` | `1` | 是否自动把 `KEYS_DIR` 里的公钥合并进 `adb_keys`（`0` 关闭，只用 `adb pair`） |
| `KEYS_DIR` | `/data/adb/adb_tls5555/keys` | 待授权公钥目录；读 `*.pub` 与 `keys.txt` |

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
| 明文通道 | 启动时清除 + 后台复核，发现回潮即关 |
| 认证强制 | `ro.adb.secure=1` 写死在 `system.prop`，不会因 `ro.secure=0` 而被绕过 |
| 暴露面 | `GUARD_MODE` 控制对外端口的来源；`all` 时依赖 TLS |
| 失败行为 | fail-closed，不回落明文 |
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

---

## License

[MIT](LICENSE)
