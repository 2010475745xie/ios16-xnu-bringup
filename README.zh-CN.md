[English](README.md) · **简体中文**

# ios16-xnu-bringup

把 Apple 的 XNU 内核和 iOS 16 用户态搬到非 Apple ARM64 手机上的构建笔记与工具集 —— 具体来说，是**宿主侧**（构建根文件系统、构建内核、在 QEMU 里验证）的一切，**也就是不需要目标手机的那部分**。

> ## 本仓库不包含任何 Apple 的二进制文件。
>
> 没有 IPSW、没有 iOS 根镜像、没有设备树、没有内核、没有用户态。
> 你必须自己从 Apple 获取 IPSW 并自行构建。
> 这是刻意的 —— 见[许可与边界](#许可与边界)。

---

## 这是什么

这些移植项目的**手机侧**上游写得都不错。没人写的是「从一台干净的 Windows 到能刷的根文件系统」这段路 —— 而这段路全是坑，每个坑要花几小时。

这个仓库就是那段路：

- **Windows 11 + WSL2** 上可用的宿主环境（不需要 Mac，不需要另一台 Linux 机器）
- iOS 16 根文件系统在 **HFS+** 上的构建流水线
- 不用 Mac 编译 XNU 的 **GitHub Actions** 配方
- 碰硬件之前先验证内核改动的 **QEMU 测试台**
- 一个**真实的上游缺陷**，含复现步骤和修复

## 验证环境

本站所有内容在下列环境实测：

| | |
|---|---|
| 宿主 | Windows 11（build 26200），x86-64，32 GB 内存 |
| WSL | Ubuntu 26.04 LTS，内核 6.18.54.1（自编 bzImage，开启 HFS+） |
| 目标用户态 | iPhone X（`iPhone10,3` / D22AP），iOS 16.7.16 (20H392) |
| XNU 基线 | xnu-8796（`dipa-studio/ios-sweet`） |
| QEMU | 10.2.1，`virt` 机器，cortex-a76 |

Ubuntu **22.04** 和 **24.04** 更容易（自带内核的 `linux-modules-extra` 里有 `hfsplus`）。26.04 是被迫走自编 bzImage 这条路的原因。

## 快速开始

```bash
git clone https://github.com/2010475745xie/ios16-xnu-bringup ~/ios16-xnu-bringup
cd ~/ios16-xnu-bringup

bash scripts/wsl-check.sh          # 7 项体检，不改任何东西
bash scripts/wsl-go.sh             # 装依赖 + apfs-fuse + 编带 HFS+ 的内核
```

然后按顺序读文档：

| # | 文档 | 你会得到 |
|---|---|---|
| 01 | [docs/01-environment.md](docs/01-environment.md) | 能读写 HFS+ 的 WSL2 |
| 02 | [docs/02-rootfs.md](docs/02-rootfs.md) | 16 GB 的 `ios16-root.img` 和 `.simg` |
| 03 | [docs/03-kernel.md](docs/03-kernel.md) | `kernel.development.sweet`，17 MB |
| 04 | [docs/04-qemu.md](docs/04-qemu.md) | 不碰手机就验证内核启动 |
| 05 | [docs/05-pitfalls.md](docs/05-pitfalls.md) | 十个坑，让你不用重走 |

> 文档目前是英文。技术术语多，机翻容易失真，所以先保持原文。需要中文版可以开 issue。

## 目录结构

```
docs/        上面那五篇文档
scripts/     宿主侧自动化（WSL 准备、根镜像构建、验证）
patches/     给上游项目的修复，unified diff 格式
analysis/    多个移植项目的横向对比和一次故障诊断
```

## 我们找到的那个真实缺陷

`dipa-studio/ios-sweet` 的 `tools/mkadt.py` 从不生成 panic log 区域。于是 XNU 的 `pexpert/arm/pe_init.c:check_for_panic_log()` 让 `gPanicBase == 0`，`debug_log_init()` 放弃初始化，内核在 `kdp_init` 里停止推进：

```
debug_log_init: Error!! gPanicBase is still not initialized
debug_log_init: Error!! gPanicBase is still not initialized
kdp_core zlib memory 0x8000
```

两个后果：**完全没有 panic 日志**（崩溃后无从符号化），以及**早期挂死**（QEMU 里完全过不去；按 `ios-fajita` 的笔记，一加 6T 也卡在同一处）。

修复在 [`patches/mkadt-panic-region.diff`](patches/mkadt-panic-region.diff) —— 四个 hunk，+13 −1：从 ADT 的 dram 顶部挖 1 MiB，描述成 `/pram` 与 `/chosen/embedded-panic-log-size`。

实测结果：`grep -c gPanicBase fb.txt` 从 **2 变成 0**，最后一行日志从 `kdp_core zlib memory 0x8000` 前进到 `Serial requested ... configuring debugging over serial`。

## 本仓库刻意不做的事

- **不**分发 iOS、IPSW、根镜像、设备树或内核。
- **不**提供任何具体机型的安装步骤 —— 那取决于设备、它的 bootloader，以及你用的上游移植项目。
- **不**声称 QEMU 能跑到用户态。它做不到：`virt` 没有 UFS，`CNTFRQ` 是 62.5 MHz 而板子是 19.2 MHz，调试串口地址也没映射。目标只是验证内核。

## 如果你是在找「Hackios」

本仓库和那个项目没有关系。Hackios 是 OOSexGang 的另一条线，至今没有公开代码；本仓库源自 `dipa-studio/ios-sweet`，只包含宿主侧工具。如果你想要一个今天就能开始的起点，下面列出的这些移植项目才是真实存在的。

## 依赖的上游项目

| 项目 | 设备 | 说明 |
|---|---|---|
| [`dipa-studio/ios-sweet`](https://github.com/dipa-studio/ios-sweet) | Redmi Note 10 Pro (SM7150) | 母项目，本站一切假设它的目录布局 |
| [`MakrSas/ios-topaz`](https://github.com/MakrSas/ios-topaz) | Redmi Note 12 4G (SM6225) | ARMv8.0 变体 |
| [`edi194/ios-fajita`](https://github.com/edi194/ios-fajita) | 一加 6T (SDM845) | 四个里 WSL2 笔记最全的 |
| [`ch1tmdgus/ios-v60`](https://github.com/ch1tmdgus/ios-v60) | LG V60 (SM8250) | GUI + 触摸已确认，触摸/无线日志质量很高 |
| [`UniXNU/UniXNU`](https://github.com/UniXNU/UniXNU) | 小米平板 6S Pro (SM8550) | 另一条路线：原生 kext + 预链接 Apple kernelcache |
| [`blacktop/ipsw`](https://github.com/blacktop/ipsw) | — | 全程使用的固件/dyld 工具 |
| [`blacktop/darwin-xnu-build`](https://github.com/blacktop/darwin-xnu-build) | — | CI 构建脚本 |

这些项目**都没有许可声明**（GitHub API 返回 `"license": null`），所以本仓库只链接它们，不内嵌它们的代码。

## 许可与边界

本仓库的脚本和文档以 **MIT 许可**发布（见 `LICENSE`），是原创作品。

它们操作的对象是 Apple 的版权物，那部分**不在**该许可覆盖范围内，也**不在**本仓库中。使用这些工具意味着你自己去获取 Apple 的 IPSW，Apple 的条款适用于它。

这是研究与互操作性质的工作，和黑苹果社区分享 EFI 配置却从不分发 macOS 是同一个道理：**分发方法，不分发产物。**

本文不构成法律意见。
