# [T10] B5-2 protected pVM Guest EPT 建图完整性缺口实现

## 状态

- 当前状态: 设计中（核心缺口已收敛：Host 通过 memslot/HVA 掌握 candidate HPA 选择权，hyp 无 per-GPA authoritative truth source）
- 所属主任务: `pkvm-x86#20`
- 关联设计文档:
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-2-protected-pVM-Guest-EPT建图边界设计.md`

## 当前阻塞

核心缺口已确认：

- Host 在 `vm_mmu_map` 前通过 memslot/HVA 解析出 candidate HPA，hyp 收到成品 HPA
- hyp 只验证 donation 合法性（ownership/page-state/mem_range/refcount），不验证语义绑定正确性
- `struct pkvm_vm` / `struct pkvm_shadow_vm` 均不包含 per-GPA authoritative truth source
- 这条缺口同时覆盖普通 RAM 和透传 MMIO/BAR，两者共用同一来源链

待确定：

- 在当前 threat model 下，这条缺口是否需要新增实现，还是接受现状
- 如果需要新增实现，具体方向是 launch-time GPA snapshot 还是 memslot provenance 约束

## 关键源码锚点

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c` — `kvm_faultin_pfn()`、`__gfn_to_pfn_memslot()`
- `pKVM-IA/virt/kvm/kvm_main.c` — `hva_to_pfn()`、`hva_to_pfn_remapped()`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c` — `pkvm_vm_mmu_map()`、`guest_mmu_map_leaf()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c` — `__pkvm_host_donate_guest()`、`check_donation()`

## 非目标

- 不覆盖 boot-time manifest 设备名单边界（B5-1）
- 不覆盖 `pgstate_pgt` DMA mirror（P0）
- 不引入 per-VM contract / firmware token / device lease 等超出现阶段范围的方案
- 不覆盖 `pvmfw` 页 trusted 内容完整性（独立信任根问题）

## 验收标准

待方案方向确定后补写。
