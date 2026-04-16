# [BOOT-014] protected pVM 活跃 DMA 时 host 强杀 `crosvm` 后单次出现 `DMAR [DMA Read NO_PASID]` fault

## 现象

- 2026-04-15 在 protected pVM + VFIO NVMe `0000:01:00.0` 的 `Case A: 活跃 DMA + host 强制销毁` 样例中，guest 内持续 direct I/O 运行时，host 侧直接 `kill -9 crosvm` 后，host `dmesg` 单次出现新的 teardown 相关 DMAR fault：

```text
[Wed Apr 15 14:36:19 2026] vfio-pci 0000:01:00.0: Relaying device request to user (#0)
[Wed Apr 15 14:36:19 2026] nvme nvme0: pci function 0000:01:00.0
[Wed Apr 15 14:36:20 2026] DMAR: DRHD: handling fault status reg 2
[Wed Apr 15 14:36:20 2026] DMAR: [DMA Read NO_PASID] Request device [01:00.0] fault addr 0xff0f0000 [fault reason 0x06] PTE Read access is not set
[Wed Apr 15 14:37:22 2026] nvme nvme0: I/O tag 16 (0010) QID 0 timeout, disable controller
[Wed Apr 15 14:37:22 2026] nvme nvme0: Identify Controller failed (-4)
[Wed Apr 15 14:37:22 2026] nvme 0000:01:00.0: probe with driver nvme failed with error -5
```

- 当前最小影响：
  - 这说明 T4 对应的 teardown 生命周期风险不再只是源码推导；
  - 至少存在一次观测到的“host kill VMM 后 IOMMU/DMA 权限状态异常”正例。

## 最新状态

- 2026-04-15 首轮 `Case A` 已单次命中上述独立签名。
- 同日做了一轮更干净的重跑：
  - guest 再次成功登录；
  - `/dev/nvme0n1` 在 guest 内可见；
  - 持续 direct I/O 成功启动；
  - host 侧再次 `kill -9 crosvm`；
  - 但这轮仅看到 host 侧 NVMe 重新 probe，未再次命中同一个 DMAR fault。
- 同日补做了一轮 `Case C: guest poweroff -f`：
  - guest 再次成功登录；
  - `/dev/nvme0n1` 在 guest 内可见；
  - 持续 direct I/O 成功启动；
  - guest 内执行 `poweroff -f` 后，`crosvm` 正常退出；
  - host `dmesg` 增量里未见新的 DMAR / IOMMU fault，只看到 host 侧 NVMe 重新 probe。
- 同日继续把三类样例扩成矩阵，每类各跑 10 轮：
  - `Case A`: `10/10` completed，`0` 次 `DMAR/IOMMU fault`
  - `Case B`: `10/10` completed，`0` 次 `DMAR/IOMMU fault`
  - `Case C`: `10/10` completed，`0` 次 `DMAR/IOMMU fault`
- 因此当前结论是：
  - 这已经是一个新的 teardown 相关本地问题签名；
  - 但复现性仍未收敛，现阶段更适合作为 `T4/T4A` 的验证结果和候选 `Bug`，而不是已稳定复现的 blocker；
  - 当前看来，那次正例更像低概率窗口或隐藏前提触发，而不是按现有脚本可稳定重现的问题。

## 本轮提交信息

- `pkvm-x86` 本轮文档提交信息：
  - 标题：`固化T4A三类样例十轮矩阵结论`
  - 展开：`记录BOOT-014单次正例与A/B/C各十轮负例结果，并将T4继续保留为validation-first`

## 根因（简述）

- 结合当前 `T4` 源码分析，teardown 生命周期存在明确风险窗口：
  - `pkvm_vm_destroy()` 先做 `pkvm_vm_mmu_destroy()`，后做 `kvm_arch_destroy_vm()`；
  - `pkvm_teardown_shadow_vm()` 当前先 `pkvm_pgstate_pgt_deinit()`，再 `pkvm_detach_ptdev()`；
  - `kvm_destroy_vm()` 则是先 `kvm_arch_destroy_vm()`，后 `kvm_destroy_devices()`。
- 这意味着：
  - guest private page / guest MMU teardown 可能先于 VFIO 设备真正释放；
  - `pkvm_detach_ptdev()` 当前更像“切回 host 视图并同步 IOMMU”，而不是“显式 quiesce 设备 DMA”。
- 因此，这次单次命中的 `DMAR [DMA Read NO_PASID] ... PTE Read access is not set` 与 T4 的源码风险是吻合的。
- 但由于目前只命中一次，还不能仅凭这条日志就断言唯一根因已经完全锁定；它更像是“源码风险被样例打穿一次”的证据。

## 解决方案

- 保留这条签名为独立问题，不要覆盖旧的 BOOT-008/其它 boot-time 问题语义。
- 后续若再次稳定命中同签名，应升级为 GitHub 独立 `Bug`，并为 `T4` 建/补对应修复 `Task`。
- `T4` 的实现方向仍应保持不变：
  - 在 VM teardown 前增加显式的 `ptdev quiesce / invalidate` 阶段；
  - 先让设备失去对 guest private page 的 DMA 可达性；
  - 再执行 guest MMU teardown / undonate；
  - 不要只靠前移 `pkvm_detach_ptdev()` 作为最终方案。

## 验证要点

- 重复执行 `Case A`：
  - guest 内持续 direct I/O；
  - host 侧直接 `kill -9 crosvm`；
  - 记录 kill 前后的 host `dmesg` 增量。
- `Case B/C` 已经补跑到 10 轮；下一步更应补的是“增加触发控制和观测点”，而不是继续无差别堆同样的三类基础 case。
- 建议下一步：
  - 记录 host kill 前设备队列/中断/控制器状态；
  - 对比不同 kill 时机（刚起 DMA、DMA 中段、DMA 轮转边界）；
  - 必要时补最小 trace/调试日志，再决定是否继续把它当作 `Bug` 主线推进。
- 若后续再次出现相同或邻近签名：
  - 单独在 GitHub 上拆出 `Bug + Task`；
  - 不与旧 boot-time 问题混追。

## 原始日志（节选）

```text
[Wed Apr 15 14:36:20 2026] DMAR: DRHD: handling fault status reg 2
[Wed Apr 15 14:36:20 2026] DMAR: [DMA Read NO_PASID] Request device [01:00.0] fault addr 0xff0f0000 [fault reason 0x06] PTE Read access is not set
[Wed Apr 15 14:37:22 2026] nvme nvme0: I/O tag 16 (0010) QID 0 timeout, disable controller
[Wed Apr 15 14:37:22 2026] nvme 0000:01:00.0: probe with driver nvme failed with error -5
```

## 完整原始报错信息文件

- 正例日志：
  - [20260415-host-dmar-no-pasid-after-host-kill.log](raw/20260415-host-dmar-no-pasid-after-host-kill.log)
- 干净重跑但未复现同签名的对照日志：
  - [20260415-caseA-clean-rerun-summary.log](raw/20260415-caseA-clean-rerun-summary.log)
  - [20260415-caseA-clean-rerun-dmesg-after-restore.log](raw/20260415-caseA-clean-rerun-dmesg-after-restore.log)
  - [20260415-caseA-clean-rerun-crosvm-console.log](raw/20260415-caseA-clean-rerun-crosvm-console.log)
- `Case C: poweroff -f` 对照日志：
  - [20260415-caseC-poweroff-summary.log](raw/20260415-caseC-poweroff-summary.log)
  - [20260415-caseC-poweroff-dmesg-after-exit.log](raw/20260415-caseC-poweroff-dmesg-after-exit.log)
  - [20260415-caseC-poweroff-dmesg-after-restore.log](raw/20260415-caseC-poweroff-dmesg-after-restore.log)
  - [20260415-caseC-poweroff-crosvm-console.log](raw/20260415-caseC-poweroff-crosvm-console.log)
- 三 case × 10 轮矩阵汇总：
  - [20260415-t4a-case-matrix-3x10-summary.tsv](raw/20260415-t4a-case-matrix-3x10-summary.tsv)
  - [20260415-t4a-case-matrix-3x10-summary.json](raw/20260415-t4a-case-matrix-3x10-summary.json)
  - 完整 30 轮逐轮日志目录（本地）：
    - `/tmp/t4-matrix-20260415-151702`

## 触发条件/复现场景

- Host 内核：`pKVM-IA`
- VM 类型：protected pVM
- 透传设备：NVMe `0000:01:00.0`
- 触发动作：
  - guest 内运行 direct I/O 压测；
  - host 侧直接 `kill -9 crosvm`。
- 最小复现命令：

```bash
sudo -n env PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

## 触发路径（常见调用链）

```text
host kill -9 crosvm
    KVM / pKVM VM destroy 路径开始收尾
        pkvm_vm_destroy()                               (pKVM-IA/arch/x86/kvm/pkvm/pkvm.c)
            pkvm_vm_mmu_destroy()                       (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
                guest_mmu_free_leaf()
                    __pkvm_host_undonate_guest(...)
        kvm_arch_destroy_vm()
        kvm_destroy_devices()                           (pKVM-IA/virt/kvm/kvm_main.c)
            kvm_vfio_file_del() / kvm_vfio_release()   (pKVM-IA/virt/kvm/vfio.c)
                pkvm_detach_ptdev()                     (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c)
                    pkvm_iommu_sync()                   (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c)

设备 DMA 仍在飞行或 teardown 窗口内到达 IOMMU
    DMAR: [DMA Read NO_PASID] ... PTE Read access is not set
```

## 关联源码

- `pKVM-IA/arch/x86/kvm/pkvm/pkvm.c`
  - `pkvm_vm_destroy()`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - `pkvm_vm_mmu_destroy()`
  - `guest_mmu_free_leaf()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`
  - `pkvm_teardown_shadow_vm()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_detach_ptdev()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`
  - `pkvm_iommu_sync()`
- `pKVM-IA/virt/kvm/kvm_main.c`
  - `kvm_destroy_vm()`
- `pKVM-IA/virt/kvm/vfio.c`
  - `kvm_vfio_file_del()`
  - `kvm_vfio_release()`

## 备注

- 这条签名和 BOOT-012/BOOT-013 的 boot-time BAR MMIO 路径问题不是一类问题：
  - BOOT-012/013 属于建图阶段的 MMIO/BAR 语义问题；
  - BOOT-014 属于 teardown 阶段的 DMA 生命周期问题。
- 因为当前还没有稳定复现，所以暂不建议只凭它直接关闭现有 issue 或宣称 T4 已转为“代码修复中”；更合理的做法是继续把 `T4A` 跑稳。
- 经过 `Case A/B/C` 各 10 轮之后，当前可以进一步收紧表述：
  - 不建议再把“重复相同三类 case”本身当作最高优先级；
  - 更高价值的下一步是找出那次正例依赖的隐藏触发条件，再决定是否升级成 GitHub blocker。
