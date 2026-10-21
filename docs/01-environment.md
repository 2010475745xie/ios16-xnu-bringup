# 01 · Host environment (Windows 11 + WSL2)

Goal: a Linux environment that can mount and write **HFS+**, because the iOS
root filesystem is built as a case-sensitive journaled HFS+ volume and Linux's
stock WSL kernel cannot mount it.

No Mac. No separate Linux machine. No VM.

---

## Prerequisites

| | |
|---|---|
| OS | Windows 10 2004+ or 11, virtualization enabled in firmware |
| Disk | **45–50 GB free on C:** (the root image alone is 16 GB) |
| RAM | 8 GB minimum; 16 GB comfortable |
| Network | WSL needs to reach Ubuntu mirrors and GitHub |

Put the working tree on a **pure-ASCII path**. `C:\Users\Public\iosxnu` needs no
elevation and is always ASCII — see
[pitfall 1](05-pitfalls.md#1-a-non-ascii-path-silently-writes-to-a-different-directory).

```powershell
mkdir C:\Users\Public\iosxnu
```

Clone this repository there, or copy `scripts/` into it.

## 1. Install WSL2 + Ubuntu

In an **administrator** PowerShell:

```powershell
wsl --install -d Ubuntu
```

Reboot when asked. On first launch Ubuntu asks for a username and password:

- **The username must start with a lowercase letter.** Digits-only is rejected
  with `Invalid username`.
- Pick something ASCII. This becomes `/home/<you>`, which is where the kernel
  source and the root image will live.

Verify:

```powershell
wsl -l -v
```

`VERSION` must be `2`. If it says 1: `wsl --set-version Ubuntu 2`.

## 2. Write `.wslconfig`

Create `%USERPROFILE%\.wslconfig` (this file is read by Windows, so its own path
being non-ASCII is fine):

```ini
[wsl2]
memory=16GB
processors=8
swap=8GB
networkingMode=mirrored
autoProxy=true
```

- `networkingMode=mirrored` — WSL shares the host network stack. Without it, a
  host-side localhost proxy is unreachable from Linux and every `apt`/`git`
  operation times out.
- `autoProxy=true` — inherits the Windows proxy settings automatically.
- **Do not add `kernel=` yet.** That line goes in after step 3, once the image
  exists. A `kernel=` pointing at a missing file prevents WSL from starting.

Apply:

```powershell
wsl --shutdown
wsl -d Ubuntu
```

```bash
free -g          # total should match the memory= you set
nproc
```

## 3. Build a WSL kernel with HFS+

Stock WSL cannot mount HFS+: `CONFIG_HFSPLUS_FS` is off. `hfsfuse` exists but is
read-only, and the root image must be written.

```bash
cd /mnt/c/Users/Public/iosxnu
bash scripts/wsl-check.sh        # 7-point check; changes nothing
bash scripts/wsl-go.sh           # takes ~10-15 min
```

`wsl-go.sh` does, in order:

1. Probes the network — domestic mirrors and GitHub separately, since a
   Google-based probe fails in mainland China and would be misread as "no
   network".
2. Falls back to probing common proxy ports (`127.0.0.1:3067`, `:7890`, …) if
   `mirrored` did not work.
3. Repoints apt at `mirrors.aliyun.com`.
4. Installs the toolchain: cross GCC, `hfsprogs`, `rsync`,
   `android-sdk-libsparse-utils`, `device-tree-compiler`, `dwarves`, `llvm`,
   `apfs-fuse` (source build if apt has no package), `mkbootimg`.
5. Downloads `microsoft/WSL2-Linux-Kernel` **as a tarball through a mirror**
   (a plain `git clone` runs at ~19 KiB/s — see
   [pitfall 7](05-pitfalls.md#7-git-clone-of-the-wsl-kernel-runs-at-19-kibs)).
6. Derives the branch from `uname -r`, so a 6.18 WSL builds from
   `linux-msft-wsl-6.18.y` rather than the hardcoded 6.6.
7. Enables `CONFIG_HFSPLUS_FS=y`, fixes the `const const` libbpf breakage
   ([pitfall 8](05-pitfalls.md#8-the-kernel-branch-must-match-the-running-wsl-kernel)),
   and builds **only `bzImage`** — the `all` target spends ~20 minutes on
   AMDGPU modules you do not need.
8. Copies the result to `~/ios16-xnu-bringup/wsl-hfsplus-bzImage`.

## 4. Point WSL at the new kernel

Add to `%USERPROFILE%\.wslconfig`:

```ini
kernel=C:/Users/Public/iosxnu/wsl-hfsplus-bzImage
```

Use **forward slashes**. INI parsing and backslash escaping interact badly, and
forward slashes always work.

```powershell
wsl --shutdown
wsl -d Ubuntu
```

## 5. Verify

```bash
grep hfs /proc/filesystems
```

Must print both:

```
nodev	hfs
	nodev	hfsplus
```

If only `hfs` appears, the new kernel did not load — re-check the `kernel=` path
and that `wsl --shutdown` actually ran.

Then prove it is writable, not just present:

```bash
dd if=/dev/zero of=/tmp/t.img bs=1M count=200
mkfs.hfsplus /tmp/t.img
sudo mkdir -p /tmp/mnt
sudo mount -t hfsplus -o loop,force /tmp/t.img /tmp/mnt
sudo touch /tmp/mnt/hello && ls /tmp/mnt
sudo umount /tmp/mnt && rm -f /tmp/t.img
```

Seeing `hello` means the environment is ready.

## Disk budget

| Stage | Cumulative |
|---|---|
| IPSW (iPhone X, iOS 16.7.16) | 6 GB |
| three extracted `.dmg` files | 14 GB |
| 16 GB root image, mid-build | 30 GB |
| sparse image written | 38 GB peak |
| after cleanup | 14 GB (IPSW + `.simg`) |

WSL stores all of this inside `ext4.vhdx` under
`%LOCALAPPDATA%\Packages\...`, **which grows but never shrinks**. Expect 40 GB+
and do not be alarmed. `wsl --manage Ubuntu --resize 60GB` only ever grows it.

---

**Next:** [02-rootfs.md](02-rootfs.md)
