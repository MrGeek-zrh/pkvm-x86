# [BOOT-009] protected pVM 在 NoIommu VFIO 透传下偶发触发 copy_gpa 写路径 #PF(err=0x2) 并继发 soft lockup

## 现象

- 在 protected pVM + VFIO(`NoIommu`) + NVMe `0000:01:00.0` 的后续运行中，又暴露出一条与 `BOOT-008` 强相关、但签名不同的新问题：
  - `pkvm: exception 14 on CPU10 @ip copy_gpa__pkvm.isra.0+0xf5/0x170 ..., err code 0x2`
  - 随后 host 出现 `watchdog: BUG: soft lockup`
  - 再随后出现 `rcu_preempt detected stalls` 与 `CPU 10: NMIs are not reaching exc_nmi() handler`
- 这条签名当前不是稳定复现，而是偶发复现。
- 结合当前运行判断，它更像是“`BOOT-008` 对应的 T2/T3 修复路径并没有在这次运行里稳定触发，随后暴露出的新 bug”，而不是 `BOOT-008` 主签名本身重新稳定回归。

```text
[102490.561068] pkvm: exception 14 on CPU10 @ip copy_gpa__pkvm.isra.0+0xf5/0x170 (0xffffffffa6200ad5), err code 0x2
[102542.002097] watchdog: BUG: soft lockup - CPU#30 stuck for 22s! [kcompactd0:218]
[102550.652757] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:
[102550.659394] pkvm: exception 14 on CPU10 @ip copy_gpa__pkvm.isra.0+0xf5/0x170 (0xffffffffa6200ad5), err code 0x2
[102560.660928] nmi_backtrace_stall_check: CPU 10: NMIs are not reaching exc_nmi() handler (CPU was never in an NMI handler function)
[102570.002544] watchdog: BUG: soft lockup - CPU#30 stuck for 48s! [kcompactd0:218]
```

- 当前最小影响：
  - 当次运行无法继续作为 `BOOT-008` 修复生效的有效验证样本；
  - host 内核进入长时间不前进状态，最终演变成 soft lockup / RCU stall。

## 根因（简述）

- 当前更合理的源码侧入口不是 DMA fault 本身，而是 hyp 向 guest 回写 MMIO allowlist 缓冲区时的 `copy_gpa()` 写路径。
- 直接源码证据：
  - [memory.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c)
    - `copy_gpa()` / `write_gpa()` 最终都落到 `__copy_gpa()`
    - `err code 0x2` 对应写 fault；而 `__copy_gpa()` 的写侧正是 `memcpy(hva, addr, len)`
    - 文件里的注释仍写着 `only support host VM now`
  - [vmx.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c)
    - 当前 `__PKVM_HYP__` 路径下，`write_gpa()` 的调用点只有：
      - `pkvm_handle_ptdev_mmio_info()`
      - `pkvm_handle_ptdev_mmio_read()`
    - 也就是 hyp 把 ptdev MMIO metadata / allowlist 回写到 guest GPA 缓冲区的路径
  - [pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c)
    - `pkvm_guest_init_coco()` 早期就会调用 `pkvm_init_mmio_allowlist()`
    - `pkvm_init_mmio_allowlist()` 通过
      - `kvm_hypercall2(PKVM_GHC_PTDEV_MMIO_INFO, __pa(&pkvm_mmio_info), ...)`
      - `kvm_hypercall3(PKVM_GHC_PTDEV_MMIO_READ, __pa(pkvm_mmio_allow_ranges), ...)`
      让 hyp 把数据直接写回 guest 物理地址
    - 同文件里的 `pkvm_set_mem_host_visibility()` 明确说明：当 guest EPT 里还没有页表项时，host/hyp 访问 guest 页可能失败，因此它在 share 前会先 `memset()` 触页；而 `pkvm_init_mmio_allowlist()` 当前没有做类似的预触页/可见性准备
- 因此，当前更像是：
  - guest 在早期初始化里发起 `PKVM_GHC_PTDEV_MMIO_INFO/READ`
  - hyp 在 `write_gpa()` -> `copy_gpa()` 写回 guest GPA 缓冲区
  - 某些运行里该 guest GPA 对应页还没有稳定 materialize / 可见
  - `copy_gpa__pkvm` 写侧因此触发 `#PF(err=0x2)`，CPU10 卡死在 pKVM 异常路径里
  - 其它 CPU 后续在 TLB flush / RCU 推进时等不到 CPU10 响应，于是外显为 soft lockup 与 RCU stall
- 上述最后几条是基于日志、调用点和现有代码的推断，不是内核已经打印出来的显式结论。

## 解决方案

- 这条签名不应回写到 `BOOT-008`，必须单独保留为 `BOOT-009`：
  - `BOOT-008` 记录的是 host DMAR `PTE Read access is not set`
  - `BOOT-009` 记录的是 `copy_gpa__pkvm` 写路径 `#PF(err=0x2)` + soft lockup
- 但它和 `BOOT-008/T2/T3` 明显强相关：
  - 一旦 `BOOT-009` 先出现，当次运行就无法证明 runtime DMA mirror 是否已稳定生效
  - 当前应把它视为“`BOOT-008` 修复闭环尚未稳定覆盖到所有运行”的派生偶发 bug
- 当前排查重点应放在：
  - guest MMIO allowlist 回写缓冲区在 `PKVM_GHC_PTDEV_MMIO_INFO/READ` 前是否已经稳定有 EPT 映射
  - `write_gpa()` / `copy_gpa()` 这条 `only support host VM now` 的老路径，是否被直接拿来承担 protected guest 的回写语义
  - 是否需要在 allowlist 查询前显式预触页，或把回写改为带翻译/容错的 guest copy 路径

## 验证要点

- 继续使用同样的 `NoIommu` 命令重复启动时：
  - host `dmesg` 不应再出现
    - `pkvm: exception 14 ... copy_gpa__pkvm ... err code 0x2`
    - `watchdog: BUG: soft lockup`
    - `rcu_preempt detected stalls`
    - `NMIs are not reaching exc_nmi() handler`
  - guest 仍应能稳定完成 ptdev MMIO allowlist 初始化，继续进入 NVMe 枚举与后续 DMA 访问阶段
  - 只有在这条偶发签名也不再出现后，`BOOT-008` 的重复启动回归才具有足够解释力

## 原始日志（节选）

```text
[102490.561068] pkvm: exception 14 on CPU10 @ip copy_gpa__pkvm.isra.0+0xf5/0x170 (0xffffffffa6200ad5), err code 0x2
[102542.002097] watchdog: BUG: soft lockup - CPU#30 stuck for 22s! [kcompactd0:218]
[102550.652757] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:
[102550.659394] pkvm: exception 14 on CPU10 @ip copy_gpa__pkvm.isra.0+0xf5/0x170 (0xffffffffa6200ad5), err code 0x2
[102560.660928] nmi_backtrace_stall_check: CPU 10: NMIs are not reaching exc_nmi() handler (CPU was never in an NMI handler function)
```

## 完整原始报错信息文件

- 当前按 2026-04-01 整理入库；原始片段只保留了 uptime 时间戳，没有 wall clock：
  - [20260401-host-copy-gpa-exception14-soft-lockup.log](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-009/raw/20260401-host-copy-gpa-exception14-soft-lockup.log)

## 触发条件/复现场景

- Host 内核：`6.12.0-pkvm-ia #2`
- VM 类型：protected pVM
- 透传设备：NVMe `0000:01:00.0`
- guest 不暴露虚拟 IOMMU，使用 `NoIommu` 路径
- 当前运行判断：
  - `BOOT-008` 的 runtime DMA mirror 修复并非每次都稳定触发
  - 这条签名只是在部分运行里偶发暴露
- 最小复现命令：

```bash
sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

## 触发路径（常见回溯）

```text
guest early init
    pkvm_guest_init_coco()                               (arch/x86/coco/pkvm/pkvm.c)
        pkvm_init_mmio_allowlist()                       (arch/x86/coco/pkvm/pkvm.c)
            kvm_hypercall2(PKVM_GHC_PTDEV_MMIO_INFO,
                           __pa(&pkvm_mmio_info), ...)
                kvm_pkvm_hypercall()                     (arch/x86/kvm/pkvm/vmx/vmx.c)
                    pkvm_handle_ptdev_mmio_info(...)
                        write_gpa(vcpu, guest_gpa, &info, ...)
                            copy_gpa(...)
                                __copy_gpa(...)
                                    host_gpa2hva(gpa)
                                    memcpy(hva, addr, len)
                                    // 这里更像是命中写 fault 的位置
```

### 另一条等价写回路径

```text
guest early init
    pkvm_init_mmio_allowlist()                           (arch/x86/coco/pkvm/pkvm.c)
        kvm_hypercall3(PKVM_GHC_PTDEV_MMIO_READ,
                       __pa(pkvm_mmio_allow_ranges), ...)
            kvm_pkvm_hypercall()                         (arch/x86/kvm/pkvm/vmx/vmx.c)
                pkvm_handle_ptdev_mmio_read(...)
                    write_gpa(vcpu, guest_gpa, ranges, ...)
                        copy_gpa(...)
                            __copy_gpa(...)
                                memcpy(hva, addr, len)
```

### 后续 soft lockup 路径推断

```text
CPU10
    卡在 copy_gpa__pkvm 的异常路径
        无法及时响应后续 IPI / NMI

CPU30 / kcompactd0
    native_flush_tlb_multi()
        on_each_cpu_cond_mask()
            smp_call_function_many_cond()
                长时间等待目标 CPU
                    watchdog 报 soft lockup

系统后续
    rcu_preempt detected stalls
    NMI backtrace 显示 CPU10 未进入 exc_nmi()
```

## 影响

- 这条签名一旦出现，当前轮 protected pVM + VFIO 验证会在更早阶段就失去解释力。
- 它会掩盖“runtime DMA mirror 是否已经稳定生效”的判断，因此不能把这类失败样本直接算作 `BOOT-008` 的正反证据。

## 环境信息（来自日志）

- 内核：`6.12.0-pkvm-ia #2`
- 硬件：`QEMU Standard PC (Q35 + ICH9, 2009)`
- BIOS：`1.16.3-debian-1.16.3-2 04/01/2014`

## 线索

- [memory.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c)
  - `copy_gpa()` / `write_gpa()` 当前仍保留 `only support host VM now` 注释
- [vmx.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c)
  - `pkvm_handle_ptdev_mmio_info()` / `pkvm_handle_ptdev_mmio_read()` 是当前 `write_gpa()` 唯一调用点
- [pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c)
  - `pkvm_guest_init_coco()` 早期即调用 `pkvm_init_mmio_allowlist()`
  - `pkvm_set_mem_host_visibility()` 里的预触页说明，也表明 guest 页未 materialize 时 host/hyp 访问可能失败

## 备注

- 当前应继续把 `BOOT-008` 视为 runtime DMA mirror 主签名，把 `BOOT-009` 视为强关联但独立的偶发派生 bug。
- 若后续确认它实际来自别的 `write_gpa()` 使用路径，再按新证据修正文档；在此之前不应把它和 `BOOT-008` 混成同一签名。
