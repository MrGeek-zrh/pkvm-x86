# [BOOT-007] protected pVM 在 NoIommu VFIO 透传下运行期触发 vCPU EFAULT

## 现象

- 使用 protected pVM + VFIO 透传 NVMe，且不向 guest 暴露虚拟 IOMMU 时，crosvm 可以走到 guest `bzImage` 加载完成，但随后在 vCPU 运行阶段失败：
  - `vcpu hit unknown error: Bad address (os error 14)`
  - `vcpu crashed`
- 在第一轮 `ptdev MMIO metadata` / guest allowlist 实现后，2026-03-24 的端到端验证中，上述 `EFAULT` 签名仍然复现。
- 当前同一轮启动中，crosvm 仍会打印：
  - `Failed to map mmio page; failed to create vm mapping`
  - `Invalid argument (os error 22)`
- 相比 2026-03-23 的旧结果，`Failed to map mmio page` 已从多次下降到 1 次，但 `vcpu hit unknown error: Bad address (os error 14)` 仍未消失。
- 当前 dmesg 中未再出现旧的 donate/refcount 阻塞签名：
  - `host_initiate_donation: page refcounted`
  - `do_donate failed ret=-16`
  - `pkvm: exception`
  - `pgtable_unmap_leaf` assertion

## 根因（简述）

- 当前已确认这不是 T1 对应的“旧 host shadow IOMMU spgt 残留 refcount 阻塞 donate”问题。
- 当前更高置信度的根因仍然是：在当前分支里，protected pVM 设备透传本身尚未被真正支持。
- 截至 2026-03-24，第一轮 `ptdev MMIO metadata -> guest allowlist` 实现已经接入 host / hyp / guest / crosvm，但运行签名仍然没有变化，这说明当前剩余 blocker 仍然位于“会触发 `RET_PF_EMULATE` 的 MMIO 路径”，而不是普通 BAR 直达白名单本身。
- 证据链如下：
  - crosvm 的通用能力判断本意上会在 pKVM 场景下关闭 `ReadOnlyMemoryRegion`，见 `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/mod.rs`。
  - 但当前 x86_64 `is_pkvm()` 仍然硬编码返回 `false`，见 `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs`。
  - 因而当前本地 crosvm 仍会误以为只读 memslot 可用，在 `PciRoot::add_mapping()` 中尝试 config page 的只读映射，并在 `add_memory_region()` 处落到 `EINVAL` 后退回 `vm-exit`，见 `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/pci_root.rs`。
  - 第一轮实现已经把 PCIe ECAM 的公开条件收敛为 `!components.hv_cfg.protection_type.isolates_memory()`，见 `/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs`；这与 `Failed to map mmio page` 次数下降相符，但并未解除最终 `EFAULT`。
  - 当前 x86_64 仍会无条件注册 `PciVirtualConfigMmio`，并无条件在 ACPI 中公开 `VCFG` 基址，见 `/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs`。
  - VFIO PCI 设备当前仍会生成 virtual config 相关 AML / shared-memory 资源，见 `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs`。
  - pKVM x86 的 protected vCPU 缺页路径对 `RET_PF_EMULATE` 直接返回 `-EFAULT`，不走传统 MMIO emulation，见 `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/mmu/mmu.c`。
  - 本地第一轮实现已经让普通 BAR 子区间可以通过 `SET_PTDEV_MMIO_METADATA -> sync_ptdev_mmio_metadata -> guest allowlist` 进入 `pkvm_virt_mmio()` 的直达分流，见 `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`、`/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`、`/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c` 与 `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs`。
  - 因而截至本轮，更可疑的残余路径已经收敛到“仍未被 allowlist 覆盖、且会触发 MMIO emulation 的 config / virtual-config 路径”。
  - 这与官方 issue `#46` 的维护者说明一致：当前 pVM 对任何 MMIO 访问都默认使用 hypercall，因而无法直接访问直通设备的物理 MMIO。
- 因而 `Failed to map mmio page; failed to create vm mapping` 不是单独的无害噪音，而只是当前能力缺口暴露出来的早期症状之一。

## 解决方案

- 当前无最终修复。
- 下一步定位方向：
  - 优先继续收敛并绕开 protected VM 下残余的 config / virtual-config MMIO 路径：
    - `PciVirtualConfigMmio`
    - ACPI `VCFG`
    - VFIO device virtual config AML / shared-memory path
  - 当前不建议为此新开 bug issue，因为运行期退出签名仍然是同一个：`vcpu hit unknown error: Bad address (os error 14)`。
  - 如果后续出现新的独立签名，例如 host panic / assertion / metadata 提交失败 / 非 `EFAULT` 的 `KVM_RUN` 退出，再新开 issue。
  - 在该前置 MMIO 路径没有收敛前，`pgstate_pgt` / runtime DMA mirror 仍不是最前置 blocker。

## 验证要点

- 使用同样的 `NoIommu` 启动命令重测时：
  - 不应再出现 `vcpu hit unknown error: Bad address (os error 14)`。
  - 若 `Failed to map mmio page` 仍然存在，需要确认它不再把 config 访问推回当前不受支持的 fallback。
- 持续确认旧 T1 签名仍不复现：
  - `host_initiate_donation: page refcounted`
  - `do_donate failed ret=-16`
  - `pkvm: exception`

## 原始日志（节选）

```text
sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
run-crosvm: enabling VFIO passthrough: 0000:01:00.0 (no virtual iommu, mapping all guest ram)
...
[2026-03-23T17:17:22.199991096+00:00 ERROR devices::pci::pci_root] Failed to map mmio page; failed to create vm mapping

Caused by:
    Invalid argument (os error 22)
...
[2026-03-23T17:17:22.215543565+00:00 INFO  x86_64] Loaded bzImage kernel
...
[2026-03-23T17:17:40.987122107+00:00 ERROR crosvm::crosvm::sys::linux::vcpu] vcpu hit unknown error: Bad address (os error 14)
[2026-03-23T17:17:40.989008124+00:00 INFO  crosvm::crosvm::sys::linux] vcpu crashed
[2026-03-23T17:17:40.989096382+00:00 ERROR crosvm::crosvm::sys::linux::vcpu] failed to send VcpuControl: sending on a closed channel
[2026-03-23T17:17:41.335113596+00:00 INFO  crosvm] exiting with success

[   74.044384] VFIO - User Level meta-driver version: 0.3
[   77.098199] pkvm-debug: first-owner table full; suppressing further overflow logs
[  125.788273] clocksource: Long readout interval, skipping watchdog check: cs_nsec: 5949682920 wd_nsec: 5949682949
```

```text
sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
run-crosvm: enabling VFIO passthrough: 0000:01:00.0 (no virtual iommu, mapping all guest ram)
...
[2026-03-24T17:34:12.461662011+00:00 ERROR devices::pci::pci_root] Failed to map mmio page; failed to create vm mapping

Caused by:
    Invalid argument (os error 22)
...
[2026-03-24T17:34:12.475671285+00:00 INFO  x86_64] Loaded bzImage kernel
...
[2026-03-24T17:34:31.202794640+00:00 ERROR crosvm::crosvm::sys::linux::vcpu] vcpu hit unknown error: Bad address (os error 14)
[2026-03-24T17:34:31.203953250+00:00 INFO  crosvm::crosvm::sys::linux] vcpu crashed
[2026-03-24T17:34:31.204047220+00:00 ERROR crosvm::crosvm::sys::linux::vcpu] failed to send VcpuControl: sending on a closed channel
[2026-03-24T17:34:31.546533564+00:00 INFO  crosvm] exiting with success

[  130.761759] pkvm-debug: first-owner table full; suppressing further overflow logs
[  146.532420] clocksource: Long readout interval, skipping watchdog check: cs_nsec: 5568468153 wd_nsec: 5568468162
[  177.695909] sched: DL replenish lagged too much
```

## 完整原始报错信息文件

- 2026-03-23 crosvm 完整输出：
  - [20260323-crosvm-noiommu.log](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-007/raw/20260323-crosvm-noiommu.log)
- 2026-03-23 dmesg 原始节选：
  - [20260323-dmesg-tail.log](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-007/raw/20260323-dmesg-tail.log)
- 2026-03-24 crosvm 完整输出：
  - [20260324-crosvm-noiommu.log](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-007/raw/20260324-crosvm-noiommu.log)
- 2026-03-24 dmesg 原始节选：
  - [20260324-dmesg-tail.log](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-007/raw/20260324-dmesg-tail.log)
- 另有自动化脚本保存的 2026-03-23 原始日志目录：
  - [BOOT-005/logs/20260323-170501](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-005/logs/20260323-170501)

## 触发条件/复现场景

- Host 内核：`pKVM-IA`
- VM 类型：protected pVM
- 透传设备：NVMe `0000:01:00.0`
- guest 不暴露虚拟 IOMMU，使用 `NoIommu` 路径
- 最小复现命令：

```bash
sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

## 触发路径（常见回溯）

```text
scripts/run-crosvm.sh
    crosvm --vfio /sys/bus/pci/devices/0000:01:00.0
        create_vfio_device(...)
            IommuDevType::NoIommu
                vfio_dma_map(整段 guest RAM)
        PciRoot::add_mapping(...)
            add_memory_region(...)
                failed to create vm mapping   (EINVAL, 非致命回退路径)
        Loaded bzImage kernel
        run_vcpu(...)
            vcpu.run()
                Bad address (os error 14)
```

## 影响

- 当前 `NoIommu` 主线下，protected pVM 的 VFIO 透传仍无法完成端到端启动验证。
- 该问题已经成为 T1 之后的最新主阻塞项。

## 环境信息（来自日志）

- 时间：`2026-03-23`
- crosvm 关键模式：
  - `PROTECTED=1`
  - `SETUP_NET=0`
  - `VFIO_DEV=0000:01:00.0`
  - `VFIO_IOMMU` 未设置

## 线索

- crosvm 只读 MMIO 映射失败路径：
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/pci_root.rs`
  - `PciRoot::add_mapping()` 中对 `mapper.add_mapping()` 的错误只打印日志并回退到 vm-exit 处理。
- crosvm 在 pKVM 下不支持只读 memslot：
  - `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/mod.rs`
  - `VmCap::ReadOnlyMemoryRegion => !self.is_pkvm()`
  - 但当前 x86_64 `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs` 中 `is_pkvm()` 仍然直接返回 `false`，因此这是“设计上应禁用，但当前实现里被误报为可用”的 correctness 问题。
- x86_64 PCIe config mmio / virtual config 仍是核心嫌疑路径：
  - `/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs`
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/pci_root.rs`
- 当前 ECAM 公开已经按 protected VM 做了条件收敛，但 `PciVirtualConfigMmio` 与 ACPI `VCFG` 仍是无条件注册/公开：
  - `/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs`
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs`
- crosvm vCPU 运行报错路径：
  - `/home/mrgeek/pkvm-x86/crosvm/src/crosvm/sys/linux/vcpu.rs`
  - 非 `EINTR/EAGAIN` 的错误会直接记为 `vcpu hit unknown error` 并退出。
- pKVM protected vCPU 不接受传统 MMIO emulation：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/mmu/mmu.c`
  - `pkvm_page_fault()` 中 `RET_PF_EMULATE -> -EFAULT`
- host->pKVM 透传 attach 接口缺少设备资源元数据：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - 目前只传 `BDF/PASID`，未传 BAR/MMIO 范围
- 已排除的旧路径：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`
  - T1 修复后，本轮未再出现 donate/refcount 旧签名。

## 备注

- `pkvm-debug: first-owner table full` 来源于调试追踪表容量打满，当前只应视作调试辅助告警，不应直接当作本问题根因。
