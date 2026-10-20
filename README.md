# Magisk-ADB-TLS

Magisk 模块：**开机确保 `adbd` 以 TLS 模式监听，并把固定的 `5555` 端口转发到它的实际端口，同时关闭明文 TCP 通道。**

认证由 `adbd` 内置的 TLS 配对完成——`adb pair` 一次，之后长期免密。模块本身**不含任何密码逻辑**，也不加任何二进制。

> 本项目是 [Magisk-ADB-TCP-5555](https://github.com/qzrsa/Magisk-ADB-TCP-5555) 的安全向变体。那个模块解决"开机即用"，本项目解决"开机即用 **且** 可以放到公网"。

---

## 和原模块的差别

| 维度 | Magisk-ADB-TCP-5555 | **本项目** |
|---|---|---|
| 通道 | 明文 TCP | TLS 1.3 |
| 认证 | RSA 挑战应答（默认可关） | TLS 配对证书（不可关） |
| 陌生人能做什么 | 连上、停在 `unauthorized` | **握手阶段就失败** |
| 传输内容可见 | 是 | 否 |
| 是否需要申请证书 | — | 不需要，adbd 自己生成 |
| 端口 | 固定 5555（属性可注入） | adbd 随机选，模块用 NAT 映射回 5555 |
| 额外组件 | 无 | 无 |

一句话：**原模块把门打开；本项目把门换成只有配过对的人才能推开的门，而且换了个固定门牌号。**

---

## 原理：为什么不能直接注入 TLS 端口

`service.adb.tls.port` 和我们直觉相反——**它是 adbd 的输出，不是输入**。实际流程是：

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
     iptables -t nat -I PREROUTING 1 -p tcp --dport 5555 -j ADB_TLS_NAT
     iptables -t nat -A ADB_TLS_NAT -j REDIRECT --to-ports 39073
4. 后台复核端口变化，变了就重建规则
```

**TLS 仍然是端到端的**：NAT 只改目的端口号，不接触内容，所以客户端依然和 adbd 直接完成 TLS 握手，中间没有任何解密环节，也不需要额外进程。

### 失败时不会降级

拿不到 TLS 端口（例如「无线调试」被关闭）时，模块只记 `FAIL` 并继续等待，**不会**回落到明文 5555。宁可连不上，也不要静默变成无加密通道。

---

## 安装

1. 从 Releases 下载 zip（或自行 `python tools/build.py`）
2. Magisk / KernelSU / APatch 管理器 → 模块 → 从本地安装
3. **重启手机**
4. 首次安装会生成配置：`/data/adb/adb_tls5555.conf`

> 如果你装了 `adb_tcp5555`（明文版），**先卸载它**。

装完点模块卡片的「操作」按钮，可以看到实际端口与 NAT 状态：

```
--- adb_tls5555 ---
service.adb.tls.port          = 39073
service.adb.tcp.port          =
persist.adb.tls_server.enable = 1
对外端口 ADB_TLS_PORT         = 5555（NAT 转发到上面的实际端口）
--- nat ---
-A PREROUTING -p tcp -m tcp --dport 5555 -j ADB_TLS_NAT
-A ADB_TLS_NAT -j REDIRECT --to-ports 39073
```

---

## 首次配对（只做一次）

配对需要**看到手机屏幕**，请在局域网内完成，不要在公网做。

1. 手机：设置 → 关于手机 → 连点「版本号」进开发者选项 → 打开 **无线调试**
2. 点进「使用配对码配对设备」，记下**配对端口**（与 5555 无关）和 6 位码
3. 控制端执行：

```bash
adb pair <手机IP>:<配对端口>
# 输入手机屏幕上的 6 位数字
```

4. 配对成功后连接固定的对外端口：

```bash
adb connect <手机IP>:5555
adb devices        # 应显示 <IP>:5555   device
```

配对信息长期有效，之后不需要再配对（除非清数据 / 换 ROM）。

### 为什么不用申请证书

TLS 用的是**自签名证书 + 配对后固定（pinning）**：证书由 adbd 在设备上自己生成，信任来自你亲眼看过屏幕上那 6 位码，而不是第三方 CA。所以不需要域名、不需要花钱、不需要续期，公网 IP 变了也不影响。

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
su -c 'iptables -t nat -S ADB_TLS_NAT'
```

正常日志：

```
===== service.sh 启动 =====
conf: port=5555 mode=all ...
INFO: adbd TLS 端口 = 39073
INFO: TLS 端口 无 → 39073，NAT 已重建（外部 5555）
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
| 通道 | TLS 1.3（adbd 内置） |
| 身份 | 配对证书 + pinning，无法暴力枚举 |
| 明文通道 | 启动时清除 + 后台复核，发现回潮即关 |
| 暴露面 | `GUARD_MODE` 控制对外端口的来源；`all` 时依赖 TLS |
| 失败行为 | fail-closed，不回落明文 |
| 撤销 | 手机端「撤销 USB 调试授权」，控制端重新 `adb pair` |

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
| `Connection refused` | 对外端口无人转发 → 看日志有没有 `OK: ... 转发就绪`；查 `iptables -t nat -S ADB_TLS_NAT` |
| `failed to authenticate` | 没配对过，或清了 `/data/misc/adb/` → 重新 `adb pair` |
| `adb connect` 卡住 | adb 版本 < 30，不支持 TLS 客户端 |
| 配对成功但连不上 | 确认连的是 `5555`（对外端口），不是配对端口 |
| 端口一会儿通一会儿不通 | adbd 的随机端口变了而复核还没跟上 → 调小 `VERIFY_INTERVAL`，或点「操作」立即重建 |

### 控制端是自研 App

`adb pair` / `adb connect` 之外的自研客户端（例如自己实现的 raw ADB 协议）**默认不支持 TLS**，需要在客户端补 `SSLSocket` + 客户端证书 + 服务端 pinning。否则只能退回明文通道或 WireGuard 方案。

---

## 卸载

管理器里卸载即可。`uninstall.sh` 会：

- 拆 `ADB_TLS_NAT` / `ADB_TLS_NAT6` 的 NAT 跳转与链
- 拆 `ADB_GUARD` / `ADB_GUARD6` 防火墙链
- 清 `service.adb.tls.port`、`service.adb.tcp.port`、`persist.adb.tls_server.enable`
- 重启 adbd，回到纯 USB 模式

配置 `/data/adb/adb_tls5555.conf` 会保留，需手动删除。

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
