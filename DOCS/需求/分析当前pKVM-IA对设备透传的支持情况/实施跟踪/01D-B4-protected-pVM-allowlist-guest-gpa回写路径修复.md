# [B4] P0: protected pVM allowlist guest-GPA 回写路径修复

## 状态

- 当前状态: 已完成（`BOOT-009` 当前可认为已修复）
- 优先级: P0

## 关联问题

- 关联 Bug:
  - [BOOT-009-protected-pVM-NoIommu-VFIO-copy-gpa-exception14-soft-lockup.md](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-009/BOOT-009-protected-pVM-NoIommu-VFIO-copy-gpa-exception14-soft-lockup.md)
- 关联 Task:
  - pkvm-x86#19

## 当前表现 / 当前阻塞

- protected pVM 在 guest 早期执行 `PKVM_GHC_PTDEV_MMIO_INFO/READ` 时，host 偶发打印：
  - `pkvm: exception 14 @ copy_gpa__pkvm ... err code 0x2`
  - 随后继发 `soft lockup` / `rcu_preempt stalls`
- 这条签名一旦先出现，当次运行就不能再作为 `BOOT-008/T2/T3` 的有效验证样本。
- 当前 blocker 不再是“allowlist 缓冲区可能没预触页”，而是“hyp 的 guest GPA copy helper 仍按 host identity 语义工作”。

## 修复方案摘要

- 当前最小修复应放在 [memory.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c)，而不是修改 guest allowlist ABI：
  - 对 host VM 保持现有 `host_gpa2hva()` identity copy 语义不变。
  - 对 protected pVM，在 `__copy_gpa()` 里先通过 `pkvm_vm->mmu` 做 guest GPA -> HPA 翻译。
  - 翻译成功后，还要再明确校验该 `HPA` 落在 normal RAM 范围内；direct-BAR / MMIO GPA 即使 lookup 成功，也必须按非法 buffer 拒绝。
  - 只有“已翻译且确认是 RAM buffer”时，才允许 `pkvm_phys_to_virt(hpa)` 执行 `memcpy()`。
  - 翻译失败时直接返回 `-EFAULT`，由 [vmx.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c) 的 `pkvm_handle_ptdev_mmio_info()` / `pkvm_handle_ptdev_mmio_read()` 回给 guest，而不是让 hyp 在 `memcpy()` 里直接 fault。
- 修复后这条 guest-GPA 回写主路径可以收敛为：

```text
guest early init
    pkvm_guest_init_coco()                               (arch/x86/coco/pkvm/pkvm.c)
        pkvm_init_mmio_allowlist()                       (arch/x86/coco/pkvm/pkvm.c)
            kvm_hypercall2(PKVM_GHC_PTDEV_MMIO_INFO, __pa(&pkvm_mmio_info), ...)
              or kvm_hypercall3(PKVM_GHC_PTDEV_MMIO_READ, __pa(pkvm_mmio_allow_ranges), ...)
                kvm_pkvm_hypercall()                     (arch/x86/kvm/pkvm/vmx/vmx.c)
                    pkvm_handle_ptdev_mmio_info()/pkvm_handle_ptdev_mmio_read()
                        write_gpa(vcpu, guest_gpa, ...)
                            copy_gpa(...)
                                __copy_gpa(...)          (arch/x86/kvm/vmx/pkvm/hyp/memory.c)
                                    pkvm_is_protected_vcpu(vcpu)
                                    guest_mmu_lock(pkvm_vm)
                                    pkvm_pgtable_lookup(&pkvm_vm->mmu, gpa, &hpa, ...)
                                    if (hpa == INVALID_ADDR)
                                        guest_mmu_unlock(pkvm_vm)
                                        return -EFAULT
                                    if (!is_mem_range(hpa, len))
                                        guest_mmu_unlock(pkvm_vm)
                                        return -EFAULT
                                    hva = pkvm_phys_to_virt(hpa)
                                    memcpy(hva, addr, len)
                                    guest_mmu_unlock(pkvm_vm)

non-protected path
    __copy_gpa(...)
        host_gpa2hva(gpa)
        memcpy(hva, addr, len)
```
- 这样可以把当前问题收敛为“guest copy 语义修正”，而不是误把它继续并入 DMA mirror 生命周期 patch。

## 为什么单独拆分

- `BOOT-009` 的 fault 点位于 guest allowlist 回写路径，不属于 `BOOT-008` 的 host DMAR 主签名本身。
- 如果不单独收敛这条早期路径，重复启动回归会持续混入无效样本，影响 T2/T3 的验证解释力。
- 这条修复是一个局部 correctness 问题，应该保持单目标补丁，不和 T4/T5/T6 混做。

## 关键源码锚点

- [memory.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c)
  - `host_gpa2hva()`
  - `__copy_gpa()`
  - `copy_gpa()` / `write_gpa()`
- [vmx.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c)
  - `pkvm_handle_ptdev_mmio_info()`
  - `pkvm_handle_ptdev_mmio_read()`
- [pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c)
  - `pkvm_init_mmio_allowlist()`
- [mmu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/mmu/mmu.c)
  - `pkvm_hypercall(vm_mmu_map, ..., gpa, hpa, ...)`
- [mem_protect.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
  - `__pkvm_guest_share_host()`
  - `__pkvm_guest_unshare_host()`

## 当前已确认结论

- guest 侧 [pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c) 的 `pkvm_init_mmio_allowlist()` 在两个 hypercall 之前，已经对 `pkvm_mmio_info` 和 `pkvm_mmio_allow_ranges` 做了完整 `memset()`。
- 因此，“allowlist buffer 没预触页/没 materialize”不能再作为当前主根因。
- [memory.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c) 的 `host_gpa2hva()` 仍是 host identity helper，不适合直接拿来写 protected guest GPA。
- [mmu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/mmu/mmu.c) 已明确说明 protected guest runtime map 是 `gpa -> hpa` 分离的，不应默认 `gpa == hpa`。
- [mem_protect.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c) 里已有 guest GPA 先 lookup 再访问的现成正确模式。
- protected guest 的 GPA 空间里也可能存在 direct-BAR / MMIO 区间；因此“lookup 成功”不等于“可以当普通 RAM buffer 做 `memcpy()`”。

## 当前本地实现进展

- 已在 [memory.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c) 落地并提交最小修正：
  - protected pVM 的 `__copy_gpa()` 先 lookup `pkvm_vm->mmu`
  - lookup 成功后先校验 `hpa` 落在 hyp 已知 normal RAM 范围
  - 只有 normal RAM 才使用 `pkvm_phys_to_virt(hpa)` copy
  - MMIO / 非 RAM buffer 直接返回 `-EFAULT`
  - lookup 失败时返回 `-EFAULT`
- 对应内核提交：`b86cfd0230b9`
- 根据当前验证判断，这版修正后未再次看到：
  - `pkvm: exception 14 @ copy_gpa__pkvm ... err code 0x2`
  - `watchdog: BUG: soft lockup`
  - `rcu_preempt detected stalls`
- 当前结论：
  - `pkvm-x86#19` 已满足关闭条件
  - `pkvm-x86#18` 当前也可作为已修复 bug 关闭保留

## 实现范围

- `pKVM-IA`:
  - [memory.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c)
- 文档:
  - `BOOT-009` 问题记录
  - `00-总览与进展看板.md`
  - 本文件

## 非目标

- 这轮不修改 guest allowlist ABI。
- 这轮不要求 guest 先额外 `SHARE_MEM` 才能查询 allowlist。
- 这轮不把 `BOOT-009` 和 `BOOT-008/T4/T5/T6` 的 DMA 生命周期或 remove-path 问题混在同一个 patch 里。

## 验收标准

- 同配置重复启动下，host `dmesg` 不再出现：
  - `pkvm: exception 14 @ copy_gpa__pkvm ... err code 0x2`
  - `watchdog: BUG: soft lockup`
  - `rcu_preempt detected stalls`
- guest 仍能稳定完成 allowlist 初始化，并继续进入 NVMe 枚举和后续 DMA 验证阶段。
- 若 guest 提供的 GPA 真的缺失映射，表现应收敛为 hypercall 返回失败，而不是 hyp 自身卡死。
- 若 guest 提供的是 MMIO / BAR GPA，表现也应收敛为 hypercall 返回失败，而不是 hyp 把 MMIO 当 RAM 写。

## 风险点

- `guest_mmu_lock()` 的加锁范围如果过小，理论上仍可能在 lookup 与 copy 之间暴露竞态。
- 这轮 patch 只修正 guest GPA copy 语义，不自动证明 `BOOT-008` 或 teardown 生命周期已经全部稳定。
- 当前工作树没有现成 `.config`，因此编译与运行验证还需要回到可复用的 host 内核构建树执行。
