#!/usr/bin/env bash
# finish-iosroot.sh — 补完 mkiosroot.sh 在 logd/keybag 段落下的两步，并自检
#
#   bash finish-iosroot.sh [镜像路径]     默认 ~/work/ios16-root.img
#
# 背景：Ubuntu 26.04 的 coreutils 9.x 拒绝 `install -o 272`（invalid user），
# 脚本在 set -e 下就此退出，导致 logd 目录和 system keybag 都没写。
# rsync 那 20 分钟已经完成，只需补这两段。
set -uo pipefail

# 在 sudo 下 $HOME 是 /root，必须回到调用者的家目录
if [[ ${EUID:-$(id -u)} -eq 0 && -n "${SUDO_USER:-}" ]]; then
	USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
	USER_HOME=${HOME}
fi
IMG=${1:-$USER_HOME/work/ios16-root.img}
MNT=/mnt/iosroot

[[ -f "$IMG" ]] || { echo "找不到镜像: $IMG" >&2; exit 1; }

sudo mkdir -p "$MNT"
if ! mountpoint -q "$MNT"; then
	sudo mount -t hfsplus -o loop,force "$IMG" "$MNT" || {
		echo "挂载失败（可能上次没卸载干净）: sudo umount $MNT" >&2
		exit 1
	}
fi

echo "=== 1. logd 目录（owner 272 = _logd）==="
db="$MNT/private/var/db"
sudo install -d -m 0751 "$db/diagnostics"
sudo install -d -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
sudo chown 272:272 "$db/diagnostics" "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	sudo install -m 0644 /dev/null "$db/$d/.migrated"
	sudo chown 272:272 "$db/$d/.migrated"
done
echo "  done"

echo "=== 2. system keybag（无密码）==="
sudo install -d -m 0700 "$MNT/private/var/keybags"
sudo chown 0:0 "$MNT/private/var/keybags"
printf '%s\n' \
	'<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' |
	sudo tee "$MNT/private/var/keybags/systembag.kb" >/dev/null
sudo chmod 600 "$MNT/private/var/keybags/systembag.kb"
sudo chown 0:0 "$MNT/private/var/keybags/systembag.kb"
echo "  done"

echo "=== 3. 自检 ==="
fail=0
c() { if sudo test -e "$2" || sudo test -L "$2"; then echo "  [OK]   $1"; else echo "  [MISS] $1"; fail=1; fi; }

c "launchd"                  "$MNT/sbin/launchd"
c "dyld"                     "$MNT/usr/lib/dyld"
c "UIKit.framework"          "$MNT/System/Library/Frameworks/UIKit.framework"
c "SpringBoard.app"          "$MNT/System/Library/CoreServices/SpringBoard.app"
c "Applications 目录"        "$MNT/Applications"
# iPhone X 是 A11：只有 arm64 缓存，没有 arm64e（arm64e 是 A12+ 的指针认证变体）
dscd="$MNT/System/Library/Caches/com.apple.dyld"
if sudo test -e "$dscd/dyld_shared_cache_arm64e"; then
	echo "  [OK]   dyld 共享缓存 (arm64e)"
elif sudo test -e "$dscd/dyld_shared_cache_arm64"; then
	ndsc=$(sudo ls "$dscd" 2>/dev/null | grep -c '^dyld_shared_cache_arm64')
	sz=$(sudo du -sh "$dscd" 2>/dev/null | cut -f1)
	echo "  [OK]   dyld 共享缓存 (arm64, ${ndsc} 个分片, ${sz})"
else
	echo "  [MISS] dyld 共享缓存"; fail=1
fi
c "SystemOS cryptex"         "$MNT/private/preboot/Cryptexes/OS/System/Library"
c "AppOS cryptex"            "$MNT/private/preboot/Cryptexes/App"
c "system keybag"            "$MNT/private/var/keybags/systembag.kb"
c "logd diagnostics"         "$MNT/private/var/db/diagnostics"
c "libobjc-trampolines"      "$MNT/usr/lib/libobjc-trampolines.dylib"

n=$(sudo find "$MNT/Applications" -maxdepth 1 -name '*.app' 2>/dev/null | wc -l)
echo "  /Applications 下 .app 数量: $n"

echo
echo "=== 4. 用量 ==="
df -h "$MNT" | tail -1

sudo umount "$MNT"
sync

echo
echo "=== 5. fsck（Linux hfsplus 会改写部分非 ASCII 名，报 Illegal name 属正常）==="
sudo fsck.hfsplus -f -y "$IMG" 2>&1 | grep -v 'Illegal name' | tail -5
sudo fsck.hfsplus -f -n "$IMG" 2>&1 | tail -3

echo
if [[ $fail -eq 0 ]]; then
	echo "镜像自检通过。下一步："
	echo "  sudo mount -t hfsplus -o loop,force $IMG /mnt/iosroot"
	echo "  sudo python3 $HOME/ios16-xnu-bringup/refs/ios-sweet-main/tools/sweet-root-tweaks.py /mnt/iosroot"
	echo "  sudo umount /mnt/iosroot"
	echo "  img2simg $IMG ~/work/ios16-root.simg"
else
	echo "有 [MISS]。dyld 共享缓存缺失说明 mkiosroot 第 4 段没跑到，需要重跑修好的版本。"
fi
