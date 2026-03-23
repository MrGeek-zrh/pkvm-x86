# [T1] P0: 清理旧 shadow spgt 残留 refcount

## 状态

- 当前状态: 待开始
- 优先级: P0

## 目标

解决当前 pVM 启动时最直接的阻塞点：旧 host shadow IOMMU spgt 在 attach 前已经对数据页做了 `hyp_page_ref_inc()`，但后续释放 spgt 时没有回收这些 refcount，导致 `__pkvm_host_donate_guest()` 命中 `-EBUSY`。

## 为什么单独拆分

- 这是当前 panic 的直接根因。
- 即使后续 `pgstate_pgt` mirror 逻辑全部补齐，只要旧 refcount 不清理，启动仍然失败。
- 这是最小 unblocker，适合先落地。

## 关键源码锚点

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`
  - `shadow_pgt_map_leaf()`
  - `shadow_pgt_unmap_leaf()`
  - `sync_shadow_pgt()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c`
  - `pkvm_put_host_iommu_spgt()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
  - `host_initiate_donation()`

## 当前已确认结论

- `shadow_pgt_map_leaf()` 会对映射到 shadow spgt 的数据页做 `hyp_page_ref_inc()`。
- `pkvm_put_host_iommu_spgt()` 在 spgt refcount 降到 0 时调用 `pkvm_pgtable_destroy(&spgt->pgt, NULL)`，不会经过 `shadow_pgt_unmap_leaf()`。
- `host_initiate_donation()` 对目标页做 `hyp_page_count()` 检查，只要 refcount 非 0 就直接拒绝 donate。

## 建议实施方式

- 首选方向：让 spgt 销毁路径在释放 leaf 时经过 `shadow_pgt_unmap_leaf()`，确保数据页 refcount 成对回收。
- 需要同时评估共享 spgt 场景：
  - 如果多个设备共用同一 spgt，则不能简单在某个设备 attach 时提前释放整个 spgt。
  - 必须确认 refcount 回收是否与 spgt 生命周期严格绑定，还是需要更细粒度解绑。

## 验收标准

- attach 之前由 host shadow spgt 引入的数据页 refcount 可以在正确时机回收。
- pVM 启动时，`host_initiate_donation()` 不再因为该路径残留的 refcount 命中 `-EBUSY`。
- host 非 pVM 路径的 shadow IOMMU 行为不被破坏。

## 风险点

- 共享 spgt 场景可能导致“改一处、坏多处”。
- 如果 refcount 回收时机过早，可能影响 host 侧设备仍在使用的 DMA 映射。

## 依赖

- 无。
