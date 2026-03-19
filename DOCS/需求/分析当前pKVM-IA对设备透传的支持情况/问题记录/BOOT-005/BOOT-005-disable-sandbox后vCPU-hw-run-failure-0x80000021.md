# [BOOT-005] 验证 pKVM-IA 设备透传能力

## 验证思路

通过逐步增加复杂度的方式，定位问题出现在哪一层：


| 序号 | L1 内核       | VM 类型    | 透传设备 | 目的                                                             |
| ------ | --------------- | ------------ | ---------- | ------------------------------------------------------------------ |
| 1    | 普通 6.8 内核 | 普通虚拟机 | NVMe     | 基线测试：验证 crosvm + VFIO 透传在标准 KVM 嵌套虚拟化下是否可行 |
| 2    | pKVM 内核     | 普通虚拟机 | NVMe     | 对比 pKVM 内核引入后，非机密 VM 透传是否受影响                   |
| 3    | pKVM 内核     | 机密虚拟机 | NVMe     | 最终目标：验证 pKVM 机密 VM 的设备透传能力                       |

- **当前进度**：场景 1、2 已通过，场景 3 失败（donate 页面时因 refcount 非零被拒绝）。

## 测试结果

### 场景 1：普通 6.8 内核 + 普通虚拟机 + NVMe 透传

- **结果**：通过
- **结论**：普通 6.8 内核下，crosvm 能正常启动普通虚拟机并成功透传 NVMe 设备。

Guest 内关键日志：

```
ubuntu@localhost:~$ lsblk
NAME    MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
vda     253:0    0  10G  0 disk
└─vda1  253:1    0  10G  0 part /
nvme0n1 259:0    0   8G  0 disk

ubuntu@localhost:~$ readlink -f /sys/block/nvme0n1/device
/sys/devices/pci0000:00/0000:00:07.0/0000:01:00.0/nvme/nvme0
```

Guest 中可见 `nvme0n1` 块设备（8G），设备拓扑为 `pci0000:00 -> 00:07.0 -> 01:00.0`，NVMe 控制器正常枚举。

### 场景 2：pKVM 内核 + 普通虚拟机 + NVMe 透传

- **结果**：通过
- **结论**：pKVM 内核（6.12.0-pkvm-ia）下，crosvm 以 `PROTECTED=0` 启动普通虚拟机，NVMe 设备透传成功。

Host 侧操作流程：

```bash
# Host 内核版本
mrgeek@ubuntu-vm:~/pkvm-x86$ uname -r
6.12.0-pkvm-ia

# 查找 NVMe 设备 BDF
lspci -nn | rg 'Non-Volatile|NVMe'
readlink -f /sys/class/nvme/nvme0/device
BDF=0000:01:00.0

# 绑定 vfio-pci 驱动
sudo modprobe vfio-pci
sudo echo vfio-pci | sudo tee /sys/bus/pci/devices/$BDF/driver_override
sudo echo "$BDF" | sudo tee /sys/bus/pci/devices/$BDF/driver/unbind || true
echo "$BDF" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
lspci -nnk -s 01:00.0

# 启动普通虚拟机（PROTECTED=0），透传 NVMe
sudo PROTECTED=0 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

Guest 内关键日志：

```
ubuntu@localhost:~$ lsblk
NAME    MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
vda     253:0    0  10G  0 disk
└─vda1  253:1    0  10G  0 part /
nvme0n1 259:0    0   8G  0 disk

ubuntu@localhost:~$ readlink -f /sys/block/nvme0n1/device
/sys/devices/pci0000:00/0000:00:07.0/0000:01:00.0/nvme/nvme0
```

Guest 中可见 `nvme0n1` 块设备（8G），说明 pKVM 内核对非机密 VM 的 VFIO 透传无影响。

### 场景 3：pKVM 内核 + 机密虚拟机 + NVMe 透传

- **结果**：失败
- **结论**：pKVM 内核（6.12.0-pkvm-ia）下，crosvm 启动机密虚拟机并透传 NVMe 设备时，`do_donate` 流程失败。Host 在尝试将 VFIO DMA 映射的页面 donate 给 Guest 时，因页面 refcount 不为零而被 pKVM hypervisor 拒绝，返回 `-EBUSY`（-16）。

Host 侧 dmesg 关键日志：

```
[  176.978553] pkvm: host_initiate_donation: page refcounted (dma/pinned?) addr=0x3f5bc8000 size=0x6000 owner_id=0 refcnt=1
[  176.980426] pkvm-debug: trace dump target_hpa=0x3f5bc8000 nr_entries=4096
[  176.981208] pkvm-debug: trace hpa=0x3f5bc8000 tag=pkvm_vcpu_create/vcpu_pre old=1 new=1 aux=0x3f5bc8000
[  176.982270] pkvm-debug: trace hpa=0x3f5bc8000 tag=donate_host_memory/pre old=1 new=1 aux=0x3f5bc8000
[  176.983288] pkvm-debug: trace hpa=0x3f5bc8000 tag=__pkvm_host_donate_hyp/pre old=1 new=1 aux=0xffffffffbba0d570
[  176.984270] pkvm-debug: trace hpa=0x3f5bc8000 tag=host_initiate_donation/fail old=1 new=1 aux=0x0
[  176.985141] pkvm: do_donate: __do_donate failed ret=-16 size=0x6000 init=1 addr=0x3f5bc8000 phys=0x0 comp=0 addr=0xff18806d35bc8000 phys=0x0 prot=0x0
[  176.986480] pkvm: exception 6 on CPU28 @ip do_donate__pkvm+0xba/0x600 (0xffffffffbba07a2a), no err code
```

关键分析：

- `ret=-16`（`-EBUSY`）：页面正在被使用（refcnt=1），pKVM 拒绝 donate

## 当前进展（2026-03-18）

- 当前这次失败点已确认不是“VFIO DMA 页 donate 给 guest 失败”，而是 `pkvm_vcpu_create()` 阶段，Host 试图把 `pkvm_vcpu` 私有内存 donate 给 Hyp 时失败。关键证据是日志里的 `pkvm_vcpu_create/vcpu_pre`。
- 当前更合理的根因假设是：某个 host 页在更早阶段已经被 Hyp 侧保留了 `hyp_page.refcount=1`，后续 Host 又把该页分配给了 `pkvm_vcpu`，导致 `__pkvm_host_donate_hyp()` 命中 `-EBUSY`。
- 设备透传链路仍然是高优先级怀疑对象，因为 `VFIO -> add_ptdev -> pkvm_iommu_sync()` 发生在 `vcpu_create` 之前，可能通过 ptdev/IOMMU/shadow-IOMMU 路径留下了 stale refcount。

已做的止血与定位增强：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
  - `do_donate()` 不再对 `ret` 走 `WARN_ON()`，改为直接返回错误，先避免 `#UD` 把整机打死。
  - `host_initiate_donation()` 改为逐页检查整个 range，并打印 `busy_hpa`。
  - `__pkvm_hyp_donate_host()` 增加逐页 refcount 检查，若 Hyp 归还页面给 Host 时页仍被引用，会直接报错。
- `pKVM-IA/arch/x86/kvm/pkvm/pkvm.c`
  - `teardown_donated_memory()` 增加 donate-back 失败日志。

## 下一步代办

- 重新编译并复现场景 3，先确认 panic 是否已降级为可返回错误。
- 重点看是否先出现 `__pkvm_hyp_donate_host: page still refcounted`。
  - 如果出现，优先追 `shadow_iommu.c` 中 refcount 加减是否不配对。
  - 如果不出现，只在 `host_initiate_donation` 看到 `busy_hpa`，继续沿 `alloc_pages_exact(pkvm_vcpu)` 和该 HPA 的历史 trace 追踪谁先占用了这页。
- 复现时保留完整 dmesg，重点抓 `busy_hpa` 对应的 trace dump，确认该页最早是在哪条路径上变成 `refcnt=1` 的。

## 状态

- **当前状态**：场景 3 失败
- **发现日期**：2026-03-17
