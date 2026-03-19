# Ask Codex Input

## Question

请为 pKVM-IA（/home/mrgeek/pkvm-x86/pKVM-IA）设计 pVM 设备透传支持方案。背景已分析清楚，请聚焦在设计决策上。

## 已知的核心矛盾

pKVM-IA 当前 memory ownership 模型：
- Host donate 给 Guest 后，页面所有权完全转移（PKVM_PAGE_OWNED -> Guest exclusive）
- shadow_pgt_map_leaf() 对 IOMMU 映射的物理页做 hyp_page_ref_inc()，这个 refcount 阻止了 donate
- pkvm_pgtable_destroy(..., NULL) 销毁 spgt 时不释放 leaf HPA 的 refcount（stale refcount leak）

pkvm-v6.18（ARM）的对比做法：
- 使用 __pkvm_host_share_guest() + host_share_guest_count，Host 保留 PKVM_PAGE_SHARED_OWNED
- Guest 得到 PKVM_PAGE_SHARED_BORROWED（不是完全 donate）
- 这样设备 DMA 仍可通过 IOMMU 访问这些页

## 关键代码位置（请阅读）

**pKVM-IA:**
- /home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c（重点：host_initiate_donation, __pkvm_host_donate_guest 附近）
- /home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c（pkvm_attach_ptdev, pkvm_put_host_iommu_spgt）
- /home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c（shadow_pgt_map_leaf, shadow_pgt_unmap_leaf, sync_shadow_pgt, pkvm_iommu_sync 附近）
- /home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c（pkvm_put_host_iommu_spgt）
- /home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/mmu.c（guest_mmu_map_leaf, pkvm_vm_mmu_map 附近）

**pkvm-v6.18（仅参考架构思路）:**
- /home/mrgeek/pkvm-x86/pkvm-v6.18/arch/arm64/kvm/hyp/nvhe/mem_protect.c（__pkvm_host_share_guest 附近）
- /home/mrgeek/pkvm-x86/pkvm-v6.18/arch/arm64/kvm/pkvm.c

## 需要设计的核心问题

**问题1（最关键）：安全模型选择**

pVM 透传设备，设备 DMA 需要访问 pVM 内存。两个可选模型：

A. Shared 模型（类似 ARM v6.18）：pVM 的 backing 内存永远不 donate，Host 保留 SHARED_OWNED，Guest 得到 SHARED_BORROWED，IOMMU 映射的是 Host-owned 页，DMA 直接写入。
   - 优：IOMMU refcount 不冲突
   - 缺：Host 理论上仍可访问 pVM 内存（安全边界下降）
   
B. Donate + IOMMU rebind 模型：先 donate 页给 pVM，然后 shadow IOMMU 切换为映射 pVM 的 pgstate_pgt（或类似机制）
   - 优：Host 彻底无法访问 pVM 内存
   - 缺：需要在 Hyp 中建立 pVM IOMMU 隔离机制

哪个模型更适合 pKVM-IA？还是有第三种选择？

**问题2（短期修复）：stale refcount 修复**

在 iommu_spgt.c 中，pkvm_put_host_iommu_spgt() 里的 pkvm_pgtable_destroy(&spgt->pgt, NULL) 改为传入 shadow_pgt_unmap_leaf，是否足以修复当前 panic？这个改动是否有副作用？

**问题3（整体流程）：device attach 到 pVM 的完整新流程应该是什么？**

目前 pkvm_attach_ptdev() 在 attach 到 pVM 时把 ptdev->pgt 切换为 vm->pgstate_pgt。请梳理：
1. attach 前后 shadow IOMMU 的状态变化
2. pVM 内存 donate 和 IOMMU 映射的时序关系
3. 需要增加哪些新的 hypercall 或钩子

请给出具体的修改思路，涉及哪些文件哪些函数。

## Configuration

- Model: gpt-5.4
- Effort: xhigh
- Timeout: 3600s
- Timestamp: 2026-03-18_14-46-44
