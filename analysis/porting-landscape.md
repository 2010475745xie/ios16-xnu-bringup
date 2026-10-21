# Porting landscape

A snapshot of the projects doing this work, and the technical split that decides
how each one is structured. Figures are from GitHub's API on 2026-10-21 and will
age — treat the reasoning as the durable part, not the numbers.

---

## The family

All of these descend from one project. `ios-sweet` bootstrapped the technique in
mid-October 2026 and was forked into per-device ports within days.

| Project | Device | SoC | Reached | Touch |
|---|---|---|---|---|
| [`dipa-studio/ios-sweet`](https://github.com/dipa-studio/ios-sweet) | Redmi Note 10 Pro (`sweet`) | SM7150 / 732G | home screen | ✅ Goodix GT9896 |
| [`MakrSas/ios-topaz`](https://github.com/MakrSas/ios-topaz) | Redmi Note 12 4G (`topaz`) | SM6225 / 685 | lock screen | ⚠️ driver written, unverified |
| [`edi194/ios-fajita`](https://github.com/edi194/ios-fajita) | OnePlus 6T (`fajita`) | SDM845 | stops inside `kdp_init` | ❌ |
| [`ch1tmdgus/ios-v60`](https://github.com/ch1tmdgus/ios-v60) | LG V60 (`timelm`) | SM8250 / 865 | **GUI + touch + buttons** | ✅ SW42902 over GPIO bit-banged I²C |
| [`UniXNU/UniXNU`](https://github.com/UniXNU/UniXNU) | Xiaomi Pad 6S Pro (`sheng`) | SM8550 | UEFI + payload load | — |
| [`NekoWannn/xnu-hongkong`](https://github.com/NekoWannn/xnu-hongkong) | Xiaomi (SM8950) | SM8950 | unknown | — |
| [`palazik/ios-dodge-old`](https://github.com/palazik/ios-dodge-old) | OnePlus 13 (`dodge`) | SM8750 | unknown | — |
| [`sbccc1888/sweet-uefi`](https://github.com/sbccc1888/sweet-uefi) | Xiaomi Mi MIX 2 | MSM8998 | UEFI layer only | — |

`ios-sweet` is the reference implementation: 616 stars, 227 forks, created
2026-10-14. Everything else either forks it or borrows its patch series.

**None of the forks carries a licence.** GitHub's API reports `"license": null`
for the whole family, which means all rights reserved. Reading, learning, forking
on the platform, and sending pull requests are fine; republishing a modified tree
is not.

## Three gates, and only one of them is about hardware

Getting iOS onto an arbitrary phone requires clearing three independent
obstacles. People usually talk about the third one and skip the first two.

| Gate | Requirement | Who fails it |
|---|---|---|
| **1. Can you flash it?** | Bootloader unlock | Huawei / Honor: no unlock channel since 2018. Oppo / vivo: none. Most Chinese-market devices: closed |
| **2. Is there a port?** | Someone wrote a shim, machine config and drivers for *this* model | Any device not in the table above |
| **3. Does it run?** | UFS, touch, display, buttons, power | Everyone, until they finish |

A device that clears gate 1 but not gate 2 means writing a full driver stack
yourself. Gate 2 is what "buying a supported phone" actually buys.

## The technical split: 16K vs 4K pages

This single decision shapes every port, and it is decided by the silicon, not by
preference.

iOS uses **16 KiB pages** for kernel and userland on arm64. Whether your CPU can
do that depends on its implementation of the ARMv8 translation granule:

| Device | Cores | Arch | 16K granule | Result |
|---|---|---|---|---|
| `sweet` | A76 ×2 + A55 ×6 | v8.2 | ✅ both clusters | 8 cores usable, all 16K |
| `topaz` | A73 ×4 + A53 ×4 | v8.0 | A73 ✅, A53 ❌ (`TGran16 = 0`) | A53s parked in `wfi`; only 4 × A73 |
| `fajita` | A75 ×4 + A55 ×4 | v8.2 | ✅ | 8 possible |
| `v60` | A77 ×1 + A77 ×3 + A55 ×4 | v8.2 | ✅ | — |

Two opposite mitigations exist:

**A. Keep 16K and drop the cores that cannot do it.**
`topaz` does this: the boot shim wakes the Gold cluster with `PSCI CPU_ON`, parks
the Silver cores, and hands off. Simple, and costs half the CPU.

**B. Convert the kernel to 4 KiB pages.**
`UniXNU` does this, and it is much harder than changing a constant:

| # | Change | File |
|---|---|---|
| 1 | drop `__ARM_16K_PG__` from the board header | `SWEET.h` |
| 2 | `PAGE_SHIFT_CONST`, `page_shift_user32` | `osfmk/arm/arm_init.c` |
| 3 | commpage `USER_PAGE_SHIFT_64` | `osfmk/arm/commpage/commpage.c` |
| 4 | `vm_map_set_page_shift` × 2 | `mach_loader.c`, `vm_shared_region.c` |
| 5 | **derive 4K code-signature hashes** | `bsd/kern/ubc_subr.c` |
| 6 | bootstrap page-table capacity | `pmap.h`, `start.s` |
| 7 | reassess shared-cache layout, IOSurface, HFS+ block size, libpthread guard pages | port-specific patches |

**Step 5 is the one that stops people.** The CodeDirectory that signs every Apple
binary hashes content in 16 KiB blocks (`pageSize` in the blob). A 4K kernel
faulting pages in 4K units looks for hashes that do not exist and rejects every
executable with `EBADEXEC`.

`UniXNU`'s solution is worth understanding even if you never switch to 4K:
authenticate each original 16 KiB block against the signed hash first, then
derive 4K sub-hashes from the *same, already-verified* buffer, publish the
derived table read-only, and serve faults from it with no vnode I/O. The security
model is unchanged — the derived table is a repartition of verified bytes.

**Practical upshot:** converting to 4K buys you cores you may not need and costs
you the hardest patch in the series. Only do it if the hardware forces it.

## What is still broken everywhere

- **Leaving an app.** `sweet` boots to the home screen but cannot get out of one:
  neither the home gesture nor AssistiveTouch's Home does anything. Since Control
  Centre works (same system-gesture manager), the HID path is presumably fine and
  the failure is in the workspace transition. Unverified — this needs runtime
  logs from a device.
- **Wallpaper.** `v60` reports black wallpaper, unresolved.
- **Settings → General → About.** `v60` freezes there.
- **Wi-Fi / Bluetooth.** `v60` is furthest along on QCA6390: internal SE6 UART
  transmit/receive verified on-device; power and HCI version query pending;
  connectivity and pairing not implemented.
- **Audio, camera, sensors, GPU.** No port has these.

## Where the leverage is

If you have no device, the useful contributions are the ones that do not need
one: host-side tooling, documentation, patch review, and the QEMU harness. If you
have a device, the useful contributions are the four items in the list above —
each of which is a bounded problem with a clear success condition.
