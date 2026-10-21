#!/usr/bin/env python3
"""
prep-iosroot.py — 从 iPhone X 的 IPSW 里找出并提取 mkiosroot.sh 需要的三个 dmg
                  (OS / SystemOS / AppOS)。

用法:
    python3 prep-iosroot.py <xxx.ipsw>              # 只解析并列出，不写盘
    python3 prep-iosroot.py <xxx.ipsw> --extract    # 解析并解压到 ~/work/dmgs

为什么需要它:
    iOS 16 的 IPSW 里，这三个卷的文件名都是 `048-xxxxx-00N.dmg` 这种纯数字编号，
    光看名字分不出谁是谁。BuildManifest.plist 里有权威映射，但它是二进制 plist，
    且 iOS 16 起 cryptex 改了 key 名（可能是 SystemOS 也可能是 Cryptex1,SystemOS）。
    本脚本按 key 名 + 大小双重匹配，打印结果让你确认，再解压。
"""
import os
import plistlib
import sys
import zipfile

# 卷名 -> BuildManifest 里可能出现的 key 片段（按优先级）
CANDIDATES = {
    "OS":       ["Cryptex1,OS", "OS"],          # 主系统卷
    "SystemOS": ["Cryptex1,SystemOS", "SystemOS"],
    "AppOS":    ["Cryptex1,AppOS", "AppOS"],
}


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def load_manifest(z):
    with z.open("BuildManifest.plist") as f:
        return plistlib.load(f)


def collect_dmg_paths(manifest):
    """返回 {bundle-key: dmg-path}，取第一个 identity（Erase 那份）。"""
    ids = manifest.get("BuildIdentities") or []
    if not ids:
        raise SystemExit("BuildManifest.plist 里没有 BuildIdentities")
    # 优先挑 Erase / Customer 那份，回退第一条
    ident = None
    for i in ids:
        variant = (i.get("Info") or {}).get("Variant", "")
        if "Erase" in variant or "Customer" in variant:
            ident = i
            break
    ident = ident or ids[0]

    out = {}
    for key, val in (ident.get("Manifest") or {}).items():
        info = val.get("Info") if isinstance(val, dict) else None
        path = (info or {}).get("Path")
        if path and path.lower().endswith(".dmg"):
            out[key] = path
    return out


def pick_volumes(paths, sizes):
    """按 key 名匹配三个卷，匹配不到就用大小兜底。"""
    chosen = {}
    used = set()
    for vol, needles in CANDIDATES.items():
        hit = None
        for needle in needles:
            # 精确同名优先，其次包含（但不让 "SystemOS" 吃掉 "OS"）
            for k in paths:
                if k in used:
                    continue
                if k == needle or (needle != "OS" and needle in k):
                    hit = (k, paths[k])
                    break
            if hit:
                break
        if hit:
            chosen[vol] = hit
            used.add(hit[0])

    # 兜底：剩下的 dmg 按大小排，最大的两个是 OS / SystemOS，第三大的是 AppOS
    if len(chosen) < 3:
        rest = sorted(
            ((k, v) for k, v in paths.items() if k not in used),
            key=lambda kv: sizes.get(kv[1], 0),
            reverse=True,
        )
        order = [v for v in ("OS", "SystemOS", "AppOS") if v not in chosen]
        # 大 -> 小 依次补
        for vol, (k, v) in zip(order, rest):
            chosen[vol] = (k, v)
    return chosen


def main():
    args = [a for a in sys.argv[1:]]
    if not args:
        print(__doc__)
        return 2
    ipsw = args[0]
    do_extract = "--extract" in args
    outdir = os.path.expanduser("~/work/dmgs")
    if "--out" in args:
        outdir = args[args.index("--out") + 1]

    if not os.path.isfile(ipsw):
        print(f"找不到 IPSW: {ipsw}", file=sys.stderr)
        print("先下载：见 WSL2-HFS环境搭建.md 或 build-iosroot 清单里的 URL", file=sys.stderr)
        return 1

    size_total = os.path.getsize(ipsw)
    print(f"IPSW : {ipsw}")
    print(f"大小 : {human(size_total)}")

    with zipfile.ZipFile(ipsw) as z:
        infos = {i.filename: i for i in z.infolist()}
        dmgs = {n: i for n, i in infos.items() if n.lower().endswith(".dmg")}
        print(f"\nIPSW 内共 {len(dmgs)} 个 .dmg：")
        for n, i in sorted(dmgs.items(), key=lambda kv: -kv[1].file_size):
            print(f"  {human(i.file_size):>10}  {n}")

        manifest = load_manifest(z)
        paths = collect_dmg_paths(manifest)
        sizes = {n: i.file_size for n, i in dmgs.items()}
        chosen = pick_volumes(paths, sizes)

    print("\n=== BuildManifest 里的 dmg 卷（key -> 文件）===")
    for k in sorted(paths):
        print(f"  {k:30s} {paths[k]:24s} {human(sizes.get(paths[k], 0))}")

    print("\n=== 选中的三个卷 ===")
    ok = True
    for vol in ("OS", "SystemOS", "AppOS"):
        if vol in chosen:
            key, path = chosen[vol]
            print(f"  {vol:<9} <- {path}   ({human(sizes.get(path, 0))})   [key: {key}]")
            if path not in dmgs:
                print(f"     !! 警告：{path} 不在 IPSW 的 dmg 列表里")
                ok = False
        else:
            print(f"  {vol:<9} <- 未找到")
            ok = False

    if not ok:
        print("\n匹配不完整。请把上面两份列表贴出来，人工确认。", file=sys.stderr)
        return 1

    space_need = sum(sizes[p] for _, p in chosen.values()) + 2 * 1024**3
    st = os.statvfs(os.path.expanduser("~")) if hasattr(os, "statvfs") else None
    if st:
        free = st.f_bavail * st.f_frsize
        print(f"\n预计解压需要 {human(space_need)}，WSL 可用 {human(free)}")
        if free < space_need:
            print("空间不足！先清理再继续。", file=sys.stderr)
            return 1

    if not do_extract:
        print("\n（只解析，未解压。确认无误后加 --extract 重跑）")
        return 0

    os.makedirs(outdir, exist_ok=True)
    print(f"\n=== 解压到 {outdir} ===")
    for vol in ("OS", "SystemOS", "AppOS"):
        _, path = chosen[vol]
        dst = os.path.join(outdir, f"{vol}.dmg")
        if os.path.exists(dst) and os.path.getsize(dst) == sizes[path]:
            print(f"  {vol}: 已存在，跳过")
            continue
        print(f"  {vol}: {path} -> {dst}  ({human(sizes[path])}) ...", flush=True)
        with zipfile.ZipFile(ipsw) as z, z.open(path) as src, open(dst, "wb") as out:
            n = 0
            while True:
                chunk = src.read(8 * 1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
                n += len(chunk)
                if n % (512 * 1024 * 1024) < 8 * 1024 * 1024:
                    print(f"    {human(n)} / {human(sizes[path])}", flush=True)
        print(f"    完成: {human(os.path.getsize(dst))}", flush=True)

    print("\n三个 dmg 就绪。下一步：")
    print(f"  sudo bash ~/ios-sweet/tools/mkiosroot.sh \\")
    print(f"      {outdir}/OS.dmg {outdir}/SystemOS.dmg {outdir}/AppOS.dmg \\")
    print(f"      ~/work/ios16-root.img 16G")
    return 0


if __name__ == "__main__":
    sys.exit(main())
