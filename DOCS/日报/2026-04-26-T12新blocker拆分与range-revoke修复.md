# 2026 年 4 月 26 日 — T12 新 blocker 拆分与 range revoke 修复

## 今日目标

把 4 月 24 日 `T12-A1` 首轮运行暴露的问题按项目管理规则固定下来：先保留 `raw_readl` #GP 现象和原始日志，再拆出对应 Bug / Task；同时给 `T12` 第一阶段补一条可验证的回归 harness，并推进 #36 的首版修复。

## 过程记录

### 阶段一：把 `T12-A1` 首轮失败固定成 BOOT-015 / #35

#### 现象

4 月 24 日 `T12-A1` 使用 `pKVM-IA` commit `9f9531b5e36a` 运行时，protected pVM + VFIO NVMe 没有到达 `login:`。Host 日志先命中 T12 新加的 Host BAR deny-remap，再在 `raw_readl()` 路径触发 general protection fault。

关键日志节选如下：

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

这条签名对应的问题记录是 `BOOT-015`，GitHub Bug 是 MrGeek-zrh/pkvm-x86#35。

#### 根因

地址 `0xfe80200c` 对应 `0000:01:00.0` 的 BAR0 `0xfe800000` 加 MSI-X table offset `0x2000`，再加 vector-control dword offset `0xc`。

触发路径是：

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

所以 `deny host BAR remap` 本身不是坏事，它说明 T12 的 Host BAR 保护分支命中了。真正的问题是第一阶段按整 BAR revoke，误把 MSI-X table / PBA 这类 Host/VFIO 控制面子区间也标成了 `OWNER_ID_PTDEV_MMIO`。

#### 解决

- 新增本地问题记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-015/BOOT-015-protected-pVM-VFIO-MSI-X-table-host-read-denied-raw_readl-GP.md`
- 保存完整 raw 日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-015/raw/`
- 新建 Bug：MrGeek-zrh/pkvm-x86#35
- 新建对应修复 Task：MrGeek-zrh/pkvm-x86#36
- 在上层 T12 Task MrGeek-zrh/pkvm-x86#34 comment 中同步当前 blocker 已从泛化 T12 实现推进到 #35 / #36

#### 结果

这一步完成了“先保留症状，再推进修复”：#35 只记录 `raw_readl` #GP 签名和证据，#36 专门承载修复动作，避免把新签名继续混在 `B5-2`、旧 T12 设计或 4 月 24 日日报里。

### 阶段二：用 `pci=nomsi` 临时验证 MSI-X 归因，又暴露 BOOT-016

#### 现象

为了确认 #35 是否和 MSI-X 路径相关，临时给 guest 增加 `GUEST_KERNEL_EXTRA=pci=nomsi`。这轮旧的 `deny host BAR remap gpa=0xfe80200c` / `raw_readl` / `general protection fault` 没再出现，guest 进入 `localhost login:`，但 Host 日志出现新的 forbidden signature：

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

#### 根因判断

这条新签名和 #35 不同：没有 `raw_readl`、没有 `pci_msix_*` 栈，也没有 `deny host BAR remap`。当前只能说明：在临时绕过 MSI-X blocker 后，Host 又暴露了 KVM_RUN / pKVM exit 后 TDP page fault 路径里的 `scheduling while atomic` 问题。

#### 解决

- 新增本地问题记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-016/BOOT-016-protected-pVM-VFIO-pci-nomsi-scheduling-while-atomic.md`
- 保存完整 raw 日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-016/raw/`
- 新建 Bug：MrGeek-zrh/pkvm-x86#37
- 不给 #37 立即建修复 Task；当前只是 triage，不能抢占 #35 / #36 的 B0 修复主线

#### 结果

`pci=nomsi` 只证明 #35 的第一 blocker 与 MSI-X table Host 访问有关，不能作为正式修复。`T12-A1` 也不能因为 guest 到了 login 就标成通过，因为同轮已经出现 #37 的新 forbidden signature。

### 阶段三：补 T12 回归 harness 和临时验证入口

#### 做了什么

把 4 月 24 日晚上的手工运行方式整理成可复用的本地回归入口：

- 回归工具入口：`tests/pkvm-regress/pkvm-regress.py`
- 工具说明：`tests/pkvm-regress/README.md`
- 测试设计：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/10-T12-第一阶段测试用例设计.md`
- `run-crosvm.sh` 新增 `GUEST_KERNEL_EXTRA`，用于显式追加 guest kernel cmdline 参数；`pci=nomsi` 只走这个 opt-in 入口
- `.gitignore` 增加 Python cache 忽略规则，避免回归工具运行后污染提交

工具当前可以做几件关键事：

- 记录 artifact 目录、`status.json`、`result.json` 和 stdout/stderr。
- 在风险动作前启动 live `dmesg` / `journalctl` collector。
- 扫描 forbidden signature，避免只凭 guest 是否登录判断通过。
- `recover-runs` 把中断遗留的 `RUNNING` 状态归档成 `CRASHED_OR_INTERRUPTED`。

#### 结果

后续 T12 运行证据不再散落在终端里，而是统一进入 `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/`。

### 阶段四：实现 #36 首版 range revoke 修复

#### 修复方案

#36 的修复方向是：T12 第一阶段不能退回到 Host 可访问整个 assigned BAR；但也不能整 BAR revoke 误伤 MSI-X table / PBA。于是把 Host EPT annotation 范围从“整个 boot manifest BAR”细化到 guest `DIRECT_BAR` 数据面范围。

新的主线是：

```text
pkvm_set_ptdev_mmio_metadata()
    validate metadata against boot manifest BAR
    cache DIRECT_BAR ranges

pkvm_revoke_ptdev_bars_locked()
    for each validated DIRECT_BAR range
        compute range_hpa = boot BAR base + bar_offset
        pkvm_host_ept_annotate_mmio_owner(range_hpa, size, OWNER_ID_PTDEV_MMIO)
        pkvm_record_ptdev_mmio_range_locked(range_hpa, size)

pkvm_publish_ptdev_mmio_contract_locked()
    require touched DIRECT_BAR ranges ready
    pkvm_update_vm_mmio_allowlist(vm, &ptdev->mmio_metadata)

pkvm_restore_ptdev_bars_locked()
    restore only touched DIRECT_BAR ranges
```

这样 MSI-X table / PBA 没出现在 crosvm 的 `DIRECT_BAR` metadata 里，就暂时保留给 Host/VFIO 控制面；真正 guest 数据面范围仍然会被 Host deny-remap 保护。

#### 实现

- `pKVM-IA` commit `19c718a05548`：显式化 `ptdev` MMIO owner ID 编码。
- `pKVM-IA` commit `a1b02bd8c012`：按 `DIRECT_BAR` range 细化 Host BAR revoke。
- 关键文件：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- 关键文件：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
- 关键文件：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h`
- 本地修复计划：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/11-T12-MSI-X-table-host-control-range修复计划.md`

#### 验证

当天完成的是源码级和工具级验证，不是运行验证：

```text
git -C pKVM-IA diff --check -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c arch/x86/kvm/vmx/pkvm/hyp/ptdev.h
pKVM-IA/scripts/checkpatch.pl --no-tree --strict  # against ptdev diff, clean
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/pkvm-regress/tests -v
```

另外新增 `tests/pkvm-regress/tests/test_kernel_source_contract.py`，防止后续实现退回到整 BAR revoke / restore。

#### 结果

#36 的本地首版实现已经落到 `pKVM-IA` topic branch。`pkvm-x86` 同步了实施文档、测试框架和 submodule 指针，但这天还没有执行完整内核构建，也没有完成实机 `T12-A1` runtime 复测。

### 阶段五：同步分支命名和后续 hardening 边界

#### 做了什么

- `pKVM-IA` 当前实现分支从 `codex/t12-msix-host-control-range` 重命名为 `t12-msix-host-control-range`。
- 旧 checkpoint 分支 `t12-mmio-donate-phase1` 已确认是当前分支祖先并删除，避免后续误选旧分支。
- 后续 P2 hardening 拆到 MrGeek-zrh/pkvm-x86#38：为 `DIRECT_BAR` metadata 增加 MSI-X/PBA reserved range 语义校验。

#### 结果

当天主线保持清楚：#36 只修 #35 的第一 blocker，即“整 BAR revoke 误伤 MSI-X table / PBA”；不把 #37 和 #38 一起塞进同一个 PR 目标里。

## 今日未完成

- #36 还没有实机运行验证：`T12-G2`、`T12-G1`、默认 `T12-A1`、`T12-B1`、`T12-R1` 都需要部署 `pKVM-IA` commit `a1b02bd8c012` 后再跑。
- #35 还不能关闭：默认 `T12-A1` 尚未在修复后证明进入 `login:` 且不再出现 `raw_readl` #GP。
- #37 只完成问题记录和 GitHub Bug，尚未建修复 Task。
- #38 只是拆出后续 hardening 边界，不作为 #36 的第一轮前置条件。
- `pKVM-IA` 修复分支还没有对应 GitHub PR。

## 明日计划

- P0：部署 `pKVM-IA` commit `a1b02bd8c012` 后运行默认 `T12-A1`，确认 #35 是否消失。
- P0：补跑 `T12-G2` / `T12-G1` / `T12-G3` 非破坏性回归，确认 range revoke 没破坏 baseline。
- P1：检查 `T12-B1` / `T12-R1` 是否已有足够判据；如果没有，先补 trace 或状态探针，不要只靠 guest 登录判断通过。
- P1：根据运行结果决定是否推进 `pKVM-IA` draft PR，以及是否更新 `pkvm-x86` superproject 集成快照。

## 关联 GitHub

- 上层 T12 Task：MrGeek-zrh/pkvm-x86#34
- 新 blocker Bug：MrGeek-zrh/pkvm-x86#35
- 当前修复 Task：MrGeek-zrh/pkvm-x86#36
- 后续新签名 Bug：MrGeek-zrh/pkvm-x86#37
- 后续 hardening Task：MrGeek-zrh/pkvm-x86#38

## 关联 commit

### `pkvm-x86`

| commit | 作用 |
|---|---|
| `1641b81` | 补写近期 T12 日报，固定 4 月 24 日第一阶段实现与验证记录 |
| `26f402b` | 新增 T12 回归测试框架 |
| `fa8efba` | 支持追加 guest kernel cmdline 参数 |
| `efc2ccb` | 记录 T12 测试结果与 MSI-X blocker |
| `19e0631` | 忽略 Python cache 文件 |
| `6143d75` | 同步 T12 range revoke 测试与文档 |
| `40de78f` | 同步 T12 分支命名 |

### `pKVM-IA`

| commit | 作用 |
|---|---|
| `19c718a05548` | 显式化 `ptdev` MMIO owner ID 编码 |
| `a1b02bd8c012` | 按 `DIRECT_BAR` range 细化 Host BAR revoke |

## 关联本地文档

- BOOT-015 问题记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-015/BOOT-015-protected-pVM-VFIO-MSI-X-table-host-read-denied-raw_readl-GP.md`
- BOOT-016 问题记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-016/BOOT-016-protected-pVM-VFIO-pci-nomsi-scheduling-while-atomic.md`
- `pci=nomsi` 临时验证：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t12-a1-nomsi-temporary-validation-20260426-075239.md`
- #36 修复计划：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/11-T12-MSI-X-table-host-control-range修复计划.md`
- #38 hardening 记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/12-T12-DIRECT_BAR-metadata-reserved-range-语义校验.md`
- T12 测试设计：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/10-T12-第一阶段测试用例设计.md`
- T12 回归工具：`tests/pkvm-regress/README.md`
