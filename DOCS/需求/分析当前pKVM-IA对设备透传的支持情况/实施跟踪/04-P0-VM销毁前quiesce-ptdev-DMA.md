# [T4] P0: VM 销毁前 quiesce ptdev DMA

## 状态

- 当前状态: 验证中（3 个 case × 10 轮矩阵已跑完，未稳定复现）
- 优先级: P0

## 目标

在 pVM 销毁前，先让设备失去对 pVM 私有页的 DMA 可达性，再执行 guest mmu teardown / undonate，保证生命周期顺序正确。

## 为什么单独拆分

- 这是 correctness 前提，不是优化项。
- 当前源码里 guest/mmu teardown 与 ptdev / VFIO 销毁时序存在生命周期风险，需要单独验证和收敛。
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
- 截至 2026-04-15，`Case A: 活跃 DMA + host 强制销毁` 已单次观测到新的 teardown 相关 DMAR fault 签名：

```text
[Wed Apr 15 14:36:20 2026] DMAR: DRHD: handling fault status reg 2
[Wed Apr 15 14:36:20 2026] DMAR: [DMA Read NO_PASID] Request device [01:00.0] fault addr 0xff0f0000 [fault reason 0x06] PTE Read access is not set
```

- 同一轮后续还能看到 host 侧 NVMe 重新 probe 时出现 timeout / `probe ... failed`，说明 teardown 后设备状态也受到影响。
- 但在 2026-04-15 补做的 `Case A/B/C` 各 10 轮矩阵里：
  - `Case A`：`10/10` 全负例
  - `Case B`：`10/10` 全负例
  - `Case C`：`10/10` 全负例
- 当前结论更新为：
  - 单次正例仍然值得保留，但它不是当前步骤下的稳定可复现签名；
  - 现阶段更像“存在低概率 teardown 风险窗口或隐藏触发条件”，还不能直接把 `T4` 从 validation-first 切到最终修复定稿。

## 建议实施方向

- 当前先不直接进入代码修改，先按 `04A-P0-teardown-DMA生命周期风险验证与触发样例.md` 执行验证样例。
- 不要直接把现有 `pkvm_detach_ptdev()` 前移当成最终解。
- 需要单独设计一个“VM teardown 前的 ptdev quiesce/invalidate”步骤，至少满足：
  - 设备不再通过 `pgstate_pgt` 访问 pVM 页。
  - 设备也不能在 VFIO 设备对象仍存活时重新走回 host 侧旧 DMA 映射。
  - quiesce 完成后，guest mmu 才允许 undonate 页面。

## 当前验证入口

- 触发样例与证据采集规则见 `04A-P0-teardown-DMA生命周期风险验证与触发样例.md`。
- 当前本地问题记录见 `../问题记录/BOOT-014/BOOT-014-protected-pVM-活跃DMA时host强杀crosvm后单次出现DMAR-NO_PASID-fault.md`。
- 当前文档继续作为“风险归因 + 修复方向”入口使用；是否升级为独立 GitHub `Bug + Task`，取决于后续是否在更细粒度触发条件下再次稳定复现同签名。

## 验收标准

- guest 页回到 host 前，设备已失去对这些页的 DMA 可达性。
- teardown 过程中不会出现“设备仍 DMA 到已归还 host 的物理页”。
- 与 KVM / VFIO 既有销毁顺序兼容。

## 风险点

- 如果只是简单前移 `pkvm_detach_ptdev()`，很可能把设备重新暴露到 host IOMMU 视图。
- 该任务可能需要新增 host <-> hyp 协作点，而不只是调整调用顺序。

## 依赖

- T2。
