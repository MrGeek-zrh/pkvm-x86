**结论**

这份分析`方向上基本对`，但`根因描述还不够准确`。

对源码的直接验证结果是：

1. `crosvm` 在 `--vfio` 默认配置下，`iommu` 默认就是 `off`/`NoIommu`，而这条路径会在第一个 VFIO group 加入 container 时遍历 `vm.get_memory().regions()`，对每个 region 调用 `vfio_dma_map(iova=guest_addr, vaddr=host_addr, ...)`。代码见 [config.rs](/home/mrgeek/pkvm-x86/crosvm/src/crosvm/sys/linux/config.rs#L52), [config.rs](/home/mrgeek/pkvm-x86/crosvm/src/crosvm/sys/linux/config.rs#L450), [lib.rs](/home/mrgeek/pkvm-x86/crosvm/devices/src/lib.rs#L197), [vfio.rs](/home/mrgeek/pkvm-x86/crosvm/devices/src/vfio.rs#L603), [vfio.rs](/home/mrgeek/pkvm-x86/crosvm/devices/src/vfio.rs#L623), [vfio.rs](/home/mrgeek/pkvm-x86/crosvm/devices/src/vfio.rs#L627)。
2. x86 guest 的低端内存 region 从 `GPA 0` 开始，`0x9000` 落在其中。代码见 [lib.rs](/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs#L820)。
3. `boot_pml4_addr = GuestAddress(0x9000)` 确实存在。代码见 [regs.rs](/home/mrgeek/pkvm-x86/crosvm/x86_64/src/regs.rs#L294)。
4. `shadow_pgt_map_leaf()` 确实会对新映射到 shadow IOMMU 页表的物理页执行 `hyp_page_ref_inc()`。代码见 [shadow_iommu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c#L330)。
5. `host_initiate_donation()` 确实会在 `hyp_page_count()!=0` 时返回 `-EBUSY`。代码见 [mem_protect.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c#L355)。
6. 本地 `pKVM-IA` 配置里 `CONFIG_PKVM_INTEL_PVIOMMU` 没开，所以这里确实是 `shadow_iommu.c` 这条 shadow 路径，不是 pviommu。见 [.config](/home/mrgeek/pkvm-x86/pKVM-IA/.config#L814)。

**逐项判断**

1. `crosvm` 是否会把 Guest 所有内存加入 IOMMU DMA 映射？
是，但要加前提：`仅限默认/显式 iommu=off (NoIommu)` 的 VFIO 路径。它映射的是 `GuestMemory` 的所有 region，不是整个连续 GPA 空间。对 x86 来说，低端 region 从 `0` 开始，所以 `GPA 0x9000` 会被覆盖。见 [vfio.rs](/home/mrgeek/pkvm-x86/crosvm/devices/src/vfio.rs#L620), [vfio.rs](/home/mrgeek/pkvm-x86/crosvm/devices/src/vfio.rs#L623), [lib.rs](/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs#L832)。

2. `boot_pml4_addr = GuestAddress(0x9000)` 是否存在？
是。见 [regs.rs](/home/mrgeek/pkvm-x86/crosvm/x86_64/src/regs.rs#L296)。

3. `shadow_pgt_map_leaf()` 是否做 `hyp_page_ref_inc()`？
是。见 [shadow_iommu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c#L376)。

4. `host_initiate_donation()` 是否因 refcount 非零拒绝 donate？
是。见 [mem_protect.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c#L382)。

5. 整体逻辑是否正确？
`部分正确，但遗漏了更关键的一段 pKVM 生命周期问题。`

**更准确的时序**

```text
crosvm 默认 --vfio
    VfioContainer::get_group_with_vm()
        for region in vm.get_memory().regions()
            vfio_dma_map(region.guest_addr, region.size, region.host_addr, true)
        kvm_device_set_group(Add)

KVM/VFIO
    kvm_vfio_file_add()
        kvm_arch_add_device_to_pkvm()

pKVM pre-attach shadow 路径
    sync_shadow_context_entry()
        pkvm_setup_ptdev_vpgt(..., shadowed=true)
        if (!ptdev_attached_to_vm(ptdev))
            sync_shadow_pgt()
                shadow_pgt_map_leaf()
                    hyp_page_ref_inc()

attach 到 pVM
    pkvm_attach_ptdev()
        if (ptdev->pgt != host_vm.ept)
            pkvm_put_host_iommu_spgt(ptdev->pgt, ...)
                pkvm_pgtable_destroy(&spgt->pgt, NULL)
        ptdev->pgt = vm->pgstate_pgt

后续 guest 建映射
    guest_mmu_map_leaf()
        __pkvm_host_donate_guest()
            host_initiate_donation()
                hyp_page_count()!=0 -> -EBUSY
```

**关键修正**

你原分析把根因归结为“crosvm 先把整段 guest memory map 到 IOMMU，所以 shadow 先 ref_inc，donate 后失败”。这`只说对了一半`。

更像真正 bug 的地方在 pKVM：

- pre-attach 阶段的 `sync_shadow_pgt()` 确实会 `ref_inc`。见 [shadow_iommu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c#L422)。
- 但 attach 后释放旧 host shadow IOMMU pgtable 时，`pkvm_put_host_iommu_spgt()` 最终走的是 `pkvm_pgtable_destroy(&spgt->pgt, NULL)`。见 [ptdev.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c#L185), [iommu_spgt.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c#L73)。
- `pkvm_pgtable_destroy(..., NULL)` 不会调用 `shadow_pgt_unmap_leaf()`，而 `shadow_pgt_unmap_leaf()` 才是做 `hyp_page_ref_dec()` 的地方。见 [pgtable.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c#L426), [shadow_iommu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c#L395)。

所以，从源码看：

- `crosvm 全量 DMA map` 是`触发条件`
- `shadow_pgt_map_leaf()` 的 `ref_inc` 是`中间现象`
- `旧 spgt teardown 没有把 leaf 页 refcount 成对减回去`，这才更像`真正导致 donate 时 refcount 仍非零`的根因

如果你要把这份结论改成一句更准确的话，我建议写成：

`默认 NoIommu 的 crosvm VFIO 路径会在设备加入 KVM 前先把 guest memory 全量 DMA map 到 host IOMMU；pKVM 在设备尚未 attach 到 pVM 时会把这些 host IOMMU 映射同步到 shadow IOMMU 并对目标 HPA 做 ref_inc。之后设备 attach 到 pVM 时，旧 host shadow IOMMU pgtable 被销毁，但源码上看不到对应 leaf HPA refcount 的成对释放，因此像 boot PML4 这类启动页会在后续 donate 时被 host_initiate_donation() 以 -EBUSY 拒绝。`

如果需要，我可以下一步把这个结论整理成一份 `DOCS/问题清单/` 下的独立问题文档。
