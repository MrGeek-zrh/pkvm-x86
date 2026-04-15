# [T10] B5-2 protected pVM Guest EPT 建图完整性缺口实现

## 状态

- 当前状态: 设计中（核心缺口已确认：Host 通过 memslot/HVA 掌握 candidate HPA 选择权，MMIO BAR 场景下缺少 device BAR 范围约束）
- 所属主任务: `pkvm-x86#20`
- 关联设计文档:
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-2-protected-pVM-Guest-EPT建图边界设计.md`

## 当前阻塞

核心缺口已确认：

- Host 在 `vm_mmu_map` 前通过 memslot/HVA 解析出 candidate HPA，hyp 收到成品 HPA
- hyp 只验证 donation 合法性（ownership/page-state/mem_range/refcount），不验证语义绑定正确性
- 对 MMIO BAR 场景：现有 `__pkvm_host_donate_guest` 的校验体系语义是针对 host RAM page 的，不适用于 PCI 物理地址
- hyp 缺少 device BAR 范围约束，无法判断收到的 PCI 物理地址是否落在正确的 BAR 范围内

待确定：

- 在当前 threat model 下，这条缺口是否需要新增实现，还是接受现状
- 如果需要新增实现，方案方向待定（见设计文档）

## 关键源码锚点

### Host 侧（HVA → HPA 解析）

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c` — `kvm_faultin_pfn()`、`__kvm_faultin_pfn()`、`pkvm_page_fault()`
- `pKVM-IA/virt/kvm/kvm_main.c` — `hva_to_pfn()`、`hva_to_pfn_remapped()`、`follow_pfnmap_start()`
- `pKVM-IA/drivers/vfio/vfio_iommu_type1.c` — `follow_fault_pfn()`，VFIO 建立 BAR VMA 后触发 `follow_pfnmap_start()` 返回 PCI 物理地址

### MMIO metadata 配置

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c` — `pkvm_vm_ioctl_set_ptdev_mmio_metadata()`、`pkvm_sync_ptdev_mmio_metadata()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c` — `pkvm_sync_ptdev_mmio_metadata()`（hyp 侧同步）
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c` — `pkvm_set_ptdev_mmio_metadata()`，将 BAR 范围写入 `vm->mmio_allow_ranges[]`

### MMIO allowlist（仅限 GPA 合法性）

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c` — `pkvm_update_vm_mmio_allowlist()`、`pkvm_guest_mmio_check()`
- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c` — VM exit 时用 allowlist 校验 GPA 是否在允许范围内
- `pKVM-IA/arch/x86/include/uapi/asm/kvm.h` — `struct kvm_protected_vm_ptdev_mmio_metadata`、`struct kvm_protected_vm_ptdev_mmio_range`（含 `bar_offset`、`bar_index`、`kind`）

### hyp 侧建图（缺少 BAR 范围校验）

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c` — `pkvm_vm_mmu_map()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c` — `__pkvm_host_donate_guest()`、`check_donation()`、`find_mem_range()`

## 非目标

- 不覆盖 boot-time manifest 设备名单边界（B5-1）
- 不覆盖 `pgstate_pgt` DMA mirror（P0）
- 不引入 per-VM contract / firmware token / device lease 等超出现阶段范围的方案
- 不覆盖 `pvmfw` 页 trusted 内容完整性（独立信任根问题）

## 验收标准

待方案方向确定后补写。
