# [T10-P6] 2026-04-15 protected pVM NVMe 直通复测（`0000:01:00.0`）

## 目的

在安装并重启到包含当前 B5-2 Guest EPT 边界改动的 Host 内核后，重新验证这条样例：

- protected pVM 是否还能正常启动到 `login:`
- passthrough NVMe 的 MMIO 是否已经不再落到 host `IOREAD/IOWRITE` fallback
- guest 内对透传盘的 `dd` 直读是否正常

## 环境

- Host 内核：
  - `Linux ubuntu-vm 6.12.0-pkvm-ia #8 SMP PREEMPT_DYNAMIC Wed Apr 15 09:37:32 UTC 2026`
- 设备：
  - `0000:01:00.0`
  - BAR0：`0xfe800000`，`size=16K`
- 启动入口：
  - `scripts/run-crosvm.sh`

## 实际执行

### 1. 绑定 `vfio-pci` 并打开 host fallback 计数

原始日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-bind-and-host-trace-setup-0100-20260415-104859.log`

执行内容包括：

- 将 `0000:01:00.0` 从 `nvme` 切到 `vfio-pci`
- 在 host `tracefs` 上对以下符号打 `kprobe`
  - `kvm_sev_es_mmio_read`
  - `kvm_sev_es_mmio_write`

### 2. 启动 protected pVM

原始串口/PTTY 日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-crosvm-protected-vfio-direct-mmio-dd-0100-20260415-104859.pty.log`

实际启动命令：

```text
sudo -n env -u DEBUG PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

### 3. 抓取 host dmesg 与 host fallback 计数

原始日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-host-dmesg-protected-vfio-direct-mmio-dd-0100-20260415-104859.log`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-host-trace-counts-protected-vfio-direct-mmio-dd-0100-20260415-104859.log`

### 4. 恢复 host 设备绑定

恢复日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-restore-0100-to-nvme-20260415-104859.log`

## 关键现象

### crosvm 侧

protected pVM 没有到达 `login:`，而是在 guest 用户态起来前直接退出：

```text
[2026-04-15T10:50:32.365903391+00:00 ERROR crosvm::crosvm::sys::linux::vcpu] vcpu hit unknown error: Bad address (os error 14)
[2026-04-15T10:50:32.366184594+00:00 INFO  crosvm::crosvm::sys::linux] vcpu crashed
```

### host dmesg 侧

最关键的新签名不是旧的 `vm_mmu_map failed`，而是：

```text
WARNING: CPU: 18 PID: 4255 at arch/x86/kvm/mmu/mmu.c:4775 kvm_tdp_page_fault+0x3f0/0x420
```

回溯里可以看到：

```text
kvm_tdp_page_fault
  -> pkvm_page_fault
     -> pkvm_pin_page
```

### host fallback 计数

本轮失败启动里，host 侧 `IOREAD/IOWRITE` fallback 计数仍然很多：

```text
HOST_SEV_MMIO_R=279
HOST_SEV_MMIO_W=2885
```

## 结合源码的归因

`pKVM-IA/arch/x86/kvm/mmu/mmu.c`：

```text
pkvm_page_fault()
    -> pkvm_hypercall(vm_mmu_map, ...)
    -> if (!r && pkvm_is_protected_vcpu(vcpu))
           pkvm_pin_page(vcpu->kvm, fault)
```

对应源码位置：

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c:4836`
- `pKVM-IA/arch/x86/kvm/mmu/mmu.c:4841`

而 `pkvm_pin_page()` 内部会把 `fault->pfn` 转成 refcounted `struct page`：

```text
page = kvm_pfn_to_refcounted_page(fault->pfn);
if (WARN_ON_ONCE(!page))
    return -EFAULT;
```

对应源码位置：

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c:4774`
- `pKVM-IA/arch/x86/kvm/mmu/mmu.c:4775`

这和本轮 B5-2 改动后的新语义正好冲突：

- hyp 侧 `vm_mmu_map()` 现在已经允许“命中 attached BAR 的 HPA”直接装 Guest EPT leaf
- 但 host-high 的 `pkvm_page_fault()` 仍然沿用“成功建图后一定要 pin 一页普通 RAM”的旧假设
- 对 BAR/MMIO PFN 来说，`kvm_pfn_to_refcounted_page()` 不会返回普通 `struct page`
- 于是 `pkvm_pin_page()` 直接 `WARN + -EFAULT`
- 最终用户态看到的还是 `Bad address (os error 14)`

## 结论

这轮复测没有进入 guest `login:`，因此：

- 还不能继续做 guest 内 `dd if=/dev/nvme0n1 of=/dev/null ...`
- 也还不能证明“当前 NVMe MMIO 已经稳定走 direct path”

但它已经把主阻塞继续前移并钉死成一条新的、更具体的路径：

- `BOOT-012` 那条“BAR HPA 误入 donate”路径本轮没有再出现
- 当前新的前置阻塞是：`pkvm_page_fault()` 在 BAR direct map 成功后仍然无条件 `pkvm_pin_page()`

换句话说，当前 B5-2 实现已经打通了“hyp 侧不再 donate BAR HPA”这一段，但 host-high 侧还缺一段与之配套的收口：

- 对 direct BAR / MMIO PFN，不能再走普通 RAM pin 语义
- 需要显式跳过 `pkvm_pin_page()`，或引入等价的 MMIO 专用处理

## 本轮状态

- protected pVM 启动：失败
- guest 登录：未达到
- guest `dd`：未执行
- MMIO direct 成功性：本轮无法给出正向结论
- 新 blocker：`pkvm_pin_page()` 误对 BAR/MMIO PFN 执行 refcounted page pin
