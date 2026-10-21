# Patches

Fixes for upstream projects, as unified diffs against the version they were
written for.

| Patch | Status |
|---|---|
| `mkadt-panic-region.diff` | ✅ **Merged upstream** — [`dipa-studio/ios-sweet#6`](https://github.com/dipa-studio/ios-sweet/pull/6), 2026-10-21 (commit `1664d638`) |

Apply with:

```bash
cd <upstream checkout>
git apply --check /path/to/mkadt-panic-region.diff   # dry run first
git apply /path/to/mkadt-panic-region.diff
```

---

## `mkadt-panic-region.diff`

**Target:** `dipa-studio/ios-sweet`, `tools/mkadt.py`
**Applies to:** the tree as of 2026-10-19 (xnu-8796 baseline)
**Size:** 4 hunks, +13 −1

### Problem

`mkadt.py` build the Apple Device Tree the kernel boots from, but never emits a
panic log region. XNU's `pexpert/arm/pe_init.c:check_for_panic_log()` looks for
`/pram` and `/chosen/embedded-panic-log-size`; finding neither, it leaves
`gPanicBase == 0` and `debug_log_init()` bails out:

```
debug_log_init: Error!! gPanicBase is still not initialized
debug_log_init: Error!! gPanicBase is still not initialized
kdp_core zlib memory 0x8000
```

Two consequences:

1. **No panic logs.** No buffer, no CRC — nothing to symbolicate after a crash.
   On a port that panics constantly during bring-up, that is crippling.
2. **Early hang.** On QEMU `virt` the kernel never proceeds past `kdp_init`. It
   re-enters the same fault forever: `qemu.log` (every exception, `-d
   int,guest_errors`) reaches tens of megabytes within minutes.

`ios-fajita`'s `NOTES-FAJITA.md` documents an identical stall on the OnePlus 6T,
and applies the same `PANIC_LOG_SIZE` / `/pram` /
`embedded-panic-log-size` workaround — but only in that fork.

### Fix

Carve 1 MiB off the top of the ADT dram range and describe it:

| Change | Detail |
|---|---|
| constant | `PANIC_LOG_SIZE = 0x100000` |
| memory split | `panic_base = phys_base + mem_size - PANIC_LOG_SIZE`; `mem_size -= PANIC_LOG_SIZE` |
| `/chosen` | add `embedded-panic-log-size` |
| root node | add `pram` with `reg = <panic_base PANIC_LOG_SIZE>` |

Because the region is carved out of the `dram-size` that is *published* to the
kernel, XNU maps the buffer but never allocates into it.

### Verified

Using `tools/qemu-sweet.py` with a `--qemu` ADT and xnu-8796:

| | before | after |
|---|---|---|
| `grep -c gPanicBase fb.txt` | 2 | **0** |
| last line of `fb.txt` | `kdp_core zlib memory 0x8000` | `Serial requested ... configuring debugging over serial` |

The kernel still stops later in QEMU — that is the absence of real hardware
(no UFS, `CNTFRQ` 62.5 MHz vs 19.2 MHz, unmapped debug UART), not this change.

### Why it is worth applying even with a phone

On real hardware the panic buffer is the difference between "the screen went
black" and a symbolicated backtrace. Patch it before the first flash.
