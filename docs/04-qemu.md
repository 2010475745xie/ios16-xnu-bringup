# 04 · Boot the kernel in QEMU

This is the only part of the pipeline that validates the kernel **without a
phone**. It catches configuration errors that would otherwise show up as a black
screen with no output — which is the worst possible failure mode on real
hardware.

**What it can prove:** the kernel reaches `kernel_bootstrap` and initialises the
platform layer, I/O Kit drivers, VM subsystem and security policies.

**What it cannot do:** reach userland. QEMU `virt` has no UFS disk, its timer
frequency differs, and the board's debug UART address is unmapped. Treat a stop
somewhere in the boot as expected, not as failure.

---

## 1. Install

```bash
sudo apt install -y qemu-system-arm llvm
```

`qemu-system-aarch64` lives in `qemu-system-arm`. `llvm` is only needed for
`--kernel` (font extraction, which produces a readable `fb.txt`); without it you
get a PNG only.

## 2. Build a QEMU-specific ADT

**Do not reuse the `--highmem` ADT.** `--qemu` switches the GIC base, `CNTFRQ`,
timer INTID, CPU count, and drops the UFS node:

| | phone | QEMU virt |
|---|---|---|
| GICD / GICR | `0x17a00000` / `0x17a60000` | `0x08000000` / `0x080a0000` |
| CNTFRQ | 19.2 MHz | 62.5 MHz |
| virtual timer INTID | 19 | 27 |
| CPUs described | 8 | 1 |
| UFS node | present | absent |
| phys_base | `0xb0000000` (or `0x100000000` with `--highmem`) | `0xb0000000` |

```bash
cd ~/ios-sweet
python3 tools/mkadt.py shim/out/sweet-qemu.adt --qemu
```

Expected: a few KB. (A phone ADT with `--highmem` is ~12 KB because of the
`/product` subtree.)

Adding `--highmem` would push `phys_base` past 4 GiB, and QEMU would need a
~10 GiB guest — it fails with `cannot set up guest memory`. Leave it off.

## 3. Pack a payload

`qemu-sweet.py` takes a **payload**, not a bare kernel. A payload is
kernel + ADT + boot-args, exactly what the phone's shim would assemble:

```bash
python3 tools/mkpayload.py \
    xnu/out/kernel.development.sweet \
    shim/out/sweet-qemu.adt \
    shim/out/payload-qemu.bin \
    --cmdline 'debug=0x4 cpus=1 keepsyms=1 -noprogress'
```

Notes on the boot-args:

| arg | effect |
|---|---|
| `debug=0x4` | `DB_KPRT` only. `0xc` additionally enables `DB_KDB`, which needs a working serial port — QEMU's PL011 is not at the address the port expects, and the kernel spins there |
| `cpus=1` | matches the single-CPU QEMU ADT |
| `keepsyms=1` | keeps the linkedit segment so symbols survive |
| `-noprogress` | suppresses the boot progress bar |

Add `rd=ufsroot0` etc. only when you actually have a root image attached, which
QEMU cannot do here.

## 4. Run

```bash
mkdir -p /tmp/qemu-out
python3 tools/qemu-sweet.py shim/out/payload-qemu.bin /tmp/qemu-out \
    --secs 300 --kernel xnu/out/kernel.development.sweet
```

`--secs` is **wall-clock**, not guest CPU time. If the host sleeps, the clock
keeps running while QEMU does not — so a 300-second run can give the guest far
less than 300 seconds of progress. Disable sleep first:

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
```

Restore afterwards with `30` / `10`.

## 5. Read the output

| File | What it is |
|---|---|
| `fb.png` | 1080×2400 framebuffer — what the phone screen would show |
| `fb.txt` | same, decoded to text via the kernel's built-in font (needs `--kernel`) |
| `regs.txt` | CPU state at the stop, including `PC` |
| `qemu.log` | every exception (`-d int,guest_errors`) |

```bash
tail -40 /tmp/qemu-out/fb.txt
```

## 6. Judge the result

### Is it progressing?

```bash
grep -c gPanicBase /tmp/qemu-out/fb.txt
```

- **`2`** → the ADT has no panic region. Apply
  [`patches/mkadt-panic-region.diff`](../patches/mkadt-panic-region.diff), rebuild
  the ADT, and rerun. See [pitfall 10](05-pitfalls.md#10-the-adt-has-no-panic-region-and-the-kernel-hangs-without-one).
- **`0`** → fixed; the kernel gets further.

### Is it alive or looping?

```bash
ls -lh /tmp/qemu-out/qemu.log
```

| size after a few minutes | meaning |
|---|---|
| tens of KB | stopped somewhere, waiting (plausible: no interrupt source) |
| **tens of MB** | **spinning on the same exception** — a hard stop, not slowness |

Then check where it stopped:

```bash
cat /tmp/qemu-out/regs.txt | head -3
grep -E 'ESR|ELR' /tmp/qemu-out/qemu.log | tail -5
```

A repeating `ELR` value means it re-enters the same fault forever. Normal
completion of the *kernel-only* phase looks like the log simply stopping after
the last initialisation message, with a small `qemu.log`.

## What "good" looks like

A healthy kernel-only run gets through roughly this (abridged):

```
SWEET: platform expert registered
SWEET AKS: AppleKeyStore registered
SWEET WDT: IOWatchdog registered
SWEET SURF: IOSurfaceRoot registered
SWEET HID: buttons registered / touch registered
SWEET FB: AppleCLCD 1080x2400 ... presented as 1125x2436
SWEET CPU: 1/1 CPUs initialized; SGI verified
MFC framework successfully initialized
Security policy loaded: SWEET AMFI / Sandbox
SWEET HFS: hfs-... registered
VM bootstrap done: 85 maps, 165 entries and ... holes left
Log queues configured / Firehose configured / OSLog stream configured
```

If you see all of that, the kernel, the ADT and the driver stubs agree with each
other. Anything wrong past this point is QEMU's missing hardware — go find a
phone.

---

**Next:** [05-pitfalls.md](05-pitfalls.md) — or go back to
[02-rootfs.md](02-rootfs.md) if you have not built the root image yet.
