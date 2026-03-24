# [T5] P1: prepopulate 与首次 attach 路径

## 状态

- 当前状态: 待开始
- 优先级: P1

## 目标

解决设备首次 attach 或热插拔时，guest 中已经存在的 donated 页面如何预填充到 `pgstate_pgt`，避免 attach 后 DMA 视图为空。

## 为什么单独拆分

- 这是“功能完整性”问题，不是当前 panic 的直接根因。
- 当前 `need_prepopulation` 只有定义和置位，没有消费逻辑。
- 该任务依赖前面的 mirror 语义和 runtime hook 已经稳定。

## 关键源码锚点

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h`
  - `need_prepopulation`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`
  - `pkvm_shadow_vm_link_ptdev()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_attach_ptdev()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c`
  - `pkvm_pgtable_sync_map()`
  - `pkvm_pgtable_sync_map_range()`

## 当前已确认结论

- `need_prepopulation` 当前只在 link ptdev 时被置为 `true`。
- 没有任何代码会消费该标志。
- guest mmu 和 `pgstate_pgt` 都是 EPT 格式，理论上可以直接做全量或范围同步。

## 建议实施方向

- 首次 attach 时，从 guest mmu 向 `pgstate_pgt` 做一次全量或范围 prepopulate。
- 建议只在“ptdev_head 从空变非空”时触发首次全量 prepopulate，避免重复成本。
- 预填充失败时需要明确定义回滚策略，不应留下半构造状态。

## 验收标准

- attach 已经存在私有 guest 页的设备后，DMA 视图不是空表。
- 首次 attach 完成后，后续新增页由 T3 的 runtime hook 继续增量同步。
- 多设备 attach 不会重复做不必要的全量 prepopulate。

## 风险点

- 全量 prepopulate 可能较重，需要评估成本。
- 若与 T3 的增量同步并发交错，需要注意锁和一致性。

## 依赖

- T2
- T3
