#!/usr/bin/env bash
# ============================================================
#  wsl-go.sh  —  一键跑通 WSL2 + HFS+ 环境
#
#  用法（在 Ubuntu 里）：
#      cd $HOME/ios16-xnu-bringup/tools
#      bash wsl-go.sh
#
#  它做四件事：
#    1. 检查网络/代理（不通就停下，不浪费时间）
#    2. sudo 缓存密码 + apt update
#    3. 调 setup-wsl.sh --wsl-kernel 编带 HFS+ 的内核
#    4. 验收 hfsplus 并打印下一步
# ============================================================
set -uo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; N='\033[0m'
say() { printf "${G}==>${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
die() { printf "${R}[x]${N} %s\n" "$1"; exit 1; }

# ---------- 1. 网络 / 代理 ----------
say "1/4 检查网络"

# 国内镜像 / GitHub 分开测。用 Google 当唯一探针在中国大陆必然失败，会误判成"没网"
CN=0; GH=0
curl -I -s --max-time 6 https://mirrors.aliyun.com >/dev/null 2>&1 && CN=1
curl -I -s --max-time 6 https://github.com        >/dev/null 2>&1 && GH=1
[ "$CN" -eq 1 ] && say "国内网络：可达" || warn "国内网络：不可达"
[ "$GH" -eq 1 ] && say "GitHub：直连可达" || warn "GitHub：直连不可达（国内常态，有绕法）"

# 连国内都不通 → 试代理
if [ "$CN" -eq 0 ]; then
    GW=$(ip route | awk '/^default/{print $3; exit}')
    [ -z "${GW:-}" ] && GW=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
    warn "尝试代理（镜像模式下 127.0.0.1 就是宿主机 localhost）"
    found=""
    for hp in 127.0.0.1:3067 127.0.0.1:7890 127.0.0.1:7897 127.0.0.1:10809 \
              "${GW:-7.7.7.7}:7890" "${GW:-7.7.7.7}:7891" \
              "${GW:-7.7.7.7}:10809" "${GW:-7.7.7.7}:3067"; do
        if curl -I -s --max-time 4 -x "http://$hp" https://mirrors.aliyun.com >/dev/null 2>&1; then
            found="$hp"; break
        fi
    done
    if [ -n "$found" ]; then
        export http_proxy="http://$found"
        export https_proxy="$http_proxy"
        say "代理可用：$found"
        CN=1
        curl -I -s --max-time 6 https://github.com >/dev/null 2>&1 && GH=1
        if ! grep -q "https_proxy=http://" "$HOME/.bashrc" 2>/dev/null; then
            { echo ""; echo "# added by wsl-go.sh"
              echo "export http_proxy=$http_proxy"
              echo "export https_proxy=$https_proxy"; } >> "$HOME/.bashrc"
            say "已写入 ~/.bashrc"
        fi
    else
        cat <<EOF

${R}WSL 连国内镜像都访问不了，代理也没探到${N}

排查顺序：
  1) PowerShell: wsl --shutdown 再进；确认 .wslconfig 有 networkingMode=mirrored
  2) 若装了代理软件，先把它打开（当前机器上没有任何代理进程在运行）
  3) 手动试：curl -I -x http://127.0.0.1:<你的端口> https://mirrors.aliyun.com
EOF
        exit 1
    fi
fi

# GitHub 不通 → 走 ghproxy 镜像，完全不需要代理
if [ "$GH" -eq 0 ]; then
    for gp in https://ghfast.top https://gh-proxy.com https://ghproxy.net; do
        if curl -I -s --max-time 6 "$gp/https://github.com/" >/dev/null 2>&1; then
            git config --global "url.$gp/https://github.com/.insteadOf" "https://github.com/"
            say "GitHub 走镜像：$gp"
            GH=1
            break
        fi
    done
    [ "$GH" -eq 0 ] && warn "所有 ghproxy 都不可用，git clone 可能失败（继续尝试）"
fi

# ---------- 2. sudo + apt ----------
say "2/4 准备 apt（会要求输入一次 sudo 密码）"
sudo -v || die "sudo 失败"

# 换国内 apt 源。Ubuntu 24.04+ 用 deb822（.sources），老版本用 .list，两处都处理
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    sudo sed -i \
        -e 's|http://archive.ubuntu.com|https://mirrors.aliyun.com|g' \
        -e 's|http://security.ubuntu.com|https://mirrors.aliyun.com|g' \
        -e 's|http://ports.ubuntu.com|https://mirrors.aliyun.com|g' \
        -e 's|http://cn.archive.ubuntu.com|https://mirrors.aliyun.com|g' "$f" 2>/dev/null || true
done
say "apt 源已指向 mirrors.aliyun.com"

# sudo 不继承环境变量，代理要显式传
sudo env http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" \
     apt-get update -qq || warn "apt update 有问题（继续尝试安装）"

# ---------- 3. 跑 setup ----------
say "3/4 调用 setup-wsl.sh --wsl-kernel（编内核，8 核约 5-10 分钟）"
SRC=$HOME/ios16-xnu-bringup/tools/setup-wsl.sh
[ -f "$SRC" ] || die "找不到 $SRC"

cp -f "$SRC" "$HOME/setup-wsl.sh"
chmod +x "$HOME/setup-wsl.sh"

JOBS=$(nproc) "$HOME/setup-wsl.sh" --wsl-kernel || die "setup-wsl.sh 失败，看上面最后 20 行"

# ---------- 4. 验收 ----------
say "4/4 验收"
if grep -qw hfsplus /proc/filesystems; then
    say "hfsplus 已可用"
else
    warn "bzImage 已生成，但当前内核还是旧的"
    cat <<'EOF'

下一步（在 PowerShell 里）：

  1) 编辑 %USERPROFILE%\.wslconfig，取消这一行的注释：
         kernel=C:\\Users\\Public\\iosxnu\\wsl-hfsplus-bzImage
  2) wsl --shutdown
  3) wsl -d Ubuntu
  4) 进去后执行：  grep hfs /proc/filesystems
     必须看到 hfsplus 才算成

或者直接跑：  bash $HOME/ios16-xnu-bringup/tools/wsl-check.sh
EOF
    exit 0
fi

say "全部完成"
cat <<'EOF'

冒烟测试（30 秒，确认 HFS+ 真能读写）：

  dd if=/dev/zero of=/tmp/t.img bs=1M count=200
  mkfs.hfsplus /tmp/t.img
  sudo mkdir -p /tmp/mnt
  sudo mount -t hfsplus -o loop,force /tmp/t.img /tmp/mnt
  sudo touch /tmp/mnt/hello && ls /tmp/mnt
  sudo umount /tmp/mnt

看到 hello 就说明环境通了。
EOF
