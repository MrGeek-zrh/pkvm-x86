# ARM pKVM / AVF 参考源清单

## 目的

本文件用于记录当前专题在分析 ARM64 pKVM / AVF 参考实现时所依赖的上游代码源和文档源。

约束：

- 参考代码本身不纳入当前仓库版本管理。
- 本地参考代码统一放在仓库根目录下的 `refs/` 目录。
- `refs/` 已加入根仓库 [`.gitignore`](/home/mrgeek/pkvm-x86/.gitignore)。
- 需要长期引用的应记录具体仓库、分支和 commit，而不是只记一个网页链接。

## 建议的本地目录

- `/home/mrgeek/pkvm-x86/refs/android-kernel-common`
- `/home/mrgeek/pkvm-x86/refs/android-virtualization`

## 参考源 1: Android common kernel

- 仓库:
  - `https://android.googlesource.com/kernel/common`
- 建议分支:
  - `refs/heads/android16-6.12`
- 当前本地 checkout:
  - branch: `android16-6.12`
  - commit: `3ec022196c4e9d5c1434599cdda63f622dd6f586`
- 本地目录:
  - `/home/mrgeek/pkvm-x86/refs/android-kernel-common`
- 参考目的:
  - ARM64 pKVM host 侧与 hyp 侧实现
  - protected guest 的 memory share/unshare、MMIO 分类相关实现
  - `arch/arm64/kvm/` 与 `arch/arm64/kvm/hyp/nvhe/` 代码路径
- 优先关注路径:
  - `arch/arm64/kvm/pkvm.c`
  - `arch/arm64/kvm/hyp/nvhe/`
  - `arch/arm64/include/asm/kvm*`
  - `include/uapi/linux/` 中与 KVM / guest hypercall 相关的头文件

## 参考源 2: Android Virtualization module

- 仓库:
  - `https://android.googlesource.com/platform/packages/modules/Virtualization`
- 建议分支或 tag:
  - 优先参考与当前文档一致的稳定 tag
  - 例如 `refs/tags/aml_ase_351114000`
- 当前本地 checkout:
  - detached HEAD
  - commit: `48c987bff45acbdd73054d7c2aaef0a607e8f3db`
- 本地目录:
  - `/home/mrgeek/pkvm-x86/refs/android-virtualization`
- 参考目的:
  - AVF 上层架构
  - device assignment 文档
  - pvmfw / manifest / VM DTBO 等上层设备元数据与信任边界设计
- 优先关注路径:
  - `docs/device_assignment.md`
  - `docs/`
  - 与 pvmfw、VM 配置、设备声明相关的实现或设计文档

## 文档参考

- Android AVF 架构文档:
  - `https://source.android.com/docs/core/virtualization/architecture`
- Linux arm64 pKVM hypercall 文档:
  - `https://docs.kernel.org/virt/kvm/arm/hypercalls.html`

## 当前参考重点

当前阶段不以“照搬 ARM 设备透传代码”为目标，而是重点借鉴：

- device metadata / manifest 通道
- guest MMIO 分类机制
- pKVM/hyp 持有 authoritative device state 的边界

对应当前 x86 主题中的主任务：

- [B3 上层与 MMIO 语义设计](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01C-B0-protected-pVM-guest-hyp-passthrough-MMIO语义设计.md)
- [B3-1 第一阶段上层方案](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01C-1-B3-1-protected-pVM-设备透传第一阶段上层方案.md)

## 后续使用方式

当后续真的把参考代码 clone 到 `refs/` 后，应补充：

- 实际 checkout 的 commit
- 关键源码入口
- 与当前 x86 设计的一对一映射关系

当前目录下已补的配套文档：

- `ARM-pKVM-到-x86-设计映射表.md`
- `ARM-pKVM-MMIO_GUARD与stage-2-abort路径讲解.md`
