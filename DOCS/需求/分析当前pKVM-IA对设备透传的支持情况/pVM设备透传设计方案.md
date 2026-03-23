

## 1. 背景

当前 pKVM-IA 在透传设备给 pVM（protected VM）时会 panic。结合 BOOT-006 当前证据链（详见问题记录），已知事实如下：

- crosvm 以 NoIommu VFIO 模式启动带透传设备的 pVM 时，会把 Guest 全部物理内存做 `VFIO_IOMMU_MAP_DMA`
- pKVM 通过 `sync_shadow_pgt()` 同步 Host IOMMU 页表到 shadow IOMMU 时，`shadow_pgt_map_leaf()` 对这些 HPA 做 `hyp_page_ref_inc()`
- 后续 pVM 启动触发 EPT violation，`host_initiate_donation()` 因 `hyp_page_count() != 0` 返回 `-EBUSY`，VM 启动失败

**注**：`hyp_page_count() != 0` 拒绝 donate，不只代表 shadow IOMMU 引用，pin 的 shared page 也会增加 refcount（见 `mem_protect.c:823/1130`）。对当前场景，BOOT-006 已直接证实的是 shadow IOMMU 路径先占住了目标页的 refcount。

## 2. 现有架构的设计意图

pKVM-IA 代码中已经有 pVM 透传的骨架设计，但关键实现缺失：

| 组件 | 状态 | 代码位置 |
|------|------|----------|
| `pgstate_pgt` 双重角色：页状态表 + IOMMU 二级页表 | 已设计 | `ept.c:357` |
| `pkvm_attach_ptdev()` 切换 `ptdev->pgt = &vm->pgstate_pgt` | 已实现 | `ptdev.c:193` |
| `sync_shadow_context_entry()` 用 `ptdev->pgt->root_pa` 作 IOMMU SLPTR（legacy mode） | 已实现 | `shadow_iommu.c:579` |
| `sync_shadow_pasid_table_entry()` 用 `ptdev->pgt->root_pa` 作 SLPTR（scalable mode） | 已实现 | `shadow_iommu.c:755` |
| `need_prepopulation` 标志：设备 attach 后设为 true | 已设计 | `pkvm.c:28` |
| `need_prepopulation` 的消费逻辑（pgstate_pgt 预填充） | 缺失 | — |

## 3. 解决思路

这份文档的推导顺序应该是：

1. 先确认 pVM 透传场景里哪些约束不能破坏
2. 再把当前问题拆成几个必须分别解决的子问题
3. 最后才是从这些约束和子问题中推导出 A/B/C 三种方案

换句话说，后面的方案不是"拍脑袋列几个选项"，而是从现有代码骨架和安全目标反推出来的。

### 3.1 先固定不能破坏的约束

- **pVM 的核心目标不能变成 Host 可见 Guest 私有内存。** 当前 pKVM-IA 的内存保护主线仍然是 donate/unshare 语义，ownership 切换由 `mem_protect.c` 驱动；如果为了 DMA 透传把 pVM RAM 长期改成 Host 仍可访问的 share 语义，那么 pVM 的核心价值就消失了。
- **应尽量顺着现有代码骨架补全，而不是另起一套。** `pgstate_pgt` 的注释已经明确写了"它既管理 page state，也作为 protected VM with passthrough devices 的 IOMMU second-level page table"，见 `ept.c:357`。`pkvm_attach_ptdev()` 也已经把 `ptdev->pgt` 切到 `vm->pgstate_pgt`，见 `ptdev.c:162`。后续 `sync_shadow_context_entry()` / `sync_shadow_pasid_table_entry()` 直接把 `ptdev->pgt->root_pa` 写入 SLPTR，见 `shadow_iommu.c:579` 和 `shadow_iommu.c:756`。这说明现有代码的预期方向，本来就是"给 pVM 准备独立的 DMA 可见页表视图"。
- **必须把 BOOT-006 已证实的冲突和后续设计目标分开。** 当前已证实的直接失败点，是 `shadow_pgt_map_leaf/new_inc` 与 `__pkvm_host_donate_guest()` 对同一 HPA 的 refcount 冲突；后续设计需要回答的是，如何既保留 pVM 的 donate 安全模型，又给透传设备提供稳定的 DMA 翻译视图。

### 3.2 再把问题拆成 3 个必须分别解决的子问题

#### 子问题 1：生命周期正确性

- 当前已证实的直接冲突，是 `shadow pgt`（也就是 pKVM 管理的给 Host 使用的 IOMMU 页表，也称 spgt）路径先对目标 HPA 增加 refcount，而 `host -> guest donate` 需要该页在 donate 时 `refcount == 0`。
- VM teardown 时，如果设备还挂着 `pgstate_pgt`，而 guest mmu 已经开始 `undonate` 页面，那么 IOMMU 仍可能继续翻译到这些刚归还给 Host 的物理页，生命周期顺序就是错的。

这类问题不回答"DMA 应该看哪张表"，只回答"谁先 detach、谁负责 release、什么时候可以归还页"。

#### 子问题 2：ownership 与 DMA 翻译视图如何分离

- `pkvm_vm->mmu` / host EPT 当前承担的是 **ownership 的真实来源**：页面是否 donate、share、unshare，都在这条链路里发生。
- 设备 DMA 侧需要的是 **IOMMU 可消费的 GPA->HPA 翻译视图**。它关心的是"设备此刻该怎么翻译 DMA 地址"，不应该顺带承担 page ownership 转移、副作用 refcount、pin/unpin 等语义。

如果继续把 host 侧现有 shadow pgt 的语义直接搬给 pVM DMA 路径，就会把 ownership、DMA mirror、host fallback 这三件事耦在一起，难以保证语义一致性。

#### 子问题 3：DMA 视图如何建立和保持同步

- attach 一个设备到 pVM 时，`pgstate_pgt` 不能是空表，否则 IOMMU SLPTR 虽然已经切过去了，但 DMA 仍然没有可用映射。
- Guest 运行过程中，新的 donate/share/unshare 会不断改变 GPA->HPA 关系；只在 attach 时切一次 SLPTR 不够，还需要把这些变化同步到 DMA 视图，并按 IOVA/GPA 范围做 IOTLB flush。

因此，不论最终选哪种主方案，都必须回答两个具体问题：
- attach 时如何把已有映射预填充进去
- 运行时如何把后续映射变化同步进去

### 3.3 方案空间是怎么推导出来的

把上面的问题压缩后，其实只剩两个核心分叉：

1. **pVM 私有内存对 Host 是继续 donate，还是改成 share？**
2. **如果继续 donate，设备 DMA 访问是自动 mirror 全量 Guest 映射，还是只开放显式 DMA-share 窗口？**

围绕这两个分叉，当前代码库里有意义的解法基本就收敛成三类：

- **方案 A：share 模型** — 直接放宽安全模型，让 Host 继续保留对 pVM RAM 的可见性，DMA 最容易打通，但安全性最差。
- **方案 B：donate + 自动 DMA mirror** — 保持 pVM 私有内存仍然 donate，只额外维护一张供 IOMMU 使用的 mirror pgtable，这是对现有 `pgstate_pgt` 骨架最自然的补全。
- **方案 C：donate + 显式 DMA-share 窗口** — 不自动 mirror 全量内存，只让 Guest 显式共享 DMA buffer；工程风险最小，但使用模型改变最大，更像过渡态。

所以这里不是"为什么偏偏挑这三种"，而是：在当前 pKVM-IA 的代码结构下，真正决定路线的就是这两个分叉，而 A/B/C 正好对应这两个分叉下最有代表性的三种落地方式。

### 3.4 为什么主方案会收敛到 B

- **A 不满足 pVM 的安全目标。** 它可以作为对照组，帮助说明"为什么 share 最省事但不能选"，但不能作为主线。
- **C 适合 bring-up，不适合作为最终完整透传模型。** 它能把问题缩小到"有限 DMA buffer 共享"，但会把设备透传的使用模型改成显式协作式 API，不符合"普通 VFIO 透传"的长期目标。
- **B 同时满足安全目标、代码骨架和最终能力目标。** 它保留 donate 语义，符合 pVM 的机密性要求；又直接沿用当前代码里已经预留好的 `pgstate_pgt -> ptdev->pgt -> IOMMU SLPTR` 这条链路，因此不是凭空发明新机制，而是把"已有但没补完"的设计走通。

因此，后续文档把 B 作为推荐方案，不是因为它"理论上最漂亮"，而是因为它是**在当前 pKVM-IA 代码基础上，唯一同时满足安全性、实现连续性和最终可用性的主线方案**。

### 3.5 方案 B 为什么能解决当前 panic

#### 实际执行时序

`pkvm_add_ptdev` 不是我们"准备插入"的新调用——它已经在现有代码里被调用了。实际时序如下：

```
时间线：
  ① crosvm: ioctl(VFIO_IOMMU_MAP_DMA)          ← 先发生，refcount 被占
  ② crosvm: ioctl(KVM_DEV_VFIO_FILE_ADD)        ← 后发生，触发 attach
  ③ pVM 启动 → EPT violation → donate            ← 最后，refcount 仍在 → panic
```

**为什么 ① 在 ② 之前？** 这是 crosvm 在同一个函数里的顺序调用（`devices/src/vfio.rs` — `get_group_with_vm()`）：

```rust
// vfio.rs:623-634 — 先做 MAP_DMA
IommuDevType::NoIommu => {
    for region in vm.get_memory().regions() {
        unsafe {
            self.vfio_dma_map(                    // → ioctl(VFIO_IOMMU_MAP_DMA)
                region.guest_addr.0,
                region.size as u64,
                region.host_addr as u64,
                true,
            )
        }?;
    }
}

// vfio.rs:639-644 — 后做 KVM_DEV_VFIO_FILE_ADD
let kvm_vfio_file = KVM_VFIO_FILE
    .get_or_try_init(|| vm.create_device(DeviceKind::Vfio))?;
group
    .lock()
    .kvm_device_set_group(kvm_vfio_file, KvmVfioGroupOps::Add)?;
    // → ioctl(KVM_SET_DEVICE_ATTR, KVM_DEV_VFIO_GROUP_ADD)
```

这是 Linux VFIO 框架的标准使用模型：必须先建立 IOMMU 映射（MAP_DMA），再把设备注册到 KVM（FILE_ADD）。否则设备注册后如果立即有 DMA 操作，IOMMU 还没有映射，会触发 DMA fault。

#### ① MAP_DMA 的完整调用栈（crosvm → Host kernel → pKVM）

```
crosvm: self.vfio_dma_map()                      // vfio.rs:629
    ioctl(VFIO_IOMMU_MAP_DMA)                    // vfio.rs:423
        ─── 进入 Host kernel ───
        vfio_iommu_type1_map_dma()               // drivers/vfio/vfio_iommu_type1.c:2994
            vfio_dma_do_map()                     // vfio_iommu_type1.c:1541
                vfio_iommu_map()                  // vfio_iommu_type1.c:1414
                    iommu_map()                   // → Intel IOMMU driver
                        intel_iommu_map_pages()   // drivers/iommu/intel/iommu.c:3627
                            __domain_mapping()    // 写 VT-d 页表
                        intel_iommu_iotlb_sync_map()  // VT-d cache invalidation
                            qi_submit_sync()      // drivers/iommu/intel/dmar.c:1395
                                writel(DMAR_IQT_REG)  // MMIO 写 invalidation queue tail
        ─── pKVM 拦截 MMIO 写 ───
        handle_host_ept_violation()               // hyp/ept.c:264（DMAR MMIO 区域）
            iommu_mmio_handler()
                case DMAR_IQT_REG:                // hyp/iommu.c:1064
                    handle_qi_invalidation()      // hyp/iommu.c:710
                        handle_descriptor()       // 处理 invalidation descriptor
                            sync_shadow_id()                        // shadow_iommu.c:1143
                                sync_shadow_context_entry()         // shadow_iommu.c:466
                                    ptdev_attached_to_vm(ptdev)?    // shadow_iommu.c:543
                                    NO → 设备未 attach（② 还没发生）
                                    sync_shadow_pgt()               // shadow_iommu.c:544
                                        shadow_pgt_map_leaf()       // shadow_iommu.c:330
                                            hyp_page_ref_inc()      // ← refcount > 0
```

#### ② KVM_DEV_VFIO_FILE_ADD 的完整调用栈（crosvm → Host kernel → pKVM）

```
crosvm: group.kvm_device_set_group(Add)          // vfio.rs:644
    ioctl(KVM_SET_DEVICE_ATTR, KVM_DEV_VFIO_GROUP_ADD)  // vfio.rs:791-809
        ─── 进入 Host kernel ───
        kvm_vfio_file_add()                      // virt/kvm/vfio.c:148
            kvm_arch_add_device_to_pkvm()         // virt/kvm/vfio.c:190 → pkvm_host.c:1252
                iommu_group_for_each_dev()        // pkvm_host.c:1259
                    add_device_to_pkvm()          // pkvm_host.c:1237
                        pkvm_hypercall(add_ptdev) // pkvm_host.c:1249 → VMCALL
        ─── 进入 pKVM hypervisor ───
        handle_vmcall()                           // hyp/vmexit.c:114
            pkvm_add_ptdev()                      // hyp/pkvm.c:57
                pkvm_attach_ptdev()               // ptdev.c:162
                    pkvm_put_host_iommu_spgt()    // ptdev.c:186 释放旧 spgt，但不清理数据页 refcount
                    ptdev->pgt = &vm->pgstate_pgt // ptdev.c:193 ← 换表
                    pkvm_shadow_vm_link_ptdev()    // ptdev.c:197
                        vm->need_prepopulation = true  // pkvm.c:28
                    pkvm_iommu_sync()              // ptdev.c:199
                        sync_shadow_id()           // iommu.c:1179 → shadow_iommu.c:1143
                            // 回调 sync_shadow_context_entry()（legacy，shadow_iommu.c:579）
                            // 或 sync_shadow_pasid_table_entry()（scalable，shadow_iommu.c:756）
                            // 读取 ptdev->pgt->root_pa 写入 SLPTR
                            // 此时 ptdev->pgt 已是 pgstate_pgt，所以 SLPTR = pgstate_pgt->root_pa
                        flush_iotlb()              // iommu.c:1195
```

关键问题：**① 已经通过 `shadow_pgt_map_leaf()` 对数据页做了 `hyp_page_ref_inc()`。② 的 attach 虽然切换了 `ptdev->pgt`，但没有清理 ① 留下的 refcount。**

#### 为什么 attach 没有清理旧 refcount

`pkvm_attach_ptdev()` 释放旧 spgt 的代码（`ptdev.c:186-187`）：

```c
if (ptdev->pgt != pkvm_hyp->host_vm.ept)
    pkvm_put_host_iommu_spgt(ptdev->pgt, ptdev->iommu_coherency);
```

`pkvm_put_host_iommu_spgt()` 递减 spgt 结构体自身的 refcount（`iommu_spgt.c:89`）。当 refcount 降到 0 时，调用 `pkvm_pgtable_destroy(&spgt->pgt, NULL)`（`iommu_spgt.c:101`）。但传入的 `free_leaf` 是 `NULL`，走默认的 `pgtable_free_leaf()`（`pgtable.c:413`），只做 `put_page(ptep)` 释放页表页——**不会调用 `shadow_pgt_unmap_leaf()` 来做 `hyp_page_ref_dec()`**：

```
pkvm_put_host_iommu_spgt()                       // iommu_spgt.c:73
    --spgt->refcount                              // iommu_spgt.c:89
    if refcount == 0:
        pkvm_pgtable_destroy(&spgt->pgt, NULL)    // iommu_spgt.c:101
            pgtable_free_cb()                     // pgtable.c:426
                pgtable_free_leaf()               // pgtable.c:413 ← 默认回调
                    put_page(ptep)                // 只释放页表页
                    // 不调用 shadow_pgt_unmap_leaf()
                    // 不做 hyp_page_ref_dec()
                    // 数据页的 refcount 残留！
```

所以即使 spgt 被完全销毁，数据页上的 `hyp_page.refcount` 也不会被清理。这就是为什么现有代码已经有 `pkvm_add_ptdev` 调用，panic 仍然发生。

#### ③ pVM 启动 → donate 被拒

```
pVM 启动，Guest 访问未映射 GPA，触发 EPT violation
    pkvm_vm_mmu_map()                           // mmu.c
        guest_mmu_map_leaf()                    // mmu.c:426
            __pkvm_host_donate_guest()          // mem_protect.c:661
                host_initiate_donation()        // mem_protect.c:355
                    for (cur = start; cur < end; cur += PAGE_SIZE):
                        hyp_page_count() != 0   // ← ① 的 refcount 仍在
                        return -EBUSY           // ← donate 失败 → panic
```

#### 方案 B 需要解决的两个问题

从上面的分析可以看出，方案 B 不仅仅是"换表 + 不做 ref_inc"，还需要解决 ① 留下的残留 refcount：

**问题 1：清理旧 refcount（修复 `pkvm_put_host_iommu_spgt` 或 attach 流程）**

attach 时需要确保旧 shadow spgt 的销毁会调用 `shadow_pgt_unmap_leaf()` 对数据页做 `hyp_page_ref_dec()`。具体方案：
- 方案 a：修改 `pkvm_put_host_iommu_spgt()`，在 `pkvm_pgtable_destroy()` 时传入 `shadow_pgt_unmap_leaf` 作为 `free_leaf` 回调，而不是 `NULL`
- 方案 b：在 `pkvm_attach_ptdev()` 中，换表前显式遍历旧 spgt 做 ref_dec
- 方案 c：如果旧 spgt 被其他设备共享（refcount > 1），则不能直接销毁；需要只对当前设备涉及的 HPA 范围做 ref_dec

**问题 2：后续 MAP_DMA 不再产生新 refcount（已有代码解决）**

attach 后，`ptdev_attached_to_vm()` 返回 true，`sync_shadow_pgt()` 被跳过（legacy 模式，`shadow_iommu.c:543`）：

```
attach 后再次触发 MAP_DMA（仅 legacy 模式）：
    sync_shadow_context_entry()                 // shadow_iommu.c:466
        ptdev_attached_to_vm(ptdev)?             // shadow_iommu.c:543
        YES → 跳过 sync_shadow_pgt()
        // 直接用 ptdev->pgt->root_pa 写 SLPTR
        // 因为 ② 已执行 ptdev->pgt = &vm->pgstate_pgt（ptdev.c:193）
        // 所以此处 ptdev->pgt->root_pa 就是 pgstate_pgt->root_pa
        context_lm_set_slptr(&tmp, ptdev->pgt->root_pa)  // shadow_iommu.c:579
        // shadow_pgt_map_leaf() 不被调用
        // hyp_page_ref_inc() 不发生
```

**问题 1 + 问题 2 都解决后，步骤 ③ 的 donate 才能成功：**

```
pVM 启动，Guest 访问未映射 GPA，触发 EPT violation
    pkvm_vm_mmu_map()
        guest_mmu_map_leaf()                     // mmu.c:426
            __pkvm_host_donate_guest()           // mem_protect.c:661（已有）
                host_initiate_donation()
                    hyp_page_count() == 0        // ← 旧 refcount 已清理，新 refcount 不产生，通过！
            ★ if shadow_vm_has_ptdev(shadow_vm):       // 待实现
                ★ pkvm_pgstate_pgt_map_range()         // 待实现：写 EPT 表项，不做 ref_inc
                pkvm_iommu_flush_iotlb()               // 已有（iommu.c:1297），需新增调用点
```

donate 成功后，立即把 GPA→HPA 映射同步到 pgstate_pgt，设备 DMA 就能翻译到正确的物理地址。

注意：当前代码树中 `need_prepopulation` 只被置位（`pkvm.c:28`），没有消费点；`shadow_vm_has_ptdev()`、`pkvm_pgstate_pgt_map_range()` 均不存在，属于方案 B 需要补全的实现。

#### 为什么 pgstate_pgt 可以不做 ref_inc

`refcount` 在 pKVM 里是 **ownership 守卫**：谁持有 refcount，谁就在声明"这个页我还在用，不能转移 ownership"。

- **host shadow pgt 做 ref_inc 是合理的**：host 设备确实在用这些页，host 侧需要声明占用，防止页被意外转移。
- **pVM 的 pgstate_pgt 不应该做 ref_inc**：这些页的 ownership 正在从 host 转移给 guest。pgstate_pgt 只是记录"guest 拥有的页的 GPA→HPA 翻译关系"，不是在声明 host 侧的占用。如果它也做 ref_inc，就会阻塞自己的 ownership 转移路径——相当于左手锁门、右手要进门。
- **安全前提（回收侧）**：不做 ref_inc 的前提是，每次 guest 取消映射、undonate、detach 或 VM destroy 时，必须同步删除 pgstate_pgt 中对应的 DMA 映射，并在页回到 host 之前完成 IOTLB flush。否则设备 DMA 可能打到已归还给 host 的物理页。此外，当前代码中有两个旧假设需要一并修改：（1）`ept.c:357` 注释将 pgstate_pgt 描述为 pinned 且"映射不可删除"，需改为允许动态增删映射；（2）`pkvm_pgstate_pgt_free_leaf()`（`ept.c:398`）对 protected VM 仍会调用 `__pkvm_host_undonate_guest()`，需改为只释放页表页本身，ownership 回收由 `guest_mmu_free_leaf()`（`mmu.c:624`）负责。当前代码的 teardown 顺序（先销毁 pgstate_pgt，再 detach 设备）也存在安全问题，需要前移 detach（见 5.3 节）。

一句话总结：**MAP_DMA 先于 attach 发生，旧 shadow spgt 销毁时不清理数据页 refcount，导致 donate 失败。方案 B 需要：（1）attach 时清理旧 refcount；（2）换表到 pgstate_pgt 避免新 refcount；（3）donate 后同步 mirror 映射。**

## 4. 安全模型决策

### 方案 A：share 模型（类 ARM v6.18）

pVM 内存改为 share（Host 保留 SHARED_OWNED，Guest 得 SHARED_BORROWED），IOMMU 映射 Host-owned 页。

**否决原因：**
- pVM 的核心安全价值是 Host 对 Guest RAM 不可见；share 模型让 Host EPT 仍 present，机密性消失
- ARM v6.18 依赖 `host_share_guest_count`（`pkvm-v6.18/.../memory.h:50`），x86 `struct hyp_page` 只有 `refcount/order`，没有对应机制（`pKVM-IA/.../buddy_memory.h:12`）

### 方案 B：donate + pVM DMA mirror pgtable（推荐）

- 内存模型继续保持 donate，Host 不可见 pVM 内存
- `pgstate_pgt` 语义明确为 DMA mirror pgtable：只反映 GPA->HPA 的 DMA 翻译，不参与 ownership 迁移
- ownership 迁移仍然只由 `pkvm_vm->mmu` 驱动
- 设备 attach 后，IOMMU context/PASID entry 的 SLPTR 指向 `pgstate_pgt->root_pa`（legacy 和 scalable 两条路径均适用）

### 方案 C：显式 DMA-share 窗口（过渡方案）

Guest 主动通过 `__pkvm_guest_share_host()` 共享 DMA buffer，其余内存继续 donate。仅适合 bring-up 阶段。

## 5. 完整执行流程（方案 B）

### 5.1 设备 attach 流程

当前代码的调用顺序（`pkvm.c:57` → `ptdev.c:162`）：

```c
pkvm_add_ptdev(shadow_vm_handle, bdf, pasid)     // pkvm.c:57，仅对 pVM 执行
    pkvm_attach_ptdev(bdf, pasid, vm)             // ptdev.c:162
        pkvm_put_host_iommu_spgt()                // ptdev.c:186，释放旧 spgt
        ptdev->pgt = &vm->pgstate_pgt             // ptdev.c:193
        pkvm_shadow_vm_link_ptdev()                // ptdev.c:197
            vm->need_prepopulation = true           // pkvm.c:28
        pkvm_iommu_sync()                          // ptdev.c:199
```

方案 B 改造后（★ 标注新增）：

```c
pkvm_add_ptdev(shadow_vm_handle, bdf, pasid)     // pkvm.c:57
    pkvm_attach_ptdev(bdf, pasid, vm)             // ptdev.c:162
        // ── P0：清理旧 refcount ──
        ★ 清理旧 shadow spgt 对数据页的 refcount（见 3.5 节"问题 1"）
            方案 a：修改 pkvm_put_host_iommu_spgt()，传入 shadow_pgt_unmap_leaf 作为 free_leaf
            方案 b：显式遍历旧 spgt 做 hyp_page_ref_dec
        pkvm_put_host_iommu_spgt()                // ptdev.c:186，释放旧 spgt
        // ── P1：prepopulate（仅设备热插拔需要，需调整内部顺序）──
        // 当前代码 link_ptdev 在换表之后（ptdev.c:197），
        // 但 prepopulate 需要先设置 coherency 再写 pgstate_pgt，
        // 所以 P1 需要把 link_ptdev 提前到换表之前。
        // P0 不需要这个调整，保持原顺序即可。
        pkvm_shadow_vm_link_ptdev()                // ptdev.c:197（P1 调整：提前到换表之前）
            vm->need_prepopulation = true
            pkvm_shadow_sl_iommu_pgt_update_coherency()  ← mm_ops 在此切换
        ★ pkvm_pgstate_pgt_prepopulate_from_guest_mmu(vm)  // P1
            遍历 pkvm_vm->mmu，将已 donated GPA->HPA 写入 pgstate_pgt
            失败时需回滚已部分构造的 pgstate_pgt，并拒绝 attach
        // ── 换表 + sync ──
        ptdev->pgt = &vm->pgstate_pgt             // ptdev.c:193
        ★ vm->need_prepopulation = false
        pkvm_iommu_sync()                          // ptdev.c:199
            sync_shadow_id() → 回调写 SLPTR = pgstate_pgt->root_pa
            flush_iotlb()
```

need_prepopulation 建议仅在 ptdev_head 从空变非空时置 true（首次 attach），后续 attach 不重复全量 prepopulate。

### 5.2 Guest 运行中（EPT violation）

```c
pkvm_vm_mmu_map(gpa, hpa)
    guest_mmu_map_leaf()
        __pkvm_host_donate_guest(hpa, gpa)   <- 改 ownership，不变
        [新增] if shadow_vm_has_ptdev(shadow_vm):
            pkvm_pgstate_pgt_map_range(pgstate_pgt, gpa, hpa, size, prot)
                prot 从 donate 时的 guest leaf prot 派生（mmu.c:509/511）
                只写 EPT 表项，不做 hyp_page_ref_inc()
            pkvm_iommu_flush_iotlb(iommu, pgstate_pgt->root_pa, gpa, size)
                按 GPA/IOVA 范围 flush（见 iommu.c:1301）
                不复用 __pkvm_host_donate_guest() 内部的 host EPT flush
```

### 5.3 VM teardown（关键：调用顺序）

**当前调用链（存在安全问题）：**

```c
pkvm_vm_destroy()                              pkvm/pkvm.c:669
    pkvm_vm_mmu_destroy()                      pkvm/mmu.c:701
        guest_mmu_free_leaf()                  pkvm/mmu.c:624
            __pkvm_host_undonate_guest()       hyp/mem_protect.c:711
            <- 此时设备仍挂着 pgstate_pgt！IOMMU 正在翻译已归还的物理页！
    kvm_arch_destroy_vm()
        vmx_vm_destroy()                       pkvm/vmx/vmx.c:7605
            pkvm_teardown_shadow_vm()          hyp/pkvm.c:87
                pkvm_pgstate_pgt_deinit()
                pkvm_detach_ptdev()            <- 太晚
```

**修复方案：detach 前移到 pkvm_vm_mmu_destroy() 之前**

```c
pkvm_vm_destroy()
    [新增] 先 detach 所有 ptdev
        pkvm_detach_ptdev(ptdev, vm)  <- IOMMU 切回 host，pgstate_pgt 不再被设备引用
    pkvm_vm_mmu_destroy()             <- 此时设备已不再使用 pgstate_pgt，安全归还页面
        guest_mmu_free_leaf()
            __pkvm_host_undonate_guest()
    kvm_arch_destroy_vm()
        vmx_vm_destroy()
            pkvm_teardown_shadow_vm()
                pkvm_pgstate_pgt_deinit()  <- 此时 pgstate_pgt 已无设备引用，安全销毁
```

注意：pkvm_detach_ptdev() 是 void，pkvm_iommu_sync() 失败不向上传播（见 ptdev.c:129/139）。若作为安全前提，需补充 WARN 或错误处理。detach 需要在 pkvm/pkvm.c 中访问 shadow_vm 的 ptdev_head，可通过 arch hook 或直接调用实现。

### 5.4 设备 detach 流程

```c
pkvm_detach_ptdev(ptdev, vm)
    ptdev->pgt = pkvm_hyp->host_vm.ept   [暂时置为 host ept]
    pkvm_iommu_sync(bdf, pasid)
        sync_shadow_context_entry()       -> SLPTR 重建为 host 当前配置
                                            （可能是 host shadow spgt 或其他，不一定是 bare host root）
        IOTLB flush
    pkvm_put_ptdev()
```

## 6. 需要修改的文件和函数

### P0：attach 时清理旧 shadow spgt 的残留 refcount（panic 直接修复）

**文件：`arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c`（`pkvm_put_host_iommu_spgt` 附近）**

当前 `pkvm_put_host_iommu_spgt()` 在 spgt refcount 降到 0 时调用 `pkvm_pgtable_destroy(&spgt->pgt, NULL)`，`NULL` 导致走默认 `pgtable_free_leaf()`，只释放页表页，不对数据页做 `hyp_page_ref_dec()`。需要传入 `shadow_pgt_unmap_leaf` 作为 `free_leaf` 回调，确保数据页的 refcount 被正确清理。若 spgt 被多设备共享（refcount > 1），需评估是否只对当前设备涉及的 HPA 范围做 ref_dec。

### P0：前移 detach 到 pkvm_vm_mmu_destroy() 之前（correctness 前提）

**文件：`arch/x86/kvm/pkvm/pkvm.c`（`pkvm_vm_destroy` 附近）**

在调用 `pkvm_vm_mmu_destroy()` 之前先遍历 shadow_vm->ptdev_head 调用 `pkvm_detach_ptdev()`。需要通过 arch hook 或直接访问 shadow_vm 实现。

### P0：pgstate_pgt_free_leaf 语义分离（correctness 前提）

**文件：`arch/x86/kvm/vmx/pkvm/hyp/ept.c:398`**

当前 `pkvm_pgstate_pgt_free_leaf()` 对 pVM 调用 `__pkvm_host_undonate_guest()`。若 `pgstate_pgt` 只作为 DMA mirror，其 teardown 只应释放页表页本身，ownership 回收由 `pkvm_vm->mmu` teardown（`guest_mmu_free_leaf()`）负责。

### P0：实现 pkvm_pgstate_pgt_map_range()

**文件：`arch/x86/kvm/vmx/pkvm/hyp/ept.c`（新增函数）**

```c
int pkvm_pgstate_pgt_map_range(struct pkvm_pgtable *pgt,
    unsigned long gpa, unsigned long hpa,
    unsigned long size, u64 prot);
```

- `prot` 来自 guest mmu leaf 权限位（见 `mmu.c:509/511`），需剥离 page-state 软件位
- 只写 EPT 表项，不做 `hyp_page_ref_inc()`

### P0：修改 guest_mmu_map_leaf() 增加 mirror hook

**文件：`arch/x86/kvm/pkvm/mmu.c:426` 附近**

donate 成功后，若 pVM 有 ptdev，同步更新 DMA mirror 并按 GPA/IOVA 刷 IOTLB（`iommu.c:1301`），不复用 host EPT flush。建议作为 VMX-specific hook。

### P1：实现 pkvm_pgstate_pgt_prepopulate_from_guest_mmu()

**文件：`arch/x86/kvm/vmx/pkvm/hyp/ept.c` 或 `ptdev.c`（新增函数）**

- 必须在 `pkvm_shadow_sl_iommu_pgt_update_coherency()` 之后调用
- 仅在 ptdev_head 从空变非空时执行（首次 attach）
- 失败时需回滚已部分构造的 pgstate_pgt，拒绝 attach
- prot 取自 guest mmu leaf 权限位，剥离 page-state 软件位

## 7. 关键设计约束

### pgstate_pgt 语义
- pgstate_pgt map：只写 EPT 表项，不做 `hyp_page_ref_inc()`
- pgstate_pgt teardown：只释放页表页本身
- ownership 归还：只在 `guest_mmu_free_leaf()` 中发生

### hyp_page.refcount 语义
`hyp_page.refcount > 0` 表示页被 pin（shadow IOMMU 引用、shared page pin 等），不能被 donate。pVM DMA mirror pgtable 不修改 refcount。

### IOTLB flush
- attach 时：`pkvm_iommu_sync()` 负责
- donate + mirror map 时：需额外按 GPA/IOVA 范围 flush pgstate_pgt（`iommu.c:1301`），与 host EPT flush 分开
- detach 时：`pkvm_iommu_sync()` 负责，IOMMU 重建为 host 当前配置（不一定是 bare host root）

### 两条路径严格分离
- host 侧现有 shadow pgt 路径：保持当前行为
- pVM DMA mirror：使用纯 EPT map（不做 ref_inc），teardown 只释放页表页

## 8. 实现优先级

| 优先级 | 内容 | 解决的问题 |
|--------|------|------------|
| P0 | attach 时清理旧 shadow spgt 的残留 refcount | panic 直接修复：MAP_DMA 先于 attach 发生，旧 refcount 残留 |
| P0 | detach 前移到 `pkvm_vm_mmu_destroy()` 之前 | 安全 teardown（correctness 前提）|
| P0 | `pgstate_pgt_free_leaf` 语义分离 | 正确区分 DMA mirror 和 ownership 回收 |
| P0 | 实现 `pkvm_pgstate_pgt_map_range()` + mirror hook | donate 时自动填充 DMA mirror |
| P1 | 实现 `pkvm_pgstate_pgt_prepopulate_from_guest_mmu()` | 设备热插拔支持 |

## 9. 已知遗留问题

- **旧 spgt 共享场景**：若多个设备共享同一个 host shadow spgt（refcount > 1），attach 其中一个设备时不能直接销毁 spgt。需要评估是否只对当前设备涉及的 HPA 范围做 ref_dec，或者在 spgt 最终销毁时统一清理
- **错误回滚**：prepopulate/runtime map 失败时的部分回滚策略未设计
- **pkvm_detach_ptdev() 静默失败**：`pkvm_iommu_sync()` 失败不向上传播，需补充 WARN
- **need_prepopulation 状态机**：建议改为仅在 ptdev_head 从空变非空时置 true，避免多设备场景重复全量 prepopulate

## 10. 参考代码位置

| 功能 | 文件 | 行号 |
|------|------|------|
| `pkvm_attach_ptdev` | `ptdev.c` | 162 |
| `sync_shadow_context_entry` SLPTR（legacy） | `shadow_iommu.c` | 578 |
| `sync_shadow_pasid_table_entry` SLPTR（scalable） | `shadow_iommu.c` | 755 |
| `ptdev_attached_to_vm` 分支判断 | `shadow_iommu.c` | 543 |
| `guest_mmu_map_leaf` donate 入口 | `mmu.c` | 426 |
| `pkvm_vm_destroy`（detach 前移位置） | `pkvm/pkvm.c` | 669 |
| `pkvm_vm_mmu_destroy` | `pkvm/mmu.c` | 701 |
| `pkvm_teardown_shadow_vm` | `hyp/pkvm.c` | 87 |
| `pkvm_pgstate_pgt_free_leaf` | `ept.c` | 398 |
| `need_prepopulation` 设置 | `hyp/pkvm.c` | 28 |
| `pgstate_pgt` 注释说明 | `ept.c` | 357 |
| `iommu_flush_iotlb` | `iommu.c` | 1301 |
| guest mmu leaf prot 来源 | `mmu.c` | 509 |

# REFERENCE
[[崩溃日志3]]
[[分析]]
