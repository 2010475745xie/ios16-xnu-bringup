# The ten traps

Every one of these cost real time. They are ordered roughly by how long they
took to diagnose, not by how likely you are to hit them — you will probably hit
all ten.

---

## 1. A non-ASCII path silently writes to a different directory

**Symptom.** A helper script runs, reports success, and the expected file is not
there — but an identical file appears somewhere else.

**Cause.** Intermediate `cmd`/`powershell` invocations get the path in the
console code page (GBK/cp936), then something re-decodes it as UTF-8. The bytes
survive but the string changes, so the "same" path resolves to a second
directory.

**Fix.** Keep the working tree at a pure-ASCII path. On Windows,
`C:\Users\Public\...` works without elevation and is always ASCII. Never run a
build script with a CJK user profile (`C:\Users\张伟\...`) as its working
directory.

This also bites Gradle (`@argfile` paths double-encoded → empty classpath), so it
is not specific to this project.

---

## 2. Under `sudo`, `$HOME` is `/root`

**Symptom.** `sudo bash tool.sh` reports `找不到镜像: /root/work/ios16-root.img`
or silently writes output into `/root`.

**Cause.** `sudo` resets `HOME` to the target user's home. Every `~` and `$HOME`
in the script now points at `/root`.

**Fix.** Resolve the caller's home explicitly:

```bash
if [[ ${EUID:-$(id -u)} -eq 0 && -n "${SUDO_USER:-}" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME=${HOME}
fi
```

Or just pass absolute paths as arguments.

---

## 3. `sudo` cannot see anything installed in `~/.local/bin`

**Symptom.**

```
Error: missing required host utilities: apfs-fuse
```

…while `apfs-fuse --version` works fine as your normal user.

**Cause.** `sudo` uses `secure_path`
(`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`), which does not
include `~/.local/bin`. A tool the script compiled locally is invisible to it.

**Fix.** Install into a directory that *is* on `secure_path`:

```bash
sudo install -m 755 ~/.local/bin/apfs-fuse /usr/local/bin/apfs-fuse
```

Or run with `sudo env PATH="$PATH" bash ...`.

---

## 4. `install -o 272` fails on coreutils 9.x

**Symptom.**

```
install: invalid user: '272'
```

**Cause.** Ubuntu 26.04 ships coreutils 9.x, which resolves `-o`/`-g` through
`/etc/passwd` instead of accepting a raw numeric ID. `272` is `_logd` on iOS, a
user that does not exist on Linux. Older coreutils (22.04, 8.x) accepted it.

**Fix.** Split creation from ownership — `chown` still accepts raw IDs:

```bash
sudo install -d -m 0751 "$db/diagnostics"
sudo chown 272:272 "$db/diagnostics"
```

This one is load-bearing: `mkiosroot.sh` uses `set -e`, so the failure aborts the
script **after** the 20-minute rsync, leaving the image without log directories
or a keybag.

---

## 5. `gh` resolves a fork clone to its upstream

**Symptom.**

```
could not create workflow dispatch event: HTTP 403: Must have admin rights to Repository
(https://api.github.com/repos/dipa-studio/ios-sweet/actions/...)
```

Note the repo in the URL — that is the **upstream**, not your fork.

**Cause.** Inside a fork's clone, `gh` deliberately resolves the "current
repository" to the parent. Changing `git remote set-url origin` does not help,
because the resolution does not read git remotes.

**Fix.** Explicit override, on every command:

```bash
gh workflow run xnu.yml -R <you>/ios-sweet
gh run list -R <you>/ios-sweet
gh run download -R <you>/ios-sweet -n xnu-kernel -D xnu/out
```

…or once per shell:

```bash
export GH_REPO=<you>/ios-sweet
```

---

## 6. A forked repository has Actions disabled

**Symptom.** `gh workflow list` prints `no workflows found`, or
`gh workflow run` fails with "workflow not found".

**Cause.** GitHub disables workflows on forks by default, as a supply-chain
protection.

**Fix.** Open `https://github.com/<you>/<repo>/actions` and click the yellow
banner's **"I understand my workflows, go ahead and enable them"**. Allow ~30 s
for propagation.

---

## 7. `git clone` of the WSL kernel runs at 19 KiB/s

**Symptom.** `Receiving objects: 7% (6300/86644), 4.08 MiB | 19.00 KiB/s` — and
it never finishes.

**Cause.** `microsoft/WSL2-Linux-Kernel` is a full Linux tree. Even with
`--depth=1` it is ~200 MB, and object negotiation over a throttled path is slow.

**Fix.** Fetch a tarball through a mirror instead of cloning:

```bash
for gp in https://ghfast.top https://gh-proxy.com https://ghproxy.net; do
    url="$gp/https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/heads/$BR.tar.gz"
    curl -L --fail -o /tmp/wslk.tar.gz "$url" && break
done
tar -xzf /tmp/wslk.tar.gz -C "$src" --strip-components=1
```

A tarball is one streaming connection: no negotiation, no delta resolution.
Observed 140 KiB/s through `ghfast.top` where direct clone managed 19.

---

## 8. The kernel branch must match the running WSL kernel

**Symptom.** After building and installing your own `bzImage`, WSL either fails
to boot or behaves strangely.

**Cause.** The hardcoded branch is `linux-msft-wsl-6.6.y`, but a 2026 WSL ships
`6.18.x`. Booting a 6.6 kernel under a 6.18 WSL is unsupported.

**Fix.** Derive the branch from the running kernel:

```bash
BR="linux-msft-wsl-$(uname -r | cut -d. -f1-2).y"   # 6.18.54.1-... -> 6.18
```

**Follow-on trap.** `tools/lib/bpf/libbpf.c` was changed upstream between those
branches. On 6.6 it declares `char *next_path;` and GCC 15's
`-Werror=duplicate-decl-specifier` wants `const`. On 6.18 it is **already**
`const`, so an unconditional `sed 's/char \*next_path;/const char *next_path;/'`
produces `const const char *next_path;` and the build dies:

```
libbpf.c:12172:31: error: duplicate 'const' declaration specifier
```

Make the patch idempotent — collapse doubles first, then add only where absent:

```bash
sed -i 's/const const char \*next_path;/const char *next_path;/' tools/lib/bpf/libbpf.c
grep -qE '^[[:space:]]*char \*next_path;' tools/lib/bpf/libbpf.c &&
    sed -i 's/^\([[:space:]]*\)char \*next_path;/\1const char *next_path;/' tools/lib/bpf/libbpf.c
```

---

## 9. `AppOS` in the IPSW is only 10 MB — that is correct

**Symptom.** You extract the three volumes and `Cryptex1,AppOS` is 10 MB while
`OS` is 4.4 GB and `Cryptex1,SystemOS` is 2.6 GB. It looks like the wrong file.

**Cause.** It is the right file. Since iOS 16, cryptexes are overlay layers: the
system apps live in `OS.dmg` under `/Applications`, and the `AppOS` cryptex
carries only what changed since the base. On a late 16.x security build that is
tiny.

**Verification.** Mount it and check that the content makes sense:

```bash
sudo apfs-fuse AppOS.dmg /mnt/appos
sudo find /mnt/appos/root -type f | wc -l
```

You should see a handful of Safari-related binaries
(`SafariSupport.bundle`, `safarifetcherd`, `webbookmarksd`), not thousands of
files. The full app set is on `OS.dmg` — check `/Applications` there and expect
100+ `.app` bundles.

**How to tell the difference from a real mistake.** Trust `BuildManifest.plist`:
if `Cryptex1,AppOS`'s `Info.Path` points at the 10 MB file, that *is* the AppOS
volume. A mismatch between the manifest and your guess is the real red flag.

---

## 10. The ADT has no panic region, and the kernel hangs without one

**Symptom.** The kernel initialises everything, then stops dead:

```
VM bootstrap done: 85 maps, 165 entries and 502 holes left
...
debug_log_init: Error!! gPanicBase is still not initialized
debug_log_init: Error!! gPanicBase is still not initialized
kdp_core zlib memory 0x8000
```

It does not crash and it does not advance. `qemu.log` grows to tens of megabytes
of repeated exceptions on the same ELR.

**Cause.** `mkadt.py` never emits a panic log region, so
`pexpert/arm/pe_init.c:check_for_panic_log()` leaves `gPanicBase == 0`.

**Fix.** See [`patches/mkadt-panic-region.diff`](../patches/mkadt-panic-region.diff):
carve 1 MiB off the top of the ADT dram range and describe it as `/pram` +
`/chosen/embedded-panic-log-size`.

**Why it matters beyond QEMU.** Without a panic region there is no panic buffer
and no CRC. When the real device eventually panics, you get nothing to
symbolicate. Fix it before you ever flash a phone.

---

## Honourable mentions

- **`wsl --install` asks for a Linux username and rejects digits-only.** Start
  with a lowercase letter.
- **`fastboot flash userdata` of a 12 GB sparse image needs `-S 512M`.** One
  shot will stall the USB stack.
- **WSL's `ext4.vhdx` grows and never shrinks.** Expect 40 GB+ after a rootfs
  build; `wsl --manage <distro> --resize` only grows.
- **`ipsw` is a single static binary — `tar -xzf` does not put it on `PATH`.**
  `sudo install -m 755 ipsw /usr/local/bin/ipsw`.
- **`dtc -I dtb` cannot parse an Apple ADT.** An empty dump is not a failure;
  verify with `strings` instead.
