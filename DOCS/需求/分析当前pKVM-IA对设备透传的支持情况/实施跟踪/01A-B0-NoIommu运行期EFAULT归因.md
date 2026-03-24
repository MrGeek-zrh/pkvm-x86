# [B1] B0: NoIommu 主线运行期 EFAULT 归因

## 状态

- 当前状态: 待开始
- 优先级: B0（当前主阻塞）

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
- `PciRoot::add_mapping()` 中的 `failed to create vm mapping (EINVAL)` 在源码里被当成可回退到 vm-exit 的非致命路径：
  - `crosvm/devices/src/pci/pci_root.rs`
- 当前真正导致退出的用户态报错是 vCPU 运行阶段的 `Bad address (os error 14)`：
  - `crosvm/src/crosvm/sys/linux/vcpu.rs`

## 当前假设

- 假设 A：这是 T2/T3 缺失后的自然后果
  - `ptdev->pgt` 已切到 `pgstate_pgt`
  - 但 `pgstate_pgt` 仍未收敛为纯 DMA mirror 语义
  - donate 后也缺少 runtime DMA mirror 同步
  - 导致运行期某个 guest 可见页 / DMA 可见页 / ownership 语义发生错位
- 假设 B：这是独立于 T2/T3 的另一条 bug 线
  - 例如 protected VM 与 crosvm 某个只读映射优化、MMIO/shmem 映射、或 KVM run 依赖条件之间存在不兼容

## 建议实施方式

- 第一阶段：先做最小归因，不急着改大语义
  - 把 `vcpu EFAULT` 的直接触发窗口尽量收窄到具体 GPA/HPA/阶段
  - 明确它发生在“guest 正常缺页建图之后”还是“设备相关路径被触发之后”
- 第二阶段：根据归因结果决定走向
  - 如果证据指向 `pgstate_pgt` / runtime mirror 缺失，则按既有主线推进 T2 → T3
  - 如果证据指向独立 bug，则在 B1 完成后新增独立修复任务，再决定是否插到 T2/T3 前面

## 验收标准

- 能明确回答以下问题中的至少前两项：
  - `vcpu EFAULT` 的直接失败点在 host/crosvm/pKVM 的哪一层
  - `failed to create vm mapping (EINVAL)` 是否只是伴随现象，还是与最终失败存在直接因果关系
  - `BOOT-007` 是否可合理归入 T2/T3 缺失项
  - 如果不能归入，是否需要新增独立 correctness 任务

## 风险点

- 如果过早把 `BOOT-007` 归入 T2/T3，可能掩盖独立 bug。
- 如果长期停留在“只做归因”而不收敛到后续实现，会拖慢主线推进。

## 依赖

- T1。
