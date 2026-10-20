#!/usr/bin/env python3
"""
net_heal.py —— 盒子重新上网就自动禁用模块

用途：
  三星安卓盒子没有 OTG 设备口，USB adb 永远用不了，唯一的入口是网络。
  这个脚本持续扫局域网，一旦发现盒子（原先的 IP 重新上线，或任意主机
  监听 5555），就立刻 adb connect 并写入 disable 标记，下次启动就不再
  加载模块。

两路探测：
  1. 每轮扫所有网段的 5555（模块正常时，NAT 会把 5555 转到 adbd 的随机端口）
  2. 每 5 轮对「盒子曾经出现过的 IP」做全端口扫描（模块半死不活时，
     adbd 只剩那个随机 TLS 端口，5555 是空的）

用法：
  python tools/net_heal.py            # 一直守
  python tools/net_heal.py 3600       # 守 1 小时
"""

import concurrent.futures
import socket
import subprocess
import sys
import time

ADB = r"C:\platform-tools\adb.exe"

# 盒子可能出现的网段（本机 192.168.11.100，10.126.126.x 经路由器过去）
SUBNETS = ["10.126.126", "192.168.11"]

# 盒子历史上用过的地址，优先全端口扫这些
BOX_HINTS = ["10.126.126.111", "192.168.11.111"]

# 这些是别的设备，别碰
EXCLUDE = {"10.126.126.110", "192.168.11.110"}

CYCLE = 20          # 每轮间隔（秒）
DEEP_EVERY = 5      # 每 5 轮做一次全端口扫描

MODULES = ["adb_tls5555", "adb_tcp5555", "adbd_tcpip_unsec", "adb_tcp_5555"]

PAYLOAD = "; ".join(
    [f"mkdir -p /data/adb/modules/{m} && : > /data/adb/modules/{m}/disable" for m in MODULES]
    + [
        "setprop persist.adb.tls_server.enable 0",
        "setprop service.adb.tcp.port ''",
        "echo HEALED",
    ]
)


def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, flush=True)


def probe(host, port, timeout=0.25):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        if s.connect_ex((host, port)) == 0:
            return host, port
    except Exception:
        pass
    finally:
        s.close()
    return None


def scan_port(hosts, port, workers=512):
    hits = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for r in ex.map(lambda h: probe(h, port), hosts, chunksize=16):
            if r:
                hits.append(r)
    return hits


def adb(*args, timeout=25):
    try:
        p = subprocess.run([ADB, *args], capture_output=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace").strip()
    except subprocess.TimeoutExpired:
        return -1, "(adb 超时)"
    except Exception as e:
        return -2, str(e)


def try_heal(host, port):
    serial = f"{host}:{port}"
    log(f"  发现 {serial}，尝试连接")
    rc, out = adb("connect", serial)
    if "connected" not in out and "already" not in out:
        log(f"    connect 失败: {out}")
        return False

    rc, out = adb("-s", serial, "shell", f"su -c \"{PAYLOAD}\"")
    if "HEALED" not in out:
        # 没有 su 或模块没装 Magisk：直接执行（recovery 下 adb 就是 root）
        rc, out = adb("-s", serial, "shell", PAYLOAD)

    if "HEALED" in out:
        log(f"  ✔ {serial} 已写入 disable —— 现在可以断电重启")
        return True

    log(f"    shell 失败: {out[:300]}")
    return False


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    start = time.time()

    all_hosts = [f"{s}.{i}" for s in SUBNETS for i in range(1, 255) if f"{s}.{i}" not in EXCLUDE]

    log("=" * 52)
    log(" 网络自愈守护启动 —— 盒子一上线就写 disable")
    log(f" 扫描范围: {', '.join(s + '.0/24' for s in SUBNETS)}")
    log(f" 排除: {', '.join(sorted(EXCLUDE))}")
    log(f" 时限: {'不限' if limit == 0 else str(limit) + ' 秒'}")
    log("=" * 52)

    cycle = 0
    while True:
        if limit and time.time() - start > limit:
            log("到时退出。")
            return 1
        cycle += 1

        hits = scan_port(all_hosts, 5555)
        if hits:
            log(f"[第 {cycle} 轮] 5555 上有 {len(hits)} 台主机")
            for host, port in hits:
                if try_heal(host, port):
                    return 0

        if cycle % DEEP_EVERY == 0:
            for box in BOX_HINTS:
                rc, out = adb("connect", f"{box}:5555")
                if "failed" not in out and "cannot" not in out:
                    if try_heal(box, 5555):
                        return 0

                # 全端口扫：模块半死时 adbd 只剩随机 TLS 端口
                ports = list(range(1, 65536))
                found = []
                with concurrent.futures.ThreadPoolExecutor(max_workers=800) as ex:
                    for r in ex.map(lambda p: probe(box, p, 0.3), ports, chunksize=256):
                        if r:
                            found.append(r[1])
                if found:
                    log(f"[第 {cycle} 轮] {box} 开放端口: {found[:12]}")
                    for p in found:
                        if try_heal(box, p):
                            return 0

        print(".", end="", flush=True)
        time.sleep(CYCLE)


if __name__ == "__main__":
    sys.exit(main())
