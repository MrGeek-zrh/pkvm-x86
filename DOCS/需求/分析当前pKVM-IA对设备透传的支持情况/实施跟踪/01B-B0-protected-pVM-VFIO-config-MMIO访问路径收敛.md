# [B2] B0: protected pVM 的 VFIO config/MMIO 访问路径收敛

## 状态

- 当前状态: 待开始
- 优先级: B0（B1 之后的新前置阻塞）
- GitHub Task: `pkvm-x86#12`
- 关联前置任务: `B1`
- 关联 Bug: `BOOT-007`

## 目标

在不破坏 protected pVM 隔离语义的前提下，让 VFIO PCI 设备的基础访问路径不再依赖当前 x86 pKVM 不支持的 MMIO emulation fallback。

最小目标是：

- guest 能完成设备枚举和基础 config/register 访问
- `KVM_RUN` 不再因为 `RET_PF_EMULATE -> -EFAULT` 提前退出

## 关键源码锚点

- ECAM/config 访问路径
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/pci_root.rs`
  - `/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs`
- VFIO PCI BAR / config / mmap 路径
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs`
- pKVM protected vCPU 对 MMIO emulation 的限制
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/mmu/mmu.c`

## 当前结论

- 这不是 DMA mirror 主线本身的问题，而是更前置的寄存器访问路径 blocker。
- 当前 crosvm VFIO PCI 仍然至少对 config space 依赖 `PciRoot` / ECAM / MMIO fallback。
- pKVM x86 protected vCPU 当前不接受这类 fallback。

## 实施方向

- 先明确哪些访问必须保留 host/userspace 参与：
  - PCI config space
  - virtual config / ACPI companion
  - 非 mmap BAR
- 再决定收敛方向：
  - 让这些访问改走 protected 兼容路径
  - 或尽量避免它们落入当前 MMIO emulation fallback

## 验收标准

- protected pVM + VFIO(`NoIommu`) 不再在 guest 枚举/早期寄存器访问阶段触发 `KVM_RUN -> -EFAULT`
- 运行日志中不再把 `failed to create vm mapping (EINVAL)` 和后续 `vcpu EFAULT` 串成同一失败链
- 为后续 T2/T3 保留清晰验证窗口
