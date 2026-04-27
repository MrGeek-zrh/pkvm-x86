# pKVM-IA 设备透传工作交接：问题时间线与解决方法

> 范围：本文按时间线梳理这段时间围绕 `pKVM-IA` protected pVM 设备透传推进过的主要问题、根因、解决方法、验证状态和后续入口。重点是 `pKVM-IA` 内核实现；必要时补充 `crosvm` 配套改动，因为多个问题的触发面在 userspace / host KVM / hyp / guest 之间跨层。

## 当前总状态

- 主线目标：让 protected pVM 在 `NoIommu`、单 VFIO PCI NVMe、静态 attach 场景下具备可验证的设备透传能力，并逐步收口 DMA mirror、Guest EPT BAR 建图、guest direct BAR MMIO、Host BAR 访问权、teardown 生命周期。
- 已闭环的主要问题：早期 `BOOT-001` jump_label / return thunk panic、`BOOT-002` pvIOMMU SRTP / DMAR panic、`RUN-001` CPUID/fpstate 启动失败、旧 `donate/refcount`、`BOOT-007` vCPU `EFAULT`、`BOOT-008` DMAR `PTE Read access is not set`、`BOOT-009` `copy_gpa` 写 fault、`BOOT-012` BAR HPA 误入 donation、`BOOT-013` MMIO PFN 误 pin、`T4/BOOT-014` 第一版 teardown DMA quiesce。
- 当前主线：`B5-3 / T12` assigned BAR 的 Host CPU 访问权收口。`pKVM-IA` 当前验证点为 `a1b02bd8c012`，Host 内核为 `6.12.0-pkvm-ia #13`。本轮 `T12-A1` 与非破坏性回归通过；`T12-A2b` 尚未执行。
- 当前开放 follow-up：`T5` 首次 attach / prepopulate、`T6` remove-path 与失败回滚、`T7` 端到端回归、`T8` T2/T3 review follow-up、`BOOT-011` manifest reject 后 `vfio group busy`。

## 关键参考入口

### 总控与进度

- GitHub Epic：MrGeek-zrh/pkvm-x86#1
- 当前主线 Task：MrGeek-zrh/pkvm-x86#34
- 总览看板：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/00-总览与进展看板.md`
- 当前进度：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/当前进度.md`
- Issue / PR 协作流：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/08-GitHub-Issue-PR-协作流.md`
- 手工验证入口：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/09-run-crosvm-交互式使用方式.md`
- T12 测试设计：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/10-T12-第一阶段测试用例设计.md`

### 方案与 ARM ref 文档

- 主方案：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/pVM设备透传设计方案.md`
- 第一阶段旧实现草案：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/pVM透传设备支持-实现方案.md`
- ARM 参考源：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-参考源.md`
- ARM 到 x86 映射：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-到-x86-设计映射表.md`
- ARM BAR / MMIO donate：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-设备BAR-MMIO-donate机制总结.md`
- ARM 设备身份校验：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-设备身份校验方案（从抽象到具体）.md`
- ARM `MMIO_GUARD` 与 stage-2 abort：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-MMIO_GUARD与stage-2-abort路径讲解.md`

### 源码背景文档

- donate / Host EPT violation 调用链：`DOCS/分析文档/pkvm-x86-pVM内存保护关键调用链-donate与Host-EPT-violation.md`
- IOMMU 管理流程：`DOCS/分析文档/pkvm-x86-IOMMU管理流程-Shadow-vs-PVIOMMU.md`
- pKVM Kconfig / 构建脚本：`DOCS/pKVM-IA-docs/PKVM-Kconfig.md`、`DOCS/pKVM-IA-docs/build-host-kernel.sh`、`DOCS/pKVM-IA-docs/build-crosvm.sh`

## 时间线


### 2026-02-02：BOOT-001，合并 pKVM-IA 热补丁后 early boot panic（jump_label / return thunk）

**问题 / 现象**

- 基于 `intel-staging/pKVM-IA` 的 `pvVMCS-POC-v6.12` 分支合入 pKVM-IA 热补丁后，Host 内核早期启动 panic。
- 关键日志包括：

```text
Unpatched return thunk in use. This should not happen!
jump_label: Fatal kernel bug, unexpected op at restore_fpregs_from_fpstate__pkvm+0x13 ... (eb 41 ... != 66 90 ...) size:2 type:1
kernel BUG at arch/x86/kernel/jump_label.c:73!
Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
```

**根因**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/Makefile` 里 `*.pkvm.o` 是通过自定义 `$(obj)/%.pkvm.o` 规则构建的。
- Linux x86 常规 `%.o` 构建规则会设置 `objtool-enabled`，从而让 objtool 处理 jump_label hack 位点、return thunk / retpoline 等元数据。
- 自定义 `%.pkvm.o` 规则没有匹配常规 `%.o` 规则，导致 `*.pkvm.o` 没有走 objtool；运行时 static key / jump_label patch 校验时读到 `eb xx` 短跳，而不是期望的 NOP（如 `66 90`），因此 `__jump_label_patch()` 触发 `BUG()`。

**解决方法**

- 在 hyp Makefile 里为自定义 `$(obj)/%.pkvm.o` 规则显式启用 objtool：

```make
$(obj)/%.pkvm.o: private objtool-enabled := y
```

- 这样 `*.pkvm.o` 也会参与 x86 boot-time patching 所需的 objtool 预处理，不再在 `restore_fpregs_from_fpstate__pkvm` 等符号附近留下未处理的 jump_label / thunk 位点。

**关键提交 / 文档**

- `pKVM-IA` commit `df87ac44fb7b`：`修复合并pKVM-IA热补丁失败导致的panic问题`
- `pkvm-x86` commit `866e8a6`：记录 `pvVMCS-POC-v6.12` 分支编译启动 panic 的修复与文档。

**验证要点**

- 重新编译后，`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.o` 中 `restore_fpregs_from_fpstate__pkvm+0x13` 附近应为 NOP，不应再是短跳。
- Host 启动日志不再出现 `Unpatched return thunk in use`、`jump_label: Fatal kernel bug`、`__jump_label_patch` panic。

**关键源码**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/Makefile`
- `pKVM-IA/arch/x86/kvm/pkvm/fpu/xstate.c`
  - `restore_fpregs_from_fpstate__pkvm` 所在的 hyp FPU/xstate 构建对象

**参考文档**

- `DOCS/问题清单/问题清单.md`
- `DOCS/pKVM-IA-docs/README.md`

### 2026-02-03：BOOT-002，pKVM + pvIOMMU 初始化 SRTP 超时导致 DMAR panic

**问题 / 现象**

- 修复 BOOT-001 后，启用 pKVM + Intel IOMMU + pvIOMMU 时，在 `intel_iommu_init()` 阶段出现早期 panic：

```text
pkvm: iommu0: SRTP request ...
pkvm: handle_gcmd_srtp: iommu0 failed to activate(err=-12)
pkvm-debug: IOMMU_WAIT_OP timeout: iommu0 off=0x1c sts=0x7000000 ...
Kernel panic - not syncing: DMAR hardware is malfunctioning
```

**根因**

- pKVM 启用后，IOMMU 初始化时序被改道到 `vmx_pkvm_init()` 中：先 deprivilege host CPUs，再由 pKVM 驱动 Intel IOMMU 初始化。
- Host 写 `RTADDR` 并通过 `GCMD.SRTP` 请求设置 root table 后，pKVM 在 VM exit/hypercall 路径里进入 `handle_gcmd_srtp()` -> `activate_iommu()`。
- `activate_iommu()` 需要初始化 Queued Invalidation，并为 `qi->desc` 分配 8KB（order=1）。
- 在 `CONFIG_PKVM_INTEL_PVIOMMU=y` 下，`iommu_pool` 没有按 shadow IOMMU 路线预留/初始化，但 `initialize_qi()` 仍然从该 pool 分配，导致 `iommu_zalloc_pages()` 返回 `-ENOMEM`。
- pKVM 没有成功置位虚拟 `GSTS.RTPS`，Host 侧 `IOMMU_WAIT_OP()` 一直等不到 RTPS，最终按 `DMAR hardware is malfunctioning` panic。

**解决方法**

- 当时采用的可启动方案是关闭 pvIOMMU，走 shadow IOMMU 路线：`CONFIG_PKVM_INTEL_PVIOMMU=n`。
- `pKVM-IA` 中补充 IOMMU/SRTP/QI 相关诊断日志，用于确认失败点是 `initialize_qi()` 分配失败。
- `pkvm-x86` 固化一份“验证过可成功编译/启动”的 Host config，作为后续设备透传实验基线。

**关键提交 / 文档**

- `pKVM-IA` commit `4271456c2f48`：增加 IOMMU 初始化与 SRTP/QI 调试信息。
- `pKVM-IA` commit `ddca29a73988`：保存验证过可成功编译的 Host config。
- `pkvm-x86` commit `866e8a6`：补充 DMAR panic 分析、IOMMU 管理流程和 Kconfig 文档。

**关键源码**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`
  - `activate_iommu()`
  - `initialize_qi()`
  - `iommu_zalloc_pages()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/init_finalise.c`
  - `divide_memory_pool()`
- `pKVM-IA/drivers/iommu/intel/iommu.c`
  - `iommu_set_root_entry()`
  - `IOMMU_WAIT_OP()`

**参考文档**

- `DOCS/问题清单/问题清单.md`
- `DOCS/分析文档/pkvm-x86-启动失败-DMAR硬件异常panic-分析.md`
- `DOCS/分析文档/pkvm-x86-IOMMU管理流程-Shadow-vs-PVIOMMU.md`
- `DOCS/pKVM-IA-docs/PKVM-Kconfig.md`

### 2026-02-05 ~ 2026-02-06：RUN-001，启动 protected VM 时 `Failed to set cpuid pages for pkvm vcpu`

**问题 / 现象**

- Host pKVM 已能启动后，使用 crosvm 启动 protected VM 时，Host dmesg 出现：

```text
pkvm: vcpu_after_set_cpuid kvm_set_cpuid failed ret=-12 ... nent=57
kvm [PID]: Failed to set cpuid pages for pkvm vcpu ... entries_pa=... ret_pa=...
```

- crosvm 启动 protected VM 失败或不能稳定进入 guest。

**根因**

- 这不是 Host 侧 `alloc_pages_exact()` 分配 CPUID buffer 失败，而是 hyp/kvm-low 侧 `kvm_set_cpuid()` 返回 `-ENOMEM`。
- Host-high 的 `pkvm_vcpu_after_set_cpuid()` 把 CPUID entries copy 到新页并通过 `vcpu_after_set_cpuid` hypercall donate 给 hyp；hyp 侧 `pkvm_enforce_cpuid()` 可能补齐额外 CPUID entries，随后调用 hyp 侧 `kvm_set_cpuid()`。
- hyp 侧 `kvm_set_cpuid()` 走到 FPU/XFD 检查时，`__xfd_enable_feature()` 发现 guest dynamic xfeature 所需 fpstate size 大于当前 pVM fpstate：例如 `cur=4096 need=10752 xfd_event=0x40000`，于是返回 `-ENOMEM`。
- hypercall 失败后按约定原样返回 `entries_pa`，Host-high 据此打印 `Failed to set cpuid pages for pkvm vcpu` 并释放 buffer。

```text
userspace
    ioctl(KVM_SET_CPUID2)

Host-high
    pkvm_vcpu_after_set_cpuid()
        pkvm_hypercall(vcpu_after_set_cpuid, entries_pa, nent)
            returns entries_pa on failure
        kvm_err("Failed to set cpuid pages for pkvm vcpu")

pKVM hyp / kvm-low
    pkvm_vcpu_after_set_cpuid(...)
        donate_host_memory(gpa, aligned_size)
        pkvm_enforce_cpuid(new_entries, &new_nent)
        kvm_set_cpuid(vcpu, new_entries, new_nent)
            fpu_enable_guest_xfd_features(...)
                __xfd_enable_feature(...)
                    fpstate too small -> -ENOMEM
```

**解决方法 / 当时状态**

- 当时先加详细日志确认：`pkvm_enforce_cpuid()` 是否失败、`kvm_set_cpuid()` 返回值、new/old cpuid buffer 是否被 consume，以及 `__xfd_enable_feature()` 的 `cur/need/xfd_event`。
- 短期绕过：Host 内核启动参数增加 `clearcpuid=amx_tile`，屏蔽触发 `xfd_event=0x40000` 的 AMX/XTILEDATA 类 dynamic xfeature；验证后 protected VM 可启动成功。
- 长期修复方向：完善 Host-high `pkvm_vcpu_realloc_fpstate()` / `vcpu_add_fpstate` hypercall 扩容链路，确保 hyp 侧 fpstate 至少覆盖 `xstate_calculate_size()` 计算出的 `need`。

**关键提交 / 文档**

- `pKVM-IA` commit `ed10f25eb099`：增加 `vcpu_after_set_cpuid`、`donate_host_memory`、`__xfd_enable_feature()` 等调试日志。
- `pkvm-x86` commit `4e0cd9c`：记录 crosvm 启动 protected VM 失败与 `Failed to set cpuid pages for pkvm vcpu` 分析。

**关键源码**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm_high.c`
  - `pkvm_vcpu_after_set_cpuid()`
  - `pkvm_vcpu_realloc_fpstate()`
- `pKVM-IA/arch/x86/kvm/pkvm/pkvm.c`
  - hyp/kvm-low `pkvm_vcpu_after_set_cpuid()`
  - `donate_host_memory()`
- `pKVM-IA/arch/x86/kvm/pkvm/fpu/xstate.c`
  - `__xfd_enable_feature()`
- `pKVM-IA/arch/x86/kvm/cpuid.c`
  - `kvm_vcpu_after_set_cpuid()` 调用链

**参考文档**

- `DOCS/问题清单/问题清单.md`
- `DOCS/pKVM-IA-docs/README.md`


### 2026-02-24 ~ 2026-03-02：确认设备透传基线与最早 donate 失败

**问题 / 现象**

- 普通 6.8 内核 + 普通 VM + NVMe 透传可用；pKVM 内核 + 普通 VM + NVMe 透传也可用。
- protected pVM + VFIO NVMe 失败，早期出现 `do_donate__pkvm` `exception 6`、`host_initiate_donation: page refcounted`、`do_donate failed ret=-16`，随后 host soft lockup。

**根因认识**

- `exception 6` 不是随机非法指令，而是 `do_donate()` 内部 `WARN_ON(ret)` 把 `-EBUSY` donation 失败打成了 pKVM 异常。
- `host_initiate_donation()` 在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c` 中检查目标页是否属于 host normal memory、owner 是否有效、`hyp_page_count()` 是否为 0；只要 refcount 非 0，host -> guest / host -> hyp donation 都会失败。
- 最早这一步只把问题从“启动失败”收敛为“某条先发生路径给目标 HPA 留下了 hyp refcount”。

**解决方法 / 产出**

- 增加最小诊断日志，把 donation 失败返回码、`busy_hpa`、refcount 来源打出来。
- 把问题记录拆成独立 `BOOT-004/005/006` 线索，不再用一个大问题覆盖所有症状。
- 形成后续 `T1` 的直接前置证据：必须先找出旧 shadow IOMMU / spgt 路径为何留下 refcount。

**关键源码**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`：`host_initiate_donation()`、`do_donate()`、`__pkvm_host_donate_guest()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/buddy_memory.h`：`hyp_page_count()`

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-004/BOOT-004-透传设备给非机密VM后启动失败-do_donate异常6.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-005/BOOT-005-disable-sandbox后vCPU-hw-run-failure-0x80000021.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-006/BOOT-006-机密VM-donate失败-IOMMU影子页表refcount冲突.md`

### 2026-03-18 ~ 2026-03-23：BOOT-006 / T1，清理旧 shadow spgt 残留 refcount

**问题 / 现象**

protected pVM + VFIO(`NoIommu`) 启动时，在 `GPA=0x9000` 的 Guest EPT 建图上失败：

```text
host_initiate_donation: page refcounted ... owner_id=1 refcnt=1
first-owner ... tag=shadow_pgt_map_leaf/new_inc aux=0x9000
__pkvm_host_donate_guest failed ret=-16 hpa=... gpa=0x9000
kvm: pkvm: vm_mmu_map failed ret=-16
```

**根因**

- 先发生路径：crosvm 对整段 guest RAM 做 `VFIO_IOMMU_MAP_DMA`，pKVM 通过 shadow IOMMU 同步 Host IOMMU 页表，`shadow_pgt_map_leaf()` 对被映射的数据页做 `hyp_page_ref_inc()`。
- 后发生路径：guest 第一次访问 `GPA=0x9000` 触发 EPT violation，host 解析出 HPA 后让 pKVM 执行 `__pkvm_host_donate_guest()`。
- 旧 host shadow IOMMU spgt 在释放时调用 `pkvm_pgtable_destroy(&spgt->pgt, NULL)`，不会经过能回收数据页 refcount 的 leaf callback，导致旧 refcount 残留，后续 donation 被拒绝。

```text
修复前：
    sync_shadow_pgt()
        shadow_pgt_map_leaf()
            hyp_page_ref_inc(data_page)

    pkvm_put_host_iommu_spgt()
        pkvm_pgtable_destroy(&spgt->pgt, NULL)
            只释放页表页
        不调用 shadow_pgt_unmap_leaf()
        不 hyp_page_ref_dec(data_page)

    guest_mmu_map_leaf()
        __pkvm_host_donate_guest()
            host_initiate_donation()
                hyp_page_count(data_page) != 0
                    return -EBUSY
```

**解决方法**

- 在 `pkvm_put_host_iommu_spgt()` 的最终销毁路径接入 destroy 专用 leaf free callback。
- 新增 `pkvm_host_iommu_spgt_free_leaf()`，只负责 destroy 场景下的数据页 `hyp_page_ref_dec()` 和 leaf 页表资源释放，避免误复用普通 unmap 路径导致 `pgtable_unmap_leaf` assertion。

**关键提交 / PR / issue**

- `pKVM-IA` commit `45c072ab1591`：`修正 BOOT-006 中 shadow spgt 销毁回调`
- GitHub：MrGeek-zrh/pkvm-x86#2、MrGeek-zrh/pkvm-x86#3

**验证状态**

- 旧签名 `host_initiate_donation: page refcounted`、`do_donate failed ret=-16`、`pkvm: exception` 不再复现。
- protected pVM + VFIO 能继续走到 guest `bzImage` 加载，说明旧 refcount blocker 被解除。

**关键源码**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c`：`pkvm_put_host_iommu_spgt()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`：`shadow_pgt_map_leaf()`、`pkvm_host_iommu_spgt_free_leaf()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`：`host_initiate_donation()`

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01-P0-清理旧shadow-spgt残留refcount.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/pVM设备透传设计方案.md`

### 2026-03-24：B3，建立 protected pVM ptdev MMIO metadata / allowlist 骨架

**问题 / 现象**

- T1 解除 donation blocker 后，新的核心问题不再只是 DMA mirror：protected pVM 没有成熟的 passthrough BAR/MMIO contract。
- host -> pKVM 的显式 attach 接口只传 `BDF/PASID`，没有 BAR/resource 元数据。
- guest 侧已有 `pkvm_virt_mmio()` 分流入口，但缺少 hyp 提供的 authoritative allowlist，无法决定哪些 BAR GPA 可以 direct raw MMIO，哪些必须 fallback 到 `PKVM_GHC_IOREAD/IOWRITE`。

**解决方法**

- 先定第一阶段范围：单 VFIO PCI 设备、静态 attach、`NoIommu`、普通 BAR MMIO；config 继续走 emulated 路径，MSI-X table / PBA 暂不直达。
- 增加 host 提交 `ptdev MMIO metadata`、host -> hyp 同步、hyp 绑定到 `ptdev`、guest 拉取 allowlist、guest `pkvm_virt_mmio()` 命中 allowlist 后走 direct raw read/write 的第一轮骨架。
- metadata 分成两层：hyp 内部富 metadata 与 guest 可见的精简 allowlist。

**关键提交 / PR / issue**

- `pKVM-IA` commit `dd91422c57b1`：`实现 protected pVM 的 ptdev MMIO metadata 通路`
- `crosvm` commit `3c97ca4cb515`：修正 protected VM PCIe 配置路径判定
- GitHub：MrGeek-zrh/pkvm-x86#13、MrGeek-zrh/pkvm-x86#14、MrGeek-zrh/pKVM-IA#1

**关键源码**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`：`pkvm_vm_ioctl_set_ptdev_mmio_metadata()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`：`pkvm_set_ptdev_mmio_metadata()`、`pkvm_update_vm_mmio_allowlist()`
- `pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c`：`pkvm_handle_ptdev_mmio_info()`、`pkvm_handle_ptdev_mmio_read()`
- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c`：`pkvm_init_mmio_allowlist()`、`pkvm_mmio_allow_hit()`、`pkvm_virt_mmio()`
- `pKVM-IA/arch/x86/include/uapi/asm/kvm.h`：`struct kvm_protected_vm_ptdev_mmio_metadata`

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01C-1-B3-1-protected-pVM-设备透传第一阶段上层方案.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01C-2-B3-2-x86-ptdev-metadata-最小结构草案.md`
- `DOCS/tmp/pKVM-IA-allowlist-代码实现讲解-dd91422.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-到-x86-设计映射表.md`

### 2026-03-24 ~ 2026-03-27：BOOT-007 / B1 / B2，收敛 protected VM 的 config/MMIO fallback 路径

**问题 / 现象**

T1 后旧 donation/refcount 签名消失，但 protected pVM + VFIO(`NoIommu`) 运行期出现：

```text
Failed to map mmio page; failed to create vm mapping
vcpu hit unknown error: Bad address (os error 14)
```

**根因**

- crosvm 的 `ReadOnlyMemoryRegion` 能力判断本意是在 pKVM 下关闭只读 memslot，但 x86_64 `KvmVm::is_pkvm()` 当时硬编码 `false`，导致 crosvm 误以为 protected VM 可创建只读 PCIe config memslot。
- 只读 memslot 建立失败后退回 vm-exit / MMIO emulation，而 `pKVM-IA/arch/x86/kvm/mmu/mmu.c` 的 protected vCPU 缺页路径明确拒绝传统 `RET_PF_EMULATE`，返回 `-EFAULT`。
- PCI virtual config / ACPI `VCFG` / device-level virtual config AML 在 protected VM 下继续暴露，会把 guest 带回 pKVM 不支持的 host-mediated MMIO emulation 路径。

**解决方法**

- 修正 crosvm x86_64 的 protected VM 识别。
- protected VM 下停止创建 `PciVirtualConfigMmio`、停止公开 ACPI `VCFG`、停止注册设备级 virtual-config AML / shared-memory 入口。
- 把 `BOOT-007` 定位为独立 bug / blocker，而不是把它混入 T2/T3 DMA mirror。

**关键提交 / issue**

- `crosvm` commit `ce788f654d`：`x86_64: disable protected VM virtual config paths`
- GitHub：MrGeek-zrh/pkvm-x86#4、MrGeek-zrh/pkvm-x86#5、MrGeek-zrh/pkvm-x86#12

**验证状态**

- 后续重测中，`BOOT-007` 的 `Bad address (os error 14)` 旧签名消失。
- 主线前移到 `BOOT-008` host DMAR fault，说明 CPU 启动链已经继续向前推进。

**关键源码**

- `crosvm/hypervisor/src/kvm/x86_64.rs`：`KvmVm::is_pkvm()`
- `crosvm/x86_64/src/lib.rs`：protected VM 下 PCI config / VCFG 公开逻辑
- `pKVM-IA/arch/x86/kvm/mmu/mmu.c`：protected VM `RET_PF_EMULATE -> -EFAULT`

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-007/BOOT-007-protected-pVM-NoIommu-VFIO-vcpu-EFAULT.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01A-B0-NoIommu运行期EFAULT归因.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01B-B0-protected-pVM-VFIO-config-MMIO访问路径收敛.md`

### 2026-03-27：BOOT-008 / T2 / T3，收敛 `pgstate_pgt` 为 DMA mirror 并补 runtime mirror hook

**问题 / 现象**

`BOOT-007` 消失后，protected pVM 已能进入 Ubuntu login prompt，但 host dmesg 出现新的 IOMMU/DMA 签名：

```text
DMAR: [DMA Read NO_PASID] Request device [01:00.0] fault addr ...
[fault reason 0x06] PTE Read access is not set
```

**根因**

- `ptdev` attach 会把 `ptdev->pgt` 切到 protected VM 的 `pgstate_pgt`，再 `pkvm_iommu_sync()` 更新 IOMMU SLPTR。
- 但 `pgstate_pgt` 当时既没有稳定作为 DMA mirror，也没有在 protected guest 页面 donate 成功后同步 runtime GPA -> HPA leaf。
- `pgstate_pgt_free_leaf()` 还带有 ownership 回收语义，可能与 `guest_mmu_free_leaf()` 双重承担 undonate。

**解决方法**

- T2：把 `pgstate_pgt` 明确定义为 DMA mirror，不再负责 ownership 回收；teardown 时只释放 mirror 页表自身。
- T3：在 `__pkvm_host_donate_guest()` 成功后，如果 VM 有 attached ptdev，就从 guest EPT leaf 派生映射，同步写入 `pgstate_pgt`，并对 `pgstate_pgt->root_pa` 定向 flush IOTLB。
- 调整 shadow VM teardown 顺序，先 detach ptdev，再销毁 `pgstate_pgt`，避免 IOMMU 仍指向待释放 mirror。

```text
protected pVM donate success path:
    guest_mmu_map_leaf()
        __pkvm_host_donate_guest(...)
            do_donate(...)
            if vm has attached ptdev:
                mirror newly donated GPA->HPA leaf into pgstate_pgt
                pkvm_iommu_flush_iotlb(root_pa = pgstate_pgt->root_pa)
```

**关键提交 / PR / issue**

- `pKVM-IA` commit `0aec8661c7df`：`收敛 protected pgstate_pgt 为 DMA mirror`
- GitHub：MrGeek-zrh/pkvm-x86#6、MrGeek-zrh/pkvm-x86#7、MrGeek-zrh/pkvm-x86#15、MrGeek-zrh/pKVM-IA#1、MrGeek-zrh/pkvm-x86#16

**验证状态**

- protected pVM 成功启动到 Ubuntu login prompt。
- guest 可见 `nvme0n1`，sysfs 指向 `0000:01:00.0`。
- 原始块设备读、1 GiB 写、`mkfs.ext4 -F /dev/nvme0n1` 成功。
- host dmesg 未再出现 `DMA Read NO_PASID` / `PTE Read access is not set`。

**关键源码**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`：`pkvm_pgstate_pgt_free_leaf()`、`pkvm_pgstate_pgt_deinit()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`：`__pkvm_host_donate_guest()` runtime mirror hook
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`：`pkvm_iommu_flush_iotlb()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`：`pkvm_attach_ptdev()` 切换 `ptdev->pgt`

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-008/BOOT-008-protected-pVM-NoIommu-VFIO-host-DMAR-PTE-Read-access-not-set.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/02-P0-pgstate_pgt语义收敛为DMA-mirror.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/03-P0-donate后同步runtime-DMA-mirror.md`

### 2026-04-01 ~ 2026-04-02：BOOT-009 / B4，修复 protected guest GPA 回写路径

**问题 / 现象**

在 protected pVM + VFIO 后续运行中偶发：

```text
pkvm: exception 14 on CPU10 @ip copy_gpa__pkvm... err code 0x2
watchdog: BUG: soft lockup
rcu_preempt detected stalls
NMIs are not reaching exc_nmi() handler
```

**根因**

- hyp 向 guest 回写 `ptdev MMIO metadata / allowlist` 时走 `write_gpa()` -> `copy_gpa()` -> `__copy_gpa()`。
- 旧 `__copy_gpa()` 通过 `host_gpa2hva(gpa)` 把 guest GPA 当作 host identity HPA 去访问。
- 对 protected guest，`GPA != HPA` 是基本前提；guest GPA 必须先经 guest MMU 查表得到 HPA，并且只允许 RAM buffer 被 copy。

**解决方法**

- 在 protected vCPU 下，`__copy_gpa()` 先 `guest_mmu_lock()`，通过 `pkvm_pgtable_lookup(&pkvm_vm->mmu, gpa, &hpa, ...)` 做 GPA -> HPA 翻译。
- 若查不到映射，返回 `-EFAULT`。
- 若 HPA 不是正常内存 `is_mem_range(hpa, len)`，返回 `-EFAULT`，避免把 direct BAR / MMIO GPA 当普通 RAM buffer copy。
- 非 protected 路径继续用原 host identity helper。

**关键提交 / issue**

- `pKVM-IA` commit `b86cfd0230b9`：`修正 protected guest GPA 回写路径`
- GitHub：MrGeek-zrh/pkvm-x86#18、MrGeek-zrh/pkvm-x86#19

**验证状态**

- `BOOT-009` 作为独立 bug 关闭保留。
- 后续 `BOOT-008` 重复启动回归不再被 `copy_gpa__pkvm` 写 fault 遮挡。

**关键源码**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c`：`__copy_gpa()`、`copy_gpa()`、`write_gpa()`
- `pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c`：`pkvm_handle_ptdev_mmio_info()`、`pkvm_handle_ptdev_mmio_read()`
- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c`：`pkvm_init_mmio_allowlist()`

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-009/BOOT-009-protected-pVM-NoIommu-VFIO-copy-gpa-exception14-soft-lockup.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01D-B4-protected-pVM-allowlist-guest-gpa回写路径修复.md`

### 2026-04-09：teardown hygiene，回收 `pid_table` donation

**问题 / 现象**

- pKVM VM teardown 后，`pid_table` donation 可能没有在销毁路径归还，属于 protected VM 生命周期资源回收缺口。

**解决方法**

- 在 pKVM VM 销毁路径归还 `pid_table` donation，避免 VM teardown 后残留已捐赠页面。

**关键提交 / 源码**

- `pKVM-IA` commit `49a878b28eb6`：`Reclaim pid_table during pKVM VM teardown`
- `pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c`

### 2026-04-11 ~ 2026-04-12：T9 / B5-1，启动期 platform manifest 与 checked ptdev 创建

**问题 / 现象**

- 仅有 BAR metadata / allowlist 还不够：在“运行期 Host 不可信”的模型下，pKVM 不能完全相信 Host 在 attach 时传来的设备身份和资源描述。
- 需要先有一份启动期冻结的设备全集，让 pVM attach 时能判断这个 BDF 是否属于 boot-known / manifest 允许范围。

**解决方法**

- 在 `check_and_init_iommu(pkvm)` 阶段基于 `for_each_pci_dev()` 构造 boot-time platform manifest，并冻结到 `struct pkvm_hyp`。
- 第一阶段 manifest 记录 `bdf + flags`，后续扩展为 BAR `base/size`。
- 拆分 helper：
  - `pkvm_get_or_create_ptdev_checked()`：pVM 显式 attach 边界使用，先 manifest check，再 get/create。
  - `pkvm_get_or_create_ptdev()`：legacy shadow IOMMU / 普通 VM 共享路径使用，不承载 manifest enforcement。
- `pkvm_attach_ptdev()` 必须始终先过 manifest check，即使 `(bdf,pasid)` 已被普通 VM 路径提前物化成 `ptdev`，也不能绕过校验。

**BOOT-010 follow-up**

- T9 第一版一度把 manifest enforcement 也接到 legacy shadow IOMMU 共享路径，导致普通 VM 透传 manifest-miss `0000:02:00.0` 时 guest NVMe probe 失败，并在 host dmesg 打出 `reject bdf ... outside boot manifest`。
- 修复方式是把 enforcement 收回到 `pkvm_attach_ptdev()`，共享路径只做 unchecked materialization。

**BOOT-011 follow-up**

- strict `N1` manifest reject 后，同轮紧接 strict `N2` 普通 VM 可能遇到 `/dev/vfio/9 group busy`。
- 目前只作为开放 bug 现象保留；临时 workaround 是对设备做 `vfio-pci -> nvme -> vfio-pci` rebind 清理。

**关键提交 / PR / issue**

- `pKVM-IA` commit `e776567b5800`：`Enforce boot manifest at pVM attach boundary`
- GitHub：MrGeek-zrh/pkvm-x86#20、MrGeek-zrh/pkvm-x86#21、MrGeek-zrh/pkvm-x86#22、MrGeek-zrh/pKVM-IA#2、MrGeek-zrh/pkvm-x86#23

**验证状态**

- boot-known `0000:01:00.0`：普通 VM 与 protected VM 正向样例都能透传。
- manifest-miss `0000:02:00.0`：protected attach 命中 reject，普通 VM 不应被 manifest 误拦截。
- `BOOT-011` 仍开放，不应算作 T9 主验收失败。

**关键源码**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`：`struct pkvm_boot_ptdev_manifest_entry`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`：boot manifest 构建
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`：`pkvm_get_or_create_ptdev_checked()`、`pkvm_get_or_create_ptdev()`、`pkvm_attach_ptdev()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`：legacy shadow IOMMU 共享路径

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-1-B5-1-启动期platform-manifest可信设备名单方案.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-2-T9-B5-1-platform-manifest与checked-ptdev创建实现.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-010-普通VM-manifest-miss设备被错误拦截导致NVMe-probe失败.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-011-manifest-reject后vfio-group-busy导致后续普通VM打开失败.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-设备身份校验方案（从抽象到具体）.md`

### 2026-04-15：crosvm boot-time metadata 提交缺口，补齐 BAR allowlist 下发前置条件

**问题 / 现象**

- protected pVM + VFIO NVMe 正向样例能启动、能枚举、能读盘，但 guest 侧 `pkvm_virt_mmio()` 没有命中 direct 分支，仍大量走 `PKVM_GHC_IOREAD/IOWRITE -> host fallback -> crosvm mmio_bus -> VFIO region read/write`。
- 打点发现 `pkvm_mmio_allow_nr_ranges == 0`，host 侧 `pkvm_vm_ioctl_set_ptdev_mmio_metadata()` 命中数也是 0。

**根因**

- boot 阶段 PCI/VFIO 设备走的是 `generate_pci_root()` 路径，而 `SET_PTDEV_MMIO_METADATA` 只存在于另一条 `configure_pci_device()` 路径。
- 因此 boot-time VFIO 设备注册时根本没有机会提交 ptdev MMIO metadata。

**解决方法**

- crosvm 统一 boot 阶段 PCI root 路径的 metadata 查询和提交。
- 对齐 KVM ptdev MMIO metadata ABI，使 crosvm 能正确下发 BAR allowlist。

**关键提交 / issue**

- `crosvm` commit `65ebf38656a4`：`补齐 protected pVM 的 ptdev metadata 提交流程`
- GitHub：MrGeek-zrh/pkvm-x86#26、MrGeek-zrh/pkvm-x86#27

**关键源码**

- `crosvm/arch/src/lib.rs`：`generate_pci_root()`、`configure_pci_device()`
- `crosvm/devices/src/pci/vfio_pci.rs`：VFIO BAR metadata 生成
- `crosvm/hypervisor/src/kvm/x86_64.rs`：KVM ioctl metadata 提交

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T10-B5-2-protected-pVM-Guest-EPT建图边界实现.md`
- `DOCS/日报/2026-04-15-B5-2问题解决记录.md`

### 2026-04-15：BOOT-012 / T10，BAR HPA 不能走 RAM donation，Guest EPT 需 direct BAR leaf

**问题 / 现象**

crosvm metadata 提交链路补齐后，运行期暴露新签名：

```text
pkvm: host_initiate_donation: addr not in mem_range addr=0xfe800000 size=0x1000 owner_id=1
pkvm: __pkvm_host_donate_guest failed ret=-1 hpa=0xfe800000 gpa=0xd0000000
kvm: pkvm: vm_mmu_map failed ret=-1 gpa=0xd0000000 hpa=0xfe800000
```

`0xfe800000` 正是 NVMe `0000:01:00.0` BAR0 起始地址，不是 host RAM。

**根因**

- Host-high 缺页路径通过 memslot/HVA 解析出 candidate HPA，然后把成品 `hpa` 传给 hyp `pkvm_vm_mmu_map()`。
- 对 direct BAR 映射，HPA 是 PCI BAR 物理地址；旧 `guest_mmu_map_leaf()` 对 protected VM 默认调用 `__pkvm_host_donate_guest()`。
- `host_initiate_donation()` 只允许 host normal memory，不允许 MMIO；BAR HPA 不在 `mem_range`，因此被 `addr not in mem_range` 拒绝。

**解决方法**

- 扩展 boot-time manifest，记录每个 boot-known 设备 memory BAR 的 `base/size`。
- 在 hyp 侧提供 BAR 范围 helper，判断 `[hpa, hpa + size)` 是否完整落在“当前 VM 已 attach 且 boot-time manifest 记录的 memory BAR”内。
- `pkvm_vm_mmu_map()` / `guest_mmu_map_leaf()` 中分流：
  - 命中合法 attached BAR：按 MMIO memory type 直接 `pgtable_map_leaf()` 安装 Guest EPT leaf，不走 donation。
  - 命中 host RAM：继续普通 RAM donation/share 语义。
  - 既非 attached BAR 又非 host RAM：提前 reject 并打印明确日志。
- VM destroy 时，direct BAR leaf 只撤 Guest EPT，不做 `__pkvm_host_undonate_guest()`。

**关键提交 / PR / issue**

- `pKVM-IA` commit `501ca0cb907f`：`实现 protected pVM 的 BAR HPA Guest EPT 直建图`
- GitHub：MrGeek-zrh/pkvm-x86#30、MrGeek-zrh/pkvm-x86#31、MrGeek-zrh/pkvm-x86#25

**关键源码**

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`：`pkvm_vm_mmu_map()`、`guest_mmu_map_leaf()`、`guest_mmu_free_leaf()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`：`pkvm_boot_ptdev_manifest_lookup()`、`pkvm_boot_ptdev_bar_contains()`、`pkvm_vm_hpa_hits_attached_boot_ptdev_bar()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`：manifest BAR `base/size`

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-012/BOOT-012-protected-pVM-BAR-HPA误入donate路径导致vm_mmu_map失败.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T10-B5-2-protected-pVM-Guest-EPT建图边界实现.md`

### 2026-04-15：BOOT-013 / T11，direct BAR leaf 后 host-high 不能误 pin MMIO PFN

**问题 / 现象**

- `BOOT-012` 旧签名消失后，protected pVM 仍未到 login，crosvm 报 `Bad address (os error 14)`。
- host dmesg 出现 `WARNING ... arch/x86/kvm/mmu/mmu.c:4775 kvm_tdp_page_fault+0x3f0/0x420`。

**根因**

`pkvm_page_fault()` 的旧流程假设 `vm_mmu_map` 成功后一定映射的是普通 RAM：

```text
pkvm_page_fault()
    kvm_faultin_pfn(...)
    pkvm_hypercall(vm_mmu_map, gpa, hpa, size, ...)
    if (!r && pkvm_is_protected_vcpu(vcpu))
        pkvm_pin_page(vcpu->kvm, fault)
```

`BOOT-012` 修复后，`vm_mmu_map` 新增了合法 direct BAR / MMIO PFN 成功路径。BAR/MMIO PFN 不是 refcounted RAM page，`kvm_pfn_to_refcounted_page(fault->pfn)` 返回 `NULL`，`pkvm_pin_page()` 触发 `WARN_ON_ONCE(!page)` 并返回 `-EFAULT`。

**解决方法**

- `pkvm_page_fault()` 后处理区分普通 RAM 与 direct MMIO/BAR：
  - refcounted RAM PFN：继续 `pkvm_pin_page()`。
  - direct BAR / MMIO PFN：在 hyp 侧 `vm_mmu_map()` 已校验成功的前提下跳过普通 RAM pin。
- 当前最小修复不引入新的 host-high/hyp ABI，只修正“没有 `struct page` 就 WARN 并失败”的错误假设。

**关键提交 / issue**

- `pKVM-IA` commit `efba4f386b27`：`修正 protected pVM 的 BAR/MMIO PFN pin 语义`
- GitHub：MrGeek-zrh/pkvm-x86#28、MrGeek-zrh/pkvm-x86#29

**验证状态**

- protected pVM 成功启动到 login 并可登录。
- guest 内 `nvme0n1` 正常枚举，sysfs 指向 `0000:01:00.0`。
- guest 内两轮 `dd` 成功，`DD_RC=0`、`DD_BIG_RC=0`。
- guest `pkvm_virt_mmio()` 打点显示 `dd` 窗口：`GUEST_DIRECT=128`、`GUEST_FALLBACK=2`，trace 尾部显示 `dd-*` 命中 `direct_hit`。
- host dmesg 未再出现 `Bad address`、`WARNING: ... kvm_tdp_page_fault`、`pkvm_pin_page`。

**关键源码**

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c`：`pkvm_page_fault()`、`pkvm_pin_page()`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`：direct BAR leaf 成功路径

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-013/BOOT-013-protected-pVM-BAR直建图后pkvm_pin_page误pin-MMIO-PFN.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T10-B5-2-protected-pVM-Guest-EPT建图边界实现.md`

### 2026-04-15 ~ 2026-04-16：BOOT-014 / T4，VM teardown 前先 quiesce / block ptdev DMA

**问题 / 现象**

在 protected pVM 内做活跃 direct I/O 时，host 侧强杀 crosvm 曾单次出现：

```text
DMAR: [DMA Read NO_PASID] Request device [01:00.0] fault addr ...
[fault reason 0x06] PTE Read access is not set
nvme ... I/O timeout / probe failed
```

该签名不稳定，后续 `Case A/B/C` 多轮矩阵大多为负例，但源码层面的生命周期逆序成立。

**根因**

旧 teardown 顺序里，guest private page / guest MMU teardown 可能先于 ptdev DMA 通路封口：

```text
pkvm_vm_destroy()
    pkvm_vm_mmu_destroy()
        guest_mmu_free_leaf()
            __pkvm_host_undonate_guest(...)
    kvm_arch_destroy_vm()
        pkvm_teardown_shadow_vm()
            pkvm_detach_ptdev()
                pkvm_iommu_sync()
```

`pkvm_detach_ptdev()` 语义太重，它会 unlink、清 metadata、切回 host EPT、清 shadow vm handle，更像彻底解绑和恢复 host view，不适合作为前半段“先切断 DMA”的最小安全屏障。

**解决方法**

- 增加独立的前置 quiesce / block DMA 步骤，插在 `pkvm_vm_mmu_destroy()` 之前。
- 第一版只做 DMA 门封口，不做 detach 的重语义：强制让对应 IOMMU context / PASID entry 失效，并 flush context / PASID / IOTLB。
- 后半段仍保留原 `pkvm_detach_ptdev()` 做收尾清理。

```text
pkvm_vm_destroy(handle)
    pkvm_quiesce_shadow_vm_ptdevs()
    pkvm_vm_mmu_destroy()
    kvm_arch_destroy_vm()
```

**关键提交 / PR / issue**

- `pKVM-IA` commit `c815350d5562`：`在 VM teardown 前预先封锁 ptdev DMA`
- GitHub：MrGeek-zrh/pkvm-x86#8、MrGeek-zrh/pkvm-x86#32、MrGeek-zrh/pKVM-IA#3、MrGeek-zrh/pkvm-x86#33

**验证状态**

- 第一版实现后，推荐矩阵 `Case A 20 轮 + Case B/C 各 5 轮` 全部负例。
- `BOOT-014` 作为单次正例历史 bug 关闭保留；后续若需要证明更高置信度，应继续做 soak / trace，而不是把相同矩阵无限重复。
- `T4` 与后续 `T12` 边界已拆开：`T4` 解决 DMA-safe barrier；`T12` 解决 Host CPU 对 assigned BAR 的访问权 / BAR owner-state。

**关键源码**

- `pKVM-IA/arch/x86/kvm/pkvm/pkvm.c`：`pkvm_vm_destroy()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`：`pkvm_quiesce_shadow_vm_ptdevs()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`：`dma_blocked` / ptdev DMA quiesce 状态
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`：shadow IOMMU 同步时识别 DMA blocked

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-014/BOOT-014-protected-pVM-活跃DMA时host强杀crosvm后单次出现DMAR-NO_PASID-fault.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/04-P0-VM销毁前quiesce-ptdev-DMA.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/04A-P0-teardown-DMA生命周期风险验证与触发样例.md`

### 2026-04-16 ~ 2026-04-27：B5-3 / T12，assigned BAR 的 Host CPU 访问权收口

**问题 / 现象**

- 到 `BOOT-013` 后，protected pVM + VFIO NVMe 已能启动、读盘，并且 guest direct BAR MMIO 已有正向证据。
- 但这还不等于“设备已经安全交给 pVM”：Host CPU 是否还能通过 Host EPT lazy remap 重新访问 assigned BAR 尚未显式收口。
- `B5-2` 只解决了 Guest EPT 建图边界：Host 不能在 `vm_mmu_map()` 时把任意 HPA 塞给 pVM；它没有证明 Host CPU 之后无法继续 MMIO 到已 assign BAR。

**ARM ref 带来的设计转向**

- 不能把 T12 简化成“fault path 上拦一次地址”。更合理的是让 `ptdev` 承载 BAR resource / owner / state / lifecycle。
- 第一阶段采用 Host -> Hyp -> Guest 的 authority 迁移：Host 失去 BAR 可见性，Hyp 成为中间 owner，Hyp 再发布 guest direct BAR 约定。
- detach / rollback 时必须先撤 guest contract 和 DMA view，再恢复 Host BAR visibility；restore 失败时不能假装 Host 已拿回 authority。

**第一阶段目标语义**

```text
初始：Host 持有 BAR authority，Host CPU 可访问 BAR

A：Host -> Hyp BAR donate
    revoke Host BAR visible leaf
    在 Host EPT invalid PTE 中写 OWNER_ID_PTDEV_MMIO annotation
    后续 Host fault 命中 annotation 时 deny-remap

C：切 DMA 视角
    ptdev->pgt = vm->pgstate_pgt
    pkvm_iommu_sync()
    DMA_VIEW_READY = 1

B：发布 guest MMIO contract
    publish direct BAR allowlist
    assignment_state = GUEST_ASSIGNED

detach / rollback：
    withdraw guest MMIO contract
    切回 / 阻断 DMA view
    restore touched BAR Host visibility
    owner HYP -> HOST
```

**已完成的第一阶段实现切片**

- `2713d30bcf26`：增加设备 MMIO 的 Host EPT 标注辅助函数。
- `a1f7acdd7c19`：Host EPT fault 遇到 `OWNER_ID_PTDEV_MMIO` 标注时拒绝 BAR remap。
- `81b0c1207c80`：增加 `ptdev` BAR authority 状态，包括 owner、assignment state、per-BAR progress、BAR snapshot、guest BAR 映射前置状态检查。
- `d4bf9376046a`：拆分 MMIO metadata 缓存与发布；`SET_PTDEV_MMIO_METADATA` 只缓存 guest direct BAR 意图，只有 Host revoke 与 DMA view commit 后才发布 guest allowlist。
- `b606249631e7`：接入 A/C/B attach 主线；先 Host BAR revoke，再 DMA view commit，最后发布 guest MMIO contract，并补齐 C 前失败回滚。
- `e9d259ba8a5a`：detach / teardown 使用统一 BAR restore helper；restore 失败时保留状态并拒绝继续 unlink / sync / put。
- `570fe6800f37`：补充 BAR revoke / restore / Host deny-remap 诊断日志。
- `19c718a05548`：显式化 `ptdev` MMIO owner ID 编码。
- `a1b02bd8c012`：按 `DIRECT_BAR` metadata range 细化 Host BAR revoke，避免整 BAR revoke 覆盖未声明的 MSI-X table / PBA 控制面。

**验证状态**

- 源码级最小验证已记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t12-mmio-donate-phase1-20260424.md`
  - 已完成 `git diff --check`、关键 grep、checkpatch（0 ERROR）。
  - 当时未运行全量内核编译。
- 后续测试设计已落地：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/10-T12-第一阶段测试用例设计.md`
- 旧失败记录保留在 `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260427-070641-T12-A1`：`T12-A1` 返回 `FAILED`，日志出现 `pkvm: deny host BAR remap`，随后出现 general protection fault。
- 重新编译并启动 `6.12.0-pkvm-ia #13` 后，`T12-A1` 重测记录为 `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t12-a1-rerun-after-kernel-13-20260427-072534.md`：protected VM + VFIO 到达 login，guest 内 `/dev/nvme0n1` 可见，只读 direct I/O 返回 `DD_RC=0`，`crosvm` 返回 `CROSVM_RC=0`。
- 非破坏性回归记录为 `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t12-regression-after-kernel-13-20260427-073526.md`：`T12-G2`、`T12-G1`、`T12-A1` 和三轮 `T12-G3` 均为 `COMPLETE`，返回值均为 `0`。
- 本轮未执行 `T12-A2b`，因为该用例需要主动触碰 Host BAR。`T12-B1`、`T12-C1`、`T12-R2` 的完整判据仍需要额外 trace 或状态探针。
- 本轮未再出现 `pkvm: deny host BAR remap` 后接 general protection fault。`ptdev BAR revoked` 精确字符串仍未出现，当前源码中也没有该字符串。

**GitHub / 分支状态**

- GitHub：MrGeek-zrh/pkvm-x86#34 仍 OPEN / `status/in-progress`。
- `pKVM-IA` 当前 topic branch：`t12-mmio-donate-phase1`
- 当前本地 `pKVM-IA` HEAD：`a1b02bd8c012`
- 该分支尚未看到对应的 GitHub PR；上一轮已合并内核 PR 到 MrGeek-zrh/pKVM-IA#3。

**关键源码**

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`：`pkvm_host_ept_annotate_mmio_owner()`、`pkvm_host_ept_restore_mmio_idmap()`、Host EPT annotation lookup / deny-remap
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h`：invalid PTE owner encoding、`OWNER_ID_PTDEV_MMIO`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`：BAR owner/state/progress、metadata cache / publish / withdraw、A/C/B attach、restore helper
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`：ptdev BAR state definitions

**参考文档**

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T12-B5-3-protected-pVM-device-MMIO-donate-机制总设计.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T12-B5-3-Host-BAR隔离-ARM对齐设计草案.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T12-B5-3-protected-pVM-assigned-BAR-Host-CPU-访问权收口.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T12-B5-3-device-MMIO-donate-第一阶段实现规划.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-设备BAR-MMIO-donate机制总结.md`
- `DOCS/日报/2026-04-17-B5-3-BAR-donate机制设计.md`

## 当前交接重点

### 1. 不要把已关闭旧签名重新混追

- `BOOT-006`：shadow spgt refcount blocker 已由 T1 解决。
- `BOOT-007`：protected vCPU `EFAULT` 旧签名已由 crosvm config/MMIO path 收敛解除。
- `BOOT-008`：runtime DMA mirror 主签名已由 T2/T3 解决。
- `BOOT-009`：`copy_gpa__pkvm` 写 fault 已由 B4 解决。
- `BOOT-012`：BAR HPA 误入 donation 已由 B5-2 / T10 解决。
- `BOOT-013`：MMIO PFN 误 pin 已由 T11 解决。
- 若 T12 后续出现新的 GPF / Oops / deny-remap 后崩溃，应新建独立 `Bug` issue，不要改写旧 bug 的语义。

### 2. 当前真正主线是 T12，不是 T4

- `T4` 已完成第一版“teardown 前 block DMA”并通过当前推荐矩阵，后续可以作为 DMA-safe barrier 的基础。
- `T12` 是 assigned BAR Host CPU authority 收口，解决的是 Host CPU 是否还能碰 BAR 控制面。
- 两者相关但不是同一个问题：T4 不应阻塞 T12，T12 也不替代 T4 的 DMA quiesce 语义。

### 3. T12 后续重点

- `T12-A1` 在 `6.12.0-pkvm-ia #13` 上已有正向证据，旧的 deny-remap 后 general protection fault 已消失。
- 下一步应把 `T12-A2b` 放到高影响测试队列；该用例会主动触碰 Host BAR，因此需要单独安排。
- `T12-B1`、`T12-C1`、`T12-R2` 需要配套 trace 或状态探针，否则只能作为有限证据。
- `ptdev BAR revoked` 精确字符串不在当前源码中。后续若继续沿用原判据，需要先调整日志要求或补充相应打印点。
- 暂时不要全量编译内核；如果需要验证，先做最小对象目标或让接手人手工确认编译范围。

### 4. 开放事项清单

- MrGeek-zrh/pkvm-x86#34：T12 Host CPU 访问权收口，当前主线。
- MrGeek-zrh/pkvm-x86#22：`BOOT-011` manifest reject 后 `vfio group busy`。
- MrGeek-zrh/pkvm-x86#17：T8 T2/T3 review follow-up。
- MrGeek-zrh/pkvm-x86#9：T5 prepopulate 与首次 attach。
- MrGeek-zrh/pkvm-x86#10：T6 remove-path 与失败回滚。
- MrGeek-zrh/pkvm-x86#11：T7 端到端验证矩阵与回归。

## 已合并 PR 速查

### pKVM-IA

- MrGeek-zrh/pKVM-IA#1：`收敛 protected pgstate_pgt 为 DMA mirror 并同步 donate 后的 leaf`
- MrGeek-zrh/pKVM-IA#2：`Enforce boot manifest at pVM attach boundary`
- MrGeek-zrh/pKVM-IA#3：`T4: 在 VM teardown 前预先封锁 ptdev DMA`

### pkvm-x86 superproject

- MrGeek-zrh/pkvm-x86#14：固化 protected pVM 第一阶段 ptdev metadata 与 MMIO allowlist ABI。
- MrGeek-zrh/pkvm-x86#16：同步 T2/T3 验证快照与内核集成点。
- MrGeek-zrh/pkvm-x86#23：同步 T9 manifest validation evidence。
- MrGeek-zrh/pkvm-x86#25：同步 B5-2 Guest EPT BAR 边界实现与验证闭环。
- MrGeek-zrh/pkvm-x86#33：同步 T4 首轮实现与 BOOT-014 验证闭环。
