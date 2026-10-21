# ios16-xnu-bringup

Build notes and tooling for getting Apple's XNU kernel plus an iOS 16 userland
running on non-Apple ARM64 phones — specifically, everything on the **host side**
(building the root filesystem, building the kernel, verifying it in QEMU) that
does **not** require the target phone.

> ## This repository contains no Apple binaries.
>
> No IPSWs, no iOS root images, no device trees, no kernels, no userland.
> You must obtain your own IPSW from Apple and build everything yourself.
> That is deliberate — see [Licensing and scope](#licensing-and-scope).

---

## What this is

The USB/phone side of these ports is covered well by the upstream projects. What
is *not* covered is the road from a fresh Windows install to a bootable root
filesystem — and that road is full of traps that cost hours each.

This repo is that road, written down:

- a working host setup for **Windows 11 + WSL2** (no Mac, no Linux box)
- a **build pipeline** for the iOS 16 root filesystem on HFS+
- the exact **GitHub Actions** recipe for compiling XNU without a Mac
- a **QEMU harness** for testing kernel changes before touching hardware
- one **real upstream bug** we found and fixed, with reproduction steps

## Verified environment

Everything here was exercised on:

| | |
|---|---|
| Host | Windows 11, build 26200, x86-64, 32 GB RAM |
| WSL | Ubuntu 26.04 LTS, kernel 6.18.54.1 (custom bzImage, HFS+ enabled) |
| Target userland | iPhone X (`iPhone10,3` / D22AP), iOS 16.7.16 (20H392) |
| XNU baseline | xnu-8796 (`dipa-studio/ios-sweet`) |
| QEMU | 10.2.1, `virt` machine, cortex-a76 |

Ubuntu **22.04** and **24.04** are easier (their stock kernels ship `hfsplus`
in `linux-modules-extra`). 26.04 is what forced the custom bzImage route.

## Quick start

```bash
git clone <this repo> ~/ios16-xnu-bringup
cd ~/ios16-xnu-bringup

bash scripts/wsl-check.sh          # 7-point health check, changes nothing
bash scripts/wsl-go.sh             # packages + apfs-fuse + HFS+ bzImage
```

Then work through the docs in order:

| # | Doc | What you end up with |
|---|---|---|
| 01 | [docs/01-environment.md](docs/01-environment.md) | WSL2 with a writable HFS+ |
| 02 | [docs/02-rootfs.md](docs/02-rootfs.md) | a 16 GB `ios16-root.img` + `.simg` |
| 03 | [docs/03-kernel.md](docs/03-kernel.md) | `kernel.development.sweet`, 17 MB |
| 04 | [docs/04-qemu.md](docs/04-qemu.md) | kernel boot verified without a phone |
| 05 | [docs/05-pitfalls.md](docs/05-pitfalls.md) | the ten traps, so you skip them |

## Layout

```
docs/        the five documents above
scripts/     host-side automation (WSL setup, rootfs build, verification)
patches/     fixes for upstream projects, as unified diffs
analysis/    cross-project comparisons and one failure diagnosis
```

## The one real bug we found

`dipa-studio/ios-sweet`'s `tools/mkadt.py` never emits a panic log region. XNU's
`pexpert/arm/pe_init.c:check_for_panic_log()` therefore leaves `gPanicBase == 0`,
`debug_log_init()` bails out, and the kernel stops making progress inside
`kdp_init`:

```
debug_log_init: Error!! gPanicBase is still not initialized
debug_log_init: Error!! gPanicBase is still not initialized
kdp_core zlib memory 0x8000
```

Two consequences: **no panic logs at all** (nothing to symbolicate after a
crash), and an **early hang** that blocks QEMU entirely and, according to
`ios-fajita`'s notes, the OnePlus 6T port too.

The fix is in [`patches/mkadt-panic-region.diff`](patches/mkadt-panic-region.diff)
— four hunks, +13 −1 lines: carve 1 MiB off the top of the ADT dram range and
describe it as `/pram` plus `/chosen/embedded-panic-log-size`.

Verified: `grep -c gPanicBase fb.txt` goes from **2 → 0**, and the last log line
moves from `kdp_core zlib memory 0x8000` to
`Serial requested ... configuring debugging over serial`.

## What this repo deliberately does not do

- It does **not** distribute iOS, IPSWs, root images, device trees or kernels.
- It does **not** provide an installation procedure for any specific phone —
  that depends on the device, its bootloader, and the upstream port you use.
- It does **not** claim the QEMU harness reaches userland. It does not: `virt`
  has no UFS, its `CNTFRQ` is 62.5 MHz instead of the board's 19.2 MHz, and the
  debug UART address is unmapped. Kernel-only verification is the goal.

## Upstream projects this builds on

| Project | Device | Notes |
|---|---|---|
| [`dipa-studio/ios-sweet`](https://github.com/dipa-studio/ios-sweet) | Redmi Note 10 Pro (SM7150) | the mother project; everything here assumes its layout |
| [`MakrSas/ios-topaz`](https://github.com/MakrSas/ios-topaz) | Redmi Note 12 4G (SM6225) | ARMv8.0 variant |
| [`edi194/ios-fajita`](https://github.com/edi194/ios-fajita) | OnePlus 6T (SDM845) | best WSL2 notes of the four |
| [`ch1tmdgus/ios-v60`](https://github.com/ch1tmdgus/ios-v60) | LG V60 (SM8250) | GUI + touch confirmed; excellent touch/wireless logs |
| [`UniXNU/UniXNU`](https://github.com/UniXNU/UniXNU) | Xiaomi Pad 6S Pro (SM8550) | different approach: native kexts + prelinked Apple kernelcache |
| [`blacktop/ipsw`](https://github.com/blacktop/ipsw) | — | firmware/dyld tooling used throughout |
| [`blacktop/darwin-xnu-build`](https://github.com/blacktop/darwin-xnu-build) | — | the CI build script |

None of them carry a licence that permits redistributing their code as part of
another project, so this repo links to them rather than vendoring them.

## Licensing and scope

The scripts and documents in this repository are released under the **MIT
licence** (see `LICENSE`). They are original work.

They operate on Apple's copyrighted material, which is **not** covered by that
licence and **not** included here. If you use these tools you are the one
fetching Apple's IPSW, and Apple's terms apply to it.

This is study and interoperability work, in the same spirit as the Hackintosh
community sharing EFI configurations while never shipping macOS. Distribute the
method, not the artifact.

Nothing here is legal advice.
