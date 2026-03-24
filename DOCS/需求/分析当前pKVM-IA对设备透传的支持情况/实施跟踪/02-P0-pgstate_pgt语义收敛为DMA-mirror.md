# [T2] P0: `pgstate_pgt` 语义收敛为 DMA mirror

## 状态

- 当前状态: 待开始
- 优先级: P0

## 目标

把 `pgstate_pgt` 明确收敛为“供 IOMMU 使用的 DMA mirror pgtable”，不再让它参与 pVM 页面 ownership 的回收逻辑。

## 为什么单独拆分

- 方案 B 是否能稳定落地，关键就在于 ownership 和 DMA 翻译视图必须分离。
- 如果 `pgstate_pgt` 仍然在 teardown 时执行 `__pkvm_host_undonate_guest()`，会与 guest mmu teardown 的 undonate 逻辑产生语义重叠。

## 关键源码锚点

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - `pgstate_pgt` 注释
  - `pkvm_pgstate_pgt_free_leaf()`
  - `pkvm_pgstate_pgt_deinit()`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - `guest_mmu_free_leaf()`

## 当前已确认结论

- 当前注释仍把 `pgstate_pgt` 描述为“内存是 pinned，映射不允许删除”。
- 当前 `pkvm_pgstate_pgt_free_leaf()` 对 protected VM 会执行 `__pkvm_host_undonate_guest()`。
- 当前 `guest_mmu_free_leaf()` 对 protected VM 也会执行 `__pkvm_host_undonate_guest()`。

## 建议收敛方向

- `pgstate_pgt`:
  - 负责维护 DMA 可见的 GPA -> HPA 映射。
  - 允许随 guest 页生命周期动态增删映射。
  - teardown 时只负责释放 mirror 页表自身，不负责 ownership 回收。
- `pkvm_vm->mmu`:
  - 继续作为 pVM 页面 ownership 的唯一真实来源。
  - donate / undonate / wipe 页面仍由 guest mmu 路径负责。

## 验收标准

- `pgstate_pgt` 与 guest mmu 不再双重承担 undonate。
- 文档、注释和实现语义一致。
- 后续 T3、T4 可以基于该语义继续补 runtime mirror 和 teardown。

## 风险点

- 如果语义收敛不彻底，后面补 runtime mirror 时容易出现双重释放或 teardown 顺序问题。
- 需要确保非 protected VM 路径不被误伤。

## 依赖

- 可与 T1 并行分析，但正式代码落地最好在 T1 之后。
