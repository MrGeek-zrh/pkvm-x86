我对着源码看，问题主要有这些：

**最严重**
- 文档里的 teardown 总顺序判断错了。真实路径是：
```text
pKVM destroy
    pkvm_vm_destroy()                  (pKVM-IA/arch/x86/kvm/pkvm/pkvm.c:669)
        pkvm_vm_mmu_destroy()          (pKVM-IA/arch/x86/kvm/pkvm/mmu.c:701)
            guest_mmu_free_leaf()      (pKVM-IA/arch/x86/kvm/pkvm/mmu.c:624)
                __pkvm_host_undonate_guest()  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c:711)
        kvm_arch_destroy_vm()          (pKVM-IA/arch/x86/kvm/pkvm/pkvm.c:695)
            vmx_vm_destroy()           (pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c:7605)
                pkvm_teardown_shadow_vm()     (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c:87)
```
- 所以仅把 `pkvm_teardown_shadow_vm()` 改成“先 detach 再 destroy `pgstate_pgt`”不够；设备仍可能在 `pkvm_vm_mmu_destroy()` 期间挂着 `pgstate_pgt`，而 guest 页已经被 `guest_mmu_free_leaf()` 归还给 host。detach 必须前移到 `pkvm_vm_mmu_destroy()` 之前。
- `pkvm_detach_ptdev()` 是 `void`，`pkvm_iommu_sync()` 的失败不会向上传播；如果你把“先 detach”当成安全前提，这个静默失败路径也要处理。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c:129` 和 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c:139`。

**技术准确性**
- “detach 后 IOMMU 切回 host root”写得过于绝对，不准确。`pkvm_detach_ptdev()` 只是先把 `ptdev->pgt` 暂时置成 `host_vm.ept`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c:134`；真正 `pkvm_iommu_sync()` 时会按 host 当前 context/PASID 配置重建，可能回到 host shadow spgt 或 nested/SL-only，不一定是 bare host root。相关路径见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:540`, `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:579`, `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:666`, `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:674`, `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:756`。
- 文档只提了 `sync_shadow_context_entry()`，漏了 scalable mode 的 `sync_shadow_pasid_table_entry()`；PASID 设备的 `SLPTR`/翻译类型是在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:756` 和 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:755` 这条路径写的，不只是 `.../shadow_iommu.c:579`。
- `hyp_page.refcount` 的语义被说窄了。`host_initiate_donation()` 只要 `hyp_page_count()!=0` 就拒绝 donate，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c:383`；这不只代表“host shadow IOMMU 引用”，共享页 pin 也会加 refcount，例如 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c:163` 和 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c:845`。所以“refcount>0 == 被 host shadow IOMMU 引用”不成立。

**pgstate_pgt 语义分离**
- 方向基本对，但文档低估了改动面。当前 protected VM 的 `pkvm_pgstate_pgt_free_leaf()` 明确把 present leaf 当成“要 undonate 的 guest 页”处理，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c:398` 和 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c:439`；如果把 `pgstate_pgt` 改成纯 DMA mirror，就必须为 protected VM 单独换 destroy callback，不能只“改理解”。
- 不能简单把 `shadow_pgt_unmap_leaf()` 导出后塞给 `pkvm_pgtable_destroy()`。它内部会调 `pgtable_unmap_leaf()`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c:417`；而 `pgtable_unmap_leaf()` 要求 `arg` 是 `struct pkvm_pgtable_unmap_data`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c:267`；但 `pkvm_pgtable_destroy()` 传的是 `struct pkvm_pgtable_free_data`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c:686`。所以这里需要单独的 destroy-only helper，不是仅仅“去掉 static”。
- 如果 `pgstate_pgt` 只做 DMA mirror，那么 teardown 正确语义应该是：先让所有 ptdev 脱离 `pgstate_pgt` 并完成 IOMMU/context/IOTLB 切换，再 destroy `pgstate_pgt`，最后再 destroy `pkvm_vm->mmu`；而这个“先 detach”要放在 `pkvm_vm_mmu_destroy()` 之前，不是只放在 `pkvm_teardown_shadow_vm()` 里。

**并发**
- “多核同时 donate 不同 GPA”本身不是主要风险，因为同一 VM 的 `pkvm_vm_mmu_map()` 已经被 `guest_mmu_lock()` 串行化了，见 `pKVM-IA/arch/x86/kvm/pkvm/mmu.c:513`。如果 mirror update 仍放在这条锁保护下，同 VM 的多核 donate 不会并发写 `pgstate_pgt`。
- 真正缺的是 attach/prepopulate 与 donate 的并发设计。`pkvm_attach_ptdev()` 当前不拿 `guest_mmu_lock()`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c:162`；如果你先 prepopulate，再切换 `ptdev->pgt`/attached 可见状态，中间可能插入一次 donate，这次 donate 既不在 prepopulate 快照里，也可能因为“尚未 attached”而不走 runtime mirror hook，最后 `pgstate_pgt` 会漏映射。
- 还要管 `vm->lock`/mm_ops 切换竞争。`pkvm_shadow_vm_link_ptdev()` / `unlink` 会改 `vm->noncoherent_ptdev` 并切换 `pgstate_pgt` 的 mm_ops，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c:27`, `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c:29`, `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c:39`, `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c:40`, `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c:477`；mirror map 路径如果不和这个锁域协调，non-coherent IOMMU 的 cache flush 可能丢。

**设计遗漏/不合理**
- `prepopulate` 放在文档现在那个位置不对：你写的是先 prepopulate，再 `ptdev->pgt = &vm->pgstate_pgt`。但 non-coherent IOMMU 的 mm_ops 是在 `pkvm_shadow_vm_link_ptdev()` 里才切过去的，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c:29`；如果 prepopulate 更早做，PTE cache flush 语义可能错。
- `pkvm_pgstate_pgt_map_range(pgt, gpa, hpa, size)` 这个接口不完整。`pkvm_pgtable_map()` 需要 `prot`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c:607`；而 guest leaf 的 `prot` 来自权限和 memory type，见 `pKVM-IA/arch/x86/kvm/pkvm/mmu.c:509` 和 `pKVM-IA/arch/x86/kvm/pkvm/mmu.c:511`。只传 `gpa/hpa/size` 不够；prepopulate/runtime map 都得明确 leaf prot 怎么来，以及是否要剥离 page-state 软件位。
- IOTLB flush 细节没写全：`__pkvm_host_donate_guest()` 已经会对 host EPT root 做一次 flush，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c:706`；mirror 更新后对 `pgstate_pgt` 还需要额外再 flush 一次，而且地址空间应该按 GPA/IOVA 去 flush，不是沿用 HPA。`pkvm_iommu_flush_iotlb()` 是按 `root_pa + addr` 组合工作的，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c:1301`。
- `need_prepopulation` 的状态机没讲清楚。当前它只定义在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h:39`，并在每次 link 时都置 `true`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c:28`；如果 mirror 是 per-VM 共享的，第二个设备 attach 时通常不该再全量 prepopulate。文档没说明何时 clear，也没说明是否要把“每次 attach 置 true”改成“0->1 转换时置 true”。
- 错误回滚没设计。prepopulate/runtime map 都可能因为页表页分配失败而返回错误，分配点在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c:193`；文档没说明 attach 失败后如何回滚部分构造好的 `pgstate_pgt`、如何恢复 host 侧 ptdev 状态。
- 优先级也偏保守：一旦开始把 mirror 真正填起来，`pgstate_pgt_free_leaf` 语义分离和“detach 前移到 `pkvm_vm_mmu_destroy()` 之前”就不是 P2，而是和 P1 同级的 correctness 前提。

如果你要，我可以下一步直接给你整理一版“按源码约束修正后的方案框架”。
