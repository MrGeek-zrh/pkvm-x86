# [T1] P0: 清理旧 shadow spgt 残留 refcount

## 状态

- 当前状态: 已完成，首轮运行验证通过
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

## 修复前 / 修复后关键调用路径对比

- 修复前：shadow spgt 销毁路径不会回收 `shadow_pgt_map_leaf()` 对数据页额外持有的 refcount

    sync_shadow_pgt()
        -> pkvm_pgtable_sync_map_range()
            -> shadow_pgt_map_leaf()
                -> hyp_page_ref_inc(data_page)

    ptdev attach / 换表 / 释放旧 spgt
        -> pkvm_put_host_iommu_spgt()
            -> pkvm_pgtable_destroy(&spgt->pgt, NULL)
                -> 默认 leaf free 路径
                    -> 只释放页表页本身
            -> 不经过 shadow_pgt_unmap_leaf()
                -> 不会 hyp_page_ref_dec(data_page)

    后续 pVM 启动缺页 donate
        -> __pkvm_host_donate_guest()
            -> host_initiate_donation()
                -> hyp_page_count(data_page) != 0
                    -> return -EBUSY

- 修复后：shadow spgt 销毁路径显式接入 destroy 专用 free callback，回收旧 refcount

    sync_shadow_pgt()
        -> pkvm_pgtable_sync_map_range()
            -> shadow_pgt_map_leaf()
                -> hyp_page_ref_inc(data_page)

    ptdev attach / 换表 / 释放旧 spgt
        -> pkvm_put_host_iommu_spgt()
            -> free_leaf = pkvm_host_iommu_spgt_free_leaf
            -> pkvm_pgtable_destroy(&spgt->pgt, free_leaf)
                -> pkvm_host_iommu_spgt_free_leaf()
                    -> hyp_page_ref_dec(data_page)
                    -> put_page(ptep)

    后续 pVM 启动缺页 donate
        -> __pkvm_host_donate_guest()
            -> host_initiate_donation()
                -> hyp_page_count(data_page) == 0
                    -> donate 不再被旧 shadow spgt 残留 refcount 阻塞

## 当前实施进展

- 已完成首版补丁:
  - 在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c` 中，spgt 最终销毁时改为传入 shadow-IOMMU 对应的 leaf free callback。
  - 在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c` 中增加 destroy 专用的 `pkvm_host_iommu_spgt_free_leaf()`，用于回收 `shadow_pgt_map_leaf()` 额外持有的数据页 refcount，同时按 destroy 语义释放 leaf entry。
  - 为避免影响 `CONFIG_PKVM_INTEL_PVIOMMU`，该回调接入做了配置保护。
- 已完成局部编译检查:
  - `make -C pKVM-IA arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.o arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.o arch/x86/kvm/vmx/pkvm/hyp/ptdev.o`
  - 结果: 通过
- 已完成首轮运行验证:
  - 先前错误路径 `pgtable_unmap_leaf` assertion 已消失，不再出现 `arch/x86/kvm/vmx/pkvm/hyp/pgtable.c:279: phys == data->phys`。
  - 最新 `NoIommu` 验证中，不再出现 `host_initiate_donation: page refcounted`、`do_donate failed ret=-16`、`pkvm: exception` 等旧阻塞签名。
  - protected pVM + VFIO 已能继续走到 guest `bzImage` 加载，说明旧的 donate/refcount 阻塞已不是当前主障碍。
- 尚未完成:
  - 共享 spgt 场景验证
  - 后续任务回归验证

## 最新验证结论

- 结论: T1 已通过当前验证，旧 shadow spgt 残留 refcount 不再是当前 blocker。
- 现象迁移:
  - `NoIommu` 路径下，crosvm 仍会打印 `Failed to map mmio page; failed to create vm mapping`。
  - 该错误在 crosvm `devices/src/pci/pci_root.rs` 中属于可退回 vm-exit 的非致命路径，不足以单独解释当前失败。
  - 当前新的主现象是 vCPU 运行阶段 `vcpu hit unknown error: Bad address (os error 14)`，属于 T1 之后暴露出的新阶段问题。

## 建议实施方式

- 已采用方向：在 spgt 销毁路径接入 destroy 专用 leaf free callback，仅做数据页 refcount 回收和 destroy 语义的 leaf 释放，不再复用 `shadow_pgt_unmap_leaf()`。
- 需要同时评估共享 spgt 场景：
  - 如果多个设备共用同一 spgt，则不能简单在某个设备 attach 时提前释放整个 spgt。
  - 必须确认 refcount 回收是否与 spgt 生命周期严格绑定，还是需要更细粒度解绑。

## 验收标准

- attach 之前由 host shadow spgt 引入的数据页 refcount 可以在正确时机回收。
- pVM 启动时，`host_initiate_donation()` 不再因为该路径残留的 refcount 命中 `-EBUSY`。
- host 非 pVM 路径的 shadow IOMMU 行为不被破坏。

## 验收结果

- 已满足:
  - 旧 donate/refcount 阻塞签名已消失。
  - 旧 `pgtable_unmap_leaf` assertion 已消失。
- 待持续观察:
  - host 非 pVM 路径和共享 spgt 场景还需要后续回归。

## 风险点

- 共享 spgt 场景可能导致“改一处、坏多处”。
- 如果 refcount 回收时机过早，可能影响 host 侧设备仍在使用的 DMA 映射。

## 依赖

- 无。
