结论先给：

- 我不建议选 A 作为 pVM 透传主模型。
- 我建议选 B，但落地形式不是“直接复用 host shadow spgt”，而是“保持 pVM 内存继续 donate + 在 Hyp 里维护一个 pVM 专用 IOMMU second-level mirror pgtable”。这个 pgtable 可以复用现在的 `vm->pgstate_pgt`，但它的语义要改成“DMA mirror”，不要再承担 ownership 回收。
- 第三个可选方案是“显式 DMA-share 窗口”，只适合分阶段 bring-up，不适合通用透传。

当前代码里其实已经有这个方向的骨架：`pkvm_attach_ptdev()` 会把 `ptdev->pgt` 切到 `vm->pgstate_pgt`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c:162`；而 shadow IOMMU 在 attached 场景下会把 shadow context/PASID entry 的 `SLPTR` 改成 `ptdev->pgt->root_pa`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:578` 和 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:755`。缺的不是“rebind 想法”，而是“pVM IOMMU pgtable 的正确填充和生命周期”。

**问题1**

- A 不适合做 pVM 通用透传主模型。
- 原因不是“做不到”，而是“安全边界不对”：
  - pVM 现在的核心价值是 host 对 guest RAM 不可见；`guest_mmu_map_leaf()` 对 protected VM 明确走 donate，见 `pKVM-IA/arch/x86/kvm/pkvm/mmu.c:426`。
  - 如果改成 host-share-guest，全量 backing memory 在 host EPT 里仍然 present，host CPU 直接可读写，confidentiality 基本就没了。
- ARM v6.18 的 share 模型不能直接照搬到 x86：
  - ARM 依赖 `host_share_guest_count`，见 `pkvm-v6.18/arch/arm64/kvm/hyp/include/nvhe/memory.h:50`。
  - x86 的 `struct hyp_page` 只有 `refcount/order`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/buddy_memory.h:12`。
  - x86 现有 share 实现是靠 pin shared page，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c:823` 和 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c:1130`，这更像“防止被错误 unshare”，不是“安全地支持 host 长期持有 pVM RAM”。

我建议的正式方案是：

- 默认内存模型继续保持 donate；
- attached ptdev 不再走 host shadow spgt，也不再依赖 host EPT；
- 给 pVM 建一个 Hyp 控制的 IOMMU second-level mirror pgtable；
- 这个 mirror pgtable 只反映 GPA->HPA DMA 翻译，不参与 ownership 迁移；
- ownership 仍然只由 `pkvm_vm->mmu` 驱动。

这样更适合 pKVM-IA，因为：

- 它保留了 protected VM 的“host 不可见”性质；
- 它和现有 attach/rebind 代码方向一致；
- 它避免把 IOMMU leaf pin/refcount 重新引回 pVM 私有页；
- 它还能继续利用 `pgstate_pgt` 现成的 IOMMU-cap/mm_ops/coherency 逻辑，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c:357` 和 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c:22`。

第三种选择我建议只作为过渡方案：

- “显式 DMA-share 窗口”，即默认仍 donate，只有 guest 主动 share 出来的 DMA buffer 才让设备访问。
- 这可以基于 `__pkvm_guest_share_host()` 做，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c:1003`。
- 优点是安全性比 A 高很多；
- 缺点是这不是“通用设备透传”，而是“受控 DMA buffer 共享”。

**问题2**

是的：对你描述的 stale refcount panic，`pkvm_put_host_iommu_spgt()` 把

- `pkvm_pgtable_destroy(&spgt->pgt, NULL)`

改成带 leaf cleanup 的 destroy，原则上足够修当前问题。

原因很直接：

    host legacy shadow IOMMU
        sync_shadow_pgt(...)
            shadow_pgt_map_leaf(...)
                hyp_page_ref_inc(HPA)    // `shadow_iommu.c:330`
        ...
        pkvm_put_host_iommu_spgt(...)
            pkvm_pgtable_destroy(..., NULL)   // `iommu_spgt.c:101`
            // 没有对称 hyp_page_ref_dec
        ...
        __pkvm_host_donate_guest(...)
            host_initiate_donation(...)
                hyp_page_count(...) != 0 -> -EBUSY   // `mem_protect.c:382`

对应的对称释放函数已经存在，就是 `shadow_pgt_unmap_leaf()`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:395`。

副作用我看是可控的：

- 它只会对 present leaf 做 `hyp_page_ref_dec()`；
- MMIO leaf 因为 `hyp_phys_to_page_safe()` 会失败，不会误减；
- spgt 的对象 refcount 已经归零时才 destroy，不存在“还在被设备使用却提前 dec”的新问题；
- 不需要额外 IOTLB flush，因为最后一个 `spgt` 用户已经没了，root 也不会再被引用。

但有两个边界要说明：

- 这只能修“host shadow spgt 销毁时漏 dec”这一类 panic；如果页面还被别的 pin source 持有，还是会 `-EBUSY`。
- `shadow_pgt_unmap_leaf()` 现在是 `static`，不能直接跨文件调用；实现上更干净的做法是把 leaf ref-release helper 下沉到 `iommu_spgt.c` 或抽公共 helper，而不是简单去掉 `static`。

**问题3**

1. attach 前后 shadow IOMMU 的状态变化

attach 前，设备还是 host 侧翻译：

- legacy 模式：
  - `ptdev->vpgt` 指向 host 给的 SL root；
  - `ptdev->pgt` 是 host shadow spgt 或 host EPT；
  - `sync_shadow_pgt()` 会把 host 页表同步到 shadow spgt，并对 leaf HPA 做 refcount，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:422`。
- scalable 模式：
  - shadow PASID entry 里的 `SLPTR` 指向 `ptdev->pgt->root_pa`；
  - attached 前通常是 host root 或 host shadow root，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:657`。

attach 后，应该切到 pVM mirror root：

    pkvm_add_ptdev(...)
        pkvm_attach_ptdev(...)
            prepopulate pVM DMA mirror pgt
            ptdev->pgt = &vm->pgstate_pgt
            pkvm_iommu_sync(...)
                sync_shadow_context_entry / sync_shadow_pasid_table_entry
                    SLPTR = vm->pgstate_pgt.root_pa

也就是说：

- `ptdev->vpgt` 仍可保留 host/guest 原始 IOMMU 配置上下文；
- 但真正给硬件用的 second-level root 改成 pVM mirror pgt；
- `pkvm_iommu_sync()` 负责把 shadow context/PASID entry 更新并 flush old/new DID，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c:1152`。

2. pVM 内存 donate 和 IOMMU 映射的时序

我建议分成两个阶段：

- attach 时做一次“历史映射预填充”
- attach 后对新增映射做“增量 mirror”

具体时序：

(1) attach 前已经存在的 pVM 映射
- 这些页已经在 `pkvm_vm->mmu` 中 donate 完成，来源是 `guest_mmu_map_leaf()` -> `__pkvm_host_donate_guest()`，见 `pKVM-IA/arch/x86/kvm/pkvm/mmu.c:385` 和 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c:661`。
- attach 时要先从 `pkvm_vm->mmu` 把现有 GPA->HPA 同步到 `vm->pgstate_pgt`，再做 `ptdev->pgt` 切换和 `pkvm_iommu_sync()`。
- 不要先切 root 再去补 mirror，否则设备会先看到一个空 root。

(2) attach 后新增的 pVM 映射
- 仍然先 donate 到 `pkvm_vm->mmu`；
- donate 成功后，再把同一段 GPA->HPA map 到 `vm->pgstate_pgt`；
- 如果 mirror 失败，要回滚刚刚的 guest map/donate，保证 CPU view 和 DMA view 一致。

这里有个关键点：

- 不能复用 `shadow_pgt_map_leaf()` 去填 `vm->pgstate_pgt`；
- 因为它会先 `pkvm_host_ept_lookup(data->phys)`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:342`；
- donate 后的 pVM 私有页已经不在 host EPT 里，这个检查会直接失败。

所以 pVM 的 IOMMU mirror 必须有单独的 map helper：

- 不查 host EPT；
- 不给 leaf HPA 做 `hyp_page_ref_inc()`；
- 只写 IOMMU 需要的 EPT leaf。

3. 需要增加哪些新的 hypercall 或钩子

我认为不需要新的“外部 ABI hypercall”才能做成透明透传，现有 `pkvm_add_ptdev()` 入口够了；需要的是几个内部钩子/辅助函数。

建议改动点：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c`
  - 修 `pkvm_put_host_iommu_spgt()` 的 destroy callback，解决 stale refcount。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_attach_ptdev()` 里增加 prepopulate 流程；
  - 最好让它拿到对应的 `struct pkvm_vm *`，不要只拿 `shadow_vm`。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - 把 `pgstate_pgt` 明确改成“pVM DMA mirror pgt”语义，或者新建 `iommu_pgt`；
  - 新增：
    - `pkvm_pgstate_pgt_prepopulate_from_guest_mmu(...)`
    - `pkvm_pgstate_pgt_map_range(...)`
  - 现有 `pkvm_pgstate_pgt_free_leaf()` 不能继续用于 pVM DMA mirror；ownership 回收只能由 `guest_mmu_free_leaf()` 做，见 `pKVM-IA/arch/x86/kvm/pkvm/mmu.c:624`。
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - 在 protected VM 的 map 成功后，增加一个 arch hook，把新映射 mirror 到 `pgstate_pgt`；
  - 这个 hook 最好做成 VMX-specific helper，因为 generic `mmu.c` 不该直接了解 `shadow_vm` 布局。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`
  - `pkvm_teardown_shadow_vm()` 的顺序要反过来：
    - 先 detach all ptdev
    - 再 destroy `pgstate_pgt`
  - 现在是先 deinit pgt 再 detach，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c:87`，这对真正启用的 pVM DMA root 是不安全的。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`
  - attach 后的 rebind 逻辑本身够用，重点是保持“host shadow spgt 路径”和“pVM DMA mirror 路径”分离，不要混用 leaf callback。

我建议的完整新流程是：

    VM 运行中，guest fault/map
        pkvm_vm_mmu_map(...)
            guest_mmu_map_leaf(...)
                __pkvm_host_donate_guest(...)   // 只改 guest mmu ownership
            if vm has attached ptdev
                pkvm_pgstate_pgt_map_range(...) // 只建 DMA mirror，不改 ownership

    设备 attach 到 pVM
        pkvm_add_ptdev(...)
            update pgstate_pgt coherency mode
            prepopulate pgstate_pgt from pkvm_vm->mmu
            ptdev->pgt = &vm->pgstate_pgt
            pkvm_iommu_sync(...)               // root switch + IOTLB flush

    设备 detach / VM teardown
        pkvm_detach_ptdev(...)
            ptdev->pgt = host root
            pkvm_iommu_sync(...)
        destroy pgstate_pgt
        destroy pkvm_vm->mmu
            guest_mmu_free_leaf(...)
                __pkvm_host_undonate_guest(...)

最后给一个决策建议：

- 短期：
  - 先修 `iommu_spgt.c` 的 stale refcount；
  - 这是当前 panic 的必要修复。
- 中期：
  - 落地“donate + pVM DMA mirror pgt”；
  - 这是适合 pKVM-IA 的正式方案。
- 如果你只是想先把设备跑起来做 bring-up：
  - 可以单独做“显式 DMA-share 窗口”模式；
  - 但不要把它当成最终的 pVM 透传方案。

如果你愿意，我下一步可以继续把这个方案收敛成一版“按文件/函数拆分的 patch plan”。
