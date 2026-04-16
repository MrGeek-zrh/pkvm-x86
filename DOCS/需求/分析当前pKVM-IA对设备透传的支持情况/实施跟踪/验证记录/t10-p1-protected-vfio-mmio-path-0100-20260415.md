# [T10] 2026-04-15 protected pVM NVMe MMIO 路径验证（`0000:01:00.0`）

## 目的

确认当前这条 protected pVM + VFIO NVMe 正向样例里：

- guest 内对 NVMe BAR 的 MMIO 访问是否真的走了 `pkvm_direct_mmio_read()` / `pkvm_direct_mmio_write()`
- 还是仍然走了 `PKVM_GHC_IOREAD` / `PKVM_GHC_IOWRITE` 的 host fallback

## 样例与入口

- 设备：boot-known NVMe `0000:01:00.0`
- VM 启动入口：`scripts/run-crosvm.sh`
- 启动命令：

```text
sudo -n env PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

## 实验 A：host 侧 kprobe `kvm_sev_es_mmio_read/write`

### 目的

确认 protected guest 运行期间，host kernel 的 MMIO emulation 入口是否被实际打到。

### 做法

在 host 上对下面两个符号打 kprobe：

- `kvm_sev_es_mmio_read`
- `kvm_sev_es_mmio_write`

再启动上面的 protected pVM 样例，等 guest 到达 `login:`，然后统计 trace 中的命中次数。

### 关键结果

- guest 确实启动到 `localhost login:`
- trace 计数：

```text
pkvm_mmio_read  = 310
pkvm_mmio_write = 3653
```

- `trace.log` 样本：

```text
pkvm_mmio_write: (kvm_sev_es_mmio_write+0x0/0x190)
pkvm_mmio_read:  (kvm_sev_es_mmio_read+0x0/0xe0)
pkvm_mmio_write: (kvm_sev_es_mmio_write+0x0/0x190)
pkvm_mmio_read:  (kvm_sev_es_mmio_read+0x0/0xe0)
```

### 解释

这一步只能证明：

- 当前这条 protected pVM 运行过程中，确实发生了大量 `IOREAD/IOWRITE -> host` fallback

这一步**单独还不能严格证明**这些 fallback 全都来自 NVMe BAR 访问，因为其中也可能混入 guest 启动阶段的其他 MMIO。

## 实验 B：guest 侧对 `pkvm_virt_mmio()` 分支直接打点

### 目的

把“是否命中 direct BAR 分支”直接收敛到 guest 内 `pkvm_virt_mmio()` 本身，而不是只看 host 侧是否有 fallback。

### 分支定位依据

先对 `build-guest/vmlinux` 反汇编 `pkvm_virt_mmio()`，确认两个分支入口：

```text
ffffffff81009a10 <pkvm_virt_mmio>:
...
ffffffff81009b05: 未命中 allowlist 后进入 fallback 分支
ffffffff81009b10: call kvm_hypercall2
ffffffff81009b70: call kvm_hypercall3
...
ffffffff81009b89: 命中 allowlist 后进入 direct 分支
```

因此在 guest 内把下面两个位置作为 kprobe 观测点：

- `pkvm_virt_mmio+0xf5`：fallback 分支入口
- `pkvm_virt_mmio+0x179`：direct 分支入口

### guest 内操作

先正常用 `scripts/run-crosvm.sh` 启动到串口 `login:`，登录 `ubuntu` 用户后执行：

```text
sudo bash <<'EOF'
set -eu
TRACE=/sys/kernel/tracing
echo 0 > $TRACE/tracing_on || true
echo > $TRACE/kprobe_events || true
echo 'p:direct_hit pkvm_virt_mmio+0x179' > $TRACE/kprobe_events
echo 'p:fallback_hit pkvm_virt_mmio+0xf5' >> $TRACE/kprobe_events
echo 1 > $TRACE/events/kprobes/direct_hit/enable
echo 1 > $TRACE/events/kprobes/fallback_hit/enable

echo > $TRACE/trace
echo 1 > $TRACE/tracing_on
sleep 1
echo 0 > $TRACE/tracing_on
grep -c ' direct_hit:' $TRACE/trace
grep -c ' fallback_hit:' $TRACE/trace

modprobe nvme >/dev/null 2>&1 || true
DEVNODE=$(ls /dev/nvme*n1 2>/dev/null | head -n1 || true)

echo > $TRACE/trace
echo 1 > $TRACE/tracing_on
dd if="$DEVNODE" of=/dev/null bs=4096 count=64 iflag=direct status=none >/dev/null 2>&1 || true
sleep 1
echo 0 > $TRACE/tracing_on
grep -c ' direct_hit:' $TRACE/trace
grep -c ' fallback_hit:' $TRACE/trace
EOF
```

另外再单独做一次返回码确认：

```text
sudo sh -c 'dd if=/dev/nvme0n1 of=/dev/null bs=4096 count=1 iflag=direct status=none; echo DD_RC=$?'
```

### 关键输出

guest 内真实输出如下：

```text
===PKVM_DIRECT_MMIO_TEST_BEGIN===
Linux localhost.localdomain 6.12.0+ #1 SMP PREEMPT_DYNAMIC Tue Mar 24 16:33:09 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
symbol: ffffffff9fc09a10 t pkvm_virt_mmio
nvme_before: /dev/nvme0  /dev/nvme0n1
```

baseline 计数：

```text
BASE_DIRECT=0
BASE_FALLBACK=2
```

NVMe `dd` 阶段计数：

```text
DD_DIRECT=0
DD_FALLBACK=130
```

NVMe 枚举证据：

```text
nvme_after_modprobe: /dev/nvme0  /dev/nvme0n1
DEVNODE=/dev/nvme0n1
major minor  #blocks  name
 259        0    8388608 nvme0n1
[    6.545211] nvme nvme0: pci function 0000:01:00.0
[    6.598203] nvme nvme0: 2/0/0 default/read/poll queues
[    6.668193] nvme nvme0: Ignoring bogus Namespace Identifiers
```

NVMe 读返回码：

```text
DD_RC=0
```

## 实验 C：guest 侧直接观察 allowlist 状态

### 目的

确认问题到底是“allowlist 范围不匹配”，还是“guest 根本没拿到 allowlist”。

### 做法

在 guest 内对 `pkvm_virt_mmio+0x9b` 打 kprobe，直接读取：

- 当前访问对应的 `gpa`
- `pkvm_mmio_allow_nr_ranges`
- `pkvm_mmio_info`
- `pkvm_mmio_allow_ranges[]`

然后执行一次：

```text
dd if=/dev/nvme0n1 of=/dev/null bs=4096 count=1 iflag=direct
```

实际使用的 guest 侧命令如下：

```text
sudo bash <<'EOF'
set -eu
TRACE=/sys/kernel/tracing
echo 0 > $TRACE/tracing_on || true
for e in allow_obs; do
  [ -e $TRACE/events/kprobes/$e/enable ] && echo 0 > $TRACE/events/kprobes/$e/enable || true
done
echo > $TRACE/kprobe_events || true
echo 'p:allow_obs pkvm_virt_mmio+0x9b gpa=%r15:x64 end=%r11:x64 nr=@pkvm_mmio_allow_nr_ranges:u16 info=@pkvm_mmio_info:x64 ranges=@pkvm_mmio_allow_ranges:x64[9]' > $TRACE/kprobe_events
echo 1 > $TRACE/events/kprobes/allow_obs/enable
echo > $TRACE/trace
echo 1 > $TRACE/tracing_on
dd if=/dev/nvme0n1 of=/dev/null bs=4096 count=1 iflag=direct status=none >/dev/null 2>&1 || true
sleep 1
echo 0 > $TRACE/tracing_on
grep 'allow_obs:' $TRACE/trace | tail -n 20 || true
echo 0 > $TRACE/events/kprobes/allow_obs/enable || true
echo > $TRACE/kprobe_events || true
EOF
```

### 关键输出

```text
allow_obs: ... gpa=0xd0001008 end=0xd000100c nr=0 info=0x0 ranges={0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0}
allow_obs: ... gpa=0xd000100c end=0xd0001010 nr=0 info=0x0 ranges={0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0}
```

### 解释

这一步把问题进一步收敛成：

- 不是“allowlist 几乎对了，但没覆盖到 `0xd0001008`”
- 而是 **guest 里的 MMIO allowlist 完全为空**

也就是说，当前 direct MMIO 不命中的原因发生在更早的阶段：

- 要么 host/hyp 根本没收到有效 metadata
- 要么收到后没有成功同步成 `vm->mmio_allow_ranges[]`

## 实验 D：host 侧追踪 metadata ioctl 是否真的被调用

### 目的

确认 `crosvm` 是否真的走到了：

```text
linux.vm.set_protected_vm_ptdev_mmio_metadata(...)
    -> KVM_CAP_X86_PROTECTED_VM_FLAGS_SET_PTDEV_MMIO_METADATA
    -> pkvm_vm_ioctl_set_ptdev_mmio_metadata()
```

### 做法

在 host 上同时对下面两个符号打 kprobe，再用 `scripts/run-crosvm.sh` 启动同一个 protected pVM 样例：

- `pkvm_vm_ioctl_enable_cap`
- `pkvm_vm_ioctl_set_ptdev_mmio_metadata`

实际使用的 host 侧命令如下：

```text
sudo -n bash -lc '
set -u
TRACE=/sys/kernel/tracing
OUT=/tmp/pkvm-mmio-metadata-trace-20260415-b.log
VMLOG=/tmp/pkvm-mmio-metadata-vm-20260415.log
: > "$OUT"
: > "$VMLOG"
echo 0 > $TRACE/tracing_on || true
for e in enable_cap meta_enter; do
  [ -e $TRACE/events/kprobes/$e/enable ] && echo 0 > $TRACE/events/kprobes/$e/enable || true
done
echo > $TRACE/kprobe_events || true
echo "p:enable_cap pkvm_vm_ioctl_enable_cap" > $TRACE/kprobe_events
echo "p:meta_enter pkvm_vm_ioctl_set_ptdev_mmio_metadata" >> $TRACE/kprobe_events
echo 1 > $TRACE/events/kprobes/enable_cap/enable
echo 1 > $TRACE/events/kprobes/meta_enter/enable
echo > $TRACE/trace
echo 1 > $TRACE/tracing_on
(
  cd /home/mrgeek/pkvm-x86
  env PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
) > "$VMLOG" 2>&1 &
vm_pid=$!
sleep 25 || true
kill $vm_pid >/dev/null 2>&1 || true
sleep 2
pkill -TERM -P $vm_pid >/dev/null 2>&1 || true
pkill -TERM crosvm >/dev/null 2>&1 || true
sleep 1
echo 0 > $TRACE/tracing_on
cat $TRACE/trace > "$OUT"
grep -E "(enable_cap|meta_enter)" "$OUT" | tail -n 30 || true
echo 0 > $TRACE/events/kprobes/enable_cap/enable || true
echo 0 > $TRACE/events/kprobes/meta_enter/enable || true
echo > $TRACE/kprobe_events || true
'
```

原始日志已保存：

- host trace：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p1-host-kprobe-enable-cap-vs-metadata-20260415.trace.log`
- VM 启动日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p1-host-kprobe-enable-cap-vs-metadata-vm-20260415.log`

### 关键输出

```text
enable_cap=2
meta_enter=0

crosvm-3104388 ... enable_cap: (pkvm_vm_ioctl_enable_cap+0x0/0x170)
crosvm-3104388 ... enable_cap: (pkvm_vm_ioctl_enable_cap+0x0/0x170)
```

### 解释

这说明：

- protected VM 相关 `enable_cap` 路径确实被调用了
- 但 `pkvm_vm_ioctl_set_ptdev_mmio_metadata()` 在这轮启动里 **一次都没有命中**

因此可以直接排除“metadata 提交给 KVM 了，但在 KVM/hyp 里丢了”这一类问题，问题已经进一步收敛为：

- `crosvm` 在这条样例里根本没有发出 `SET_PTDEV_MMIO_METADATA` ioctl

结合 `crosvm/arch/src/lib.rs` 和 `crosvm/devices/src/pci/vfio_pci.rs` 的代码，这基本意味着：

- `device.get_protected_vm_ptdev_mmio_metadata(&linux.vm)` 返回了 `None`
- 进一步看，最可能是 `build_protected_vm_ptdev_mmio_metadata()` 里的 `ranges` 为空

## 实验 E：排除“MSI-X 裁剪把整个 BAR 清空”这个可能

### 目的

确认 `remove_bar_mmap_msix()` 是否可能把 NVMe BAR0 的所有候选 mmap 区间都删掉。

### 关键输入

host 上对 `0000:01:00.0` 做 `lspci -vvvxxx`，得到：

```text
Region 0: Memory at fe800000 [size=16K]
MSI-X:
    Vector table: BAR=0 offset=00002000
    PBA:          BAR=0 offset=00003000
```

实际命令：

```text
sudo -n lspci -s 01:00.0 -vvvxxx
```

原始输出已保存：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p1-host-lspci-0100-vfio-20260415.log`

### 结合源码的解释

`crosvm/devices/src/pci/vfio_pci.rs` 里：

- `remove_bar_mmap_msix()` 会删掉 MSI-X table 和 PBA 所在区间
- 这两个区间最终按页对齐后，分别对应：
  - `0x2000..0x2fff`
  - `0x3000..0x3fff`

而 BAR0 总大小是 `0x4000`，所以如果 VFIO 原始上报的是“整个 BAR0 可 mmap”，删掉这两段之后，理论上仍应至少保留：

```text
0x0000..0x1fff
```

guest 本次实际命中的 GPA 也正落在这部分前半段：

```text
gpa = 0xd0001008 / 0xd000100c
```

### 结论

因此，当前 `ranges` 为空 **不能** 用“MSI-X 裁剪把整个 BAR 都删光了”来解释。

更强的怀疑点已经收敛为：

- VFIO 这边对 BAR0 根本没有给出 `VFIO_REGION_INFO_FLAG_MMAP`
- 或者 `get_region_mmap(bar_index)` 返回的 sparse mmap 区间本身就是空

## 实验 F：核对 `crosvm` 启动期到底走哪条 PCI 注册路径

### 目的

确认 boot 阶段这块 VFIO NVMe 设备是否真的会走到：

```text
configure_pci_device()
    -> get_protected_vm_ptdev_mmio_metadata()
    -> set_protected_vm_ptdev_mmio_metadata()
```

### 做法

直接对 `crosvm` 源码做调用路径核对：

```text
cd /home/mrgeek/pkvm-x86/crosvm
rg -n "configure_pci_device\\(|generate_pci_root\\(" . -g '!target'
nl -ba x86_64/src/lib.rs | sed -n '1035,1062p'
nl -ba x86_64/src/lib.rs | sed -n '1501,1519p'
nl -ba arch/src/lib.rs | sed -n '787,825p'
nl -ba arch/src/lib.rs | sed -n '1264,1335p'
```

### 关键输出

源码显示：

```text
x86_64/src/lib.rs:1035-1061
    let (pci_devices, devs): (Vec<_>, Vec<_>) = devs
        .into_iter()
        .partition(|(dev, _)| dev.as_pci_device().is_some());
    ...
    arch::generate_pci_root(pci_devices, ...)

x86_64/src/lib.rs:1501-1519
    fn register_pci_device(...)
        -> arch::configure_pci_device(...)

arch/src/lib.rs:787-825
    configure_pci_device()
        -> device.get_protected_vm_ptdev_mmio_metadata(&linux.vm)
        -> if let Some(metadata) {
               linux.vm.set_protected_vm_ptdev_mmio_metadata(&metadata)
           }

arch/src/lib.rs:1264-1335
    generate_pci_root() 设备注册循环里
        -> register_device_capabilities()
        -> generate_acpi_methods()
        -> set_gpe()
        -> root.add_device()
        -> mmio_bus.insert(...)
```

而 `generate_pci_root()` 这条路径里**没有**任何：

- `get_protected_vm_ptdev_mmio_metadata()`
- `set_protected_vm_ptdev_mmio_metadata()`

### 解释

这一步把前面那个“日志上看到 `before set_gpe`，但始终看不到 metadata 查询日志”的矛盾彻底解开了：

- 我们看到的 `before set_gpe` 埋点实际来自 `generate_pci_root()`
- 但 metadata 提交逻辑只存在于 `configure_pci_device()`
- boot 阶段的 PCI 设备（包括这块 VFIO NVMe）当前走的是 `generate_pci_root()`，不是 `configure_pci_device()`

因此，当前这条 protected pVM 启动样例里：

- `crosvm` 在启动期**根本没有机会**去提交 ptdev MMIO metadata
- 所以 host 侧 `pkvm_vm_ioctl_set_ptdev_mmio_metadata()` 命中数为 `0`
- 所以 guest 侧 `pkvm_mmio_allow_nr_ranges` 也是 `0`

### 结论

当前更直接的功能性缺口已经收敛为：

- `crosvm` 的 boot-time PCI/VFIO 设备注册路径缺少 `ptdev MMIO metadata` 提交逻辑

## 实验 G：补齐 `generate_pci_root()` 提交后，先暴露出 `crosvm` / KVM metadata ABI 不匹配

### 做法

在 `crosvm` 中补齐：

- boot-time `generate_pci_root()` 路径的 metadata 提交
- 与 `configure_pci_device()` 共用同一个 helper

然后直接重新运行：

```text
sudo -n env -u DEBUG PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

原始日志已保存：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p4-crosvm-after-fix-0100-20260415-pty.log`

### 关键输出

```text
ERROR crosvm] exiting with error 1: the architecture failed to build the vm

Caused by:
    failed to create a PCI root hub:
    failed to submit protected VM ptdev MMIO metadata:
    Invalid argument (os error 22)
```

### 解释

继续核对 `crosvm/hypervisor/src/kvm/x86_64.rs` 和
`pKVM-IA/arch/x86/include/uapi/asm/kvm.h` 后确认：

- `crosvm` 当时发送给 KVM 的 `kvm_protected_vm_ptdev_mmio_metadata`
  / `kvm_protected_vm_ptdev_mmio_range` 布局仍是旧版本口径
- 当前内核 UAPI 要求：
  - `segment` / `bdf` / `pasid` 在 metadata 顶层
  - range 里只保留 `guest_gpa` / `size` / `bar_offset` / `bar_index` / `kind`
- 两边 ABI 不一致，所以在真正开始走 boot-time metadata 提交后，首先被内核以 `EINVAL` 拒绝

### 结论

这一步说明：

- 补齐 `generate_pci_root()` 提交逻辑本身方向是对的
- 但还必须同时修正 `crosvm` 到当前 pKVM UAPI 的 metadata 编码布局

## 实验 H：对齐 metadata ABI 后，成功命中 `SET_PTDEV_MMIO_METADATA`，并暴露出 kernel 侧 B5-2 缺口

### 做法

继续修正 `crosvm/hypervisor/src/kvm/x86_64.rs` 中 metadata/range 的 KVM UAPI 编码布局后，再次运行同一条 protected pVM 样例，并同时打 host kprobe：

```text
pkvm_vm_ioctl_enable_cap
pkvm_vm_ioctl_set_ptdev_mmio_metadata
```

原始日志已保存：

- host trace：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p5-host-kprobe-enable-cap-vs-metadata-after-abi-fix-20260415.trace.log`
- VM 启动日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p5-crosvm-after-abi-fix-0100-20260415-pty.log`
- host dmesg 节选：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p5-host-dmesg-vm_mmu_map-fail-after-metadata-20260415.log`

### 关键输出

host trace 中已经出现：

```text
crosvm-3138585 ... enable_cap: (pkvm_vm_ioctl_enable_cap+0x0/0x170)
crosvm-3138585 ... enable_cap: (pkvm_vm_ioctl_enable_cap+0x0/0x170)
crosvm-3138585 ... meta_enter: (pkvm_vm_ioctl_set_ptdev_mmio_metadata+0x0/0x3e0)
crosvm-3138585 ... enable_cap: (pkvm_vm_ioctl_enable_cap+0x0/0x170)
```

随后 host dmesg 出现：

```text
pkvm: host_initiate_donation: addr not in mem_range addr=0xfe800000 size=0x1000 owner_id=1
pkvm: do_donate: __do_donate failed ret=-1 ... addr=0xd0000000 phys=0xfe800000 prot=0x77
pkvm: __pkvm_host_donate_guest failed ret=-1 hpa=0xfe800000 gpa=0xd0000000 size=0x1000 prot=0x77
kvm: pkvm: vm_mmu_map failed ret=-1 gpa=0xd0000000 hpa=0xfe800000 size=0x1000 writable=1 goal_level=1 pfn=0xfe800
```

### 解释

这一步把当前主阻塞进一步钉死成：

- `crosvm` 侧 boot-time metadata 提交现在已经真正打穿到 KVM/pKVM
- 但 guest 在尝试把 NVMe BAR HPA `0xfe800000` 映入 protected pVM Guest EPT 时
- hyp 仍然走的是 `__pkvm_host_donate_guest()` / normal memory donation 语义
- 于是 BAR HPA 不在 `mem_range`，被 `host_initiate_donation()` 直接拒绝

新问题已单独归档：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-012/BOOT-012-protected-pVM-BAR-HPA误入donate路径导致vm_mmu_map失败.md`

### 结论

这已经不是 `crosvm` metadata 路径的问题，而是当前 kernel / hyp 侧正缺少 B5-2 设计里要补的那部分：

- BAR HPA 命中合法 boot-time manifest BAR 后，不能再走 normal memory donation
- 需要切到 direct BAR leaf 建图路径

## 调用路径对照：`configure_pci_device()` vs `generate_pci_root()`

为避免后续再混淆，把当前已经核实的两条路径并排列出来：

```text
路径 A：configure_pci_device()（有 metadata 提交）

x86_64/src/lib.rs
    register_pci_device(...)
        -> arch::configure_pci_device(...)

arch/src/lib.rs
    configure_pci_device(...)
        -> device.allocate_address(...)
        -> device.allocate_io_bars(...)
        -> device.allocate_device_bars(...)
        -> device.get_protected_vm_ptdev_mmio_metadata(&linux.vm)
            -> 对 VFIO 设备：
               devices/src/pci/vfio_pci.rs
                   get_protected_vm_ptdev_mmio_metadata(...)
                       -> build_protected_vm_ptdev_mmio_metadata()
        -> if let Some(metadata)
            -> linux.vm.set_protected_vm_ptdev_mmio_metadata(&metadata)
                -> hypervisor/src/kvm/x86_64.rs
                    KVM_CAP_X86_PROTECTED_VM_FLAGS_SET_PTDEV_MMIO_METADATA
                -> pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c
                    pkvm_vm_ioctl_set_ptdev_mmio_metadata()
                -> pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
                    pkvm_set_ptdev_mmio_metadata()
                        -> pkvm_update_vm_mmio_allowlist()
        -> 后续普通设备注册


路径 B：generate_pci_root()（当前没有 metadata 提交）

x86_64/src/lib.rs
    devs.partition(|(dev, _)| dev.as_pci_device().is_some())
        -> arch::generate_pci_root(pci_devices, ...)

arch/src/lib.rs
    generate_pci_root(...)
        -> generate_pci_topology(...)
        -> for each pci device
            -> register_device_capabilities()
            -> generate_acpi_methods()
            -> set_gpe()
            -> root.add_device(...)
            -> mmio_bus.insert(...)

        [当前缺少]
            -> device.get_protected_vm_ptdev_mmio_metadata(...)
            -> vm.set_protected_vm_ptdev_mmio_metadata(...)
```

这两条路径的区别就是当前问题的核心：

- `configure_pci_device()` 已经具备“生成 metadata + 提交 metadata”完整链路
- `generate_pci_root()` 当前只有 PCI 设备注册，没有 `ptdev MMIO metadata` 提交
- boot 阶段 VFIO NVMe 设备走的是路径 B，所以 guest 最终拿到的 allowlist 为空

这比“`build_protected_vm_ptdev_mmio_metadata()` 返回空 `ranges`”更前置，也更符合现有所有观测结果。

## host fallback 继续落到哪里（源码补充）

为避免把“`PKVM_GHC_IOREAD/IOWRITE -> host fallback`”理解成只到
`kvm_sev_es_mmio_read()` / `kvm_sev_es_mmio_write()` 就结束，这里把 metadata
缺失阶段的实际 host 处理链继续展开。

更准确地说，这一轮 `dd if=/dev/nvme0n1 ...` 能成功，依赖的是：

- guest 侧 NVMe BAR 寄存器访问没有命中 allowlist，于是走 host-mediated MMIO
- host KVM 把这次 MMIO exit 继续交给 `crosvm`
- `crosvm` 再通过 VFIO PCI BAR 读写真实设备寄存器
- 设备的数据搬运仍走已 attach 的 ptdev/IOMMU DMA 路径，而不是依赖 allowlist

对应调用栈可以收敛为：

```text
guest NVMe BAR MMIO
    -> pKVM-IA/arch/x86/coco/pkvm/pkvm.c
        pkvm_virt_mmio()
            -> pkvm_mmio_allow_hit() == false
            -> mmio_read()/mmio_write()
            -> kvm_hypercall2/3(PKVM_GHC_IOREAD/IOWRITE)

pKVM/hyp
    -> pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c
        PKVM_GHC_IOREAD/IOWRITE
            -> kvm_skip_emulated_instruction()
            -> return 0
    -> pKVM-IA/arch/x86/kvm/pkvm/x86.c
        handle_exit() <= 0
            -> pkvm_make_req_to_host(HOST_HANDLE_EXIT, vcpu)

host KVM
    -> pKVM-IA/arch/x86/kvm/x86.c
        kvm_pkvm_hypercall()
            -> kvm_sev_es_mmio_read()/kvm_sev_es_mmio_write()
                -> vcpu_mmio_read()/vcpu_mmio_write()
                -> kvm_io_bus_read()/kvm_io_bus_write()
                -> 若内核内未完全处理
                    -> run->exit_reason = KVM_EXIT_MMIO
                    -> complete_userspace_io = complete_sev_es_emulated_mmio

crosvm userspace
    -> crosvm/hypervisor/src/kvm/mod.rs
        vcpu.run() => VcpuExit::Mmio
        vcpu.handle_mmio()
    -> crosvm/src/crosvm/sys/linux/vcpu.rs
        mmio_bus.read()/write()
    -> crosvm/devices/src/bus.rs
        Bus::read()/write()
    -> crosvm/devices/src/pci/pci_device.rs
        PciDevice::read()/write()
            -> find_bar_and_offset()
    -> crosvm/devices/src/pci/vfio_pci.rs
        VfioPciDevice::read_bar()/write_bar()
    -> crosvm/devices/src/vfio.rs
        VfioDevice::region_read()/region_write()
            -> 对 VFIO device fd 做 pread/pwrite
            -> 命中真实 NVMe BAR
```

这条栈对应的关键源码位置：

- guest miss allowlist 后回退超调用：
  - `pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
    - `pkvm_virt_mmio()`
- hyp 把 `PKVM_GHC_IOREAD/IOWRITE` 转发给 host：
  - `pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c`
  - `pKVM-IA/arch/x86/kvm/pkvm/x86.c`
- host KVM 复用 SEV-ES MMIO 处理并在必要时抛出 `KVM_EXIT_MMIO`：
  - `pKVM-IA/arch/x86/kvm/x86.c`
    - `kvm_pkvm_hypercall()`
    - `kvm_sev_es_mmio_read()`
    - `kvm_sev_es_mmio_write()`
- `crosvm` 接住 `KVM_EXIT_MMIO` 后把 GPA 路由到 VFIO PCI BAR：
  - `crosvm/hypervisor/src/kvm/mod.rs`
  - `crosvm/src/crosvm/sys/linux/vcpu.rs`
  - `crosvm/devices/src/bus.rs`
  - `crosvm/devices/src/pci/pci_device.rs`
  - `crosvm/devices/src/pci/vfio_pci.rs`
  - `crosvm/devices/src/vfio.rs`

因此，这里所谓“转发给 host”的更准确语义不是“host kernel 自己模拟了整个 NVMe”，而是：

- host KVM 先承接 guest 的 MMIO hypercall
- 然后把未在内核内完成的 MMIO 继续抛给 `crosvm`
- 最终由 `crosvm + VFIO` 对真实 NVMe BAR 做寄存器访问

同时，这也解释了为什么在 allowlist 为空时 `dd` 仍可成功：

- 控制面寄存器访问由 `host fallback + VFIO BAR` 补上
- 数据面搬运仍由设备 DMA 完成

DMA 侧与 MMIO allowlist 是两条独立机制；当前 ptdev attach 后，DMA 使用的是
`pkvm_shadow_vm.pgstate_pgt` 这份 DMA mirror，并通过 `pkvm_iommu_sync()` 同步到
IOMMU 上下文：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h`
  - `struct pkvm_shadow_vm`
  - `pgstate_pgt`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_attach_ptdev()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`
  - `pkvm_iommu_sync()`

## 结论

2026-04-15 这轮验证可以直接得出下面这组结论：

1. 这条 protected pVM + VFIO NVMe 正向样例确实可以启动到 guest `login:`，guest 内也确实能看到 `nvme0n1`
2. guest 内对 `/dev/nvme0n1` 的原始读取可以成功返回 `DD_RC=0`
3. 但在这次 NVMe `dd` 过程中：
   - `pkvm_virt_mmio()` 的 direct 分支命中数是 `0`
   - `pkvm_virt_mmio()` 的 fallback 分支命中数是 `130`
4. 因此当前这条样例的 NVMe MMIO 访问**不是**通过 `pkvm_direct_mmio_read()` / `pkvm_direct_mmio_write()` 完成的
5. 当前实际走通的是：

```text
guest NVMe BAR MMIO
    -> pkvm_virt_mmio()
        -> 未命中 allowlist
        -> mmio_read()/mmio_write()
        -> PKVM_GHC_IOREAD/IOWRITE
        -> pKVM/hyp 转发给 host
        -> host 侧 kvm_sev_es_mmio_read/write
```
6. guest 里的 MMIO allowlist 在访问发生时是空的（`nr=0`）
7. host 侧 `pkvm_vm_ioctl_set_ptdev_mmio_metadata()` 没有命中，说明这轮启动中 `crosvm` 没有真正提交 `ptdev MMIO metadata`
8. 继续核对 `crosvm` 源码后，已经确认 boot 阶段 PCI/VFIO 设备走的是 `generate_pci_root()`，而不是 `configure_pci_device()`
9. `set_protected_vm_ptdev_mmio_metadata()` 只存在于 `configure_pci_device()`，`generate_pci_root()` 当前没有对应逻辑
10. 补齐 `generate_pci_root()` 提交后，又继续暴露出一层更前置的兼容性问题：
    - `crosvm` 发送给 KVM 的 protected ptdev metadata ABI 与当前内核 UAPI 不一致
11. 对齐 ABI 后，host trace 已确认 `pkvm_vm_ioctl_set_ptdev_mmio_metadata()` 真正命中
12. 这说明 `crosvm` 侧 metadata 提交链路已经打通
13. `remove_bar_mmap_msix()` 的调试输出又说明：
    - 这块 NVMe 的 BAR0 原始 mmap 并不为空
    - MSI-X 裁剪后仍保留 `(0, 8192)`
14. 在 metadata 提交打通后，新的主阻塞变成：
    - kernel / hyp 侧仍把 BAR HPA 映射当成 normal memory donation 处理
15. host dmesg 中已经出现：
    - `host_initiate_donation: addr not in mem_range`
    - `__pkvm_host_donate_guest failed`
    - `vm_mmu_map failed`
16. 所以当前 direct MMIO 主线已经从“用户态没提 metadata”前移到真正的 B5-2 kernel 缺口：
    - Guest EPT BAR HPA 命中合法 BAR 后，仍缺少 direct BAR leaf 建图分流

## 当前最可能的问题位置

这次实验已经足够说明：**`pkvm_mmio_allow_hit()` 在当前正向样例下没有把 NVMe 访问判成 direct BAR 命中。**

并且现在已经可以进一步收敛为：

- 旧主阻塞已经不是 `crosvm` boot-time PCI/VFIO 注册路径
- `generate_pci_root()` metadata 提交 + metadata ABI 对齐之后，新的主阻塞已经前移到 kernel / hyp
- 更具体地说，是 `pKVM-IA/arch/x86/kvm/pkvm/mmu.c` / `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
  这条 Guest EPT 建图路径仍把 BAR HPA 送进了 `__pkvm_host_donate_guest()`

因此后续分析应优先收敛下面几类问题：

- `crosvm/devices/src/pci/vfio_pci.rs` 中：
  - `get_region_flags(bar_index)` 是否没带 `VFIO_REGION_INFO_FLAG_MMAP`
  - `get_region_mmap(bar_index)` 是否返回空 sparse mmap 列表
- 若上面两者都不是，再继续看：
  - `build_protected_vm_ptdev_mmio_metadata()` 是否被别的条件提前跳过
  - metadata `ranges` 是否在用户态被构造为空

## 关联源码

- guest MMIO 分流：`pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
- host fallback 超调用：`pKVM-IA/arch/x86/kvm/x86.c`
- pKVM/hyp guest hypercall 处理：`pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c`
- allowlist 初始化：`pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
- allowlist 同步：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- crosvm metadata 生成：`crosvm/devices/src/pci/vfio_pci.rs`
