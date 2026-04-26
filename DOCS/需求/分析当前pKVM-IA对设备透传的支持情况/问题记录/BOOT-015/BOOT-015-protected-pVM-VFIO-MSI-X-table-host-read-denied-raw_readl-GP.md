# [BOOT-015] protected pVM + VFIO 启用 MSI-X 时 Host 读 MSI-X table 被拒绝并在 `raw_readl` #GP

## 现象

- 2026-04-24 执行 `T12-A1 protected VFIO attach 后 BAR revoke` 时，protected VM + VFIO `0000:01:00.0` 未到达 `login:`。
- Host 日志先出现 `pkvm: deny host BAR remap gpa=0xfe80200c`，随后 `crosvm_vcpu0` 在 host kernel `raw_readl()` 触发 `general protection fault`。
- `0xfe80200c` 对应 `0000:01:00.0` 的 BAR0 `0xfe800000` + MSI-X table offset `0x2000` + vector-control offset `0xc`。
- 2026-04-26 使用 `GUEST_KERNEL_EXTRA=pci=nomsi` 临时禁用来宾侧 MSI/MSI-X 后，旧签名未再出现，guest 进入 `login:`，说明第一阻塞点与 MSI-X table host 访问有关。
- 当前最小影响：默认 protected pVM + VFIO NVMe 主线仍无法判定 T12-A1 通过；临时 `pci=nomsi` 只用于定位，不是最终修复。

## 关联 GitHub Issue

- 关联 Bug：MrGeek-zrh/pkvm-x86#35
- 关联 Task：MrGeek-zrh/pkvm-x86#36
- 上层 T12 Task：MrGeek-zrh/pkvm-x86#34

## 原始日志（节选）

```text
[Fri Apr 24 15:58:28 2026] pkvm: deny host BAR remap gpa=0xfe80200c owner_id=1048575 raw_pte=0xfffff000
[Fri Apr 24 15:58:28 2026] pkvm: handle host ept violation failed
[Fri Apr 24 15:58:28 2026] Oops: general protection fault, maybe for address 0xff402836c095900c: 0000 [#1] PREEMPT SMP NOPTI
[Fri Apr 24 15:58:28 2026] CPU: 6 UID: 0 PID: 3781 Comm: crosvm_vcpu0 Tainted: G S                 6.12.0-pkvm-ia #12
[Fri Apr 24 15:58:28 2026] RIP: 0010:raw_readl+0x0/0x10
[Fri Apr 24 15:58:28 2026]  ? pci_msix_vec_count+0x37/0x70
[Fri Apr 24 15:58:28 2026]  ? msix_prepare_msi_desc+0x6b/0xa0
[Fri Apr 24 15:58:28 2026]  msix_setup_msi_descs+0xea/0x140
[Fri Apr 24 15:58:28 2026]  __pci_enable_msix_range+0x37c/0x580
[Fri Apr 24 15:58:28 2026]  vfio_pci_set_msi_trigger+0x84/0x260 [vfio_pci_core]
```

## 完整原始报错信息文件

- Host final dmesg：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-015/raw/20260424-t12-a1-host-dmesg-final.log`
- Host live dmesg：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-015/raw/20260424-t12-a1-host-dmesg-live.log`
- crosvm / guest stdout：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-015/raw/20260424-t12-a1-action-stdout.log`
- 运行记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-015/raw/20260424-t12-phase1-run-record.md`
- 对照临时验证：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-016/raw/20260426-t12-a1-nomsi-validation-record.md`

## 触发条件 / 复现场景

- Host 内核：`6.12.0-pkvm-ia #12`
- pKVM-IA commit：`9f9531b5e36a`
- VM 类型：protected pVM
- 透传设备：NVMe `0000:01:00.0`
- 设备 BAR：BAR0 `0xfe800000-0xfe803fff`
- MSI-X table：BAR0 offset `0x2000`
- PBA：BAR0 offset `0x3000`
- 默认 guest cmdline：`root=/dev/vda1 rw`

复现命令：

```bash
cd /home/mrgeek/pkvm-x86
python3 tests/pkvm-regress/pkvm-regress.py run-shell T12-A1 \
  --vfio-dev 0000:01:00.0 \
  --artifacts-root DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts \
  -- sudo -n env PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

临时对照命令：

```bash
cd /home/mrgeek/pkvm-x86
python3 tests/pkvm-regress/pkvm-regress.py run-shell T12-A1 \
  --vfio-dev 0000:01:00.0 \
  --artifacts-root DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts \
  -- sudo -n timeout -k 10s 180s env PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 GUEST_KERNEL_EXTRA=pci=nomsi ./scripts/run-crosvm.sh
```

## 触发路径（常见回溯）

```text
guest 启用 MSI-X
    crosvm 写 MSI-X control
        crosvm enable_msix()
            VFIO_DEVICE_SET_IRQS
                vfio_pci_set_msi_trigger()
                    pci_alloc_irq_vectors()
                        __pci_enable_msix_range()
                            msix_setup_msi_descs()
                                msix_prepare_msi_desc()
                                    readl(BAR0 + 0x200c)
                                        pKVM Host EPT violation
                                            handle_host_ept_violation()
                                                OWNER_ID_PTDEV_MMIO -> deny host BAR remap
                                                kvm_inject_gp(vcpu, 0)
                                                    Host raw_readl #GP / Oops
```

## 根因（简述）

- 当前 T12 第一阶段在 `pkvm_attach_ptdev()` 中按 boot manifest 对 managed BAR 做整 BAR Host EPT annotation / revoke。
- 该策略会把 BAR0 内的 MSI-X table / PBA 一并标成 `OWNER_ID_PTDEV_MMIO`，导致 host kernel 的 VFIO MSI-X 控制路径无法读取 MSI-X table。
- crosvm 在 guest direct mmap / ptdev MMIO metadata 侧已经通过 `remove_bar_mmap_msix()` 排除了 MSI-X table / PBA；但 pKVM hyp 侧 revoke 仍按整 BAR 执行，Host 控制面子区间没有被保留。
- 因此 `deny host BAR remap` 本身是保护逻辑生效；错误在于被拒绝的是合法 VFIO host 控制路径，而不是恶意或测试性的 Host BAR touch。

## 关联源码

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_revoke_ptdev_bars_locked()` 当前按整 BAR 调 `pkvm_host_ept_annotate_mmio_owner()`。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - `handle_host_ept_violation()` 命中 `OWNER_ID_PTDEV_MMIO` 后打印 `deny host BAR remap` 并返回 `-EPERM`。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/vmexit.c`
  - `handle_host_ept_violation()` 失败后对 host 注入 #GP。
- `pKVM-IA/drivers/pci/msi/msi.c`
  - `msix_prepare_msi_desc()` 读取 MSI-X table vector control。
- `pKVM-IA/drivers/vfio/pci/vfio_pci_intrs.c`
  - `vfio_pci_set_msi_trigger()` 进入 MSI-X enable。
- `crosvm/devices/src/pci/vfio_pci.rs`
  - `remove_bar_mmap_msix()` 已在 guest mmap / metadata 侧排除 MSI-X table / PBA。

## 解决方案

- 保留本问题为独立 Bug，不覆盖 `BOOT-012` / `BOOT-013` 等旧签名历史。
- 新增专门 Task：将 T12 第一阶段 Host BAR revoke 从“整 BAR”收敛为“只 revoke guest DIRECT_BAR 数据面范围”，显式保留 MSI-X table / PBA 等 VFIO host 控制面子区间。
- 第一轮修复只处理当前已证实的 MSI-X table / PBA host 控制面，不扩展到 hotplug、migration、reset framework 或复杂多设备 group 原子切换。

## 验证要点

- 默认 protected pVM + VFIO `T12-A1` 不再出现：
  - `pkvm: deny host BAR remap gpa=0xfe80200c`
  - `raw_readl`
  - `general protection fault`
- 默认 guest cmdline 不加 `pci=nomsi` 时，guest 能进入 `login:`。
- `T12-A2a` 的 Host BAR deny-remap 语义仍保留：Host 访问真正 assigned DIRECT_BAR 数据面范围时仍应 deny。
- `T12-B1` guest DIRECT_BAR / NVMe 只读 I/O 继续可用。
- `T12-R1` detach / teardown 后 Host BAR 可见性按 touched range 正确恢复。
