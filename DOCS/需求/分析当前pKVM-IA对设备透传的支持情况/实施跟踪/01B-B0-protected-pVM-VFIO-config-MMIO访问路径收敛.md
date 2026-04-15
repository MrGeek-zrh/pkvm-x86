# [B2] B0: protected pVM 的 VFIO config/MMIO 访问路径收敛

## 状态

- 当前状态: 已完成（2026-03-27 已确认旧 MMIO/config 签名不再复现，阻塞前移到 DMA/IOMMU 新签名）
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
- pKVM 能力判断 / 只读 memslot 判定
  - `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/mod.rs`
  - `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs`
- VFIO PCI BAR / config / mmap 路径
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs`
- pKVM protected vCPU 对 MMIO emulation 的限制
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/mmu/mmu.c`

## 当前结论

- 这不是 DMA mirror 主线本身的问题，而是更前置的寄存器访问路径 blocker。
- 当前 crosvm VFIO PCI 仍然至少对 config space 依赖 `PciRoot` / ECAM / MMIO fallback。
- pKVM x86 protected vCPU 当前不接受这类 fallback。
- 当前本地 crosvm 还有一个单独的 correctness 问题：
  - `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/mod.rs` 的 `VmCap::ReadOnlyMemoryRegion` 本意上会在 pKVM 下返回 `false`
  - 但 `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs` 的 `is_pkvm()` 仍然直接返回 `false`
  - 结果是 x86_64 crosvm 会误以为只读 memslot 可用，先去尝试 config page 只读映射，再在 `PciRoot::add_mapping()` 里落到 `EINVAL`
- 但官方 issue `#46` 和本地 guest 源码进一步表明：仅仅收敛 crosvm config 路径并不足以让 protected pVM 设备透传工作。
- `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c` 中：
  - `pv_ops.mmio.raw_read* / raw_write*`
  - `pv_ops.mmio.pci_mmcfg_*`
  - 先统一汇聚到 `pkvm_virt_mmio()`
  - 命中 allowlist 的 `DIRECT_BAR` 时会 direct `raw_read*/raw_write*`
  - 未命中时才退回 `PKVM_GHC_IOREAD/IOWRITE`
- 因而当前更准确的问题不是“所有 BAR MMIO 一律不直接访问”，而是“若没有正确的 allowlist 和对应 Guest EPT 建图，passthrough BAR MMIO 仍会退回 host emulated path，不能形成可信 direct path”。
- 这使得 B2 最多只能作为“把早期症状往后推”的实验性 workaround，而不是主线修复。

## 当前实施进展

- 当前轮已在 crosvm 收敛两类更早暴露的残余路径：
  - `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs`
    - `KvmVm::is_pkvm()` 已改为复用现有 `get_protected_vm_info()` 检测，而不再硬编码返回 `false`
    - 因而 `VmCap::ReadOnlyMemoryRegion` 在 x86 pKVM 下不再被误报为可用
  - `/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs`
    - protected VM 下不再向 `generate_pci_root()` 传入 `vcfg_base`
    - protected VM 下不再注册 `PciVirtualConfigMmio`
    - protected VM 下不再在 ACPI 中公开 `VCFG`
- 这轮修改的目标不是“宣布 B2 已经修好 BOOT-007”，而是先把已知 residual `virtual-config` 路径真正关掉，再看失败点能否继续后移。
- 已完成本地 userspace 构建验证：
  - `/home/mrgeek/.cargo/bin/cargo build -p crosvm --locked`
- 已完成有效端到端验证：
  - guest 已启动到 Ubuntu login prompt
  - `Failed to map mmio page; failed to create vm mapping` 未再出现
  - `vcpu hit unknown error: Bad address (os error 14)` 未再出现
  - 当前新签名已前移到 host DMAR fault，见 [BOOT-008-protected-pVM-NoIommu-VFIO-host-DMAR-PTE-Read-access-not-set.md](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-008/BOOT-008-protected-pVM-NoIommu-VFIO-host-DMAR-PTE-Read-access-not-set.md)

## 实施方向

- 当前不建议直接把 B2 当主线实现。
- 若后续要继续做实验性 workaround，可用于回答一个更窄的问题：
  - 绕开 ECAM/config fallback 后，失败点是否能进一步后移
- 当前这轮的直接验证目标已经收敛为：
  - protected VM 下不再暴露 `PciVirtualConfigMmio`
  - ACPI 中不再公开 `VCFG`
  - 设备级 virtual-config AML / shared-memory 路径不再注册
- 但真正主线应先转向 B3 的 guest/hyp MMIO 语义设计，而不是继续在 crosvm 单点打补丁

## 验收标准

- 作为 workaround 的验收标准：
  - protected pVM + VFIO(`NoIommu`) 的失败点能够从早期 ECAM/config 访问继续后移
  - 但不把它误判为“protected pVM 设备透传已经具备主线修复条件”
  - 若旧签名消失并暴露新的独立 DMA/IOMMU 签名，则本任务视为达成目标，但必须单独记录新 bug
