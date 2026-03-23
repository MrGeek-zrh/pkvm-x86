# [T4] P0: VM 销毁前 quiesce ptdev DMA

## 状态

- 当前状态: 待开始
- 优先级: P0

## 目标

在 pVM 销毁前，先让设备失去对 pVM 私有页的 DMA 可达性，再执行 guest mmu teardown / undonate，保证生命周期顺序正确。

## 为什么单独拆分

- 这是 correctness 前提，不是优化项。
- 当前实现里“先销毁 guest/mmu，再处理 ptdev”是错误顺序。
- 更关键的是，现有 `pkvm_detach_ptdev()` 只是切回 host IOMMU 视图，不等于真正 quiesce DMA。

## 关键源码锚点

- `pKVM-IA/arch/x86/kvm/pkvm/pkvm.c`
  - `pkvm_vm_destroy()`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - `pkvm_vm_mmu_destroy()`
  - `guest_mmu_free_leaf()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`
  - `pkvm_teardown_shadow_vm()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_detach_ptdev()`
- `pKVM-IA/virt/kvm/kvm_main.c`
  - `kvm_destroy_vm()`
- `pKVM-IA/virt/kvm/vfio.c`
  - `kvm_vfio_file_del()`
  - `kvm_vfio_release()`

## 当前已确认结论

- `pkvm_vm_destroy()` 当前先做 `pkvm_vm_mmu_destroy()`，后做 `kvm_arch_destroy_vm()`。
- `pkvm_teardown_shadow_vm()` 当前先 `pkvm_pgstate_pgt_deinit()`，再 `pkvm_detach_ptdev()`。
- `kvm_destroy_vm()` 当前是先 `kvm_arch_destroy_vm()`，再 `kvm_destroy_devices()`，因此 VFIO 设备释放晚于 pKVM VM 销毁。
- 现有 `pkvm_detach_ptdev()` 会把 `ptdev->pgt` 直接切回 `host_vm.ept` 并调用 `pkvm_iommu_sync()`，这更像“恢复 host 视图”，不是“立即阻断 DMA”。

## 建议实施方向

- 不要直接把现有 `pkvm_detach_ptdev()` 前移当成最终解。
- 需要单独设计一个“VM teardown 前的 ptdev quiesce/invalidate”步骤，至少满足：
  - 设备不再通过 `pgstate_pgt` 访问 pVM 页。
  - 设备也不能在 VFIO 设备对象仍存活时重新走回 host 侧旧 DMA 映射。
  - quiesce 完成后，guest mmu 才允许 undonate 页面。

## 验收标准

- guest 页回到 host 前，设备已失去对这些页的 DMA 可达性。
- teardown 过程中不会出现“设备仍 DMA 到已归还 host 的物理页”。
- 与 KVM / VFIO 既有销毁顺序兼容。

## 风险点

- 如果只是简单前移 `pkvm_detach_ptdev()`，很可能把设备重新暴露到 host IOMMU 视图。
- 该任务可能需要新增 host <-> hyp 协作点，而不只是调整调用顺序。

## 依赖

- T2。
