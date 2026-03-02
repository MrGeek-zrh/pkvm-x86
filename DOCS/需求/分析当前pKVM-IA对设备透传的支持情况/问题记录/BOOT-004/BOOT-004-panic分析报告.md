# [BOOT-004] Panic 分析报告：非机密 VM VFIO 透传触发 host->hyp donate 失败

## 问题概述

在非机密 VM（`PROTECTED=0`）启用 VFIO 设备透传后，系统出现 `#UD` 异常（exception 6）并最终触发 soft lockup，导致系统无法继续运行。

核心错误信息：
```
pkvm: host_initiate_donation: page refcounted (dma/pinned?) addr=0x3897c7000 size=0x1000 owner_id=0 refcnt=1
pkvm: do_donate: __do_donate failed ret=-16 size=0x1000 init=1 addr=0x3897c7000
pkvm: exception 6 on CPU20 @ip do_donate__pkvm+0xba/0x5d0
watchdog: BUG: soft lockup - CPU#24 stuck for 22s! [node:2095]
```

## 根因分析（已证实部分）

## 完整调用链（✓ 已证实）

```
KVM-high (host kernel)
  kvm_tdp_page_fault()
    pkvm_page_fault()
      kvm_faultin_pfn()
      topup_pkvm_memcache(&vcpu->arch.pkvm_vcpu.guest_mmu_memcache, ...)
        __topup_pkvm_memcache()
          pkvm_mc_alloc_fn() -> __get_free_page()  // 分配普通页
      pkvm_hypercall(vm_mmu_map, ...)

pKVM (hypervisor)
  pkvm_vm_mmu_map()
    pkvm_refill_mmu_memcache()
      refill_memcache()
        __topup_pkvm_memcache(mc, min_pages, admit_host_page, ...)
          admit_host_page()
            __pkvm_host_donate_hyp(host_mc->head, PAGE_SIZE)
              do_donate()
                __do_donate()
                  host_initiate_donation()
                    hyp_page_count(__hyp_va(addr)) == 1  // ❌ 失败点
                    return -EBUSY
                WARN_ON(ret)  // ❌ 触发 #UD (exception 6)

KVM-high (host kernel)
  后果：部分 CPU 停在异常路径，无法响应 IPI
    smp_call_function_many_cond() 超时等待
      watchdog 报 soft lockup
```

### 1. 为什么非机密 VM 也会触发 host->hyp donation（✓ 已证实）

启用 pKVM 后，host kernel 处于 deprivilege 状态，内存所有权管理由 hypervisor 严格控制。关键区分：

- **给 guest 映射页**：非机密 VM 使用 `__pkvm_host_share_guest()`（share 语义）
- **给 hypervisor 自用页**：使用 `__pkvm_host_donate_hyp()`（donate 语义），**与 guest 是否 protected 无关**

Hypervisor 自用页包括：
- Guest stage-2 页表页（`pkvm_vm->mmu` 使用的页表结构）
- VMCS/PML 等 VMX 控制结构
- Shadow IOMMU 页表页
- 其他 hypervisor 内部数据结构

**本次 case 的 donation 类型**：日志显示 `init=1 (HOST)`, `comp=0 (HYP)`, `owner_id=0 (HYP)`，确认是 host->hyp donation。根据调用链（`admit_host_page()` -> `__pkvm_host_donate_hyp(host_mc->head, PAGE_SIZE)`），本次 donation 的目标页来自 **memcache head**（用于 guest stage-2 页表页）。是否涉及 VMCS/PML 等其他类型需要通过栈回溯或额外日志确认。

### 2. 为什么需要 memcache 机制（✓ 已证实）

#### 2.1 Hyp 预留内存的用途（启动期分配）

`pkvm_mem_base/pkvm_mem_size` 在 `divide_memory_pool()` 中被切分为：
- `host_ept_pool`：host EPT 页表页
- `mmu_pool`：hyp 自身 MMU 页表页
- `iommu_mem`：IOMMU 相关结构
- `shadow_ept`：shadow EPT 页表页
- `vmemmap`：hyp 页元数据

这些 pool 的共同特点：
- 生命周期与 hyp 一致
- 服务于全局能力（host EPT/IOMMU/hyp MMU）
- 启动期就能确定预算

#### 2.2 Guest stage-2 页表页的动态分配策略

每个 VM 的 `current_vm->pool` 初始只有 **1 个 4K 页**（用作 stage-2 root）：

```c
// pKVM-IA/arch/x86/kvm/pkvm/mmu.c: pkvm_vm_mmu_init()
pgd_pa = host_gpa2hpa(pgd_gpa);
__pkvm_host_donate_hyp(pgd_pa, PAGE_SIZE);
hyp_pool_init(&pkvm_vm->pool, hyp_phys_to_pfn(pgd_pa), 1, 0);  // nr_pages=1
```

当需要更多页表页时，`guest_mmu_zalloc_page()` 的分配策略：

```c
// pKVM-IA/arch/x86/kvm/pkvm/mmu.c
page = hyp_alloc_pages(&current_vm->pool, 0);
if (page) return page;  // 优先使用 VM pool

// VM pool 用尽，从 memcache 获取
if (mc == NULL) return NULL;  // 失败
page = pop_pkvm_memcache(mc, hyp_phys_to_virt);
```

**结论**：由于 per-VM pool 起始只有 1 页，任何额外的页表层级/拆分/映射扩展都会走 memcache 路径。

### 3. Memcache 的完整生命周期（✓ 已证实）

#### 3.1 KVM-high 侧准备（分配普通页）

```c
// pKVM-IA/arch/x86/kvm/mmu/mmu.c: pkvm_page_fault()
topup_pkvm_memcache(&vcpu->arch.pkvm_vcpu.guest_mmu_memcache,
                    pkvm_mmu_cache_min_pages());

// pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm.c
pkvm_mc_alloc_fn() -> __get_free_page(GFP_KERNEL_ACCOUNT)
```

此时页面仍属于 host，只是物理地址被记录在 memcache 链表中。

#### 3.2 Hypervisor 侧消费（先 donate，再使用）

```c
// pKVM-IA/arch/x86/kvm/pkvm/mmu.c: pkvm_refill_mmu_memcache()
refill_memcache(&vcpu->arch.pkvm_vcpu.guest_mmu_memcache,
                host_mc->nr_pages, host_mc);

// admit_host_page()
__pkvm_host_donate_hyp(host_mc->head, PAGE_SIZE);  // 所有权转移
pop_pkvm_memcache(host_mc, hyp_phys_to_virt);      // 弹出使用
```

**关键点**：hypervisor 必须先通过 `__pkvm_host_donate_hyp()` 把页面从 host 转移到 hyp，才能使用该页。这一步会：
- 在 host EPT 中 annotate/unmap 该页
- 修改 ownership 元数据为 hyp-owned
- 确保 host 无法再访问该页（隔离边界）

### 4. Donation 失败的直接原因（✓ 已证实）

```c
// pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c: host_initiate_donation()
if (hyp_page_count(__hyp_va(addr)))
    return -EBUSY;  // refcount != 0，拒绝 donate
```

**硬证据**：页面 `0x3897c7000` 在 hyp vmemmap 中的 `refcount=1`，被视为"仍在使用"，donation 被拒绝，返回 `-EBUSY` (ret=-16)。

**重要区分**：`hyp_page_count()` 读取的是 `struct hyp_page.refcount`（pKVM-IA/arch/x86/kvm/vmx/pkvm/include/buddy_memory.h），这是 **pKVM hypervisor 内部对页面使用/Pin 的计数**，不等同于 Linux `struct page` 的引用计数。因此：
- 这个 refcount=1 是 hypervisor 侧的状态，不是 host kernel 的 page refcount
- 修改这个 refcount 的路径是 pKVM 内部的 `hyp_page_ref_inc()` / `hyp_page_ref_dec()`
- 需要追踪的是 hypervisor 内部哪个路径对该页调用了 `hyp_page_ref_inc()` 但未正确 `hyp_page_ref_dec()`

随后 `do_donate()` 中的 `WARN_ON(ret)` 触发 `#UD` 异常（exception 6）。

### 5. 为什么会导致 soft lockup（✓ 已证实）

`#UD` 异常发生在 hypervisor 上下文中，导致：
- 触发异常的 CPU 停在 pKVM 异常处理路径
- 无法及时响应其他 CPU 的 IPI/TLB flush 请求
- 跨 CPU 同步操作（如 `smp_call_function_many_cond()`）超时等待
- Watchdog 检测到 CPU 长时间无响应，报告 soft lockup

## 待确认的关键问题

### 核心问题：谁把 hyp_page refcount 增加到 1？

**当前状态**：已确认 `hyp_page_count(__hyp_va(0x3897c7000)) == 1`，但尚未定位是哪个路径调用了 `hyp_page_ref_inc()` 且未正确配对 `hyp_page_ref_dec()`。

**可能的路径（按优先级排序）**：

#### 1. 共享/Pin 路径（高优先级）
- `pin_shared_mem_pages()` / `pin_unpin_mem_pages()`
- 位置：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
- 这些函数会调用 `hyp_page_ref_inc()` 来标记页面被 pin 住

#### 2. Shadow IOMMU 同步路径（高优先级）
- `shadow_pgt_map_leaf()` / `shadow_pgt_unmap_leaf()`
- 位置：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`
- Shadow IOMMU 页表操作会修改页表页的 refcount

#### 3. VFIO DMA mapping 路径（假设，待验证）
- **注意**：目前没有代码级证据证明"VFIO pin 直接影响 hyp vmemmap refcount"
- `hyp_page_count()` 读取的是 pKVM 内部的 `struct hyp_page.refcount`，不是 Linux `struct page` 的引用计数
- VFIO 的 `vfio_pin_pages()` 操作的是 host kernel 的 page refcount，不会直接修改 hyp vmemmap
- 但 VFIO DMA buffer 可能通过其他路径（如 shadow IOMMU 映射）间接影响 hyp_page refcount
- **需要通过追踪 `hyp_page_ref_inc/dec` 的调用点来证实这一假设**

#### 4. 为什么 VFIO 透传场景更容易触发此问题？（推测）

**当前状态**：尚未证明"只有 VFIO 才触发"，但 VFIO 场景确实更容易触发/放大该问题。

VFIO 透传引入的变化：
- 更多的 GPA->HPA 映射建立（设备 MMIO 区域、DMA buffer）
- 更频繁的 EPT fault / page fault
- 更多的页表页分配需求（shadow IOMMU 页表、guest stage-2 页表扩展）
- Shadow IOMMU 页表同步操作增加（可能涉及 refcount 变更）

**需要验证**：
- 非 VFIO 场景下是否也会出现相同问题（降低映射频率/复杂度）
- Shadow IOMMU 初始化/映射路径是否会对 memcache 页产生 refcount 操作

## 下一步调试建议

### 1. 追踪 hyp_page refcount 变更（最高优先级）

在以下位置对 `phys=0x3897c7000` 增加条件日志，追踪 `hyp_page_ref_inc/dec` 调用：

```c
// pKVM-IA/arch/x86/kvm/vmx/pkvm/include/buddy_memory.h 或相关实现
hyp_page_ref_inc() / hyp_page_ref_dec()
  if (page_to_phys(page) == 0x3897c7000)
    pkvm_err("hyp_page refcount: %d -> %d, caller: %pS",
             old_refcount, new_refcount, __builtin_return_address(0));

// pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c
pin_shared_mem_pages() / pin_unpin_mem_pages()
  if (addr == 0x3897c7000)
    pkvm_err("pin/unpin: refcount=%d, op=%s, caller: %pS",
             refcount, op, __builtin_return_address(0));

// pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c
shadow_pgt_map_leaf() / shadow_pgt_unmap_leaf()
  if (phys == 0x3897c7000)
    pkvm_err("shadow IOMMU: refcount=%d, op=%s", refcount, op);
```

**目标**：找到第一个把 refcount 从 0 增加到 1 的调用点，以及为什么没有配对的 dec 操作。

### 2. 检查 memcache 页分配与已使用页的冲突

验证 `__get_free_page()` 分配的页是否可能与以下区域重叠：
- 已被 hypervisor 使用的页（通过 hyp vmemmap 检查）
- Shadow IOMMU 页表页
- 其他已 donate 给 hyp 的页

**方法**：在 `pkvm_mc_alloc_fn()` 中增加检查：
```c
// pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm.c
page = __get_free_page(GFP_KERNEL_ACCOUNT);
if (page == 0x3897c7000)
    pkvm_err("memcache allocated target page, check if already in use");
```

### 3. 检查 donation 时序与 shadow IOMMU 初始化

确认 donation 发生时，该页是否已被其他路径（如 shadow IOMMU 初始化）提前使用。

**方法**：在 `host_initiate_donation()` 失败时增加详细日志：
```c
// pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c
if (hyp_page_count(__hyp_va(addr))) {
    pkvm_err("donation failed: addr=0x%llx refcount=%d owner=%d",
             addr, hyp_page_count(__hyp_va(addr)),
             hyp_page_owner(__hyp_va(addr)));
    // 增加：打印该页的使用历史/状态
    return -EBUSY;
}
```

### 4. 验证非 VFIO 场景

测试不启用 VFIO 透传的情况下，是否仍会出现相同问题：
- 纯计算型 VM（无设备透传）
- 只透传简单设备（如串口）vs 复杂设备（如 GPU/NIC）

**目标**：确认问题是否与 VFIO/shadow IOMMU 强相关，还是通用的 memcache/donation 时序问题。

### 5. 考虑 workaround（如果确认根因后）

根据追踪结果，可能的修复方向：

**如果是 refcount 泄漏**（inc/dec 不配对）：
- 修复对应路径的 refcount 管理逻辑
- 确保每个 `hyp_page_ref_inc()` 都有配对的 `hyp_page_ref_dec()`

**如果是 memcache 页与已使用页冲突**：
- 在 `admit_host_page()` 中增加预检查，提前失败而非触发 WARN_ON
- 调整 memcache 分配策略（避开已使用区域）
- 增加 per-VM pool 初始大小（减少 memcache 依赖）

**如果是 donation 时序问题**：
- 调整 shadow IOMMU 初始化与 guest MMU 初始化的顺序
- 确保 donation 前页面状态已稳定

**临时 workaround**（不推荐用于生产）：
- 将 `WARN_ON(ret)` 改为 `if (ret) return ret;`，避免 #UD 但保留错误传播
- 这只是避免系统崩溃，不解决根本问题

## 总结

### 已证实的事实

1. **失败机制**：`__pkvm_host_donate_hyp()` 尝试 donate 页面 `0x3897c7000` 时，发现 `hyp_page_count() == 1`，返回 `-EBUSY`，随后 `WARN_ON(ret)` 触发 `#UD` 异常，导致 soft lockup。

2. **调用链**：从 `pkvm_page_fault()` -> `topup_pkvm_memcache()` -> `pkvm_vm_mmu_map()` -> `admit_host_page()` -> `__pkvm_host_donate_hyp()` -> `host_initiate_donation()` 失败。

3. **Refcount 语义**：`hyp_page_count()` 读取的是 pKVM hypervisor 内部的 `struct hyp_page.refcount`，不是 Linux `struct page` 的引用计数。修改该 refcount 的路径是 hypervisor 内部的 `hyp_page_ref_inc/dec`。

4. **Memcache 机制**：这是正常的动态分配策略，因为 per-VM pool 初始只有 1 页，运行期必然需要通过 memcache 获取更多页表页。

5. **非机密 VM 也会 donate**：host->hyp donation 用于 hypervisor 自用页（页表页/VMCS 等），与 guest 是否 protected 无关。

### 待确认的问题

1. **核心问题**：谁把 `hyp_page refcount` 从 0 增加到 1，且为什么没有配对的 dec 操作？
   - 可能路径：pin/unpin、shadow IOMMU、其他 hypervisor 内部操作
   - 需要通过追踪 `hyp_page_ref_inc/dec` 来定位

2. **VFIO 相关性**：VFIO 场景更容易触发/放大该问题，但尚未证明"只有 VFIO 才触发"。
   - 需要验证非 VFIO 场景是否也会出现

3. **时序问题**：是否存在 donation 与其他操作（如 shadow IOMMU 初始化）的竞态条件。

### 根本原因（推测）

这是一个"内存所有权冲突"问题，不在 memcache 机制本身，而在于：
1. 页面 refcount 管理的某个路径未正确释放/清理（refcount 泄漏）
2. 或者 memcache 分配的页与已使用页面发生冲突（分配策略问题）
3. 或者存在 donation 时序问题（竞态条件）

需要通过追踪 refcount 变更来定位具体的冲突源。
