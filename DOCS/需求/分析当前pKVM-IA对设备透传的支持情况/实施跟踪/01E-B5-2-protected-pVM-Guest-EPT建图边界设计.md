# [B5-2] protected pVM Guest EPT 建图完整性缺口

## 状态

- 当前状态: 进行中
- 所属主任务: `pkvm-x86#20`

## 核心问题

**Host 在首次 page-fault 建图时掌握 candidate HPA 选择权，hyp 只验证 donation 合法性，不验证"HPA 在语义上就该对应这个 GPA"。**

## 为什么是 Host 控制 candidate HPA

在 `vm_mmu_map` hypercall 之前，`fault->pfn` 已经先由 Host/KVM-high 的 memslot/HVA 体系解析完成：

```text
protected pVM page fault
    -> kvm_faultin_pfn(vcpu, &fault)
        -> __gfn_to_pfn_memslot(slot, gfn, ...)
            -> __gfn_to_hva_many(slot, gfn, ...)
                -> hva_to_pfn(hva, ...)
                    -> 普通 RAM: get_user_page_fast_only() -> pfn
                    -> VM_IO|VM_PFNMAP (direct BAR): follow_pfnmap_start() -> pfn
    -> pkvm_hypercall(vm_mmu_map, vcpu, gpa, fault->pfn << PAGE_SHIFT, ...)
```

无论普通 RAM 还是透传 MMIO/BAR，都走同一条链。**进入 hyp 时已经是成品 HPA，hyp 并不重新推导"GPA 本来该对应哪页"**。

## hyp 收到 HPA 后做了什么

```text
pkvm_vm_mmu_map(shared_vcpu, gpa, hpa, size, writable)
    -> guest_mmu_map_leaf(...)
        -> __pkvm_host_donate_guest(hpa, guest_pgt, gpa, size, prot, ...)
            -> check_donation(...)
                -> host_request_donation()     // 源 HPA 仍是 Host owned？
                -> guest_ack_donation()        // 目标 GPA 当前是 PKVM_NOPAGE？
            -> find_mem_range()                // 源 HPA 在 hyp normal memory 范围内？
            -> hyp_page_count()                // 源 HPA 没有 host pin / DMA refcount？
```

hyp 验证的是 **donation 合法性**：ownership、page-state、mem_range、refcount。

hyp **不验证**的是：这块 HPA 是否就是该 memslot/gfn 启动时承诺的那一页，是否和预先冻结的 `GPA -> page identity` 一致。

## 结论

当前 protected pVM 的 Guest EPT 首次建图完整性缺口在于：

- Host 通过 memslot/HVA 体系掌握 candidate HPA 选择权
- hyp 没有独立于运行期 Host 的 per-GPA authoritative truth source
- 从结构体上看，`struct pkvm_vm` 和 `struct pkvm_shadow_vm` 都不包含"这个 GPA 启动时本来该对应哪个 page"的冻结快照

这条缺口同时覆盖普通 RAM 和透传 MMIO/BAR，两者共用同一套 candidate HPA 来源链。

## 关联文档

- B5 主文档：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`
- B5-1 方案设计：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-1-B5-1-启动期platform-manifest可信设备名单方案.md`
- B5-1 实现跟踪：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-2-T9-B5-1-platform-manifest与checked-ptdev创建实现.md`
- B5-2 实现跟踪：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T10-B5-2-protected-pVM-Guest-EPT建图边界实现.md`
