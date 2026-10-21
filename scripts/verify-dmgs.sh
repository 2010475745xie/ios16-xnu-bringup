#!/usr/bin/env bash
# verify-dmgs.sh — 建镜像前，30 秒内确认三个 dmg 的内容对不对
#
#   bash verify-dmgs.sh [DMG_DIR]       默认 ~/work/dmgs
#
# 只看不写，挂载后立刻卸载。任一项 [MISS] 都说明卷挑错了，别急着建镜像。
set -uo pipefail

D=${1:-$HOME/work/dmgs}
M=/mnt/verify
ok=0
miss=0

chk() { # chk "描述" "路径"
	if sudo test -e "$2" || sudo test -L "$2"; then
		printf "  [OK]   %s\n" "$1"
		ok=$((ok+1))
	else
		printf "  [MISS] %s\n         %s\n" "$1" "$2"
		miss=$((miss+1))
	fi
}

mount_one() { # mount_one dmg 子目录
	local dmg=$1 sub=$2
	[[ -f "$dmg" ]] || { echo "缺文件: $dmg" >&2; return 1; }
	sudo mkdir -p "$M/$sub"
	sudo apfs-fuse "$dmg" "$M/$sub" || { echo "挂载失败: $dmg" >&2; return 1; }
	return 0
}

cleanup() {
	for s in os sysos appos; do
		sudo umount "$M/$s" 2>/dev/null || true
	done
}
trap cleanup EXIT

echo "=== 1/3 OS.dmg —— 根文件系统 ==="
if mount_one "$D/OS.dmg" os; then
	chk "dyld"                      "$M/os/root/usr/lib/dyld"
	chk "UIKit.framework"           "$M/os/root/System/Library/Frameworks/UIKit.framework"
	chk "MobileSafari.app"          "$M/os/root/Applications/MobileSafari.app"
	chk "Preferences.app (设置)"    "$M/os/root/Applications/Preferences.app"
	chk "launchd"                   "$M/os/root/sbin/launchd"
	n=$(sudo find "$M/os/root/Applications" -maxdepth 1 -name '*.app' 2>/dev/null | wc -l)
	echo "         /Applications 下 .app 数量: $n"
fi

echo
echo "=== 2/3 SystemOS.dmg —— 系统 cryptex（含 dyld 共享缓存）==="
if mount_one "$D/SystemOS.dmg" sysos; then
	dsc="$M/sysos/root/System/Library/Caches/com.apple.dyld"
	chk "dyld_shared_cache_arm64e"  "$dsc/dyld_shared_cache_arm64e"
	chk "UIKitCore (共享缓存里查不到属正常)" "$M/sysos/root/System/Library/PrivateFrameworks"
	if sudo test -e "$dsc/dyld_shared_cache_arm64e"; then
		echo -n "         共享缓存大小: "
		sudo du -sh "$dsc/dyld_shared_cache_arm64e" 2>/dev/null | cut -f1
	fi
fi

echo
echo "=== 3/3 AppOS.dmg —— App cryptex（可能只是增量）==="
if mount_one "$D/AppOS.dmg" appos; then
	n=$(sudo find "$M/appos/root/Applications" -maxdepth 1 -name '*.app' 2>/dev/null | wc -l)
	echo "         /Applications 下 .app 数量: $n"
	if [[ "${n:-0}" -gt 0 ]]; then
		echo "         前 5 个:"
		sudo find "$M/appos/root/Applications" -maxdepth 1 -name '*.app' 2>/dev/null |
			head -5 | sed 's|.*/|           |'
	fi
	echo -n "         卷内文件数: "
	sudo find "$M/appos/root" -type f 2>/dev/null | wc -l
fi

echo
echo "=== 结论 ==="
echo "  OK=$ok  MISS=$miss"
if [[ $miss -eq 0 ]]; then
	echo "  三个卷都合理，可以建镜像："
	echo "    sudo bash $HOME/ios16-xnu-bringup/refs/ios-sweet-main/tools/mkiosroot.sh \\"
	echo "        $D/OS.dmg $D/SystemOS.dmg $D/AppOS.dmg ~/work/ios16-root.img 16G"
else
	echo "  有缺失项。若只是 AppOS 的 .app 为 0 且文件数很少，那是增量卷，正常。"
	echo "  但 OS 或 SystemOS 若 MISS，说明卷挑错了，别往下走。"
fi
