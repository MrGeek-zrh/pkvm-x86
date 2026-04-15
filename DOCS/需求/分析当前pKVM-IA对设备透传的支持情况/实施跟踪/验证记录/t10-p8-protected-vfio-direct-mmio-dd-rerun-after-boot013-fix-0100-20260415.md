# [T10-P8] 2026-04-15 protected pVM NVMe 直通复测（BOOT-013 本地修复后，`0000:01:00.0`）

## 目的

在重启到新的 Host 内核后，重新验证：

- protected pVM 是否能越过 `BOOT-013` 的旧失败点并启动到 `login:`
- guest 内对透传 NVMe 的 `dd` 直读是否正常
- guest 内 NVMe BAR 的 MMIO 访问是否已经命中 `pkvm_virt_mmio()` 的 direct 分支

## 环境

- Host 内核：
  - `Linux ubuntu-vm 6.12.0-pkvm-ia #9 SMP PREEMPT_DYNAMIC Wed Apr 15 12:46:27 UTC 2026`
- 透传设备：
  - `0000:01:00.0`
  - `BAR0 = 0xfe800000`
  - `size = 16K`
- 启动入口：
  - `scripts/run-crosvm.sh`

## 实际执行

### 1. 绑定 `vfio-pci` 并打开 host MMIO fallback 观测

原始日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-bind-and-host-trace-setup-0100-20260415-130256.log`

执行内容：

- 将 `0000:01:00.0` 从 `nvme` 切到 `vfio-pci`
- 在 host `tracefs` 上对以下符号打 `kprobe`
  - `kvm_sev_es_mmio_read`
  - `kvm_sev_es_mmio_write`

### 2. 启动 protected pVM

启动命令：

```text
sudo -n env -u DEBUG PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

原始串口/PTTY 日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-crosvm-protected-vfio-direct-mmio-dd-0100-20260415-130256.pty.log`

### 3. guest 登录后确认 NVMe 枚举

guest 内执行：

```text
uname -a
ls -l /dev/nvme*
readlink -f /sys/block/nvme0n1/device
printf '\n' | sudo -S dmesg | grep -E 'nvme|pci function 0000:01:00.0|bogus Namespace|default/read/poll'
```

### 4. 第一轮 `dd`：只看 guest 读盘返回码 + host fallback 计数

guest 内执行：

```text
printf '\n' | sudo -S sh -c 'dd if=/dev/nvme0n1 of=/dev/null bs=4096 count=64 iflag=direct status=none; echo DD_RC=$?'
```

host 侧在 `dd` 前清空 `tracefs`，`dd` 后抓取：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-host-trace-counts-protected-vfio-direct-mmio-dd-0100-20260415-130256.log`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-host-dmesg-protected-vfio-direct-mmio-dd-0100-20260415-130256.log`

### 5. 第二轮 `dd`：在 guest 内对 `pkvm_virt_mmio()` direct / fallback 分支打点

guest 内执行：

```text
printf '\n' | sudo -S bash <<'EOF'
set -eu
TRACE=/sys/kernel/tracing
echo 0 > $TRACE/tracing_on || true
for e in direct_hit fallback_hit; do
  [ -e $TRACE/events/kprobes/$e/enable ] && echo 0 > $TRACE/events/kprobes/$e/enable || true
done
echo > $TRACE/kprobe_events || true
echo 'p:direct_hit pkvm_virt_mmio+0x179' > $TRACE/kprobe_events
echo 'p:fallback_hit pkvm_virt_mmio+0xf5' >> $TRACE/kprobe_events
echo 1 > $TRACE/events/kprobes/direct_hit/enable
echo 1 > $TRACE/events/kprobes/fallback_hit/enable
echo > $TRACE/trace
echo 1 > $TRACE/tracing_on
dd if=/dev/nvme0n1 of=/dev/null bs=4096 count=64 iflag=direct status=none >/dev/null 2>&1 || true
sleep 1
echo 0 > $TRACE/tracing_on
echo GUEST_DIRECT=$(grep -c ' direct_hit:' $TRACE/trace || true)
echo GUEST_FALLBACK=$(grep -c ' fallback_hit:' $TRACE/trace || true)
tail -n 20 $TRACE/trace || true
EOF
```

host 侧后续补抓：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-host-trace-counts-guest-kprobe-window-0100-20260415-130256.log`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-host-dmesg-final-0100-20260415-130256.log`

### 6. 第三轮 `dd`：补一个稍大的顺序读

guest 内执行：

```text
printf '\n' | sudo -S sh -c 'dd if=/dev/nvme0n1 of=/dev/null bs=4M count=16 iflag=direct status=progress; echo DD_BIG_RC=$?'
```

### 7. 关机并恢复 host 设备绑定

恢复相关日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-restore-0100-to-nvme-20260415-130256.log`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-restore-explicit-0100-to-nvme-20260415-130256.log`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-restore-final-0100-to-nvme-20260415-130256.log`

其中恢复时暴露了一个清理细节：

- 单纯 `printf '' > driver_override` 没有清掉旧值
- `driver_override` 里仍残留 `vfio-pci`
- 改成 `echo > /sys/bus/pci/devices/$BDF/driver_override` 后，设备成功重新探测并回到 `nvme`

## 关键现象

### protected pVM 成功启动并到达 `login:`

本轮已经不再出现 `BOOT-013` 的旧签名：

- 未见 `Bad address (os error 14)`
- 未见 `WARNING: ... kvm_tdp_page_fault`
- 未见 `pkvm_pin_page`
- 未见 `host_initiate_donation: addr not in mem_range`
- 未见 `vm_mmu_map failed`

串口内已经到达：

```text
Ubuntu 24.04.3 LTS localhost.localdomain hvc0

localhost login:
```

### guest 内 NVMe 已正常枚举

guest 内关键输出：

```text
Linux localhost.localdomain 6.12.0+ #1 SMP PREEMPT_DYNAMIC Tue Mar 24 16:33:09 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
crw------- 1 root root 240, 0 Apr 15 13:06 /dev/nvme0
brw-rw---- 1 root disk 259, 0 Apr 15 13:06 /dev/nvme0n1
/sys/devices/pci0000:00/0000:00:05.0/0000:01:00.0/nvme/nvme0
```

### guest 内 `dd` 直读成功

第一轮小块直读：

```text
DD_RC=0
```

第三轮较大块直读：

```text
16+0 records in
16+0 records out
67108864 bytes (67 MB, 64 MiB) copied, 0.173974 s, 386 MB/s
DD_BIG_RC=0
```

### guest 内 `pkvm_virt_mmio()` 观测到 direct 分支命中

第二轮 guest kprobe 结果：

```text
GUEST_DIRECT=128
GUEST_FALLBACK=2
```

尾部原始 trace 可见：

- `dd-282` 命中的是 `direct_hit`
- 两条 `fallback_hit` 来自 `sleep-283`

对应节选：

```text
dd-282     ... direct_hit: (pkvm_virt_mmio+0x179/0x260)
sleep-283  ... fallback_hit: (pkvm_virt_mmio+0xf5/0x260)
sleep-283  ... fallback_hit: (pkvm_virt_mmio+0xf5/0x260)
```

因此至少在这次 `dd if=/dev/nvme0n1 ...` 触发的观测窗口里，NVMe BAR MMIO 已经明确命中 direct 分支。

### host `kvm_sev_es_mmio_*` 计数仍能看到写

第一轮 `dd` 后的 host 计数：

```text
HOST_SEV_MMIO_R=0
HOST_SEV_MMIO_W=30
```

第二个更长窗口的 host 计数：

```text
HOST_SEV_MMIO_R=0
HOST_SEV_MMIO_W=186
```

这说明：

- 单看 host `kvm_sev_es_mmio_write` 计数，当前仍能观测到 host fallback 写
- 但它不能直接等价于“这次 NVMe `dd` 本身没有走 direct path”
- 因为 guest 侧 `pkvm_virt_mmio()` trace 已经把 `dd` 任务本身钉在 `direct_hit`

所以本轮可以给出的更稳妥判断是：

- `BOOT-013` 的旧失败签名已经不再复现
- NVMe `dd` 触发的 guest MMIO 路径已经有 direct branch 的正向证据
- host `kvm_sev_es_mmio_write` 里剩余的写来源，后续如果需要，还应单独分类

### host dmesg 未见新的失败签名

对最终 host `dmesg` 的关键字检查结果：

- 只见到开机期正常的 `DMAR/IOMMU enabled` 日志
- 未见：
  - `WARNING:`
  - `Bad address`
  - `vm_mmu_map failed`
  - `addr not in mem_range`
  - `kvm_tdp_page_fault`
  - `pkvm_pin_page`

## 结论

这轮复测可以确认：

- 当前本地 Host 内核上的 `BOOT-013` 症状已经不再复现
- protected pVM + VFIO NVMe `0000:01:00.0` 能启动到 `login:` 并完成 guest 登录
- guest 内 `nvme0n1` 能正常枚举，`dd` 直读返回码为 `0`
- guest 内 `pkvm_virt_mmio()` 观测到 `dd` 对应窗口里明确命中 direct 分支

同时也保留一个后续观察点：

- host `kvm_sev_es_mmio_write` 计数仍有残留写事件
- 这部分还不能直接当成 “NVMe MMIO 没走 direct”
- 如果后续要把整条 MMIO 调用链彻底收敛清楚，需要再单独分析这些 host write 的来源
