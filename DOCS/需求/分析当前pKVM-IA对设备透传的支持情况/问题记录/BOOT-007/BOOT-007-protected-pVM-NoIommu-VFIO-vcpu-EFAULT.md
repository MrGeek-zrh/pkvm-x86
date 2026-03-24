# [BOOT-007] protected pVM 在 NoIommu VFIO 透传下运行期触发 vCPU EFAULT

## 现象

- 使用 protected pVM + VFIO 透传 NVMe，且不向 guest 暴露虚拟 IOMMU 时，crosvm 可以走到 guest `bzImage` 加载完成，但随后在 vCPU 运行阶段失败：
  - `vcpu hit unknown error: Bad address (os error 14)`
  - `vcpu crashed`
- 同一轮启动中，crosvm 还会多次打印：
  - `Failed to map mmio page; failed to create vm mapping`
  - `Invalid argument (os error 22)`
- 当前 dmesg 中未再出现旧的 donate/refcount 阻塞签名：
  - `host_initiate_donation: page refcounted`
  - `do_donate failed ret=-16`
  - `pkvm: exception`
  - `pgtable_unmap_leaf` assertion

## 根因（简述）

- 当前已确认这不是 T1 对应的“旧 host shadow IOMMU spgt 残留 refcount 阻塞 donate”问题。
- 当前更高置信度的根因是：protected pVM 还不能消费 crosvm 这套 VFIO PCI 的 config/MMIO fallback 路径。
- 证据链如下：
  - crosvm 在 pKVM 场景下显式关闭 `ReadOnlyMemoryRegion`，见 `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/mod.rs`。
  - 因此 `PciRoot::add_mapping()` 为 PCIe config page 建立只读 memslot 的优化路径会失败，并退回 `vm-exit`，见 `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/pci_root.rs`。
  - x86_64 上 PCIe ECAM 本身就是一个 `mmio_bus` 设备，见 `/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs` 和 `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/pci_root.rs`。
  - pKVM x86 的 protected vCPU 缺页路径对 `RET_PF_EMULATE` 直接返回 `-EFAULT`，不走传统 MMIO emulation，见 `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/mmu/mmu.c`。
- 因而 `Failed to map mmio page; failed to create vm mapping` 不是单独的无害噪音，而是当前失败链的前置信号之一。

## 解决方案

- 当前无最终修复。
- 下一步定位方向：
  - 先补 protected pVM 的 VFIO config/MMIO 访问路径，使 guest 不再落入当前不支持的 MMIO emulation fallback。
  - 之后再回到 `pgstate_pgt` / runtime DMA mirror 主线，处理真正的 DMA 可见性问题。

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
- x86_64 PCIe config mmio 是 `mmio_bus` 设备：
  - `/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs`
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/pci_root.rs`
- crosvm vCPU 运行报错路径：
  - `/home/mrgeek/pkvm-x86/crosvm/src/crosvm/sys/linux/vcpu.rs`
  - 非 `EINTR/EAGAIN` 的错误会直接记为 `vcpu hit unknown error` 并退出。
- pKVM protected vCPU 不接受传统 MMIO emulation：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/mmu/mmu.c`
  - `pkvm_page_fault()` 中 `RET_PF_EMULATE -> -EFAULT`
- 已排除的旧路径：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`
  - T1 修复后，本轮未再出现 donate/refcount 旧签名。

## 备注

- `pkvm-debug: first-owner table full` 来源于调试追踪表容量打满，当前只应视作调试辅助告警，不应直接当作本问题根因。
