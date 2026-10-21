#!/usr/bin/env bash
# Prepare a Linux environment for the fajita port without a full VM.
#
#   ./tools/setup-wsl.sh                 # packages + tools, check HFS+
#   ./tools/setup-wsl.sh --wsl-kernel    # also build a WSL2 kernel with HFS+
#
# Run inside WSL2 Ubuntu (22.04/24.04). On a normal Ubuntu VM, run without
# --wsl-kernel; the stock kernel has hfsplus in linux-modules-extra.
set -euo pipefail

BUILD_WSL_KERNEL=0
for arg in "$@"; do
	case "$arg" in
	--wsl-kernel) BUILD_WSL_KERNEL=1 ;;
	-h|--help)
		sed -n '2,10p' "$0"
		exit 0
		;;
	*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

if [[ $(id -u) -eq 0 ]]; then
	echo "run as your normal user, not root (the script uses sudo)" >&2
	exit 1
fi

IS_WSL=0
if grep -qi microsoft /proc/version 2>/dev/null; then
	IS_WSL=1
fi

# Everything we build locally lands here; no sudo for /usr/local.
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.local/bin"
# WSL defaults to ~50% of host RAM (3.5 GiB here); keep the kernel build
# from OOMing. Raise with JOBS=4 after setting memory=5GB in .wslconfig.
JOBS=${JOBS:-2}

echo "== packages =="
sudo apt update

# Core packages: any failure here is fatal.
sudo apt install -y \
	build-essential git curl unzip ca-certificates \
	python3 python3-pip \
	gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu cpio \
	flex bison libssl-dev libelf-dev bc libncurses-dev \
	libfuse3-dev libbz2-dev zlib1g-dev libattr1-dev cmake file pkg-config \
	|| { echo "core packages failed" >&2; exit 1; }

# Optional packages: names differ between Ubuntu 22.04 and 26.04, so install
# them one by one; a missing one must not abort the whole batch.
for p in hfsprogs rsync android-sdk-libsparse-utils dwarves \
         device-tree-compiler gh apfs-fuse; do
	if sudo apt install -y "$p" >/dev/null 2>&1; then
		echo "  [ok]      $p"
	else
		echo "  [missing] $p (optional)"
	fi
done

echo "== apfs-fuse =="
if ! command -v apfs-fuse >/dev/null 2>&1; then
	if ! sudo apt install -y apfs-fuse 2>/dev/null; then
		mkdir -p "$HOME/opt"
		if [[ ! -d "$HOME/opt/apfs-fuse/.git" ]]; then
			git clone --depth=1 --recursive \
				https://github.com/sgan81/apfs-fuse.git "$HOME/opt/apfs-fuse"
		fi
		# GCC 15: PList.h uses uint8_t/uint32_t without including <cstdint>.
		if ! grep -q '#include <cstdint>' "$HOME/opt/apfs-fuse/ApfsLib/PList.h"; then
			sed -i '1i #include <cstdint>' "$HOME/opt/apfs-fuse/ApfsLib/PList.h"
		fi
		# apfs-fuse still declares cmake_minimum_required(VERSION 3.0),
		# which CMake >= 4 rejects; keep the old policy floor.
		cmake -S "$HOME/opt/apfs-fuse" -B "$HOME/opt/apfs-fuse/build" \
			-DCMAKE_POLICY_VERSION_MINIMUM=3.5
		make -C "$HOME/opt/apfs-fuse/build" -j"$JOBS"
		install -m 0755 "$HOME/opt/apfs-fuse/build/apfs-fuse" "$HOME/.local/bin/apfs-fuse"
	fi
fi
command -v apfs-fuse >/dev/null || { echo "apfs-fuse install failed" >&2; exit 1; }

echo "== mkbootimg =="
if ! command -v mkbootimg >/dev/null 2>&1; then
	mkdir -p "$HOME/opt" "$HOME/.local/bin"
	if [[ ! -d "$HOME/opt/aosp-mkbootimg/.git" ]]; then
		GIT_TERMINAL_PROMPT=0 git clone --depth=1 \
			https://github.com/jbeich/platform_system_tools_mkbootimg.git \
			"$HOME/opt/aosp-mkbootimg"
	fi
	cat >"$HOME/.local/bin/mkbootimg" <<EOF
#!/bin/sh
exec python3 "$HOME/opt/aosp-mkbootimg/mkbootimg.py" "\$@"
EOF
	chmod +x "$HOME/.local/bin/mkbootimg"
	if ! grep -q 'HOME/.local/bin' "$HOME/.bashrc" 2>/dev/null; then
		echo 'export PATH="$HOME/.local/bin:$PATH"' >>"$HOME/.bashrc"
	fi
	export PATH="$HOME/.local/bin:$PATH"
fi

echo "== HFS+ check =="
if grep -qw hfsplus /proc/filesystems; then
	echo "hfsplus: available"
	exit 0
fi

cat <<'EOF'
hfsplus is NOT available in this kernel.
Stock WSL2 (Microsoft kernel) has FUSE and loop, but CONFIG_HFSPLUS_FS is off.
EOF
if [[ $BUILD_WSL_KERNEL -eq 1 && $IS_WSL -eq 1 ]]; then
	echo "== building a WSL2 kernel with CONFIG_HFSPLUS_FS=y =="
	# Branch must match the RUNNING kernel. 6.6 sources under a 6.18 WSL will
	# often refuse to boot; derive the branch from uname -r instead of hardcoding.
	BR="linux-msft-wsl-$(uname -r | cut -d. -f1-2).y"
	src=$HOME/WSL2-Linux-Kernel
	if [[ ! -f "$src/Makefile" ]]; then
		rm -rf "$src"
		got=0
		for gp in https://ghfast.top https://gh-proxy.com https://ghproxy.net; do
			url="$gp/https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/heads/$BR.tar.gz"
			echo "  fetching $BR via $gp"
			if curl -L --fail --retry 2 --connect-timeout 20 --progress-bar \
			     -o /tmp/wslk.tar.gz "$url"; then
				mkdir -p "$src"
				if tar -xzf /tmp/wslk.tar.gz -C "$src" --strip-components=1; then
					got=1
					break
				fi
			fi
		done
		if [[ $got -eq 0 ]]; then
			echo "  tarball mirrors failed, falling back to git clone (slow)"
			git clone --depth=1 -b "$BR" \
				https://github.com/microsoft/WSL2-Linux-Kernel.git "$src"
		fi
	fi
	cd "$src"
	cp Microsoft/config-wsl .config
	if grep -q '^# CONFIG_HFSPLUS_FS is not set' .config; then
		sed -i 's/^# CONFIG_HFSPLUS_FS is not set/CONFIG_HFSPLUS_FS=y/' .config
	elif ! grep -q '^CONFIG_HFSPLUS_FS=y' .config; then
		echo 'CONFIG_HFSPLUS_FS=y' >>.config
	fi
	# GCC 15 builds tools/lib/bpf with -Werror. 6.6 upstream has `char *next_path`
	# and needs `const`; 6.18 already has it, so the old unconditional sed produced
	# `const const char` and aborted the build. Keep this idempotent.
	if [ -f tools/lib/bpf/libbpf.c ]; then
		sed -i 's/const const char \*next_path;/const char *next_path;/' tools/lib/bpf/libbpf.c
		if grep -qE '^[[:space:]]*char \*next_path;' tools/lib/bpf/libbpf.c; then
			sed -i 's/^\([[:space:]]*\)char \*next_path;/\1const char *next_path;/' tools/lib/bpf/libbpf.c
		fi
	fi
	# Only the kernel image is needed: CONFIG_HFSPLUS_FS=y is built-in, and
	# the full `all` target spends ~20 min on unused AMDGPU modules.
	make -j"$JOBS" bzImage
	# PATCHED for this machine: do NOT resolve %USERPROFILE% (it contains CJK
	# characters, and `cmd.exe /c echo %USERPROFILE%` comes back GBK-encoded,
	# which makes wslpath misbehave). Write the bzImage to a pure-ASCII
	# directory instead, so .wslconfig references an ASCII kernel path too.
	outdir=$HOME/ios16-xnu-bringup
	mkdir -p "$outdir"
	cp arch/x86/boot/bzImage "$outdir/wsl-hfsplus-bzImage"
	winpath='C:\Users\Public\iosxnu\wsl-hfsplus-bzImage'
	escaped=$winpath
	echo
	echo "built: $winpath"
	echo "Add this to %USERPROFILE%\\.wslconfig:"
	echo
	echo "  [wsl2]"
	echo "  kernel=$escaped"
	echo "  memory=5GB"
	echo "  processors=$(nproc)"
	echo
	echo "Then run: wsl --shutdown"
else
	echo "Re-run with --wsl-kernel, or use an Ubuntu VM with linux-modules-extra."
	exit 1
fi
