# [B1] B0: NoIommu 主线运行期 EFAULT 归因

## 状态

- 当前状态: 已完成（源码归因）
- 优先级: B0（当前主阻塞）
- GitHub Task: `pkvm-x86#4`
- 关联 Bug: `pkvm-x86#5`

## 目标

在 T1 已验证通过之后，尽快回答一个关键问题：

- `BOOT-007` 里的 protected pVM + VFIO(`NoIommu`) 运行期 `vcpu hit unknown error: Bad address (os error 14)`，到底是：
  - T2/T3 尚未实现所自然暴露出来的后续问题
  - 还是一条与 DMA mirror 主线并行、需要单独修复的独立 bug 线

这个任务的输出不是“功能修好”，而是“把后续实现顺序定准”。

## 为什么单独拆分

- T1 已经解除旧的 donate/refcount 直接阻塞，当前失败点已经前移到更后面的运行期阶段。
- 仅凭当前现象，不能直接断言 `BOOT-007` 一定由 T2/T3 缺失引起。
- 如果不先做归因就直接进入 T2/T3，存在两类风险：
  - 把独立 bug 错当成主线缺项，导致修错方向
  - 在未确认因果关系前，把多个 correctness 变化叠在一起，后续验证难以归因

## 关键源码锚点

- crosvm `NoIommu` 路径
  - `/home/mrgeek/pkvm-x86/crosvm/src/crosvm/sys/linux/device_helpers.rs`
    - `create_vfio_device()`
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/vfio.rs`
    - `get_group_with_vm()`
    - `vfio_dma_map()`
- crosvm 只读 MMIO 映射失败路径
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/pci_root.rs`
    - `PciRoot::add_mapping()`
- crosvm vCPU 运行报错路径
  - `/home/mrgeek/pkvm-x86/crosvm/src/crosvm/sys/linux/vcpu.rs`
    - `run_vcpu()`
- protected pVM 缺页建图路径
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
    - `guest_mmu_map_leaf()`
- `pgstate_pgt` 当前 free/teardown 语义
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
    - `pkvm_pgstate_pgt_free_leaf()`
- ptdev attach 切表路径
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
    - `pkvm_attach_ptdev()`

## 当前已确认结论

- T1 已通过当前验证：
  - 不再出现 `host_initiate_donation: page refcounted`
  - 不再出现 `do_donate failed ret=-16`
  - 不再出现 `pkvm: exception`
  - 不再出现 `pgtable_unmap_leaf` assertion
- 当前 `NoIommu` 路径下，crosvm 会先对整段 guest RAM 做 `VFIO_IOMMU_MAP_DMA`：
  - `crosvm/devices/src/vfio.rs`
- 当前真正导致退出的用户态报错是 vCPU 运行阶段的 `Bad address (os error 14)`：
  - `crosvm/src/crosvm/sys/linux/vcpu.rs`
- 来自 pKVM-IA 官方 issue `#46` 的维护者答复（用户提供）进一步确认：
  - 当前 `pKVM-IA` 尚不支持把设备分配给 protected pVM
  - 旧 PoC 曾有过部分支持，但在不再使用 `#VE` 做 pVM MMIO emulation、转而要求 pVM 直接使用 hypercall 后，这条路径已不再工作
- 本地源码与该结论一致：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
  - `pv_ops.mmio.raw_read* / raw_write* / pci_mmcfg_*` 全部改成了 `PKVM_GHC_IOREAD/IOWRITE`
  - 这意味着 pVM guest 目前并不会直接访问 passthrough 设备的物理 MMIO，而是把这些访问一律当成“由 host 模拟的 MMIO”
- crosvm 的通用能力判断本意是：在 pKVM 场景下关闭 `ReadOnlyMemoryRegion`：
  - `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/mod.rs`
  - `VmCap::ReadOnlyMemoryRegion => !self.is_pkvm()`
- 但当前 x86_64 `KvmVm::is_pkvm()` 仍然硬编码返回 `false`：
  - `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs`
- 因而当前本地 crosvm 实际会误以为 `ReadOnlyMemoryRegion` 可用，继续尝试为 PCIe config page 建立只读 memslot，最终在 `add_memory_region()` 处打出 `Failed to map mmio page; Invalid argument (os error 22)`，再退回到 `vm-exit`：
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/pci_root.rs`
  - `/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs`
- PCIe ECAM 本身就是一个 `mmio_bus` 设备：
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/pci_root.rs`
    - `PciConfigMmio`
  - `/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs`
    - `mmio_bus.insert(pcie_cfg_mmio, ...)`
- pKVM x86 的 protected vCPU 缺页路径明确拒绝传统 MMIO emulation：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/mmu/mmu.c`
    - `if (pkvm_is_protected_vcpu(vcpu) && r == RET_PF_EMULATE) return -EFAULT;`
- 对于没有 memslot 的 private GPA，KVM 也会准备 `KVM_EXIT_MEMORY_FAULT` 并直接返回 `-EFAULT`：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/mmu/mmu.c`
    - `kvm_handle_noslot_fault()`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/include/linux/kvm_host.h`
    - `kvm_prepare_memory_fault_exit()`
- 当前 crosvm 的 VFIO PCI 仍然依赖 host/userspace 参与至少一部分寄存器访问路径：
  - PCI config 访问依赖 `PciRoot` / `PciConfigMmio`
  - BAR 虽然可对可 mmap 区段做 `register_memory()`，但这并不能消除 config 路径依赖
  - 见 `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs`

## 本任务结论

- `BOOT-007` 更高置信度地属于一条独立 blocker，而不是 T2/T3 缺失的直接自然后果。
- 当前更像是：
  - protected pVM 还不能消费 crosvm 这套 VFIO PCI 的 config/MMIO fallback 路径
  - 其中最直接的已知触发器是：ECAM 只读映射失败后退回 `vm-exit`，而 pKVM protected vCPU 不接受这类 MMIO emulation
- 但官方结论和 guest 侧源码进一步说明：这还不是完整根因的最深处。
- 更深一层的主阻塞是：
  - 当前 protected pVM guest 把“所有 MMIO”都走 hypercall
  - 因而即使 crosvm 侧绕开早期 ECAM/config fallback，也依然无法让 passthrough 设备 BAR 的物理 MMIO 真正直达 guest
- 进一步地，当前 host->pKVM 设备 attach 接口也没有传递 BAR/MMIO 资源元数据：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- 所以后续顺序不应把 crosvm workaround 当成主线修复，而应先承认当前分支在能力上“尚不支持 protected pVM 设备透传”，再决定是否要设计并实现新的 guest/hyp MMIO 语义

## 建议实施方式

- 第一阶段：承认并记录当前 capability gap
  - protected pVM 设备透传在当前分支尚不成立
  - crosvm workaround 只能用于验证“早期症状是否前移”，不能作为最终修复
- 第二阶段：如果仍要继续支持该能力，需要先设计 guest/hyp contract
  - guest 如何区分“需要 hypercall 的 emulated MMIO”与“应直接访问的 passthrough 物理 MMIO”
  - passthrough 设备 BAR/MMIO 资源信息如何从 host/VFIO 传给 guest/hyp
  - 哪些 MMIO 区间需要在 guest 侧被特殊标记或改走新接口
  - config space / BAR / MSI-X / virtual config 各自归谁处理
- 第三阶段：在 guest MMIO 语义明确之后，再回到 DMA 主线
  - B3 `protected pVM guest/hyp passthrough MMIO 语义设计`
  - T2 `pgstate_pgt` 纯 DMA mirror 语义化
  - T3 donate 后 runtime DMA mirror 同步

## 验收标准

- 已完成：
  - `vcpu EFAULT` 的直接失败层次已经收窄到 protected pVM 的 MMIO/config 访问语义不兼容
  - `failed to create vm mapping (EINVAL)` 不再视为纯伴随现象；它是 ECAM 只读映射失败并退回 MMIO fallback 的前置信号
  - `BOOT-007` 当前不再归入 T2/T3 缺失项
  - 后续需要新增独立 correctness 任务

## 风险点

- 当前结论仍是源码级高置信归因，不是带 GPA/回溯证据的最终运行时闭环。
- 即使修掉 config/MMIO 路径，后续仍大概率会继续暴露 T2/T3 对应的 DMA mirror 问题。

## 依赖

- T1。
