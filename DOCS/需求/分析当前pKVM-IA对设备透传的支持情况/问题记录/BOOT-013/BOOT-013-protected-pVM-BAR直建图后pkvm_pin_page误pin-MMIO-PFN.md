# [BOOT-013] protected pVM BAR 直建图后 `pkvm_pin_page()` 误 pin MMIO PFN

## 现象

- 2026-04-15 在安装并重启到包含当前 B5-2 Guest EPT 边界改动的 Host 内核后，重新运行 protected pVM + VFIO NVMe `0000:01:00.0` 样例。
- `BOOT-012` 中的旧签名：
  - `host_initiate_donation: addr not in mem_range`
  - `__pkvm_host_donate_guest failed`
  - `vm_mmu_map failed`
  在本轮日志中没有再出现。
- 但 protected pVM 没有启动到 `login:`，`crosvm` 侧仍然退出：

```text
[2026-04-15T10:50:32.365903391+00:00 ERROR crosvm::crosvm::sys::linux::vcpu] vcpu hit unknown error: Bad address (os error 14)
[2026-04-15T10:50:32.366184594+00:00 INFO  crosvm::crosvm::sys::linux] vcpu crashed
```

- 同轮 host `dmesg` 出现新的关键签名：

```text
[Wed Apr 15 10:50:32 2026] WARNING: CPU: 18 PID: 4255 at arch/x86/kvm/mmu/mmu.c:4775 kvm_tdp_page_fault+0x3f0/0x420
```

- 回溯路径显示当前失败点已经前移到 host-high 的 page fault 后处理：

```text
kvm_tdp_page_fault
    kvm_mmu_do_page_fault
        kvm_mmu_page_fault
            handle_ept_violation
                pkvm_handle_exit
                    vcpu_enter_guest
```

- 当前最小影响：
  - B5-2 的 hyp 侧 BAR HPA direct leaf 分流已经让旧的 BAR HPA donation 报错消失；
  - 但 host-high 在 direct BAR leaf 建图成功后仍把该 PFN 当普通 RAM 去 pin；
  - 于是 `pkvm_pin_page()` 对 MMIO PFN 触发 `WARN_ON_ONCE(!page)`，并向上返回 `-EFAULT`。

## 根因（简述）

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c` 中，protected VM 的 `pkvm_page_fault()` 当前流程是：

```text
pkvm_page_fault()
    kvm_faultin_pfn(...)
    pkvm_hypercall(vm_mmu_map, gpa, hpa, size, ...)
    if (!r && pkvm_is_protected_vcpu(vcpu))
        pkvm_pin_page(vcpu->kvm, fault)
```

- 对普通 RAM，这个流程是合理的：
  - hyp 侧完成 Guest EPT leaf 建图；
  - host-high 侧把对应 host page pin 住；
  - 后续 VM 生命周期内避免 host 页被回收或迁移。
- 但 B5-2 新增了另一类合法成功路径：
  - 如果 `hpa` 命中“当前 VM 已 attach 且 boot-time manifest 记录的 memory BAR”，hyp 侧会直接安装 Guest EPT BAR leaf；
  - 这类 `hpa` 是 PCI BAR/MMIO 物理地址，不是普通 host RAM。
- 因此 `pkvm_pin_page()` 中这句会失败：

```text
page = kvm_pfn_to_refcounted_page(fault->pfn);
```

- 对 BAR/MMIO PFN，`kvm_pfn_to_refcounted_page()` 不会返回 refcounted `struct page`，于是触发：

```text
if (WARN_ON_ONCE(!page)) {
    kfree(ppage);
    return -EFAULT;
}
```

- 最终 `-EFAULT` 向上传到 `KVM_RUN`，用户态 `crosvm` 看到 `Bad address (os error 14)`。

## 解决方案

- 这条问题应作为 `BOOT-012` 修复后暴露的新签名独立记录，不能继续混在 `BOOT-012` 中。
- 修复方向应收敛到 host-high 的 `pkvm_page_fault()` 后处理：
  - 普通 RAM PFN：继续走现有 `pkvm_pin_page()`；
  - direct BAR / MMIO PFN：不能走普通 RAM pin 语义；
  - direct BAR / MMIO PFN 的安全边界应由 hyp 侧 `vm_mmu_map()` 已完成的 BAR 范围与 VM attached 设备校验承担。
- 一种最小修复方向：
  - 在 `pkvm_page_fault()` 中区分 refcounted RAM PFN 和 MMIO PFN；
  - 对 `kvm_pfn_to_refcounted_page(fault->pfn)` 能返回 `struct page` 的路径继续 pin；
  - 对不能返回 `struct page` 的路径，不再 `WARN`，而是只允许在 `vm_mmu_map` 已经成功返回后跳过 pin。
- 更完整的修复方向：
  - host-high 明确引入“本次映射是否为 direct MMIO/BAR”的判断或返回语义；
  - 避免仅靠“没有 refcounted page”来隐式表示 MMIO；
  - 但这会涉及更多接口或状态同步，当前可以先评估是否有必要。

## 验证要点

- 重启到修复后的 Host 内核后，重新运行：

```bash
sudo -n env -u DEBUG PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

- host `dmesg` 不应再出现：
  - `WARNING: ... arch/x86/kvm/mmu/mmu.c:4775 kvm_tdp_page_fault`
  - `host_initiate_donation: addr not in mem_range`
  - `__pkvm_host_donate_guest failed`
  - `vm_mmu_map failed`
- protected pVM 应至少启动到 `login:`。
- 如果启动成功，需要继续做 guest 内验证：
  - `ls /dev/nvme*n1`
  - `dd if=/dev/nvme0n1 of=/dev/null bs=4096 count=64 iflag=direct status=none`
  - 确认 `DD_RC=0`
- 同时继续保留 host fallback 计数：
  - `kvm_sev_es_mmio_read`
  - `kvm_sev_es_mmio_write`
  用于确认 MMIO 是否仍大量落回 host fallback。

## 原始日志（节选）

```text
[2026-04-15T10:50:32.365903391+00:00 ERROR crosvm::crosvm::sys::linux::vcpu] vcpu hit unknown error: Bad address (os error 14)
[2026-04-15T10:50:32.366184594+00:00 INFO  crosvm::crosvm::sys::linux] vcpu crashed
```

```text
[Wed Apr 15 10:50:32 2026] WARNING: CPU: 18 PID: 4255 at arch/x86/kvm/mmu/mmu.c:4775 kvm_tdp_page_fault+0x3f0/0x420
[Wed Apr 15 10:50:32 2026] CPU: 18 UID: 0 PID: 4255 Comm: crosvm_vcpu0 Tainted: G S                 6.12.0-pkvm-ia #8
[Wed Apr 15 10:50:32 2026] RIP: 0010:kvm_tdp_page_fault+0x3f0/0x420
[Wed Apr 15 10:50:32 2026] Call Trace:
[Wed Apr 15 10:50:32 2026]  kvm_mmu_do_page_fault+0x24c/0x290
[Wed Apr 15 10:50:32 2026]  kvm_mmu_page_fault+0x92/0x890
[Wed Apr 15 10:50:32 2026]  handle_ept_violation+0x8a/0x1a0
[Wed Apr 15 10:50:32 2026]  pkvm_handle_exit+0x1e1/0x410
[Wed Apr 15 10:50:32 2026]  vcpu_enter_guest+0x3a1/0x1660
```

host fallback 计数仍然很多：

```text
HOST_SEV_MMIO_R=279
HOST_SEV_MMIO_W=2885
```

## 完整原始报错信息文件

- 本轮汇总记录：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-protected-vfio-direct-mmio-dd-rerun-0100-20260415.md`
- crosvm 串口/PTTY 原始日志：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-crosvm-protected-vfio-direct-mmio-dd-0100-20260415-104859.pty.log`
- host dmesg 原始日志：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-host-dmesg-protected-vfio-direct-mmio-dd-0100-20260415-104859.log`
- host fallback trace 计数：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-host-trace-counts-protected-vfio-direct-mmio-dd-0100-20260415-104859.log`
- 设备绑定与恢复日志：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-bind-and-host-trace-setup-0100-20260415-104859.log`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-restore-0100-to-nvme-20260415-104859.log`

## 触发条件/复现场景

- Host 内核：`Linux ubuntu-vm 6.12.0-pkvm-ia #8 SMP PREEMPT_DYNAMIC Wed Apr 15 09:37:32 UTC 2026`
- VM 类型：protected pVM
- 透传设备：NVMe `0000:01:00.0`
- 设备 BAR：
  - `BAR0 = 0xfe800000`
  - `size = 16K`
- 当前前提：
  - `crosvm` boot-time metadata 提交已补齐；
  - `crosvm` metadata ABI 已对齐；
  - `pKVM-IA` hyp 侧已补 direct BAR leaf 建图与 BAR miss reject；
  - 设备启动前绑定到 `vfio-pci`。

最小复现命令：

```bash
sudo -n env -u DEBUG PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

## 触发路径（常见调用链）

```text
guest 访问 NVMe BAR GPA
    host KVM 缺页路径解析出 BAR HPA
        pkvm_page_fault(...)                                  (pKVM-IA/arch/x86/kvm/mmu/mmu.c)
            pkvm_hypercall(vm_mmu_map, gpa, hpa, size, ...)
                pkvm_vm_mmu_map(...)                          (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
                    // B5-2 后，命中 attached BAR 可直接建 Guest EPT leaf
                    pgtable_map_leaf(...)
            pkvm_pin_page(vcpu->kvm, fault)
                kvm_pfn_to_refcounted_page(fault->pfn)
                    // BAR/MMIO PFN 不是普通 RAM refcounted page
                    return NULL
                WARN_ON_ONCE(!page)
                return -EFAULT
        KVM_RUN 返回 -EFAULT
    crosvm 打印 Bad address
```

## 关联源码

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c`
  - `pkvm_pin_page()` 当前只支持 refcounted RAM page
  - `pkvm_page_fault()` 当前在 `vm_mmu_map` 成功后无条件对 protected VM 调 `pkvm_pin_page()`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - B5-2 后 `pkvm_vm_mmu_map()` 已允许 attached BAR HPA direct leaf 建图
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - B5-2 后用于判断 HPA 是否命中当前 VM attached 设备的 boot-time BAR

## 备注

- 这条问题是 `BOOT-012` 修复后暴露出来的新 blocker：
  - `BOOT-012` 说明 hyp 侧不能把 BAR HPA 当 RAM donation；
  - `BOOT-013` 说明 host-high 侧也不能把 BAR/MMIO PFN 当普通 RAM page pin。
- 因为签名、代码路径和修复位置都不同，应单独跟踪。

## 2026-04-15 本地修复后的再次验证

在当前本地 Host 内核重新编译、安装并重启后，使用同一条样例再次验证：

```bash
sudo -n env -u DEBUG PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

对应原始记录：

- 汇总记录：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-protected-vfio-direct-mmio-dd-rerun-after-boot013-fix-0100-20260415.md`
- crosvm 串口/PTTY：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-crosvm-protected-vfio-direct-mmio-dd-0100-20260415-130256.pty.log`
- host dmesg：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-host-dmesg-final-0100-20260415-130256.log`

本轮结果：

- protected pVM 已成功启动到 `login:`，并可登录 `ubuntu`
- guest 内 `nvme0n1` 已正常枚举，`readlink -f /sys/block/nvme0n1/device` 指向 `0000:01:00.0`
- guest 内两轮 `dd` 都成功：
  - `DD_RC=0`
  - `DD_BIG_RC=0`
- guest 内对 `pkvm_virt_mmio()` 打点后，`dd` 窗口里观测到：

```text
GUEST_DIRECT=128
GUEST_FALLBACK=2
```

- trace 尾部显示：
  - `dd-*` 命中的是 `direct_hit`
  - 两条 `fallback_hit` 来自 `sleep-*`
- 最终 host `dmesg` 未再出现：
  - `Bad address (os error 14)`
  - `WARNING: ... kvm_tdp_page_fault`
  - `pkvm_pin_page`

因此至少对当前这份本地 Host 内核构建而言：

- `BOOT-013` 的旧签名已经不再复现
- 当前 protected pVM + VFIO NVMe 正向样例已重新恢复到“可启动、可登录、可读盘”

仍需保留的一个后续观察点：

- host `kvm_sev_es_mmio_write` 计数里仍能看到写事件
- 但 guest 侧 `pkvm_virt_mmio()` trace 已经给出 `dd` 命中 direct 分支的正向证据
- 因此这部分 host write 的来源应作为后续独立分析点，不应再与 `BOOT-013` 旧签名混为一谈
