# pKVM-IA pVM 设备透传设计方案

> 本文档经 Codex 代码审核（2026-03-19）修订。

## 1. 背景

当前 pKVM-IA 在透传设备给 pVM（protected VM）时会 panic。根因已确认（详见 BOOT-006 问题记录）：

- crosvm 以 NoIommu VFIO 模式启动带透传设备的 pVM 时，会把 Guest 全部物理内存做 `VFIO_IOMMU_MAP_DMA`
- pKVM 通过 `sync_shadow_pgt()` 同步 Host IOMMU 页表到 shadow IOMMU 时，`shadow_pgt_map_leaf()` 对这些 HPA 做 `hyp_page_ref_inc()`
- `pkvm_put_host_iommu_spgt()` 销毁旧 shadow pgtable 时调用 `pkvm_pgtable_destroy(&spgt->pgt, NULL)`，不调用 `shadow_pgt_unmap_leaf()`，leaf HPA 的 refcount 永远不被归还（stale refcount）
- 后续 pVM 启动触发 EPT violation，`host_initiate_donation()` 因 `hyp_page_count() != 0` 返回 `-EBUSY`，VM 启动失败

**注**：`hyp_page_count() != 0` 拒绝 donate，不只代表 shadow IOMMU 引用，pin 的 shared page 也会增加 refcount（见 `mem_protect.c:823/1130`）。当前场景的根因是 shadow IOMMU 的 stale refcount。

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
| stale refcount 修复 | 缺失 | `iommu_spgt.c:101` |

## 3. 安全模型决策

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

## 4. 完整执行流程（方案 B）

### 4.1 设备 attach 流程

```
pkvm_add_ptdev(shadow_vm_handle, bdf, pasid)   [仅对 pVM 执行]
    pkvm_shadow_vm_link_ptdev()
        vm->need_prepopulation = true
        pkvm_shadow_sl_iommu_pgt_update_coherency()  <- non-coherent mm_ops 在此切换
                                                         必须在 prepopulate 之前完成
    pkvm_attach_ptdev()
        旧 host shadow spgt teardown（修复后：含 leaf ref_dec）
        [新增] pkvm_pgstate_pgt_prepopulate_from_guest_mmu(vm)
            在 update_coherency 之后调用（mm_ops 已正确设置）
            遍历 pkvm_vm->mmu，将已 donated GPA->HPA 写入 pgstate_pgt
            prot 取自 guest mmu leaf 权限位，剥离 page-state 软件位
            若 pgstate_pgt 为空（pVM 刚启动未 donate 任何页），结果为空，属正常
            失败时需回滚已部分构造的 pgstate_pgt，并拒绝 attach
        ptdev->pgt = &vm->pgstate_pgt
        [新增] vm->need_prepopulation = false
        pkvm_iommu_sync()
            sync_shadow_context_entry()         -> SLPTR = pgstate_pgt->root_pa（legacy）
            sync_shadow_pasid_table_entry()     -> SLPTR = pgstate_pgt->root_pa（scalable）
            IOTLB flush
```

need_prepopulation 建议仅在 ptdev_head 从空变非空时置 true（首次 attach），后续 attach 不重复全量 prepopulate。

### 4.2 Guest 运行中（EPT violation）

```
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

### 4.3 VM teardown（关键：调用顺序）

**当前调用链（存在安全问题）：**

```
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

```
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

### 4.4 设备 detach 流程

```
pkvm_detach_ptdev(ptdev, vm)
    ptdev->pgt = pkvm_hyp->host_vm.ept   [暂时置为 host ept]
    pkvm_iommu_sync(bdf, pasid)
        sync_shadow_context_entry()       -> SLPTR 重建为 host 当前配置
                                            （可能是 host shadow spgt 或其他，不一定是 bare host root）
        IOTLB flush
    pkvm_put_ptdev()
```

## 5. 需要修改的文件和函数

### P0：修复 stale refcount（解除 panic）

**文件：`arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c:101`**

`shadow_pgt_unmap_leaf` 是 `shadow_iommu.c` 中的 `static` 函数，不能直接跨文件调用。需先导出或抽取 helper：

```c
// 修改前：
pkvm_pgtable_destroy(&spgt->pgt, NULL);
// 修改后：
pkvm_pgtable_destroy(&spgt->pgt, spgt_leaf_release_cb);  // 对 leaf HPA 做 hyp_page_ref_dec
```

副作用分析：只对 present leaf 做 ref_dec；MMIO leaf 因 `hyp_phys_to_page_safe()` 安全失败不会误减；不需要额外 IOTLB flush。

### P1：前移 detach 到 pkvm_vm_mmu_destroy() 之前（correctness 前提）

**文件：`arch/x86/kvm/pkvm/pkvm.c`（`pkvm_vm_destroy` 附近）**

在调用 `pkvm_vm_mmu_destroy()` 之前先遍历 shadow_vm->ptdev_head 调用 `pkvm_detach_ptdev()`。需要通过 arch hook 或直接访问 shadow_vm 实现。

### P1：pgstate_pgt_free_leaf 语义分离（correctness 前提）

**文件：`arch/x86/kvm/vmx/pkvm/hyp/ept.c:398`**

当前 `pkvm_pgstate_pgt_free_leaf()` 对 pVM 调用 `__pkvm_host_undonate_guest()`。若 `pgstate_pgt` 只作为 DMA mirror，其 teardown 只应释放页表页本身，ownership 回收由 `pkvm_vm->mmu` teardown（`guest_mmu_free_leaf()`）负责。

### P1：实现 pkvm_pgstate_pgt_map_range()

**文件：`arch/x86/kvm/vmx/pkvm/hyp/ept.c`（新增函数）**

```c
int pkvm_pgstate_pgt_map_range(struct pkvm_pgtable *pgt,
                               unsigned long gpa, unsigned long hpa,
                               unsigned long size, u64 prot);
```

- `prot` 来自 guest mmu leaf 权限位（见 `mmu.c:509/511`），需剥离 page-state 软件位
- 只写 EPT 表项，不做 `hyp_page_ref_inc()`

### P1：修改 guest_mmu_map_leaf() 增加 mirror hook

**文件：`arch/x86/kvm/pkvm/mmu.c:426` 附近**

donate 成功后，若 pVM 有 ptdev，同步更新 DMA mirror 并按 GPA/IOVA 刷 IOTLB（`iommu.c:1301`），不复用 host EPT flush。建议作为 VMX-specific hook。

### P2：实现 pkvm_pgstate_pgt_prepopulate_from_guest_mmu()

**文件：`arch/x86/kvm/vmx/pkvm/hyp/ept.c` 或 `ptdev.c`（新增函数）**

- 必须在 `pkvm_shadow_sl_iommu_pgt_update_coherency()` 之后调用
- 仅在 ptdev_head 从空变非空时执行（首次 attach）
- 失败时需回滚已部分构造的 pgstate_pgt，拒绝 attach
- prot 取自 guest mmu leaf 权限位，剥离 page-state 软件位

## 6. 关键设计约束

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

- host shadow spgt：使用 `shadow_pgt_map_leaf` / `shadow_pgt_unmap_leaf`（含 ref_inc/dec）
- pVM DMA mirror：使用纯 EPT map（不做 ref_inc），teardown 只释放页表页

## 7. 实现优先级

| 优先级 | 内容 | 解决的问题 |
|--------|------|------------|
| P0 | 修复 `iommu_spgt.c` stale refcount | 解除当前 panic |
| P1 | detach 前移到 `pkvm_vm_mmu_destroy()` 之前 | 安全 teardown（correctness 前提）|
| P1 | `pgstate_pgt_free_leaf` 语义分离 | 正确区分 DMA mirror 和 ownership 回收 |
| P1 | 实现 `pkvm_pgstate_pgt_map_range()` + mirror hook | donate 时自动填充 DMA mirror |
| P2 | 实现 `pkvm_pgstate_pgt_prepopulate_from_guest_mmu()` | 设备热插拔支持 |

## 8. 已知遗留问题

- **错误回滚**：prepopulate/runtime map 失败时的部分回滚策略未设计
- **pkvm_detach_ptdev() 静默失败**：`pkvm_iommu_sync()` 失败不向上传播，需补充 WARN
- **need_prepopulation 状态机**：建议改为仅在 ptdev_head 从空变非空时置 true，避免多设备场景重复全量 prepopulate

## 9. 参考代码位置

| 功能 | 文件 | 行号 |
|------|------|------|
| `shadow_pgt_unmap_leaf`（ref_dec） | `shadow_iommu.c` | 395 |
| `pkvm_put_host_iommu_spgt`（待修复） | `iommu_spgt.c` | 73 |
| `pkvm_attach_ptdev` | `ptdev.c` | 162 |
| `sync_shadow_context_entry` SLPTR（legacy） | `shadow_iommu.c` | 578 |
| `sync_shadow_pasid_table_entry` SLPTR（scalable） | `shadow_iommu.c` | 755 |
| `guest_mmu_map_leaf` donate 入口 | `mmu.c` | 426 |
| `pkvm_vm_destroy`（detach 前移位置） | `pkvm/pkvm.c` | 669 |
| `pkvm_vm_mmu_destroy` | `pkvm/mmu.c` | 701 |
| `pkvm_teardown_shadow_vm` | `hyp/pkvm.c` | 87 |
| `pkvm_pgstate_pgt_free_leaf` | `ept.c` | 398 |
| `need_prepopulation` 设置 | `hyp/pkvm.c` | 28 |
| `pgstate_pgt` 注释说明 | `ept.c` | 357 |
| `iommu_flush_iotlb` | `iommu.c` | 1301 |
| guest mmu leaf prot 来源 | `mmu.c` | 509 |
