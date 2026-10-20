# Magisk-ADB-TLS

Magisk 模块：**开机让 `adbd` 以 TLS 模式在固定端口监听，并关闭明文 TCP 通道。**

认证由 `adbd` 内置的 TLS 配对完成——`adb pair` 一次，之后长期免密。模块本身**不含任何密码逻辑**，也不加任何二进制。

> 本项目是 [Magisk-ADB-TCP-5555](https://github.com/qzrsa/Magisk-ADB-TCP-5555) 的安全向变体。那个模块解决"开机即用"，本项目解决"开机即用 **且** 可以放到公网"。

---

## 和原模块的差别

| 维度 | Magisk-ADB-TCP-5555 | **本项目** |
|---|---|---|
| 传输属性 | `service.adb.tcp.port` | `service.adb.tls.port` |
| 通道 | 明文 | TLS 1.3 |
| 认证 | RSA 挑战应答（默认可关） | TLS 配对证书（不可关） |
| 陌生人能做什么 | 连上、停在 `unauthorized` | **握手阶段就失败**，连认证都到不了 |
| 传输内容可见 | 是 | 否 |
| 是否需要申请证书 | — | 不需要，adbd 自己生成 |
| 开机即用 | 是 | 是（属性注入，零重启） |
| 额外组件 | 无 | 无 |

一句话：**原模块把门打开；本项目把门换成只有配过对的人才能推开的门。**

---

## 原理：adbd 有两条互相独立的 TCP 通道

| | 明文通道 | **TLS 通道** |
|---|---|---|
| 属性 | `service.adb.tcp.port` | `service.adb.tls.port` |
| 开关 | — | `persist.adb.tls_server.enable=1` |
| 加密 | 无 | TLS 1.3 |
| 客户端要求 | 任意 adb | adb 30+ |

这两条通道可以**同时存在**。本项目做三件事：

1. 注入 `service.adb.tls.port` 与 `persist.adb.tls_server.enable`（`system.prop`，post-fs-data 阶段，早于 adbd 首次启动）；
2. 主动清掉 `service.adb.tcp.port`，确保明文通道不并存；
3. 按配置加设备侧防火墙，并在后台低频复核（端口是否还在、明文是否回潮、防火墙规则是否还在）。

### 失败时不会降级

如果本机不支持 `service.adb.tls.port`（TLS 起不来），模块会**放弃并记录 FAIL**，**不会**回落到明文 5555。宁可连不上，也不要静默变成无加密通道。

---

## 安装

1. 从 Releases 下载 zip（或自行 `python tools/build.py`）
2. Magisk / KernelSU / APatch 管理器 → 模块 → 从本地安装
3. **重启手机**
4. 首次安装会生成配置：`/data/adb/adb_tls5555.conf`

> 如果你装了 `adb_tcp5555`（明文版），**先卸载它**。两者会同时注入 `service.adb.*` 属性，行为不可预测。

---

## 首次配对（只做一次）

配对需要**看到手机屏幕**，请在局域网内完成，不要在公网做。

1. 手机：设置 → 关于手机 → 连点「版本号」进开发者选项 → 打开 **无线调试**
2. 点进「使用配对码配对设备」，记下**配对端口**（一个高位端口，与 5555 不同）和 6 位码
3. 控制端执行：

```bash
adb pair <手机IP>:<配对端口>
# 提示输入配对码，输入手机屏幕上的 6 位数字
```

4. 配对成功后连接：

```bash
adb connect <手机IP>:5555
adb devices        # 应显示 <IP>:5555   device
```

**配对完成后可以关掉「无线调试」开关**——模块负责让 TLS 服务端常驻。若关掉开关导致端口消失，后台复核会在一个间隔内把它拉回来（可在配置里调 `VERIFY_INTERVAL`）。

### 为什么不用申请证书

TLS 用的是**自签名证书 + 配对后固定（pinning）**：证书由 adbd 在设备上自己生成，信任来自你亲眼看过屏幕上那 6 位码，而不是第三方 CA。所以：

- 不需要域名、不需要花钱、不需要续期；
- 公网 IP 变了不影响（证书与 IP 无关）；
- 清数据 / 换 ROM / 手动清 `/data/misc/adb/` 后证书失效，需要重新配对一次。

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

在设备上自查：

```bash
su -c 'cat /data/adb/modules/adb_tls5555/adb_tls.log'
su -c 'getprop service.adb.tls.port; getprop service.adb.tcp.port'
su -c 'netstat -ltn | grep 5555'
```

日志正常的样子：

```
2026-10-20 12:00:03 ===== service.sh 启动 =====
2026-10-20 12:00:03 conf: port=5555 mode=all ...
2026-10-20 12:00:04 OK: tcp:5555 已监听
2026-10-20 12:00:04 guard: mode=all 已应用
2026-10-20 12:00:04 INFO: 已启动后台复核，间隔 60s
```

---

## 配置

编辑 `/data/adb/adb_tls5555.conf`，改完点模块卡片的「操作」按钮（或重启）。

| 键 | 默认 | 说明 |
|---|---|---|
| `ADB_TLS_PORT` | `5555` | TLS 监听端口 |
| `GUARD_MODE` | `all` | `all` 不限来源（公网直连）；`lan` 只放行内网；`strict` 只放行 lo（配隧道用） |
| `ALLOW4_CIDR` | `192.168.0.0/16 10.0.0.0/8 172.16.0.0/12` | `lan` 模式下放行的 IPv4 网段 |
| `ALLOW6_CIDR` | 空 | `lan` 模式下放行的 IPv6 网段；空表示 v6 只放行 lo |
| `VERIFY_INTERVAL` | `60` | 后台复核间隔（秒）；`0` 关闭复核 |

三种模式怎么选：

| 场景 | 建议 |
|---|---|
| 公网直连（本项目的设计目标） | `all` |
| 只在内网用，但想要加密 | `lan` |
| 配合 VPS 反向隧道 / WireGuard | `strict` |

> `GUARD_MODE=all` 意味着这个端口对公网可见。安全性**完全依赖 TLS 认证**：未配对的主机握手即失败。如果你不确定自己是否已经配对成功，先用 `lan` 跑通，再切到 `all`。

---

## 安全模型

| 层 | 措施 |
|---|---|
| 通道 | TLS 1.3（adbd 内置） |
| 身份 | 配对证书 + pinning，无法暴力枚举 |
| 明文通道 | 启动时清除 + 后台复核，发现回潮即关 |
| 暴露面 | 由 `GUARD_MODE` 控制；`all` 时依赖 TLS，`lan`/`strict` 时由 iptables 收敛 |
| 失败行为 | fail-closed，不回落明文 |
| 撤销 | 手机端「撤销 USB 调试授权」或清除配对，控制端重新 `adb pair` |

### 这个方案不解决的问题

- **认证是单向的**：adbd 验客户端，客户端不验设备。TLS 的服务器证书是自签的，`adb` 客户端不做 CA 校验。中间人无法在没有配对私钥的情况下完成 TLS 握手，但"确认对面是你要的那台手机"依赖你首次配对时的判断。
- **端口对公网可见**（`all` 模式下）。扫描器能看到这里有一个 TLS 端点，但拿不到任何东西。

---

## 排错

### 属性不生效（`service.adb.tls.port` 设了但端口不监听）

部分 ROM 的 adbd 不读这条属性，或需要框架层配合。表现为日志里出现：

```
FAIL: tcp:5555 仍未监听 —— 本机可能不支持 service.adb.tls.port
```

确认方法：

```bash
su -c 'setprop service.adb.tls.port 5555; setprop ctl.restart adbd; sleep 3; netstat -ltn | grep 5555'
```

仍不监听 → 这台机器不支持这条路。替代方案（按推荐度）：

1. **WireGuard 点对点**：公网上只映射一个 UDP 端口，`adb connect` 隧道内网 IP。加密与认证都由 WireGuard 提供，1 跳直连。
2. **SSH 反向隧道到 VPS**：`restrict,permitlisten` 收窄爆炸半径，适合手机在 CGNAT 下的情况。
3. **`GUARD_MODE=lan` + 原明文模块**：仅限局域网，不要把 5555 暴露到公网。

### 连不上

| 现象 | 排查 |
|---|---|
| `Connection refused` | 端口没监听 → 看日志；或防火墙拦了 → `iptables -L ADB_GUARD -n` |
| `failed to authenticate` | 没配对过，或清了 `/data/misc/adb/` → 重新 `adb pair` |
| `adb connect` 卡住 | adb 版本 < 30，不支持 TLS 客户端 |
| 配对成功但连不上 | 确认连的是 `5555`（连接端口），不是配对端口 |

### 控制端是自研 App

`adb pair` / `adb connect` 之外的自研客户端（例如自己实现的 raw ADB 协议）**默认不支持 TLS**。需要在客户端补 `SSLSocket` + 客户端证书 + 服务端证书 pinning，否则只能退回明文通道或 WireGuard 方案。

---

## 卸载

管理器里卸载即可。`uninstall.sh` 会：

- 拆掉 `ADB_GUARD` / `ADB_GUARD6` 防火墙链
- 清掉 `service.adb.tls.port`、`service.adb.tcp.port`、`persist.adb.tls_server.enable`
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
