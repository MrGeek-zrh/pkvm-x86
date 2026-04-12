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

## 最新状态

- 在 2026-03-27 的后续带 patch 实机验证中，这条签名当前已暂不复现：
  - protected pVM 可启动到 Ubuntu login prompt
  - guest `dmesg` 已出现 `nvme nvme0: pci function 0000:01:00.0`
  - guest `readlink -f /sys/block/nvme0n1/device` 已指向 `0000:01:00.0`
  - guest `lsblk` 已看到透传盘 `nvme0n1`
  - guest 已完成 `/dev/nvme0n1` 整盘直接读取
  - guest 已完成向 `/dev/nvme0n1` 连续写入 1 GiB 零数据
  - guest 已完成 `mkfs.ext4 -F /dev/nvme0n1`
  - guest 关机退出后，host `dmesg` 仍未见新的 DMAR / IOMMU fault
  - host `dmesg` 全程未再出现：
    - `DMA Read NO_PASID`
    - `PTE Read access is not set`
- 当前判断：
  - T2/T3 这轮 patch 已经较高置信度解除 `BOOT-008` 的主签名
  - 当前 teardown 退出路径已完成一轮验证，仍建议再补一次重复启动回归
  - 2026-04-01 归档的强关联偶发问题 `BOOT-009` 已由 `B4` 独立修复：
    - 对应签名是 `pkvm: exception 14 @ copy_gpa__pkvm ... err code 0x2`
    - 对应内核提交：`b86cfd0230b9`
    - 因为签名不同，它作为独立 bug 关闭保留，不并回 `BOOT-008`
  - 若要把“文件系统级数据写入完整成功”作为硬证据，还需补一轮显式 mount 后的 NVMe 写入/回读

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
- 当前 blocker 已经前移到 T2/T3 主线，并且已完成一轮真实 patch 落地：
  - [02-P0-pgstate_pgt语义收敛为DMA-mirror.md](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/02-P0-pgstate_pgt语义收敛为DMA-mirror.md)
  - [03-P0-donate后同步runtime-DMA-mirror.md](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/03-P0-donate后同步runtime-DMA-mirror.md)
- 当前这轮 patch 已完成的关键动作：
  - T2：`pgstate_pgt` 注释与 free 路径已收敛为 DMA mirror 语义，protected VM 的 shadow teardown 不再执行 `__pkvm_host_undonate_guest()`
  - T3：`__pkvm_host_donate_guest()` 成功后已补一版 runtime DMA mirror 同步，并按 `pgstate_pgt->root_pa` 定向刷 IOTLB
  - 生命周期补强：`shadow_vm` teardown 顺序已调整为先 detach ptdev，再 deinit `pgstate_pgt`
- 当前状态已经从“等待真实修复”前移到“首轮修复后等待回归确认”：
  - 首轮带 patch 实机验证里，这条签名已不再复现
  - 当前已满足作为已修复历史 blocker 关闭保留的条件；后续重复启动与更强数据路径证据继续作为验证补全项维护

## 验证要点

- 继续使用同样的 `NoIommu` 命令重测时：
  - guest 仍应能稳定启动到 login prompt
  - guest 内应能看到 `nvme0n1`，且 sysfs 路径落到 `0000:01:00.0`
  - 原始块设备直接读取应成功
  - 原始块设备直接写入应成功
  - host dmesg 不应再出现：
    - `DMA Read NO_PASID`
    - `PTE Read access is not set`
- 持续确认 `BOOT-007` 的旧签名不再复现：
  - `Failed to map mmio page; failed to create vm mapping`
  - `vcpu hit unknown error: Bad address (os error 14)`
- 建议在关闭前再补：
  - 如需更强硬证据，再补一次显式 mount 后的 NVMe 写入/回读

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
- guest 补充验证终端记录：
  - [20260327-guest-nvme-dd-verify.log](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-008/raw/20260327-guest-nvme-dd-verify.log)

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

### 修复前的 DMA fault 路径细化

```text
scripts/run-crosvm.sh
    crosvm --vfio /sys/bus/pci/devices/0000:01:00.0
        host/hyp
            pkvm_attach_ptdev(...)                          (hyp/ptdev.c)
                ptdev->pgt = &vm->pgstate_pgt
                pkvm_iommu_sync(...)                        (hyp/iommu.c)
                    sync_shadow_id(...)                     (hyp/shadow_iommu.c)
                        sync_shadow_context_entry(...)      (hyp/shadow_iommu.c)
                            context_lm_set_slptr(..., ptdev->pgt->root_pa)
                            // 设备 DMA 的 second-level root 已切到 pgstate_pgt

        guest runtime page population
            kvm_mmu_page_fault(...)                         (arch/x86/kvm/mmu/mmu.c)
                pkvm_hypercall(vm_mmu_map, ...)             (arch/x86/kvm/pkvm/pkvm.c)
                    pkvm_vm_mmu_map(...)                    (arch/x86/kvm/pkvm/mmu.c)
                        guest_mmu_map_leaf(...)             (arch/x86/kvm/pkvm/mmu.c)
                            __pkvm_host_donate_guest(...)   (hyp/mem_protect.c)
                                do_donate(...)
                                    CPU 访问链建立
                                    // 修复前这条路径到这里结束
                                    // 只建立了 guest MMU / ownership 侧映射
                                    // 没有把新 GPA->HPA leaf 同步到 pgstate_pgt

        device DMA                                          [基于 NoIommu 语义和 DMAR 日志的推断]
            NVMe 发起 DMA Read (NO_PASID)
                Intel IOMMU walks ptdev->pgt == pgstate_pgt
                    pgstate_pgt 上该 GPA 对应的 runtime leaf 缺失 / stale
                    或 DMA 可见 leaf 的 read 权限没有正确准备好
                        host DMAR fault
                            [DMA Read NO_PASID]
                            [fault reason 0x06] PTE Read access is not set
```

### 加入方案后的 DMA 路径

```text
scripts/run-crosvm.sh
    crosvm --vfio /sys/bus/pci/devices/0000:01:00.0
        host/hyp
            pkvm_attach_ptdev(...)                          (hyp/ptdev.c)
                ptdev->pgt = &vm->pgstate_pgt
                pkvm_iommu_sync(...)                        (hyp/iommu.c)
                    sync_shadow_id(...)                     (hyp/shadow_iommu.c)
                        sync_shadow_context_entry(...)      (hyp/shadow_iommu.c)
                            context_lm_set_slptr(..., ptdev->pgt->root_pa)
                            // 设备 DMA 的 second-level root 仍然指向 pgstate_pgt

        guest runtime page population
            kvm_mmu_page_fault(...)                         (arch/x86/kvm/mmu/mmu.c)
                pkvm_hypercall(vm_mmu_map, ...)             (arch/x86/kvm/pkvm/pkvm.c)
                    pkvm_vm_mmu_map(...)                    (arch/x86/kvm/pkvm/mmu.c)
                        guest_mmu_map_leaf(...)             (arch/x86/kvm/pkvm/mmu.c)
                            __pkvm_host_donate_guest(...)   (hyp/mem_protect.c)
                                do_donate(...)
                                    CPU 访问链建立
                                pkvm_shadow_vm_sync_dma_mirror(...)
                                    pkvm_pgtable_sync_map_range(guest_pgt,
                                                                &vm->pgstate_pgt,
                                                                gpa, size, ...)
                                        pkvm_pgstate_pgt_map_leaf(...)
                                            strip PKVM_PAGE_STATE_PROT_MASK
                                            建立 DMA-visible GPA->HPA leaf
                                pkvm_iommu_flush_iotlb(&vm->pgstate_pgt, gpa, size)

        device DMA                                          [基于 NoIommu 语义和 DMAR 日志的推断]
            NVMe 发起 DMA Read (NO_PASID)
                Intel IOMMU walks ptdev->pgt == pgstate_pgt
                    这次 pgstate_pgt 已经有对应的 fresh runtime leaf
                    DMA 可见 read 权限来自刚同步进去的 mirror leaf
                        DMA 访问成功
                        host 不再报 PTE Read access is not set
```

### NoIommu 模式下 DMA 路径的特殊性

- guest 不暴露虚拟 IOMMU，设备直接使用 pasid=0 (NO_PASID)
- 设备 DMA 地址直接经过 ptdev->pgt (即 pgstate_pgt) 翻译
- 因此 pgstate_pgt 必须包含设备 DMA 可能访问的所有 GPA 范围的正确映射

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
- [shadow_iommu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c)
  - `sync_shadow_context_entry()` 在 legacy mode 下设置 shadow context entry 的 SLPTR 指向 `ptdev->pgt`
  - `sync_shadow_pgt()` 用于同步 shadow IOMMU second-level page table
  - `shadow_pgt_map_leaf()` 维护 shadow IOMMU 页表映射的 HPA refcount
- [mmu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
  - `guest_mmu_map_leaf()` 是 protected VM donate 的天然 runtime hook 点
- [ept.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c)
  - `pgstate_pgt` 当前仍带有 teardown undonate 语义，和纯 DMA mirror 目标不一致
- [iommu_internal.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu_internal.h)
  - `context_lm_set_slptr()` 设置 context entry 的 second-level page table pointer

## 备注

- 当前这条签名是在“旧 `BOOT-007` 签名已经不再复现”的前提下出现的，因此必须单独记录为新问题，而不是继续覆盖 `BOOT-007` 的历史语义。
