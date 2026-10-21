#!/usr/bin/env bash
# wsl-check.sh —— 只体检，不改任何东西。任何时候都可以跑。
#   bash $HOME/ios16-xnu-bringup/tools/wsl-check.sh

ok(){ printf "  [OK]   %s\n" "$1"; }
no(){ printf "  [FAIL] %s\n" "$1"; }
info(){ printf "  [--]   %s\n" "$1"; }

echo "=== 1. 发行版 / 内核 ==="
info "$(grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '\"')"
info "kernel: $(uname -r)"
info "cpus: $(nproc)   mem: $(free -g | awk '/^Mem:/{print $2}') GB"

echo "=== 2. 内存是否吃到 16GB ==="
m=$(free -g | awk '/^Mem:/{print $2}')
if [ "${m:-0}" -ge 14 ]; then ok "内存 ${m} GB（.wslconfig 生效）"; else no "内存只有 ${m} GB，检查 .wslconfig 的 memory="; fi

echo "=== 3. 网络 ==="
if curl -I -s --max-time 6 https://mirrors.aliyun.com >/dev/null 2>&1; then
    ok "国内网络可达（阿里云镜像）"
    CN=1
else
    no "连阿里云镜像都不通 —— WSL 基础网络真的没通"
    CN=0
fi
if curl -I -s --max-time 6 https://github.com >/dev/null 2>&1; then
    ok "GitHub 直连可达"
    GH=1
else
    info "GitHub 直连不可达（国内常态，可用 ghproxy 绕过，非必需）"
    GH=0
fi
info "https_proxy=${https_proxy:-<未设置>}"
if [ "$CN" -eq 0 ]; then
    info "默认网关: $(ip route | awk '/^default/{print $3; exit}')"
fi

echo "=== 4. HFS+ ==="
if grep -qw hfsplus /proc/filesystems; then
    ok "hfsplus 已加载"
else
    no "hfsplus 不在内核里 —— 还没换自编内核"
    info "见 wsl-go.sh 结尾的下一步"
fi

echo "=== 5. 工具链 ==="
for c in gcc aarch64-linux-gnu-gcc apfs-fuse mkbootimg mkfs.hfsplus img2simg dtc python3 git; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c"; else no "$c 缺失"; fi
done

echo "=== 6. bzImage ==="
if [ -f $HOME/ios16-xnu-bringup/wsl-hfsplus-bzImage ]; then
    ok "已生成 $(du -h $HOME/ios16-xnu-bringup/wsl-hfsplus-bzImage | cut -f1)"
else
    info "尚未生成（还没跑 setup-wsl.sh --wsl-kernel）"
fi

echo "=== 7. 工作根 ==="
if [ -d $HOME/ios16-xnu-bringup/refs ]; then
    ok "C:\\Users\\Public\\iosxnu 可访问，$(ls $HOME/ios16-xnu-bringup/refs | wc -l) 个参考项目"
else
    no "找不到 $HOME/ios16-xnu-bringup"
fi
