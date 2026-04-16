# [T11-P1] protected pVM NVMe MMIO / DMA 抓取助手

## 目的

把“guest 里透传 NVMe 的 BAR MMIO 到底是不是直通访问”以及“设备访问 pVM 内存时是否走 DMA 路径”拆成两类可重复证据：

- guest 侧：
  - `nvme_map_data` / `dma_map_bvec` / `dma_map_sgtable`
  - `nvme_write_sq_db`
  - `pkvm_direct_mmio_*`
  - `mmio_*`
- host 侧：
  - `pkvm_vm_ioctl_set_ptdev_mmio_metadata`
  - `pkvm_sync_ptdev_mmio_metadata`
  - `kvm_sev_es_mmio_read`
  - `kvm_sev_es_mmio_write`

## 结论判据

### 1. guest 对 NVMe BAR 的 MMIO 是否 direct

看 guest 脚本输出的这两组计数：

- `pkvmdma_guest_direct_mmio_write`
- `pkvmdma_guest_direct_mmio_read`
- `pkvmdma_guest_fallback_mmio_write`
- `pkvmdma_guest_fallback_mmio_read`

若在 `dd` 观测窗口内：

- direct 计数明显大于 `0`
- fallback 计数为 `0` 或极低且与本次 `dd` 无直接对应

则可判定这轮 `dd` 触发的 NVMe BAR MMIO **命中了 guest direct 分支**。

对应源码：

- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c:168`
- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c:181`
- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c:185`

### 2. 设备访问 pVM 内存是否走 DMA 路径

这里要区分“CPU 函数调用证据”和“真实 PCIe 事务”：

- 真正的设备读写内存是 IOMMU/PCIe 硬件事务，不会每次都进入一个 CPU 函数。
- 因此我们抓的是 **DMA 建图与提交链**，而不是“每个 DMA beat 的软件调用”。

若在 guest `dd` 窗口内看到：

- `nvme_map_data`
- `dma_map_bvec` 或 `dma_map_sgtable`
- 随后 `nvme_write_sq_db`

则说明这次 I/O 的数据 buffer 已经由 DMA API 建好设备可见地址，再由 doorbell 提交给设备，属于 **标准 NVMe DMA 提交路径**。

对应源码：

- `pKVM-IA/drivers/nvme/host/pci.c:769`
- `pKVM-IA/drivers/nvme/host/pci.c:802`
- `pKVM-IA/drivers/nvme/host/pci.c:838`
- `pKVM-IA/drivers/nvme/host/pci.c:876`
- `pKVM-IA/drivers/nvme/host/pci.c:471`

### 3. host fallback 是否仍被打到

看 host 脚本输出：

- `pkvmdma_host_sev_mmio_read`
- `pkvmdma_host_sev_mmio_write`

若这两个计数在你只做 guest `dd` 的窗口里明显增长，说明 guest 仍有一部分 MMIO 走到了 host fallback。

对应源码：

- `pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c:5219`
- `pKVM-IA/arch/x86/kvm/x86.c:10085`

## 证据链

```text
guest dd
    -> nvme_queue_rq()
        -> nvme_prep_rq()
            -> nvme_map_data()
                -> dma_map_bvec() / dma_map_sgtable()
        -> nvme_write_sq_db()
            -> writel()
                -> pkvm_virt_mmio()
                    -> pkvm_direct_mmio_write()   [direct]
                    -> mmio_write()               [fallback -> PKVM_GHC_IOWRITE]
```

## 文件

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p1-nvme-mmio-dma-trace-helper/host-trace.sh`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p1-nvme-mmio-dma-trace-helper/guest-trace.sh`

## 用法

### Host

启动观测：

```bash
sudo bash host-trace.sh start --out-dir /tmp/t11-host
```

在 host 上启动 pVM，进入 guest 后跑 guest 脚本。

停止并汇总：

```bash
sudo bash host-trace.sh stop --out-dir /tmp/t11-host
```

### Guest

在 guest 中执行：

```bash
sudo bash guest-trace.sh --dev /dev/nvme0n1 --count 64 --bs 4096 --out-dir /tmp/t11-guest
```

## 输出

### Host

- `host-trace.txt`
- `host-summary.txt`
- `host-dmesg.txt`

### Guest

- `guest-trace.txt`
- `guest-summary.txt`
- `guest-dd.log`

## 备注

- 这套助手默认尽量只用 `tracefs + kprobe_events`，避免依赖 `bpftrace`。
- `guest-trace.sh` 默认使用 `set_event_pid` 把窗口缩到本次 `dd` 的提交线程，减少后台噪声。
- 由于 NVMe completion 和部分回调可能在中断/软中断上下文发生，`CQ doorbell` 一类事件不一定完整进入本次 PID 过滤窗口；这不影响判断 **SQ 提交、direct MMIO 与 DMA 建图**。
