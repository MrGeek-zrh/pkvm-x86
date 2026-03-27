# [BOOT-008] protected pVM 在 NoIommu VFIO 透传下触发 host DMAR DMA Read NO_PASID / PTE Read access is not set

## 现象

- 在 2026-03-27 的有效复现中，protected pVM + VFIO(`NoIommu`) 已不再复现 `BOOT-007` 的旧签名：
  - crosvm 不再打印 `Failed to map mmio page; failed to create vm mapping`
  - crosvm 不再打印 `vcpu hit unknown error: Bad address (os error 14)`
  - guest 已经可以启动到 Ubuntu login prompt
- 但 host dmesg 出现了新的独立签名：

```text
[Fri Mar 27 06:21:01 2026] DMAR: DRHD: handling fault status reg 2
[Fri Mar 27 06:21:01 2026] DMAR: [DMA Read NO_PASID] Request device [01:00.0] fault addr 0x105cff000 [fault reason 0x06] PTE Read access is not set
[Fri Mar 27 06:34:31 2026] DMAR: DRHD: handling fault status reg 2
[Fri Mar 27 06:34:31 2026] DMAR: [DMA Read NO_PASID] Request device [01:00.0] fault addr 0x106313000 [fault reason 0x06] PTE Read access is not set
```

- 当前最小影响：
  - guest CPU 启动链已经打通
  - 但透传 NVMe `0000:01:00.0` 的 DMA 访问仍然落在 host IOMMU fault，上层功能还不能视作“设备透传已正确可用”

## 根因（简述）

- 这已经不是 `BOOT-007` 的 MMIO emulation / virtual-config 路径问题，而是新的 DMA/IOMMU 映射签名。
- 当前更合理的判断是：设备已经被 attach 到 protected VM，且 guest CPU 访问链已经足以启动；但供 IOMMU 使用的 `pgstate_pgt` 仍没有稳定成为“正确的 DMA mirror”。
- 直接源码证据：
  - [ptdev.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c)
    - `pkvm_attach_ptdev()` 会把 `ptdev->pgt` 切到 `&vm->pgstate_pgt`
    - 然后调用 `pkvm_iommu_sync()` 让设备对应的 IOMMU context / SLPTR 生效
  - [pkvm_hyp_types.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h)
    - `pkvm_shadow_vm.pgstate_pgt` 的注释已经把它定义成 protected VM passthrough device 使用的 IOMMU second-level page table
  - [mmu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
    - `guest_mmu_map_leaf()` 在 protected VM 下会走 `__pkvm_host_donate_guest()`
    - 但当前这条 donate 成功路径并没有同步把 runtime GPA->HPA leaf 写入 `pgstate_pgt`
  - [ept.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c)
    - `pkvm_pgstate_pgt_free_leaf()` 仍然带有 undonate 语义，说明 `pgstate_pgt` 语义本身还没有完全从 page-state 路径里剥离出来
- 因此，当前更像是：
  - CPU 侧 guest 映射已经足够让系统启动
  - 但设备 DMA 侧仍在走 `ptdev->pgt == pgstate_pgt` 这条 IOMMU 翻译路径
  - 而 `pgstate_pgt` 上缺少对应 leaf，或 leaf 权限未正确派生，最终在 host IOMMU 报出 `PTE Read access is not set`
- 上述最后一条是基于 dmesg 和源码的推断，不是内核已经打印出来的显式结论。

## 解决方案

- 当前不应再把这个现象继续混记到 `BOOT-007`。
- 当前 blocker 已经前移到 T2/T3 主线：
  - [02-P0-pgstate_pgt语义收敛为DMA-mirror.md](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/02-P0-pgstate_pgt语义收敛为DMA-mirror.md)
  - [03-P0-donate后同步runtime-DMA-mirror.md](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/03-P0-donate后同步runtime-DMA-mirror.md)
- 当前优先方向：
  - T2：把 `pgstate_pgt` 语义真正收敛成 DMA mirror，而不是继续混用 page-state / undonate 语义
  - T3：在 protected VM donate 成功后，把新 leaf 同步写入 `pgstate_pgt`，并对刷新的 `root_pa` 做 IOTLB flush
- 在还没有开始真实修复前，这里只记录现象和根因收敛；等进入修复阶段，再补对应 `Task` 的方案摘要和 GitHub 关联。

## 验证要点

- 继续使用同样的 `NoIommu` 命令重测时：
  - guest 仍应能稳定启动到 login prompt
  - host dmesg 不应再出现：
    - `DMA Read NO_PASID`
    - `PTE Read access is not set`
- 持续确认 `BOOT-007` 的旧签名不再复现：
  - `Failed to map mmio page; failed to create vm mapping`
  - `vcpu hit unknown error: Bad address (os error 14)`

## 原始日志（节选）

```text
[Fri Mar 27 06:21:01 2026] DMAR: DRHD: handling fault status reg 2
[Fri Mar 27 06:21:01 2026] DMAR: [DMA Read NO_PASID] Request device [01:00.0] fault addr 0x105cff000 [fault reason 0x06] PTE Read access is not set
[Fri Mar 27 06:34:31 2026] DMAR: DRHD: handling fault status reg 2
[Fri Mar 27 06:34:31 2026] DMAR: [DMA Read NO_PASID] Request device [01:00.0] fault addr 0x106313000 [fault reason 0x06] PTE Read access is not set
```

## 完整原始报错信息文件

- host dmesg 原始节选：
  - [20260327-host-dmar-fault.log](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-008/raw/20260327-host-dmar-fault.log)

## 触发条件/复现场景

- Host 内核：`pKVM-IA`
- VM 类型：protected pVM
- 透传设备：NVMe `0000:01:00.0`
- guest 不暴露虚拟 IOMMU，使用 `NoIommu` 路径
- 当前有效复现前提：
  - 设备已绑定 `vfio-pci`
  - crosvm 已包含 2026-03-27 前的 `is_pkvm()` / protected VM virtual-config 路径收敛改动
- 最小复现命令：

```bash
sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

## 触发路径（常见回溯）

```text
scripts/run-crosvm.sh
    crosvm --vfio /sys/bus/pci/devices/0000:01:00.0
        host/hyp
            pkvm_attach_ptdev(...)                          (hyp/ptdev.c)
                ptdev->pgt = &vm->pgstate_pgt
                pkvm_iommu_sync(...)                        (hyp/iommu.c)
        guest runtime page population
            guest_mmu_map_leaf(...)                         (pkvm/mmu.c)
                __pkvm_host_donate_guest(...)
                    CPU 访问链建立
        device DMA
            IOMMU walks ptdev->pgt == pgstate_pgt
                missing or stale read permission
                    host DMAR fault: PTE Read access is not set
```

## 影响

- protected pVM + VFIO(`NoIommu`) 的 guest 启动链已经明显前移，不再被 `BOOT-007` 阻塞。
- 但设备 DMA 仍未正确打通，因此当前主阻塞已经转移到 DMA mirror / IOMMU 映射路径。

## 环境信息（来自日志）

- 时间：`2026-03-27`
- crosvm 关键模式：
  - `PROTECTED=1`
  - `SETUP_NET=0`
  - `VFIO_DEV=0000:01:00.0`
  - `VFIO_IOMMU` 未设置

## 线索

- [ptdev.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c)
  - `pkvm_attach_ptdev()` 会把 IOMMU second-level root 切到 `vm->pgstate_pgt`
- [iommu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c)
  - `pkvm_iommu_sync()` 负责把新的 `ptdev->pgt->root_pa` 同步到 IOMMU context / PASID entry
- [mmu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
  - `guest_mmu_map_leaf()` 是 protected VM donate 的天然 runtime hook 点
- [ept.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c)
  - `pgstate_pgt` 当前仍带有 teardown undonate 语义，和纯 DMA mirror 目标不一致

## 备注

- 当前这条签名是在“旧 `BOOT-007` 签名已经不再复现”的前提下出现的，因此必须单独记录为新问题，而不是继续覆盖 `BOOT-007` 的历史语义。
