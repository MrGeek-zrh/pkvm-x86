# [BOOT-004] 调用链：非机密 VM（PROTECTED=0）VFIO 透传触发 host -> hyp donate，最终 #UD + soft lockup

## 目标

把 “为什么非 pVM + VFIO 会出现 host -> hyp donate” 以及 “donate 失败后为什么会出现 pkvm exception 6 与 soft lockup” 的完整调用过程串起来，并标注关键源码位置。

## 关键现象（最新 dmesg）

```text
[  252.181636] pkvm: host_initiate_donation: page refcounted (dma/pinned?) addr=0x3897c7000 size=0x1000 owner_id=0 refcnt=1
[  252.182642] pkvm: do_donate: __do_donate failed ret=-16 size=0x1000 init=1 addr=0x3897c7000 phys=0x0 comp=0 addr=0xff3e23bc097c7000 phys=0x0 prot=0x0
[  252.183687] pkvm: exception 6 on CPU20 @ip do_donate__pkvm+0xba/0x5d0 (0xffffffffb1c079da), no err code
[  280.078446] watchdog: BUG: soft lockup - CPU#24 stuck for 22s! [node:2095]
[  280.079227] RIP: 0010:smp_call_function_many_cond+0x155/0x550
```

## 为什么非 pVM 也会有 host -> hyp donate

启用 pKVM 后，host kernel 处于 deprivilege 状态，KVM 被拆成：

- KVM-high：host kernel 中的 KVM 逻辑（处理 page fault、构造 hypercall 参数、准备 memcache 等）
- pKVM hypervisor（VMX root）：执行关键受控操作（如 EPT/页状态变更、内存 ownership 变更等）

因此即便 guest 是非机密 VM（`PROTECTED=0`），hypervisor 仍需要拿到“它自己要用”的页面所有权（host 不能继续持有/访问），这类页面通过 `__pkvm_host_donate_hyp()` 从 host 转交给 hyp。

注意区分两类内存操作：

- 给 guest 映射页：非机密 VM 走 `share`（`__pkvm_host_share_guest()`），不会走 guest donation
- 给 hypervisor 自己用的页：会走 `donate_hyp`（`__pkvm_host_donate_hyp()`），与 guest 是否 protected 无关

## 调用链（从 VFIO 透传导致更多映射/缺页开始，到 #UD/soft lockup）

下面这条链路完全来自 pKVM-IA 源码，省略了 crosvm/VFIO 用户态细节，仅从“guest 访问/建立映射导致 KVM 处理缺页”开始。

文字解释（读法建议）：

1. VFIO 透传本身不直接调用 `donate`，它改变的是 guest/host 的 IOMMU/EPT 交互与访问模式，从而更容易触发大量的 GPA->HPA 建图、EPT fault / page fault 与页表页分配。
2. KVM-high 侧在处理缺页时，会为 pKVM 预先准备一批“供 hypervisor 使用的页表页”（memcache）。
3. 当 KVM-high 通过 hypercall 请求 hypervisor 建立映射时，hypervisor 需要消费这些 memcache 页面；为了把这些页变成 hypervisor 私有资源，会把它们从 host 侧 `donate` 成 hyp owned page。
4. 本问题的失败点发生在第 3 步：donate 的目标页在 hyp vmemmap 里 `refcount=1`，被视为仍在使用（dma/pinned/share 等），因此拒绝 donate，返回 `-EBUSY`，随后 `WARN_ON` 触发 #UD，并导致系统进入不前进状态，最终 watchdog 报 soft lockup。

KVM-high (host kernel) 部分解释：

- `pkvm_page_fault()` 是在启用 pKVM（`enable_pkvm`）情况下，KVM-high 用来替代普通 TDP fault 处理的一条路径（它最终把“建 stage-2 映射”的动作交给 hypervisor）。
- `topup_pkvm_memcache()` 这里分配的是 host kernel 的普通页（`__get_free_page()`），把这些页的物理地址串成一个 memcache 链表，后续会被 hypervisor 取走当作“它自己的页表页/临时页”。这一步的 “分配” 发生在 host，而真正的 “所有权转移” 发生在 hypervisor 的 `__pkvm_host_donate_hyp()`。

pKVM (hypervisor) 部分解释：

- `pkvm_refill_mmu_memcache()` 做的是“把 host 传进来的 memcache 页变成 hypervisor 可用的页”，关键函数是 `admit_host_page()`：
  - 先对 `host_mc->head` 调用 `__pkvm_host_donate_hyp()`，把该页从 host 所有权转移到 hyp（host EPT 会被 annotate/unmap，ownership 写入 invalid PTE）。
  - donation 成功后才 `pop_pkvm_memcache()` 把这个页弹出来给 hyp 当成“真实 page”（用来当页表页/中间页）。
- donation 的拒绝条件之一是 `hyp_page_count(__hyp_va(addr)) != 0`：refcount 非 0 被当作“仍在使用/被 pin 住”的页面，不能 donate（源码注释用的是 DMA 场景）。本问题命中 `refcnt=1`，因此返回 `-EBUSY`（`ret=-16`）。\n+- 随后 `do_donate()` 里的 `WARN_ON(ret)` 触发 #UD（也就是你看到的 `pkvm: exception 6`），这不是随机非法指令，而是明确的防御性告警。

soft lockup 部分解释：

- `soft lockup` 的栈里出现 `smp_call_function_many_cond()`，通常意味着“某个需要其它 CPU 响应的操作在等待”，但被等待的 CPU 无法及时响应（例如卡在 pKVM 异常路径或无法调度/退出）。\n+- 这也是为什么问题表象里往往同时出现 `pkvm: exception 6` 与 host 的软锁死：前者是触发点（WARN_ON/#UD），后者是系统无法继续前进的后果。
```text
KVM-high (host kernel)
    kvm_tdp_page_fault(...)                                               (pKVM-IA/arch/x86/kvm/mmu/mmu.c)
        pkvm_page_fault(...)                                               (pKVM-IA/arch/x86/kvm/mmu/mmu.c)
            kvm_faultin_pfn(...)                                           (pKVM-IA/arch/x86/kvm/mmu/mmu.c)
            topup_pkvm_memcache(&vcpu->arch.pkvm_vcpu.guest_mmu_memcache,
                               pkvm_mmu_cache_min_pages())                (pKVM-IA/arch/x86/kvm/mmu/mmu.c)
                topup_pkvm_memcache(...)                                   (pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm.c)
                    __topup_pkvm_memcache(...)                             (pKVM-IA/arch/x86/include/asm/kvm_host.h)
                        pkvm_mc_alloc_fn -> __get_free_page(...)           (pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm.c)
            pkvm_hypercall(vm_mmu_map, ...)                                (pKVM-IA/arch/x86/kvm/mmu/mmu.c)

pKVM (hypervisor)
    pkvm_vm_mmu_map(...)                                                   (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
        pkvm_refill_mmu_memcache(...)                                      (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
            refill_memcache(...)                                           (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
                __topup_pkvm_memcache(mc, min_pages, admit_host_page, ...) (pKVM-IA/arch/x86/include/asm/kvm_host.h)
                    admit_host_page(...)                                   (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
                        __pkvm_host_donate_hyp(host_mc->head, PAGE_SIZE)   (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
                            do_donate(...)                                 (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
                                __do_donate(...)                           (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
                                    host_initiate_donation(...)            (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
                                        hyp_page_count(__hyp_va(addr))     (pKVM-IA/arch/x86/kvm/vmx/pkvm/include/buddy_memory.h)
                                        -> refcnt != 0 => return -EBUSY
                                WARN_ON(ret) -> #UD                        (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)

KVM-high (host kernel)
    后果：部分 CPU 停在 pKVM 异常路径/无法及时响应，导致跨 CPU 的 flush/IPI 等等待超时
        watchdog 报 soft lockup
            smp_call_function_many_cond(...)                               (host 栈回溯中可见)
```


## 失败点的“因果关系”总结

- VFIO 透传会引入更多 EPT/guest 映射建立与访问路径，间接增加 KVM 处理缺页、调用 `pkvm_hypercall(vm_mmu_map, ...)` 的频率。
- 每次 pKVM hypervisor 要更新 guest 的 stage-2 映射，都可能需要页表页；它通过 `pkvm_refill_mmu_memcache()` 向 host 申请/接收 memcache page。
- pKVM hypervisor 将 host memcache page 通过 `__pkvm_host_donate_hyp()` 转为 hyp owned page（这一步就是你看到的 host->hyp donate）。
- 本问题中 donation 失败原因已确定：页 `0x3897c7000` 在 hyp vmemmap 的 refcount=1，因此 `host_initiate_donation()` 返回 `-EBUSY`，继而 `WARN_ON(ret)` 触发 #UD（exception 6）。
- #UD 之后系统进入长时间不前进状态，最终 host watchdog 报 soft lockup。

## 仍待确认的点（下一步追踪方向）

当前已知“donate 的目标页 refcnt=1”，但尚未确定是谁把该页的 refcount 增加到 1：

- 共享/Pin 路径会修改 refcount：
    - `pin_unpin_mem_pages()` / `pin_shared_mem_pages()`                   (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
- shadow IOMMU 同步路径会对页表页 refcount 变更：
    - `shadow_pgt_map_leaf()` / `shadow_pgt_unmap_leaf()`                  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c)

建议在上述 refcount 变更点对目标 phys=0x3897c7000 增加条件日志（只打印该页或只打印 0->1），即可确认 refcnt=1 的来源。
