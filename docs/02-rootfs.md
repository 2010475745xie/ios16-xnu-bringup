# 02 · Build the iOS 16 root filesystem

You are turning an Apple IPSW into a 16 GB HFS+ image containing:

- the iOS root filesystem (141 app bundles, on a 16.7.16 iPhone X image)
- the `SystemOS` cryptex (frameworks + the 3.2 GB dyld shared cache)
- the `AppOS` cryptex (an overlay layer — tiny)
- log directories, a plain system keybag, and the bring-up tweaks

This image is what gets flashed to the phone's `userdata` partition.

---

## What you need

| | |
|---|---|
| IPSW | iPhone X (`iPhone10,3` / `iPhone10,6`), **iOS 16.7.16 (20H392)** |
| Disk | ~38 GB peak |
| Tools | everything from [01-environment.md](01-environment.md) |

The version matters: the port's patches assume the iOS 16.7.16 userland. Other
16.x builds mostly work but the ABI edges differ.

**Find the URL** (Apple rotates CDN paths):

```bash
curl -s 'https://api.ipsw.me/v4/device/iPhone10,3?type=ipsw' |
  python3 -c "import json,sys; [print(f['version'], f['build'], f['url'])
              for f in json.load(sys.stdin)['firmwares'] if f['version'].startswith('16.7.1')]"
```

> The endpoint `api.ipsw.me/v4/ipsw/iPhone10,3/16.7.16` returns 404 — it needs a
> *build* number, not a version. Use the device listing above instead.

Download it somewhere with room. Keep it — you need it again for the device tree.

## 1. Find the three volumes

An IPSW contains several `.dmg` files with pure-numeric names
(`087-86698-044.dmg`). Which is which is only recorded in `BuildManifest.plist`.

```bash
python3 scripts/prep-iosroot.py /path/to/ios16.ipsw
```

It parses the manifest (binary plist), matches `OS` / `Cryptex1,SystemOS` /
`Cryptex1,AppOS`, prints every `key → file` mapping, and — if name matching is
ambiguous — falls back to size ordering. **It writes nothing in this mode.**

Expected shape on a 16.7.16 iPhone X image:

| key | size |
|---|---|
| `OS` | ~4.4 GB |
| `Cryptex1,SystemOS` | ~2.6 GB |
| `Cryptex1,AppOS` | **~10 MB** |
| `RestoreRamDisk` | ~102 MB |

> **The 10 MB AppOS is correct.** iOS 16 cryptexes are overlay layers; the app
> bundles live in `OS.dmg`. See
> [pitfall 9](05-pitfalls.md#9-appos-in-the-ipsw-is-only-10-mb--that-is-correct).

## 2. Extract them

```bash
python3 scripts/prep-iosroot.py /path/to/ios16.ipsw --extract
```

Writes `~/work/dmgs/{OS,SystemOS,AppOS}.dmg`, resumable, skipping files that
already match.

**Extract into WSL's own filesystem, not `/mnt/c`.** WSL reaches Windows drives
over 9p, which is several times slower for the many-small-files workload that
follows.

### Sanity check before spending 20 minutes

```bash
bash scripts/verify-dmgs.sh
```

Mounts each volume read-only and checks the things that matter:

| Check | Expected |
|---|---|
| `OS.dmg` → `/Applications/*.app` | **100+ bundles** |
| `OS.dmg` → `usr/lib/dyld`, `System/Library/Frameworks/UIKit.framework` | present |
| `SystemOS.dmg` → `System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64` | present, ~3.2 GB across 40+ shards |
| `AppOS.dmg` → file count | small — an overlay, that is fine |

> **A11 has no `arm64e`.** iPhone X is an A11, so its cache is
> `dyld_shared_cache_arm64`, **without the trailing `e`**. `arm64e` is the A12+
> pointer-authentication variant. Looking for `...arm64e` reports a false
> negative.

If `OS` or `SystemOS` come back missing, stop — the volumes were mismatched.

## 3. Build the HFS+ image

```bash
sudo bash <ios-sweet>/tools/mkiosroot.sh \
    ~/work/dmgs/OS.dmg \
    ~/work/dmgs/SystemOS.dmg \
    ~/work/dmgs/AppOS.dmg \
    ~/work/ios16-root.img 16G
```

**15–30 minutes** — it rsyncs a few hundred thousand small files.

What it does:

1. Mounts each APFS volume through `apfs-fuse` (**LZBITMAP-compressed files are
   decompressed at mount time**)
2. `mkfs.hfsplus -s -J -v iOSRoot` — case-sensitive, journaled
3. `rsync -aH --numeric-ids` each root into place, preserving owners, modes,
   symlinks and hard links
4. Hard-links the `SystemOS` dyld cache into
   `/System/Library/Caches/com.apple.dyld` (no extra space)
5. Hard-links any cryptex file absent from the OS root
   (`libobjc-trampolines`, `libstdc++`, `libffi-trampolines`, …)
6. Creates logd's `diagnostics` / `uuidtext` directories owned by **272**
   (`_logd`), with `.migrated` markers — without these, `libtrace` aborts with
   `BUG IN LIBTRACE: Failed to migrate directory`
7. Writes a plain-text system keybag so `keybagd` starts without a passcode
8. Runs `fsck.hfsplus` to normalise decomposed non-ASCII filenames

### If it dies at `install: invalid user: '272'`

coreutils 9.x (Ubuntu 24.04+) rejects numeric `-o`/`-g`. The rsync has already
finished by then, so **do not re-run the whole thing** — use:

```bash
bash scripts/finish-iosroot.sh
```

It completes steps 6 and 7 against the existing image and then self-checks
11 paths (`launchd`, `dyld`, `UIKit`, `SpringBoard`, `/Applications`, the
hard-linked cache, both cryptexes, the keybag, logd's directory,
`libobjc-trampolines`).

## 4. fsck: what to worry about and what to ignore

```bash
sudo fsck.hfsplus -f -y ~/work/ios16-root.img
sudo fsck.hfsplus -f -n ~/work/ios16-root.img
```

- `-f -y` (write) reporting **`appears to be OK`** → the volume is structurally
  fine.
- `-f -n` (read-only) afterwards reporting **`Volume header needs minor repair`**
  → **ignore it.**

Linux HFS+ leaves the journal empty when it unmounts, so a read-only check
always sees "journal not replayed". XNU replays it at mount. What *would* be a
real problem is `Catalog hierarchy` or `Extents overflow` errors — those are
structural.

## 5. Apply the bring-up tweaks

```bash
sudo mount -t hfsplus -o loop,force ~/work/ios16-root.img /mnt/iosroot
sudo python3 <ios-sweet>/tools/sweet-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
```

It renames `_PanicOnCrash` on 7 daemons (so a crash logs instead of deadlocking),
removes the 2 `CommCenter` jobs (no baseband hardware), creates
`private/var/containers/*`, disables `VirtualAudio.plugin` and the
`MediaToolbox` recorder sub-servers, and presets migration / SpringBoard /
Setup-Assistant preferences.

**One warning is normal and expected:**

```
warning: no mobileactivationd system container in the image; skipped data ark
```

Activation on these ports goes through `mobileactivationd`'s local
**Hactivation** branch, driven by security-status values in the device tree — no
Apple servers, no activation record. **If the phone ever boots to the "Hello"
screen and refuses to proceed, this warning is the first thing to investigate.**

## 6. Convert to a sparse image

```bash
img2simg ~/work/ios16-root.img ~/work/ios16-root.simg
```

16 GB → roughly **12 GB** (iOS has almost no zero blocks to elide, so do not
expect 8 GB).

```bash
file ~/work/ios16-root.simg        # must say: Android sparse image
```

`fastboot` only accepts the sparse format.

## 7. Clean up

```bash
rm -f ~/work/dmgs/*.dmg            # ~9 GB
# keep the IPSW: you need DeviceTree.d22ap.im4p from it later
rm -f ~/work/ios16-root.img        # 16 GB, only if you keep the .simg
```

---

## Flashing (for reference)

```bash
fastboot -S 512M flash userdata ios16-root.simg
```

`-S 512M` is not optional: a 12 GB image in one transfer stalls the USB stack.
Many vendor fastboot implementations hang after a large flash — hold
power+volume-down to re-enter the bootloader. **This erases the phone's Android
user data.**

---

**Next:** [03-kernel.md](03-kernel.md) — build the kernel that mounts this image.
