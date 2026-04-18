# [T4] P0: VM 销毁前 quiesce ptdev DMA

## 状态

- 当前状态: GitHub Task `pkvm-x86#8` 已关闭；第一版实现已完成首轮重启后推荐矩阵验证，`Case A 20 轮 + Case B/C 各 5 轮` 全部负例
- 优先级: P0
- GitHub Task: `pkvm-x86#8`
- 关联 Bug: `pkvm-x86#32`

## 目标

在 pVM 销毁前，先让设备失去对 pVM 私有页的 DMA 可达性，再销毁 guest mmu 并把页面还给 host，保证生命周期顺序正确。

## 为什么单独拆分

- 这是 correctness 前提，不是优化项。
- 当前源码里 guest/mmu teardown 与 ptdev / VFIO 销毁时序存在生命周期风险，需要单独验证和收敛。
- 更关键的是，现有 `pkvm_detach_ptdev()` 只是切回 host IOMMU 视图，不等于真正把 DMA 先切断。

## 关键源码锚点

- `pKVM-IA/arch/x86/kvm/pkvm/pkvm.c`
  - `pkvm_vm_destroy()`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - `pkvm_vm_mmu_destroy()`
  - `guest_mmu_free_leaf()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`
  - `pkvm_teardown_shadow_vm()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_detach_ptdev()`
- `pKVM-IA/virt/kvm/kvm_main.c`
  - `kvm_destroy_vm()`
- `pKVM-IA/virt/kvm/vfio.c`
  - `kvm_vfio_file_del()`
  - `kvm_vfio_release()`

## 当前已确认结论

- `pkvm_vm_destroy()` 当前先做 `pkvm_vm_mmu_destroy()`，后做 `kvm_arch_destroy_vm()`。
- `pkvm_teardown_shadow_vm()` 当前会在受保护 VM 收尾时执行 `pkvm_detach_ptdev()`，之后才 `pkvm_pgstate_pgt_deinit()`。
- `kvm_destroy_vm()` 当前是先 `kvm_arch_destroy_vm()`，再 `kvm_destroy_devices()`，因此 VFIO 设备释放晚于 pKVM VM 销毁。
- 现有 `pkvm_detach_ptdev()` 会把 `ptdev->pgt` 直接切回 `host_vm.ept` 并调用 `pkvm_iommu_sync()`，这更像“恢复 host 视图”，不是“立即阻断 DMA”。
- 截至 2026-04-15，`Case A: 活跃 DMA + host 强制销毁` 已单次观测到新的销毁阶段 DMAR fault 签名：

```text
[Wed Apr 15 14:36:20 2026] DMAR: DRHD: handling fault status reg 2
[Wed Apr 15 14:36:20 2026] DMAR: [DMA Read NO_PASID] Request device [01:00.0] fault addr 0xff0f0000 [fault reason 0x06] PTE Read access is not set
```

- 同一轮后续还能看到 host 侧 NVMe 重新 probe 时出现 timeout / `probe ... failed`，说明 teardown 后设备状态也受到影响。
- 但在 2026-04-15 补做的 `Case A/B/C` 各 10 轮矩阵里：
  - `Case A`：`10/10` 全负例
  - `Case B`：`10/10` 全负例
  - `Case C`：`10/10` 全负例
- 当前结论更新为：
  - 单次正例仍然值得保留，但它不是当前步骤下的稳定可复现签名；
  - 现阶段更像“存在低概率销毁窗口或隐藏触发条件”，但源码层面的生命周期逆序已经足够明确，可以开始做第一版修复收敛。

## 当前问题调用栈

```text
userspace close VM fd
    kvm_destroy_vm()                                     (virt/kvm/kvm_main.c)
        kvm_arch_destroy_vm()                            (arch/x86/kvm/x86.c)
            kvm_x86_call(vm_destroy)
                pkvm_vm_destroy()                        (arch/x86/kvm/vmx/pkvm_high.c)
                    pkvm_hypercall(vm_destroy)
                        pkvm_vm_destroy(handle)          (arch/x86/kvm/pkvm/pkvm.c)
                            pkvm_vm_mmu_destroy()        (arch/x86/kvm/pkvm/mmu.c)
                                guest_mmu_free_leaf()   (arch/x86/kvm/pkvm/mmu.c)
                                    __pkvm_host_undonate_guest()
                            kvm_arch_destroy_vm()
                                vmx_vm_destroy()         (arch/x86/kvm/pkvm/vmx/vmx.c)
                                    pkvm_teardown_shadow_vm()    (arch/x86/kvm/vmx/pkvm/hyp/pkvm.c)
                                        pkvm_detach_ptdev()      (arch/x86/kvm/vmx/pkvm/hyp/ptdev.c)
                                            pkvm_iommu_sync()    (arch/x86/kvm/vmx/pkvm/hyp/iommu.c)
```

当前问题不在“VFIO release 太晚”这一点本身，而在更前面的 hyp 销毁顺序：

- guest 页先在 `__pkvm_host_undonate_guest()` 里还给 host；
- ptdev 对应的 IOMMU 入口要到后面的 `pkvm_detach_ptdev()` / `pkvm_iommu_sync()` 才真正切走；
- 这中间就是 T4 的生命周期风险窗口。

## 修复方案摘要

- 修复目标收敛为“两阶段销毁”：
  1. 先切断 ptdev DMA；
  2. 再销毁 guest mmu 并把页面还给 host；
  3. 最后保留现有 `pkvm_detach_ptdev()` 做收尾清理。
- 第一版不调整 generic `kvm_destroy_vm()` / `kvm_destroy_devices()` 的顺序。
- 第一版也不直接前移现有 `pkvm_detach_ptdev()`。

### 为什么不能直接前移 `pkvm_detach_ptdev()`

- 当前 `pkvm_detach_ptdev()` 的语义太重，不只是“让 DMA 不可达”：
  - 会把 `shadow_vm_handle` 清零；
  - 会清空 MMIO metadata；
  - 会把 `ptdev->pgt` 切回 `host_vm.ept`；
  - 会把 ptdev 从 shadow VM 链表里 unlink。
- 这更像“彻底解绑并恢复 host 视图”，而不是“先把 DMA 门关上”。
- 因此它适合留在销毁后半段做收尾，不适合作为前半段的“先切断 DMA”步骤。

### 第一版实现设计

- 修复插点：
  - 真正入口在 `arch/x86/kvm/pkvm/pkvm.c` 的 `pkvm_vm_destroy(handle)`。
  - 更准确地说，插在 `pkvm_vm_mmu_destroy()` 之前。
- 新增一个“前置切断 DMA”步骤，形态上类似：

```text
pkvm_vm_destroy(handle)
    pkvm_quiesce_shadow_vm_ptdevs()
    pkvm_vm_mmu_destroy()
    kvm_arch_destroy_vm()
```

- 这个前置步骤只做两件事：
  - 强制把对应的 IOMMU context / PASID 表项改成无效；
  - 刷新对应的 context cache / PASID cache / IOTLB。
- 这个前置步骤明确不做：
  - unlink ptdev
  - 改 `shadow_vm_handle`
  - 清 MMIO metadata
  - `put_ptdev()` / 改 refcount
  - 把设备切回 `host_vm.ept`

### “先切断 DMA” 的目标语义

- 这里的目标不是“切回 host DMA 视图”，而是“先把 DMA 能力封死”。
- 对应到 IOMMU 影子表语义上，就是：
  - 传统模式：把该设备的 context 表项直接改成无效；
  - 可扩展模式：把该设备的 PASID 表项直接改成无效；
  - 然后立即刷新缓存，确保旧 DMA 翻译不再可用。
- 这样做的原因是：
  - 如果前置步骤只是薄封装当前 `pkvm_iommu_sync()`，它仍可能沿用当前 attach / did audit 语义，不够彻底；
  - T4 这里需要的是销毁前的强制封口，不是普通 attach/detach 同步。

### 第一版实现范围

- 第一版验收仍以当前主线为准：
  - 单设备
  - 静态 attach
  - `NoIommu`
  - `pasid = 0`
- 若代码路径自然覆盖可扩展模式，可以一并保持语义一致；
  但第一版不把“完整可扩展模式销毁语义”作为当前验收门槛。

## 当前实施方向

- `T4A` 验证已经完成，可以把当前主文档从“只保留风险归因”前移到“按当前设计开始编码”。
- 当前第一版修复方向已经明确：
  - 不改 generic KVM/VFIO 销毁顺序；
  - 不前移现有 `pkvm_detach_ptdev()`；
  - 先补一个独立的“前置切断 DMA”步骤；
  - 再做 `guest_mmu_free_leaf()` 的 undonate；
  - 最后沿用现有 detach 做收尾。

### 与 `T12` / BAR ownership 的关系

- 截至 2026-04-17，当前决定不把 `T4` 的第一版修复改写成“先等 BAR ownership 状态机落地，再统一实现”。
- 当前原因是：
  - `T4` 首先要解决的是“guest 页回到 Host 前，设备 DMA 通路必须先被切断”；
  - `T12` / BAR ownership 首先要解决的是“Host CPU 是否还能通过 BAR / Host EPT 继续访问设备控制面”；
  - 两者相关，但不是同一个 correctness 条件。
- 因此当前阶段口径收敛为：
  - `T4` 继续沿用现有主线：先做前置 `quiesce / block DMA`，不等待完整 BAR ownership 实现；
  - `T12` 继续独立推进 `ptdev` 的 BAR `owner/state`、Host EPT invalid annotation 与 Host fault deny-remap；
  - 待 `T12` 的 BAR ownership 功能完成后，再回头评估是否基于同一套 `ptdev owner/state` 把 `T4` 的 teardown 编排进一步收敛到统一状态机。
- 也就是说，BAR ownership 是后续优化 `T4` 的候选骨架，而不是当前 `T4` 第一版修复的前置阻塞。

## 当前验证入口

- 触发样例与证据采集规则见 `04A-P0-teardown-DMA生命周期风险验证与触发样例.md`。
- 当前本地问题记录见 `../问题记录/BOOT-014/BOOT-014-protected-pVM-活跃DMA时host强杀crosvm后单次出现DMAR-NO_PASID-fault.md`。
- 当前自动化执行入口见 `../问题记录/BOOT-014/auto-repro-boot014-t4a-matrix.py`：
  - 默认跑 `Case A` 四个 kill 时机各 `5` 轮，共 `20` 轮；
  - `Case B/C` 默认各 `5` 轮回归；
  - 如需把 `B/C` 拉回旧强度，可显式传 `--iterations-b 10 --iterations-c 10`。
- 当前首轮推荐矩阵结果已保存到：
  - `../问题记录/BOOT-014/raw/20260416-t4a-recommended-matrix-summary.tsv`
  - `../问题记录/BOOT-014/raw/20260416-t4a-recommended-matrix-summary.json`
- 当前文档继续作为“风险归因 + 修复方案”入口使用；后续若再次稳定复现独立 fault，再补独立 GitHub `Bug + Task`。

## 验收标准

- guest 页回到 host 前，设备已失去对这些页的 DMA 可达性。
- 销毁过程中不会出现“设备仍 DMA 到已归还 host 的物理页”。
- 与 KVM / VFIO 既有销毁顺序兼容。
- 现有 `pkvm_detach_ptdev()` 仍保留为销毁后半段收尾，而不是被前置切断 DMA 步骤替代。
- 这轮验证除继续检查旧签名 `DMAR ... PTE Read access is not set` 外，也必须检查新的“表项已被前置无效化但仍有 DMA 命中”类签名，例如 `Present bit in context entry is clear` / `Present bit in PASID entry is clear`。

## 当前阶段结论（2026-04-16）

- 当前第一版实现已通过首轮推荐矩阵：
  - `Case A`: `20/20` 全负例
  - `Case B`: `5/5` 全负例
  - `Case C`: `5/5` 全负例
- 在这轮 `30/30` 样例里，未再出现：
  - `BOOT-014` 的旧签名 `DMAR [DMA Read NO_PASID] ... PTE Read access is not set`
  - 预期中的邻近 blocked-DMA 签名 `Present bit in context entry is clear` / `Present bit in PASID entry is clear`
  - `nvme timeout` / `probe with driver nvme failed`
- 当前更合理的口径是：
  - 第一版 T4 实现在当前推荐样例下表现稳定；
  - 但这仍然属于“负例回归通过”，还不能单靠这一轮就宣称 teardown correctness 已被完全证明；
  - 后续若需要进一步抬高置信度，应考虑扩大轮次、引入更细的 kill 时机控制，或补 trace 观测点。

## 风险点

- 如果只是简单前移 `pkvm_detach_ptdev()`，很可能把设备重新暴露到 host IOMMU 视图。
- 如果前置步骤只是复用当前普通同步路径，可能不足以在所有 IOMMU 模式下真正把表项改成无效。
- 第一版只是先把 IOMMU 里的 DMA 通路切断，并刷新相关缓存；它不等于设备本身已经完全停止 DMA。
- 当前销毁路径仍未建立“销毁中途失败”的完整语义；当前实现里如果前置切断 DMA 失败，仍只是记录日志并继续销毁，这一收口方式后续还需要单独评估。
- 第一版应尽量控制在 hyp 内部收敛，避免把这次销毁修复和更大范围的 host/UAPI 设计耦合到一起。

## 依赖

- T2。
