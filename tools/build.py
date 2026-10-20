#!/usr/bin/env python3
"""
把本仓库打包成可刷入的 Magisk 模块 zip。

用法：
    python tools/build.py                # 产物输出到仓库上一级目录
    python tools/build.py --out dist     # 产物输出到指定目录

设计要点（沿用 Magisk-ADB-TCP-5555 的踩坑经验）：
  * 只打包模块运行必需的文件（见 MODULE_FILES）——README/LICENSE/tools 不进 zip。
  * zip 内路径统一用正斜杠，且 module.prop 必须位于 zip 根（不得有包裹目录），
    否则 Magisk / KernelSU 认不出模块。
  * .sh 权限显式写成 0755（通过 ZipInfo.external_attr），不依赖解压端的 umask。
  * 打包前统一换行符为 LF 并剥掉 UTF-8 BOM。CRLF 会让 Android 的 sh 直接报
    `#!/system/bin/sh\\r: not found`，BOM 会污染 module.prop 的解析。
"""

import argparse
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 只有这些文件会进 zip
MODULE_FILES = [
    "module.prop",
    "system.prop",
    "module.conf",
    "lib.sh",
    "service.sh",
    "action.sh",
    "uninstall.sh",
    "customize.sh",
]

TEXT_SUFFIXES = (".sh", ".prop", ".conf", ".md", ".py", ".txt")


def read_prop(key, default=""):
    path = os.path.join(ROOT, "module.prop")
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    return default


def normalize(path, name):
    """转 LF、去 BOM。返回是否有改动。"""
    with open(path, "rb") as fh:
        raw = fh.read()

    new = raw.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    if new.startswith(b"\xef\xbb\xbf"):
        new = new[3:]

    if new != raw:
        with open(path, "wb") as fh:
            fh.write(new)
        print(f"  [FIX] {name}: CRLF/BOM normalized ({len(raw)} -> {len(new)} bytes)")
        return True

    print(f"  [ok ] {name}: {len(raw)} bytes, LF, no BOM")
    return False


def build(out_dir):
    mod_id = read_prop("id", "module")
    version = read_prop("version", "0.0.0")
    out_name = f"{mod_id}-v{version}.zip"
    out_path = os.path.join(out_dir, out_name)

    os.makedirs(out_dir, exist_ok=True)

    print("=== 1/3 规范化换行符 ===")
    for name in MODULE_FILES:
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            sys.exit(f"缺少必需文件: {name}")
        if name.endswith(TEXT_SUFFIXES):
            normalize(path, name)
        else:
            print(f"  [ok ] {name} (binary, skipped)")

    print("=== 2/3 打包 ===")
    if os.path.exists(out_path):
        os.remove(out_path)

    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in MODULE_FILES:
            path = os.path.join(ROOT, name)
            with open(path, "rb") as fh:
                data = fh.read()

            info = zipfile.ZipInfo(name)
            info.create_system = 3  # Unix：让 external_attr 里的权限位生效
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o755 if name.endswith(".sh") else 0o644) << 16
            zf.writestr(info, data)

            print(f"  + {name:<16} {len(data):>6} B")

    print("=== 3/3 校验 ===")
    with zipfile.ZipFile(out_path) as zf:
        corrupt = zf.testzip()
        if corrupt is not None:
            sys.exit(f"zip 损坏: {corrupt}")

        names = zf.namelist()
        print(f"  CRC 校验通过，{len(names)} 个条目")

        if "module.prop" not in names:
            sys.exit("module.prop 不在 zip 根目录，管理器会认不出模块")
        if any("/" in n for n in names):
            sys.exit("zip 内存在子目录，模块文件必须平铺在根目录")

        for info in zf.infolist():
            mode = info.external_attr >> 16
            print(f"  {oct(mode)}  {info.file_size:>6} B  {info.filename}")

    size = os.path.getsize(out_path)
    print(f"\n产物: {out_path}  ({size} B)")
    return out_path


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass

    parser = argparse.ArgumentParser(description="打包 Magisk 模块 zip")
    parser.add_argument(
        "--out",
        default=os.path.dirname(ROOT),
        help="输出目录，默认为仓库的上一级目录",
    )
    args = parser.parse_args()
    build(os.path.abspath(args.out))


if __name__ == "__main__":
    main()
