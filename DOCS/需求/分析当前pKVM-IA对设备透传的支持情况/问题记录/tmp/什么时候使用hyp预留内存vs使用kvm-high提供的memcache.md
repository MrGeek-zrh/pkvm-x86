# 什么时候使用 hyp 预留内存 vs 使用 KVM-high 提供的 memcache（基于源码）

> 背景：你问的核心是：pKVM hypervisor 既然有预留内存（`pkvm_mem_base/pkvm_mem_size`），为什么还会在运行时通过 KVM-high 的 `pkvm_memcache` 走 `__pkvm_host_donate_hyp()` 拿页？以及两条路径分别在什么条件下被选中。
>
> 本文只分析 `pKVM-IA` 树下的实现。

## 结论概览

- hyp 预留内存（`pkvm_mem_base` 切分出的各种 pool）主要覆盖：host EPT 表页、shadow EPT/IOMMU 表页、hyp 自身 mmu 页表页、IOMMU 相关结构等“启动期就能确定预算”的常驻资源。
- **guest stage-2 页表页**（`pkvm_vm->mmu`）的分配策略是：
  1. 优先从 per-VM pool `current_vm->pool` 分配（hyp 侧 pool）
  2. 不够时，从 `pkvm_memcache` pop（该 memcache 页由 KVM-high 侧分配，并在 hyp 侧先 donate 成 hyp-owned）

因此只要 per-VM pool 页数不够，或者被设计为只提供很小起始值（当前就是 1 页），就会在运行期频繁走 memcache/donate。

## 1) hyp 预留内存在哪里切分/用于什么

hyp 初始化最终在 `divide_memory_pool()` 中从 `pkvm_mem_base/pkvm_mem_size` 切出多块区域（vmemmap、mmu pgtable、host ept pgtable、iommu_mem、shadow_ept 等）：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/init_finalise.c`：`divide_memory_pool()`

这些区域随后用于初始化不同的 hyp pool，例如 host EPT 页表页来自 `host_ept_pool`：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`：`pkvm_host_ept_init()` -> `hyp_pool_init(&host_ept_pool, ...)`

类似地，hyp 自身的 mmu 页表页来自 `mmu_pool`：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mmu.c`：`static struct hyp_pool mmu_pool;` + `mmu_zalloc_page()` 使用 `hyp_alloc_pages(&mmu_pool, 0)`

这类 pool 的共同点：

- 它们从 hyp 预留内存切出来，生命周期跟 hyp 一致
- 它们服务于“hyp 自身/host EPT/IOMMU 等全局能力”

## 2) guest stage-2 页表页的分配：先 VM pool，后 memcache

### 2.1 VM pool 的来源（当前实现只有 1 页）

每个 VM 的 `current_vm->pool` 是在 `pkvm_vm_mmu_init()` 里初始化的：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`：
  - `pgd_pa = host_gpa2hpa(pgd_gpa)`
  - `__pkvm_host_donate_hyp(pgd_pa, PAGE_SIZE)`
  - `hyp_pool_init(&pkvm_vm->pool, hyp_phys_to_pfn(pgd_pa), 1, 0)`

也就是说：

- per-VM pool 初始只包含 **1 个 4K 页**（`nr_pages=1`）
- 这个页来自 host（用 `__pkvm_host_donate_hyp()` donate 给 hyp）
- 这 1 页会被用作该 VM 的 stage-2 root（`pkvm_pgtable_init(... alloc_root=true)`）

### 2.2 guest MMU 的 zalloc_page：优先 VM pool，不够再用 memcache

`pkvm_pgtable_map()` 需要分配新表页时会回调 `mm_ops->zalloc_page()`。
对 guest stage-2 来说，`mm_ops->zalloc_page = guest_mmu_zalloc_page()`：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`：`guest_mmu_zalloc_page(struct pkvm_memcache *mc)`

逻辑非常直接：

- `page = hyp_alloc_pages(&current_vm->pool, 0); if (page) return page;`
- VM pool 没页了：
  - 如果 `mc == NULL`：直接失败（返回 NULL -> 上层映射失败）
  - 否则：`page = pop_pkvm_memcache(mc, hyp_phys_to_virt)`，pop 到就用
    - 并 `hyp_set_page_refcounted(hyp_virt_to_page(page))`

因此：

- **什么时候用 hyp 的 per-VM pool？**
  - 当 `hyp_alloc_pages(&current_vm->pool, 0)` 成功（VM pool 还有可用页）
- **什么时候用 KVM-high 提供的 memcache？**
  - 当 VM pool 已经用光，且调用者传入了 `mc != NULL`

在 `pkvm_vm_mmu_map()` 里确实会把 memcache 传进去：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`：
  - `pkvm_pgtable_map(..., guest_mmu_map_leaf, &vcpu->arch.pkvm_vcpu.guest_mmu_memcache)`

## 3) memcache 页从哪来，为什么需要 host->hyp donate

### 3.1 KVM-high 如何准备 memcache（分配普通页串链表）

缺页路径里，KVM-high 会先补足 `vcpu->arch.pkvm_vcpu.guest_mmu_memcache`：

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c`：`pkvm_page_fault()`
  - `topup_pkvm_memcache(&vcpu->arch.pkvm_vcpu.guest_mmu_memcache, pkvm_mmu_cache_min_pages())`

而 `topup_pkvm_memcache()` 的实现会调用 `__get_free_page()` 分配普通页：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm.c`：`topup_pkvm_memcache()` -> `pkvm_mc_alloc_fn()` -> `__get_free_page(GFP_KERNEL_ACCOUNT)`

所以 memcache page 本质就是“普通页”，只是被组织成 `pkvm_memcache` 链表用于后续交付。

### 3.2 hyp 侧如何消费 memcache（先 donate，再 pop）

hyp 在 `pkvm_refill_mmu_memcache()` 中从 host 提供的 memcache 里取页：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`：
  - `host_mc = &pkvm_vcpu->shared_vcpu->arch.pkvm_vcpu.guest_mmu_memcache;`
  - `refill_memcache(&vcpu->arch.pkvm_vcpu.guest_mmu_memcache, host_mc->nr_pages, host_mc)`

关键在 `refill_memcache()` 使用的 `alloc_fn = admit_host_page()`：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`：`admit_host_page()`
  - `__pkvm_host_donate_hyp(host_mc->head, PAGE_SIZE)`
  - `pop_pkvm_memcache(host_mc, hyp_phys_to_virt)`

也就是说：

- host 侧只是“分配并记录这些页的物理地址”
- hyp 真正消费前必须把页 `host -> hyp donate`，使其变成 hyp owned（host EPT annotate/unmap），满足 pKVM 的隔离边界

## 4) hyp 不够页时，如何请求 host 再 refill 一批 memcache

除了 `pkvm_page_fault()` 这种“host 预先 topup”场景，hyp 也会在某些 hypercall 中主动判断 memcache 不够，并通过转发机制让 host 再 topup。

例子：`PKVM_GHC_SHARE_MEM`（guest share host）路径里，hyp 会计算完成操作所需的页表页上界，不够就写 `req_param` 并返回 0，让 host 去 refill。

- hyp：`pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c`：`kvm_pkvm_hypercall()`（`#ifdef __PKVM_HYP__`）
  - `memcache_refill_size = __pkvm_pgtable_max_pages(a1 >> PAGE_SHIFT)`
  - `if (vcpu->arch.pkvm_vcpu.guest_mmu_memcache.nr_pages < memcache_refill_size) {`
    - `shared_vcpu->arch.pkvm_vcpu.req_param = memcache_refill_size;`
    - `return 0; /* forward to host */`

- host：`pKVM-IA/arch/x86/kvm/x86.c`：`kvm_pkvm_hypercall()`
  - `refill_size = vcpu->arch.pkvm_vcpu.req_param;`
  - `topup_pkvm_memcache(&vcpu->arch.pkvm_vcpu.guest_mmu_memcache, refill_size)`

这说明 memcache/donate 是一个“可按需扩展”的机制，不只是缺页路径的副产物。

## 5) 跟 BOOT-004 的关系：为什么会走到 donate_hyp

在 BOOT-004 的日志里，触发的是 `host -> hyp donate`，而不是 `host -> guest donate`：

- `init=1 (HOST)`, `comp=0 (HYP)`, `owner_id=0 (HYP)`
- `host_initiate_donation: ... refcnt=1 -> -EBUSY`

这与上面第 3 节完全一致：hyp 在消费 memcache 页（或 donate VMCS/PML 等 hyp 自用页）时，需要 `__pkvm_host_donate_hyp()`。

本次失败点不在“memcache 页从哪来”，而在 donation 前置条件：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`：`host_initiate_donation()`
  - `if (hyp_page_count(__hyp_va(addr))) return -EBUSY;`

也就是 donation 目标页在 hyp vmemmap 的 refcount 非 0（你日志里是 1）。

## 6) 一个直接的观察：当前实现里 per-VM pool 起始太小

`hyp_pool_init(&pkvm_vm->pool, ..., nr_pages=1)` 基本只够 root 页表页。
实际运行中，任何额外的页表层级/拆分/映射扩展都会需要更多页表页，因此几乎必然会走 memcache。

这不是 bug 结论，只是从源码分配策略能推导出的行为：guest stage-2 页表页的增长主要依赖 memcache。

