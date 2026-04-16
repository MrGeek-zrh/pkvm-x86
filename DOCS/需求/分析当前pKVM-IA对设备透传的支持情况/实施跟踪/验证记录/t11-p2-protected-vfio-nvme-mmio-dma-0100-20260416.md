# [T11-P2] 2026-04-16 protected pVM NVMe MMIO / DMA 路径实测（`0000:01:00.0`）

## 目的

在 2026-04-16 这轮 protected pVM 实机验证里，直接回答两个问题：

- guest 里对透传 NVMe BAR 的 MMIO，运行期到底是不是落在 direct 访问分支
- 设备对 pVM 内存的读写，在这轮 NVMe `dd` 数据路径里到底有没有走 DMA API / DMA map 路径

## 环境

- Host 内核：
  - `Linux ubuntu-vm 6.12.0-pkvm-ia #10 SMP PREEMPT_DYNAMIC Thu Apr 16 03:55:22 UTC 2026`
- Guest 内核：
  - `Linux localhost.localdomain 6.12.0+ x86_64`
- 透传设备：
  - `0000:01:00.0`
  - `Red Hat, Inc. QEMU NVM Express Controller [1b36:0010]`
- 启动入口：
  - `scripts/run-crosvm.sh`
- 原始输出目录：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p2-protected-vfio-nvme-mmio-dma-0100-20260416-114232/`

## 实际执行

### 1. Host 侧绑定 `vfio-pci` 并启动 host trace

执行前先确认 `0000:01:00.0` 不是 host 根盘，然后将该设备从 `nvme` 切到 `vfio-pci`。

原始日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p2-protected-vfio-nvme-mmio-dma-0100-20260416-114232/host-bind.log`

host trace helper：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p1-nvme-mmio-dma-trace-helper/host-trace.sh`

实际打开的 host 观测点：

- `pkvm_vm_ioctl_set_ptdev_mmio_metadata`
- `pkvm_vm_ioctl_enable_cap`
- `kvm_sev_es_mmio_read`
- `kvm_sev_es_mmio_write`

### 2. 启动 protected pVM 并登录 guest

启动命令：

```text
sudo -n env -u DEBUG PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

guest 内确认到：

```text
/dev/nvme0
/dev/nvme0n1
/sys/devices/pci0000:00/0000:00:05.0/0000:01:00.0/nvme/nvme0
```

说明 `0000:01:00.0` 已在 guest 内枚举为 `nvme0n1`。

### 3. guest 内先做可观测点勘探，再切到 `function_graph`

一开始准备直接复用 `guest-trace.sh` 的 kprobe 方案，但这轮 guest 构建里可见符号比预期更少：

- `nvme_map_data`
- `nvme_setup_prp_simple`
- `nvme_setup_sgl_simple`
- `dma_map_bvec`
- `nvme_write_sq_db`
- `pkvm_direct_mmio_write`
- `pkvm_direct_mmio_read`
- `mmio_write`

这些要么不在 guest `kallsyms`，要么不在 `available_filter_functions`，因此没法稳定用一套 kprobe / ftrace 直接命中。

原始勘探结果：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p2-protected-vfio-nvme-mmio-dma-0100-20260416-114232/guest-filter-discovery.txt`

因此本轮改用 `function_graph` 抓以下函数：

- `dma_map_sgtable`
- `pkvm_virt_mmio`
- `pkvm_mmio_read*`
- `pkvm_mmio_write*`
- `mmio_read`

这样仍然能把：

- NVMe 数据面是否触发 DMA map
- guest MMIO 访问是否至少到达 `pkvm_virt_mmio()`
- 是否继续落入 guest fallback `mmio_read()`

这三件事钉住。

### 4. guest 内执行 8 次 1 MiB 的直读窗口

guest root 脚本的核心数据窗口是：

```text
dd if=/dev/nvme0n1 of=/dev/null bs=1048576 count=8 iflag=direct status=none
```

这次选择 `1 MiB * 8` 的原因是：

- 比 `4 KiB` 小块更容易稳定落到 `dma_map_sgtable()` 路径
- trace 量仍然可控，方便保留 `function_graph` 证据

guest 侧原始摘录：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p2-protected-vfio-nvme-mmio-dma-0100-20260416-114232/guest-fgraph-summary.txt`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p2-protected-vfio-nvme-mmio-dma-0100-20260416-114232/guest-fgraph-trace-head.txt`

### 5. 停止 host trace

原始日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p2-protected-vfio-nvme-mmio-dma-0100-20260416-114232/host-trace/host-summary.txt`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p2-protected-vfio-nvme-mmio-dma-0100-20260416-114232/host-trace/host-trace.txt`

### 6. 关闭 guest 并恢复 host 设备绑定

恢复后 `0000:01:00.0` 已重新回到 `nvme` 驱动。

原始日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p2-protected-vfio-nvme-mmio-dma-0100-20260416-114232/host-restore.log`

## 关键现象

### guest 直读成功

guest `function_graph` 摘要里：

```text
DEV=/dev/nvme0n1
BS=1048576
COUNT=8
DD_RC=0
```

说明这轮透传 NVMe 的 `dd` 直读已经成功完成。

### guest 内明确观察到 DMA 映射链

guest 摘要计数：

```text
dma_map_sgtable=16
```

guest `function_graph` 节选：

```text
dma_map_sgtable() {
  __dma_map_sg_attrs() {
    dma_direct_map_sg() {
      swiotlb_map();
      ...
    }
  }
}
```

对应源码关系是：

```text
NVMe request path
    nvme_prep_rq()
        nvme_map_data()
            dma_map_sgtable()
                __dma_map_sg_attrs()
                    dma_direct_map_sg()
                        swiotlb_map()
```

这里的源码锚点分别在：

- `pKVM-IA/drivers/nvme/host/pci.c`
  - `nvme_map_data()` 里调用 `dma_map_sgtable()`
  - `nvme_prep_rq()` 调用 `nvme_map_data()`

因此，这轮 `dd if=/dev/nvme0n1 ...` 的数据面已经有直接运行时证据表明：

- 设备访问 pVM 内存不是“凭空直打某个 GPA/HPA”
- 而是经由 guest 内 NVMe 驱动的 DMA API 映射路径下发
- 当前具体落到 `dma_map_sgtable() -> __dma_map_sg_attrs() -> dma_direct_map_sg() -> swiotlb_map()`

### guest 内明确观察到 `pkvm_mmio_write* -> pkvm_virt_mmio()`

guest 摘要计数：

```text
pkvm_virt_mmio=12
pkvm_mmio_write=12
mmio_read=0
```

guest `function_graph` 节选：

```text
pkvm_mmio_writel() {
  pkvm_virt_mmio() {
    lookup_address() {
      lookup_address_in_pgd_attr();
    }
  }
}
```

同一窗口里还能看到 `pkvm_mmio_writew()` 的同类路径：

```text
pkvm_mmio_writew() {
  pkvm_virt_mmio() {
    lookup_address() {
      lookup_address_in_pgd_attr();
    }
  }
}
```

对应源码关系是：

```text
guest submit-side MMIO
    nvme_write_sq_db()
        writel(nvmeq->sq_tail, nvmeq->q_db)
            pkvm_mmio_writel()
                pkvm_virt_mmio()
                    allow-hit -> pkvm_direct_mmio_write()
                    fallback  -> mmio_write()
```

源码锚点：

- `pKVM-IA/drivers/nvme/host/pci.c` 的 `nvme_write_sq_db()`
- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c` 的 `pkvm_virt_mmio()`

### host 侧整个观测窗口没有出现 MMIO fallback

host 摘要：

```text
pkvmdma_host_sev_mmio_read=0
pkvmdma_host_sev_mmio_write=0
```

而 host 这边抓的正是 fallback 到 host 的最终可见点：

```text
guest mmio fallback
    PKVM_GHC_IOREAD / PKVM_GHC_IOWRITE
        handle_vmcall()
            return 0
            -> host side handles MMIO
                -> kvm_sev_es_mmio_read/write
```

因此，这轮窗口里至少可以确认：

- guest 确实执行了 `pkvm_mmio_write* -> pkvm_virt_mmio()`
- host 没有观测到任何 `kvm_sev_es_mmio_read/write`

结合 `pkvm_virt_mmio()` 的源码分支：

```text
pkvm_virt_mmio()
    if (pkvm_mmio_allow_hit(...))
        -> pkvm_direct_mmio_write/read()
    else
        -> mmio_write/read()
```

可以做出高置信推断：

- 这轮 NVMe 数据路径里看到的 BAR MMIO 访问没有走 host fallback
- 更符合 `pkvm_mmio_allow_hit()` 命中后的 direct 分支

## 源码对照

### MMIO direct / fallback 分流点

- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
  - `pkvm_virt_mmio()` 在 `pkvm_mmio_allow_hit()` 命中时走 `pkvm_direct_mmio_write/read()`
  - 未命中时走 `mmio_write/read()`

### NVMe 数据路径中的 DMA map 与 doorbell MMIO

- `pKVM-IA/drivers/nvme/host/pci.c`
  - `nvme_write_sq_db()` 通过 `writel()` 打 SQ doorbell
  - `nvme_map_data()` 里对一般多段请求调用 `dma_map_sgtable()`
  - `nvme_prep_rq()` 调用 `nvme_map_data()`
  - `nvme_queue_rq()` 调用 `nvme_prep_rq()` 并提交命令

### fallback 到 host 的处理点

- `pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c`
  - `PKVM_GHC_IOREAD`
  - `PKVM_GHC_IOWRITE`
  - 注释直接写明这类 MMIO hypercall “should be forwarded to the host”

## 结论

这轮 2026-04-16 的 protected pVM + `0000:01:00.0` 实测，可以给出下面两个结论：

- 对这次 `dd if=/dev/nvme0n1 of=/dev/null bs=1048576 count=8 iflag=direct` 的运行窗口，guest 已明确出现：
  - `dma_map_sgtable()`
  - `__dma_map_sg_attrs()`
  - `dma_direct_map_sg()`
  - `swiotlb_map()`
  这说明设备对 pVM 内存的数据面访问确实走了 DMA API / DMA 映射路径。
- 对同一窗口，guest 已明确出现：
  - `pkvm_mmio_writew()/pkvm_mmio_writel()`
  - `pkvm_virt_mmio()`
  而 host 侧 `kvm_sev_es_mmio_read/write` 全部为 `0`；结合 `pkvm_virt_mmio()` 的源码分支，可以高置信推断这轮 NVMe BAR MMIO 访问走的是 direct 路径，而不是 host fallback。

## 这轮结论的边界

也保留两点边界，避免过度外推：

- 这轮窗口主要抓到了 submit-side 的 MMIO write；没有单独抓到一个显式的 `pkvm_mmio_read*` 样本。
- 由于这版 guest 构建里 `pkvm_direct_mmio_write/read` 不在可直接观测的函数列表里，所以“direct”是依据
  - guest 端 `pkvm_virt_mmio()` 命中
  - host 端 `kvm_sev_es_mmio_* = 0`
  - guest 端 `mmio_read = 0`
  三组证据联合推断出来的，而不是直接抓到 `pkvm_direct_mmio_*` 符号本身。
