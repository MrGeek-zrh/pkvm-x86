# debug思路

## 目标

定位是谁先把 donation 目标页的 `hyp_page.refcount` 从 `0` 改成了 `1`，从而导致 `host_initiate_donation()` 返回 `-EBUSY`。

关键失败点：

    pkvm_refill_mmu_memcache(...)                                      (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
        admit_host_page(...)                                           (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
            __pkvm_host_donate_hyp(host_mc->head, PAGE_SIZE)           (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
                host_initiate_donation(...)                            (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
                    hyp_page_count(__hyp_va(addr))
                        refcnt != 0 -> -EBUSY

## 当前判断

- 这次先不要从 `VFIO add_ptdev` 开始查。
- 当前问题发生在非机密 VM（`PROTECTED=0`），优先级更高的是 donation 前该页为什么已被 refcount。
- `WARN_ON(ret)` 触发的 `#UD` 是后果，真正要找的是 refcount 来源。

## 新增线索

### 1. memcache 页在真正变成 guest MMU 页表页时，会被直接设成 `refcount=1`

    guest_mmu_zalloc_page(...)                                         (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
        page = pop_pkvm_memcache(mc, hyp_phys_to_virt)
        hyp_set_page_refcounted(p)                                     (pKVM-IA/arch/x86/kvm/vmx/pkvm/include/buddy_memory.h)
            p->refcount = 1

这说明：如果某页曾经作为 guest MMU 页表页被真正使用过，那么它后续必须在返还 host 前把 refcount 清回 `0`，否则 host 以后再次拿到这页时，就可能在 `host_initiate_donation()` 处失败。

### 2. `hyp -> host` donation 路径本身不检查 refcount

    __pkvm_hyp_donate_host(...)                                        (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
        do_donate(...)
            check_donation(...)                                        (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
                initiator = HYP -> ret = 0
                completer = HOST -> host_ack_donation(...)
                    只检查 page state，不检查 refcount

这说明：如果某条返还路径在调用 `__pkvm_hyp_donate_host()` 前忘了把 refcount 降回 `0`，这个问题不会在 `hyp -> host` 当场暴露，而可能在 host 以后再次 donate 该页给 hyp 时暴露。

### 3. 当前没有看到页表框架里很明显的 `get/put` 不配对

    pgtable_map_leaf(...)                                              (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c)
        mapped old entry -> put_page(...)
        mapped new entry -> get_page(...)

    pgtable_free_leaf(...)                                             (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c)
        mapped leaf -> put_page(...)

    pkvm_pgtable_destroy(...)                                          (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c)
        root -> put_page(...)

这说明：从当前源码静态看，guest MMU 页表框架本身暂时不像第一嫌疑点；更值得先验证的是“页返还 host 前 refcount 未清零”或 `pin/share` 路径额外加了 refcount。

## 本轮已落地

- 已在以下位置加入第一轮动态日志：
  - `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
- 当前日志关键字统一为 `pkvm-debug`。
- 当前实现不再写死某个物理页，而是记录最近一批页生命周期事件，并在 `host_initiate_donation()` 因 `refcnt != 0` 失败时，按本次失败页动态 dump 相关历史。

## 第一轮打点位置

### 1. 先确认失败页来源

    admit_host_page(...)                                               (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
        记录 `host_mc->head`

    host_initiate_donation(...)                                        (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
        记录 `addr` 和 `refcnt`

目标：先确认 `host_mc->head` 是否就是报错页。

### 2. 确认页是否曾被真正当成 guest MMU 页表页使用过

    guest_mmu_zalloc_page(...)                                         (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
        记录 `page`
        记录 `hyp_set_page_refcounted()` 前后状态

目标：确认目标页是否在更早的一轮中被真正消费成页表页。

### 3. 确认 hyp 把页还给 host 时 refcount 是否已经清零

    __pkvm_hyp_donate_host(...)                                        (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
        donation 前记录 `hpa` 对应页的 refcount

    pkvm_free_mmu_memcache(...)                                        (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
        记录从 `vcpu_mc` 返还 host 的页

    drain_vm_pool(...)                                                 (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
        记录 `hyp_page_ref_dec(page)` 后再返还 host 的页

目标：优先验证“返还 host 前 refcount 没清零”的方向。

### 4. 继续追 refcount writer

    pin_unpin_mem_pages(...)                                           (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
        hyp_page_ref_inc(...)
        hyp_page_ref_dec(...)

    pin_shared_mem_pages(...)                                          (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
        hyp_page_ref_inc(...)

    shadow_pgt_map_leaf(...)                                           (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c)
        hyp_page_ref_dec(old_page)
        hyp_page_ref_inc(new_page)

    shadow_pgt_unmap_leaf(...)                                         (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c)
        hyp_page_ref_dec(page)

    hyp_get_page(...)                                                  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/page_alloc.c)
        hyp_page_ref_inc(p)

## 打点规则

- 只在以下情况打印：
  - 命中特定物理页
  - `refcount` 发生 `0 -> 1` 或 `1 -> 0`
- 日志最小字段即可：`phys`、函数名、old/new refcount。

## 本轮预期输出

- 确认 donation 失败页是否来自 `host_mc->head`。
- 确认该页是否曾被 `guest_mmu_zalloc_page()` 作为真实页表页消费过。
- 确认是否存在“hyp 返还 host 时 refcount 未清零”的情况。
- 如果上述方向都不成立，再继续收缩到 `pin/share` 和 `shadow_iommu`。

## 下一步判定

- 如果 `__pkvm_hyp_donate_host()` 前该页 refcount 已非 `0`，优先查返还路径遗漏。
- 如果 `guest_mmu_zalloc_page()` 先命中该页，优先查该页作为页表页释放时是否配对 `put_page`。
- 如果两者都没命中，再继续查 `pin/share` 和 `shadow_iommu`。

## 迭代方式

- 每轮只补三类内容：
  - 新确认的事实
  - 已排除的路径
  - 下一轮动作

## 第二轮已落地

- 已新增跨重启自动复现脚本：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-004/auto-repro-boot004.sh`。
  - 负责重启后重新定位 NVMe、绑定 vfio-pci、启动 crosvm，并同时抓取 dmesg / crosvm 日志。
  - 现已新增 `manual` 模式，尽量贴近手工步骤：默认不额外等待、默认不对 crosvm 加 timeout，并支持 `--skip-vfio-rebind`。
- 已给 trace buffer 加锁，避免并发写入把相邻事件覆盖掉。
- 已补 `__pkvm_host_donate_hyp()` 前后事件，用于确认本次 `host -> hyp donate` 是从哪条调用链触发的。
- 已补 `pin/share` 路径的 `0 -> 1` / `1 -> 0` refcount 变化。
- 已补 `shadow_iommu` 路径的 `0 -> 1` / `1 -> 0` refcount 变化。

## 第二轮重点观察

- 如果 dump 里先出现：

    pin_unpin_mem_pages/pin

  或：

    pin_shared_mem_pages/inc

  说明更偏向 `share/unshare` 配对问题。

- 如果 dump 里先出现：

    shadow_pgt_map_leaf/new_inc

  或：

    shadow_pgt_unmap_leaf/dec

  说明更偏向 `shadow_iommu` 路径。

- 如果 dump 里能看到：

    __pkvm_host_donate_hyp/pre
        ...
    host_initiate_donation/fail

  但中间没有任何 `0 -> 1` writer，说明当前覆盖范围仍不够，需要继续往更底层的 refcount 修改点扩展。

## 当前最新结论（基于 2026-03-16 日志）

- 这次失败页是 `0x238563000`，并且失败时 `refcnt=2`。
- `__pkvm_host_donate_hyp/pre` 的 `aux` 已经反推出调用方落在 `pkvm_vm_mmu_init()`，说明这次不是运行期 memcache refill 才失败，而是新 VM 初始化时就失败。
- 这更像是“旧 VM 生命周期里某条清理路径没有把某页的 hyp refcount 清干净，后来 host allocator 又把这页重新分配给新的 `vm_init_pool`”。

## 第三轮已落地

- `PKVM_BOOT004_TRACE_DEPTH` 已增大到 `4096`，扩大历史窗口。
- `pin/share` 路径现在记录每次 refcount 变化，并把调用者地址放到 `aux`。
- `shadow_iommu` 路径现在记录每次 refcount 变化，不再只记录 `0 -> 1` / `1 -> 0`。

## 第三轮重点观察

- 如果同一失败页在更早位置出现：

    pin_unpin_mem_pages/pin
    pin_unpin_mem_pages/unpin
    pin_shared_mem_pages/inc

  说明更偏向 `share/unshare` 清理不完整。

- 如果同一失败页在更早位置出现：

    shadow_pgt_map_leaf/new_inc
    shadow_pgt_map_leaf/old_dec
    shadow_pgt_unmap_leaf/dec

  说明更偏向 `shadow_iommu` 对该页还有残留引用。

- 如果第三轮仍然只有：

    __pkvm_host_donate_hyp/pre
    host_initiate_donation/fail

  就需要继续往更底层的 refcount 修改点扩展，或者直接在 `hyp_page_ref_inc/dec` 原语附近做定向条件打点。

## 第四轮已落地

- 已在 `donate_host_memory()` 上增加范围级打点，能看到整个 donation 区间内每一页在进入 `__pkvm_host_donate_hyp()` 前的 refcount。
- 已在 `teardown_donated_memory()` 上增加范围级打点，能看到一段 donated memory 在返还 host 前后的每页状态。
- 已在 `__pkvm_vcpu_free()` 上分别对 `cpuid`、`fpu`、`pkvm_vcpu` 三段内存增加 teardown 前的范围打点。

## 第四轮重点观察

- 如果第二次 panic 时，`donate_host_memory/pre` 已经显示某一页 refcount 非 0，则说明脏页在进入新的 `__pkvm_host_donate_hyp()` 前就已经存在。
- 如果第一次失败后的清理日志里，`pkvm_vcpu_free/vcpu-pre` 或 `teardown_donated_memory/pre|post` 能看到对应页 refcount 一直不归零，则更支持“第一次 crosvm 早退触发了 teardown 泄漏”。
- 如果只有 `fpu` 或 `cpuid` 范围里出现脏页，而 `pkvm_vcpu` 范围没有，则要重新审视具体是哪段 donated memory 被 host allocator 复用了。
