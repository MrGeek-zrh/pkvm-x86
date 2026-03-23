`pgstate_pgt` 不是 pKVM 里给 vCPU 做二阶段地址转换的主 guest EPT；主 guest stage-2 页表是 `struct pkvm_vm::mmu`，定义在 [pkvm.h:67](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/pkvm.h#L67) 和 [pkvm.h:77](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/pkvm.h#L77)。  
`pgstate_pgt` 是额外挂在 `struct pkvm_shadow_vm` 里的一个 `struct pkvm_pgtable`，源码直接把它定义成 “Page state page table”，并说明它在 protected VM 有直通设备时还会复用成 IOMMU second-level page table，见 [pkvm_hyp_types.h:29](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h#L29)。

**它是什么**

从实现看，`pgstate_pgt` 是一张 EPT 格式的页表对象，而不是单独的“状态数组”。初始化时它走的是 `ept_ops`，能力参数也取的是 IOMMU/EPT 的层级和页大小，见 [ept.c:459](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c#L459)。  
页状态本身编码在 PTE 里：

- SW bits 56/57 表示 `NOPAGE / OWNED / SHARED_OWNED / SHARED_BORROWED`，见 [mem_protect.h:20](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h#L20)
- 无效 PTE 还可以塞 owner_id 注释，`pkvm_pgtable_annotate()` 就是“unmap + annotate”，见 [mem_protect.c:82](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c#L82) 和 [pgtable.c:703](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c#L703)
- EPT 代码也明确说了：非 present 但非 0 的 entry 仍然算“mapped”，因为里面可能装的是 page state/ownership 信息，见 [ept.c:97](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c#L97)

所以，`pgstate_pgt` 本质上是“用 EPT entry 携带页状态元数据”的一张页表。

**它的作用**

1. 记录 VM 页的状态/归属信息  
从注释和销毁路径看，它被设计成 page-state 账本。销毁 VM 时，`pkvm_pgstate_pgt_deinit()` 会 walk 这张表；对 normal VM 回收 shared 页，对 protected VM 回收 donated 页，并在归还 host 前清零页面，见 [ept.c:398](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c#L398)。

2. protected VM 挂直通设备时，直接当 IOMMU 二级页表用  
`pkvm_attach_ptdev()` 会把 `ptdev->pgt` 切到 `&vm->pgstate_pgt`，见 [ptdev.c:185](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c#L185)。  
随后 shadow IOMMU 会把 context/PASID entry 的 `SLPTR` 指到 `ptdev->pgt->root_pa`，见 [shadow_iommu.c:569](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c#L569) 和 [shadow_iommu.c:731](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c#L731)。  
IOTLB flush 也按同一个 `root_pa` 找设备，见 [iommu.c:1251](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c#L1251)。

3. 为 non-coherent IOMMU 切换缓存一致性处理  
有非一致性直通设备挂进来时，会把 `pgstate_pgt` 的 `mm_ops` 切到带 `flush_cache` 的版本，见 [pkvm.c:22](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c#L22) 和 [ept.c:382](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c#L382)。

**调用关系**

```text
初始化：
    pkvm_init_shadow_vm(...)                     (arch/x86/kvm/vmx/pkvm/hyp/pkvm.c)
        pkvm_pgstate_pgt_init(...)              (arch/x86/kvm/vmx/pkvm/hyp/ept.c)
            pkvm_pgtable_init(..., &ept_ops, ...)

直通设备接入：
    pkvm_add_ptdev(...)                         (arch/x86/kvm/vmx/pkvm/hyp/pkvm.c)
        pkvm_attach_ptdev(...)                  (arch/x86/kvm/vmx/pkvm/hyp/ptdev.c)
            ptdev->pgt = &vm->pgstate_pgt
            pkvm_iommu_sync(...)                (arch/x86/kvm/vmx/pkvm/hyp/iommu.c)
                context/pasid entry -> ptdev->pgt->root_pa

销毁：
    pkvm_teardown_shadow_vm(...)                (arch/x86/kvm/vmx/pkvm/hyp/pkvm.c)
        pkvm_pgstate_pgt_deinit(...)            (arch/x86/kvm/vmx/pkvm/hyp/ept.c)
            pkvm_pgtable_destroy(...)
                pkvm_pgstate_pgt_free_leaf(...)
                    __pkvm_host_unshare_guest() / __pkvm_host_undonate_guest()
```

**一个需要注意的边界**

按当前代码搜索，`pgstate_pgt` 这个名字的显式使用主要集中在：

- `struct pkvm_shadow_vm` 定义
- init/deinit
- ptdev attach / IOMMU 路径

而 guest CPU 运行时的主 EPT 映射路径走的是 `struct pkvm_vm::mmu`，见 [mmu.c:421](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/mmu.c#L421)。  
所以更准确地说，`pgstate_pgt` 不是“guest 正在执行时那张主 EPT”，而是 shadow VM 侧的一张“页状态表”，并在直通 DMA 场景下被复用成 IOMMU SLPT。

补充一点：`need_prepopulation` 在当前代码树里我只看到定义和置位，没有看到读取/消费点。
