# 03 · Build XNU without a Mac

The upstream projects build the kernel on GitHub's macOS runners. This works
from Windows or Linux — you only need a GitHub account.

**Cost:** free for public repositories (macOS minutes are billed at 10× but the
allowance is plenty). **Time:** about 8 minutes per build.

---

## 1. Fork the repository

```bash
gh auth login            # once; device-code flow, no SSH key needed
gh repo fork dipa-studio/ios-sweet --clone
cd ios-sweet
```

If `gh` is not installed: `sudo apt install gh` (or see
[cli.github.com](https://cli.github.com)).

## 2. Enable Actions on the fork

GitHub disables workflows on forks. Check:

```bash
gh workflow list -R <you>/ios-sweet
```

- Lists `xnu` → good, continue.
- `no workflows found` → open `https://github.com/<you>/ios-sweet/actions` and
  click the yellow banner's **"I understand my workflows, go ahead and enable
  them"**. Give it 30 seconds.

## 3. Trigger a build

`gh` resolves a fork clone to its **upstream**, so `-R` is mandatory here (see
[pitfall 5](05-pitfalls.md#5-gh-resolves-a-fork-clone-to-its-upstream)):

```bash
gh workflow run xnu.yml -R <you>/ios-sweet
```

The command prints nothing on success. Confirm:

```bash
sleep 10 && gh run list -R <you>/ios-sweet --limit 3
```

Watch it live:

```bash
gh run watch -R <you>/ios-sweet
```

Expect roughly:

```
✓ Set up job
✓ Run actions/checkout@v4
✓ Fetch build script
✓ Deps
✓ Build                        ← most of the 8 minutes
✓ Package build tree for local compiles
✓ Run actions/upload-artifact@v4
✓ Inspect closed KDK support libs
✓ Collect
✓ Run actions/upload-artifact@v4
✓ Complete job
```

## 4. Download the kernel

`gh run download` sometimes dies with `error writing zip archive: unexpected
EOF` on a flaky link. The web UI is more reliable:

```
https://github.com/<you>/ios-sweet/actions/runs/<RUN_ID>
```

Scroll to the **Artifacts** section at the bottom and download `xnu-kernel`.
Then:

```bash
mkdir -p ~/ios-sweet/xnu/out
unzip -o ~/Downloads/xnu-kernel.zip -d ~/ios-sweet/xnu/out/
```

Or, if the CLI cooperates:

```bash
gh run download <RUN_ID> -R <you>/ios-sweet -n xnu-kernel -D xnu/out
```

### What you get

| File | Size | Needed? |
|---|---|---|
| `kernel.development.sweet` | ~17 MB | **yes — this is the kernel** |
| `kernel.development.sweet.link/` | ~128 MB | no (archive + dSYM, for local single-file compiles) |
| `kdk-libs/` | ~1 MB | no (kernel SDK symbol tables, for building kexts) |
| `SHA256SUMS` | — | optional integrity check |

## 5. Verify

Check the Mach-O header — this is an ARM64 kernel, not an x86 one:

```bash
xxd -l 8 xnu/out/kernel.development.sweet
```

Expected:

```
00000000: cffa edfe 0c00 0001
```

| bytes | meaning |
|---|---|
| `cf fa ed fe` | `MH_MAGIC_64` (little-endian) |
| `0c 00 00 01` | `CPUTYPE_ARM64` (`0x0100000C`) |

And optionally:

```bash
cd xnu/out && sha256sum -c SHA256SUMS 2>/dev/null | grep kernel
# kernel.development.sweet: OK
```

## Why `sweet` in the filename

The kernel's machine config is `SWEET` — a board config inside `pexpert`. Even
when you port to another phone, the upstream port keeps the name (its symbols
are compiled into the kernel, so renaming breaks the build). Do not treat
`kernel.development.sweet` as evidence that the build is sweet-specific.

## When the build fails

```bash
gh run view <RUN_ID> -R <you>/ios-sweet --log-failed 2>&1 | tail -60
```

The patch series is applied in order and the build script **silently skips a
patch that fails to apply** — so a "successful" build with a missing patch is
possible. The upstream `tools/check-hunk-counts.py` guards against the most
common cause (a hunk header whose declared line count does not match its body).
Run it after editing any patch:

```bash
python3 tools/check-hunk-counts.py xnu/patches/
```

---

**Next:** [04-qemu.md](04-qemu.md) — boot this kernel in QEMU, without a phone.
