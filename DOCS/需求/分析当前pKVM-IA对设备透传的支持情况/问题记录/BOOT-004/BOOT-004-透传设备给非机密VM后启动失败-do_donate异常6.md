# [BOOT-004] 透传设备给非机密 VM（PROTECTED=0）后启动失败：pkvm exception 6 @ do_donate__pkvm

## 现象

- 在 L1 pKVM 环境中，将 PCI 设备 `0000:01:00.0` 绑定到 `vfio-pci` 并通过 crosvm 透传后，启动非机密 VM（`PROTECTED=0`）失败。
- L1 内核 `dmesg` 出现：
  - `pkvm: exception 6 on CPU2 @ip do_donate__pkvm+0x332/0x380`
  - 随后出现 `watchdog: BUG: soft lockup`，系统进入卡死/不可用状态。
- crosvm 侧同时出现 VFIO 子进程异常退出与大量 `tube was disconnected` / `Broken pipe` 报错。

## 触发条件/复现场景

- L1 内核：`6.12.0-pkvm-ia #31`
- 平台：`QEMU Standard PC (Q35 + ICH9, 2009)`
- 透传设备：`BDF=0000:01:00.0`
- 启动模式：非机密 VM（`PROTECTED=0`）
- 设备来源：L1 中透传给 pVM 的该 NVMe 设备来自 L0 的 QEMU 模拟设备（非物理直通设备）。
- 复现步骤：

```bash
lspci -nn | rg 'Non-Volatile|NVMe'
cat /sys/class/nvme/nvme0/serial
# 找到透传的设备的BDF号
readlink -f /sys/class/nvme/nvme0/device
BDF=0000:01:00.0
sudo modprobe vfio-pci
echo vfio-pci | sudo tee /sys/bus/pci/devices/$BDF/driver_override
echo "$BDF" | sudo tee /sys/bus/pci/devices/$BDF/driver/unbind || true
echo "$BDF" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
lspci -nnk -s 01:00.0

BDF=0000:01:00.0 sudo PROTECTED=0 SETUP_NET=0 VFIO_DEV=$BDF ./scripts/run-crosvm.sh
```

## 原始日志（节选）

### L1 dmesg

```text
[ 1913.625505] pkvm: exception 6 on CPU2 @ip do_donate__pkvm+0x332/0x380 (0xffffffff8c007c52), no err code
...
[ 1940.570465] watchdog: BUG: soft lockup - CPU#12 stuck for 26s! [kcompactd0:218]
...
[ 1940.571172] RIP: 0010:smp_call_function_many_cond+0x155/0x550
...
[ 1940.571249] native_flush_tlb_multi+0x67/0x130
[ 1940.571252] flush_tlb_mm_range+0x155/0x1c0
[ 1940.571261] try_to_migrate_one+0x28c/0xd40
[ 1940.571292] compact_zone+0xafa/0x1220
[ 1940.571300] kcompactd+0x2f1/0x4e0
```

### L1 dmesg（最新：增加 do_donate 失败原因/返回码日志）

在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c` 增加最小打点后，观测到 `__do_donate()` 返回 `-16`（`-EBUSY`），触发原因是 donation 目标页 `hyp_page_count()==1`：

```text
[  252.181636] pkvm: host_initiate_donation: page refcounted (dma/pinned?) addr=0x3897c7000 size=0x1000 owner_id=0 refcnt=1
[  252.182642] pkvm: do_donate: __do_donate failed ret=-16 size=0x1000 init=1 addr=0x3897c7000 phys=0x0 comp=0 addr=0xff3e23bc097c7000 phys=0x0 prot=0x0
[  252.183687] pkvm: exception 6 on CPU20 @ip do_donate__pkvm+0xba/0x5d0 (0xffffffffb1c079da), no err code
[  280.078446] watchdog: BUG: soft lockup - CPU#24 stuck for 22s! [node:2095]
```

### crosvm 日志

```text
[2026-03-02T02:19:16.431329035+00:00 ERROR devices::pci::vfio_pci] vfio 0000:01:00.0 device: failed to enable ACPI notifications
...
[2026-03-02T02:19:16.556255692+00:00 ERROR devices::proxy] ... tube was disconnected
...
[2026-03-02T02:19:16.667092811+00:00 ERROR crosvm::crosvm::sys::linux] child vfio 0000:01:00.0 device (pid 4545) exited: signo 17, status 31, code 3
```

## 触发路径（常见回溯）

- 已观测到异常点：`do_donate__pkvm`
- 对应源码函数：`do_donate()` / `__do_donate()`
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`

## 根因（简述）

- 已定位到 `do_donate__pkvm` 的失败原因：`__do_donate()` 返回 `-EBUSY`（`-16`），触发点在 `host_initiate_donation()` 的 `hyp_page_count(__hyp_va(addr))` 检查（refcnt=1）。对应源码：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`：`host_initiate_donation()` / `do_donate()`
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/buddy_memory.h`：`hyp_page_count()`（读取 hyp vmemmap 的 `refcount`）
- `exception 6`（#UD）是由 `do_donate()` 内的 `WARN_ON(ret)` 主动触发，用于打印 warning/回溯，并非 CPU 执行到随机非法指令。
- 失败的 donation 类型从日志可以确定为 `host -> hyp`（`init=1` / `comp=0` / `owner_id=0`），即 host 试图 donate 页给 hypervisor，但该页在 hyp vmemmap 中已被 refcount 标记为“正在使用/被 pin”。
- 随后的 `soft lockup`（`smp_call_function_many_cond()` 自旋）属于后果：某 CPU 在 pKVM 异常路径停住后，导致跨 CPU 的 IPI/flush 等等待长时间无法完成。

下一步定位目标从“donation 返回码”转为“refcnt=1 的来源”：

- 追踪哪些路径会对该物理页做 `hyp_page_ref_inc/dec` 或 `pin_shared_mem_pages()`：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`：`pin_unpin_mem_pages()` / `pin_shared_mem_pages()`（共享/Pin 相关）
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`：`shadow_pgt_map_leaf()` / `shadow_pgt_unmap_leaf()`（shadow IOMMU 映射同步对页表页 refcount 变更）
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/page_alloc.c`：hyp pool 分配/释放对 refcount 的通用维护
- 建议在上述 refcount 变更点增加“只在 refcount 从 0->1 或命中特定 phys=0x3897c7000 时打印”的打点，以确定是哪条 pin/share/iommu 路径导致 refcnt 泄漏或时序冲突。

## 解决方案

- 当前无正式修复。
- 临时规避：
  - 在该内核版本上避免对非机密 VM（`PROTECTED=0`）启用 VFIO 设备透传；
  - 或先使用不透传设备的启动方式完成其他功能验证。
- 建议后续定位动作：
  - 已增加并验证：在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c` 打印 `__do_donate()` 返回码与 `hyp_page_count()` 失败原因；
  - 抓取完整异常前后 dmesg（含首个 `pkvm: exception 6` 前后 2~5 秒）；
  - 记录触发时的设备 BAR/IOMMU 映射操作序列，和 crosvm 子进程退出点对应关系。

## 验证要点

- 复现命令稳定触发 `pkvm: exception 6 @ do_donate__pkvm` 可作为回归基线。
- 应用后续修复后，需同时满足：
  - L1 dmesg 不再出现 `pkvm: exception 6` 与后续 `soft lockup`；
  - crosvm 不再出现 VFIO 子进程异常退出（`status 31, code 3`）及批量 `tube was disconnected`。

## 备注

- 本问题由 2026-03-02 现场日志整理。
- 已确认透传设备链路为 “L0 QEMU 模拟 NVMe -> L1 VFIO 绑定 -> 透传给非机密 VM（PROTECTED=0）”。
- 如后续确认该问题与 BOOT-003（`root_tbl_walk__pkvm` #GP）存在共同触发前置条件，应补充交叉引用。
