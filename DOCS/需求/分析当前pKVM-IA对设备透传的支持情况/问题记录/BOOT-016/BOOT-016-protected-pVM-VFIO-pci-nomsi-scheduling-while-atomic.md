# [BOOT-016] protected pVM + VFIO `pci=nomsi` 后在 KVM page fault 路径出现 `scheduling while atomic`

## 现象

- 2026-04-26 为验证 `BOOT-015`，临时使用 `GUEST_KERNEL_EXTRA=pci=nomsi` 禁用来宾侧 MSI/MSI-X。
- 本轮旧签名 `deny host BAR remap` / `raw_readl` / `general protection fault` 未再出现，guest 成功进入 `localhost login:`。
- 但 Host 日志出现新的 forbidden signature：`BUG: scheduling while atomic: crosvm_vcpu0/99825/...`。
- 当前最小影响：`T12-A1 pci=nomsi` 临时验证只能证明第一 blocker 已移开，不能标为 PASS；默认 T12 主线仍需先修 `BOOT-015`。

## 关联 GitHub Issue

- 关联 Bug：MrGeek-zrh/pkvm-x86#37
- 关联 Task：暂未创建；当前仅保留新签名与证据，若进入实际修复阶段需补 Task
- 上层 T12 Task：MrGeek-zrh/pkvm-x86#34

## 原始日志（节选）

```text
[Sun Apr 26 07:53:18 2026] BUG: scheduling while atomic: crosvm_vcpu0/99825/0x00000002
[Sun Apr 26 07:53:18 2026] CPU: 4 UID: 0 PID: 99825 Comm: crosvm_vcpu0 Tainted: G S                 6.12.0-pkvm-ia #12
[Sun Apr 26 07:53:18 2026] Call Trace:
[Sun Apr 26 07:53:18 2026]  __schedule_bug+0x64/0x80
[Sun Apr 26 07:53:18 2026]  __schedule+0x113c/0x16e0
[Sun Apr 26 07:53:18 2026]  schedule+0x29/0x130
[Sun Apr 26 07:53:18 2026]  throttle_direct_reclaim+0x1ae/0x2e0
[Sun Apr 26 07:53:18 2026]  try_to_free_pages+0xb0/0x210
[Sun Apr 26 07:53:18 2026]  __alloc_pages_noprof+0x6e6/0x1350
[Sun Apr 26 07:53:18 2026]  kvm_tdp_page_fault+0x2b4/0x400
```

第二处同轮栈显示在进入 guest mode work 处理时仍触发 scheduling while atomic：

```text
[Sun Apr 26 07:53:18 2026] BUG: scheduling while atomic: crosvm_vcpu0/99825/0x00000000
[Sun Apr 26 07:53:18 2026]  ? pkvm_vcpu_run+0x114/0x510
[Sun Apr 26 07:53:18 2026]  ? vcpu_enter_guest+0x3a1/0x1660
[Sun Apr 26 07:53:18 2026]  schedule+0x29/0x130
[Sun Apr 26 07:53:18 2026]  xfer_to_guest_mode_handle_work+0x48/0xe0
[Sun Apr 26 07:53:18 2026]  kvm_arch_vcpu_ioctl_run+0x62f/0x790
```

## 完整原始报错信息文件

- Host final dmesg：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-016/raw/20260426-t12-a1-nomsi-host-dmesg-final.log`
- Host live dmesg：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-016/raw/20260426-t12-a1-nomsi-host-dmesg-live.log`
- crosvm / guest stdout：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-016/raw/20260426-t12-a1-nomsi-action-stdout.log`
- 临时验证记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-016/raw/20260426-t12-a1-nomsi-validation-record.md`

## 触发条件 / 复现场景

- Host 内核：`6.12.0-pkvm-ia #12`
- pKVM-IA commit：`9f9531b5e36a`
- VM 类型：protected pVM
- 透传设备：NVMe `0000:01:00.0`
- 临时 guest cmdline：`root=/dev/vda1 rw pci=nomsi`
- 目的：仅用于绕过 `BOOT-015` 的 MSI-X table host read blocker。

复现命令：

```bash
cd /home/mrgeek/pkvm-x86
python3 tests/pkvm-regress/pkvm-regress.py run-shell T12-A1 \
  --vfio-dev 0000:01:00.0 \
  --artifacts-root DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts \
  -- sudo -n timeout -k 10s 180s env PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 GUEST_KERNEL_EXTRA=pci=nomsi ./scripts/run-crosvm.sh
```

## 触发路径（当前收窄）

```text
KVM_RUN ioctl
    kvm_arch_vcpu_ioctl_run()
        vcpu_enter_guest()
            pkvm_handle_exit()
                handle_ept_violation()
                    kvm_mmu_page_fault()
                        kvm_mmu_do_page_fault()
                            kvm_tdp_page_fault()
                                __kmalloc_cache_noprof()
                                    __alloc_pages_noprof()
                                        try_to_free_pages()
                                            schedule()
                                                BUG: scheduling while atomic
```

## 根因（简述）

- 根因尚未最终确认。
- 当前证据已将问题收窄到 KVM_RUN / pKVM exit 后的 TDP page fault 路径：在某个 atomic / preempt-disabled 上下文中发生了可能睡眠的内存分配或 direct reclaim。
- 该签名不同于 `BOOT-015`：它没有 `raw_readl`、没有 `pci_msix_*` 栈，也没有 `deny host BAR remap`。
- 因为这是禁用 MSI-X 后暴露出来的新唯一签名，应作为独立 Bug 保留，不应混入 `BOOT-015` 的 BAR revoke 粒度修复任务。

## 关联源码

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm.c`
  - `pkvm_handle_exit()` 进入 protected KVM exit 处理。
- `pKVM-IA/arch/x86/kvm/mmu/mmu.c`
  - `kvm_mmu_page_fault()` / `kvm_mmu_do_page_fault()`。
- `pKVM-IA/arch/x86/kvm/mmu/tdp_mmu.c`
  - `kvm_tdp_page_fault()` 触发分配路径。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - 与 `BOOT-015` 的 host EPT deny-remap 不同，本轮没有命中相关日志。

## 解决方案

- 当前先保留为 triage Bug，不立即绑定修复 Task。
- 如果后续进入实际修复，应新建独立 Task，至少回答：
  - 哪个路径使 `crosvm_vcpu0` 在 page fault 处理时保持 atomic / preempt-disabled 状态；
  - 为什么 `kvm_tdp_page_fault()` 会在该上下文触发可睡眠分配；
  - 是应提前补充 memcache / 预分配，还是应调整 pKVM exit 到 host KVM fault 处理的上下文边界。

## 验证要点

- 使用 `GUEST_KERNEL_EXTRA=pci=nomsi` 的 T12-A1 临时验证不再出现：
  - `BUG: scheduling while atomic`
  - `try_to_free_pages` 位于 `kvm_tdp_page_fault` 下方的栈
- guest 仍能进入 `login:`。
- 同轮仍不应重新出现 `BOOT-015` 旧签名：
  - `deny host BAR remap gpa=0xfe80200c`
  - `raw_readl`
  - `general protection fault`
