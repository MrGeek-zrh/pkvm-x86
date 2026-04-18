# [T12] B5-3 Host BAR 隔离的 ARM 对齐设计草案

## 目的

这份文档用于讨论 `pkvm-x86#34` 的下一轮设计：在 protected pVM 设备透传场景下，如何隔离 Host CPU 对已分配给 pVM 的设备 BAR / MMIO 区域的访问。

本文回答三件事：

1. 当前 pKVM-IA 要完整隔离 Host 对 pVM 设备 BAR 的访问，还缺少哪些能力。
2. ARM pKVM 在同类设备 BAR / MMIO ownership 场景下是怎么做的。
3. pKVM-IA 可以如何参考 ARM，把当前方案从“地址特判”推进成“设备资源 ownership 状态机”。

## 当前决策

- 已决定丢弃上一轮未提交的 x86 本地 patch：
  - attach 时直接 `pkvm_host_ept_unmap()` BAR
  - Host EPT fault 时按 attached BAR 地址 deny-remap
  - detach 时直接 `pkvm_host_ept_map()` BAR
- 丢弃原因不是“Host BAR 不需要隔离”，而是那版实现仍然是局部补丁：
  - BAR ownership 状态没有成为 hyp 内部的 authoritative state
  - Host EPT invalid leaf 没有记录“这段 MMIO 已不归 Host”
  - fault deny-remap 依赖地址扫描，无法表达 reset、DMA quiesce、IOMMU group、rollback 的一致性
- 下一轮应转向 ARM 对齐的设计：把 device BAR / MMIO 当作一种设备资源，由 pKVM/hyp 维护 owner 与 lifecycle，而不是只在 fault path 上做地址黑名单。

## 当前 pKVM-IA 已有基础

### 1. 启动期可信设备清单

pKVM-IA 已经有 boot manifest，用于冻结启动期可接受的设备与 BAR 区间：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`
  - `struct pkvm_boot_ptdev_bar_entry`
  - `struct pkvm_boot_ptdev_manifest_entry`
  - `pkvm_hyp.boot_ptdev_manifest[]`

当前 helper 可以按 BDF 查询 manifest，也可以判断一个 HPA 是否落在 manifest BAR 中：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_boot_ptdev_manifest_lookup()`
  - `pkvm_boot_ptdev_bar_contains()`
  - `pkvm_host_hpa_hits_boot_ptdev_bar()`
  - `pkvm_vm_hpa_hits_attached_boot_ptdev_bar()`

但这里的 manifest 目前更像“启动期输入快照”，还不是完整的 device ownership state。

### 2. `ptdev` 已经承载部分设备上下文

当前 `struct pkvm_ptdev` 已经有：

- `bdf` / `pasid` / `did`
- IOMMU shadow / DMA mirror 相关 `pgt`
- `shadow_vm_handle`
- `dma_blocked`
- `mmio_metadata_valid`
- `mmio_metadata`
- `vm_node`

源码：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`

这说明 x86 不一定要新造一个与 `pkvm_device` 完全平行的对象；可以先让 `ptdev` 扩展出 ARM `pkvm_device` 的关键能力：资源快照、当前 owner、assignment state、rollback state。

### 3. 当前 attach / detach 已经切换 DMA 视角

当前 `pkvm_attach_ptdev()` 的核心动作是：

```text
pkvm_attach_ptdev()
    -> pkvm_get_or_create_ptdev_checked()
    -> ptdev->shadow_vm_handle = vm_handle
    -> ptdev->pgt = &vm->pgstate_pgt
    -> pkvm_shadow_vm_link_ptdev()
    -> pkvm_iommu_sync()
```

当前 `pkvm_detach_ptdev()` 的核心动作是：

```text
pkvm_detach_ptdev()
    -> ptdev->shadow_vm_handle = 0
    -> ptdev->dma_blocked = false
    -> clear mmio_metadata
    -> ptdev->pgt = pkvm_hyp->host_vm.ept
    -> pkvm_shadow_vm_unlink_ptdev()
    -> pkvm_iommu_sync()
```

源码：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_attach_ptdev()`
  - `pkvm_detach_ptdev()`
  - `pkvm_quiesce_ptdev()`

但这条链路主要切换的是 DMA / IOMMU 视角，没有把设备 BAR 的 Host CPU 访问权纳入同一个状态机。

更具体地说，当前 `pkvm_attach_ptdev()` / `pkvm_detach_ptdev()` 都没有直接修改 Host EPT 里的 BAR leaf：

- attach 时没有对已存在的 Host BAR 映射做 revoke / annotation
- detach 时也没有按 BAR ownership 恢复 Host 侧可见性

这意味着当前实现只切了“设备 DMA 视角”，没有切“Host CPU 视角”：

- 如果 Host 之前已经因为 EPT fault 或其它路径把某个 BAR 映射进 Host EPT，
  那么仅靠后续在 `handle_host_ept_violation()` 里禁止 lazy remap，并不能回收这条已经存在的映射
- 因而对 `handle_host_ept_violation()` 的 deny-remap 改造是必要条件，但不是充分条件
- 真正的 ownership 切换必须发生在 attach / detach 主链，而不是等到 Host 再次 fault 时才“被动发现”

### 4. pKVM-IA 已有普通 RAM owner annotation 机制

pKVM-IA 的普通 RAM donate 路径已经会在 Host EPT 的 invalid PTE 里写 owner annotation：

```text
__pkvm_host_donate_guest(...)
    -> do_donate(tx)
        -> host_initiate_donation(tx)
            -> find_mem_range(addr, &range)
            -> hyp_page_count(__hyp_va(cur))
            -> host_ept_set_owner_locked(..., owner_id)
                -> pkvm_pgtable_annotate(host_ept, addr, size, annotation)
```

相关源码：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
  - `host_initiate_donation()`
  - `host_ept_set_owner_locked()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c`
  - `pkvm_pgtable_annotate()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h`
  - `PKVM_INVALID_PTE_OWNER_MASK`
  - `PKVM_PAGE_STATE_PROT_MASK`

但这条 donate 链路目前明确只接受普通 RAM：

```text
host_initiate_donation()
    -> find_mem_range(addr, &range)
        -> 只接受 hyp_memory / memblock 中的普通 RAM
    -> hyp_page_count(__hyp_va(cur))
        -> 依赖 hyp vmemmap / struct hyp_page 元数据
```

因此不能直接把设备 BAR 塞进现有普通 RAM donate 主链。

## 当前缺少的能力

### 能力 1：BAR 资源级 authoritative state

当前 x86 的 BAR 信息分散在几个地方：

- boot manifest：启动期看到的 BDF 与 BAR HPA
- `ptdev->mmio_metadata`：Host/userspace 提交给 hyp 的 MMIO metadata
- `shadow_vm->mmio_allow_ranges[]`：guest 查询和 `pkvm_virt_mmio()` 消费的 allowlist
- `ptdev->pgt`：DMA mirror / IOMMU 二级页表根

缺口是：没有一个 hyp 内部对象明确记录“这个 BAR resource 当前 owner 是 Host / Hyp / Guest”。

建议补齐：

```c
enum pkvm_ptdev_bar_owner {
	PKVM_PTDEV_BAR_OWNER_HOST,
	PKVM_PTDEV_BAR_OWNER_HYP,
	PKVM_PTDEV_BAR_OWNER_GUEST,
};

enum pkvm_ptdev_bar_state {
	PKVM_PTDEV_BAR_HOST_VISIBLE,
	PKVM_PTDEV_BAR_HOST_REVOKED,
	PKVM_PTDEV_BAR_GUEST_ASSIGNED,
	PKVM_PTDEV_BAR_RESTORING,
};
```

这里的 `owner` 与 `state` 分工不同：

- `owner`
  - 回答“这段 BAR 当前逻辑上归谁裁决”
  - 主要服务于 Host EPT fault、reclaim、restore
- `state`
  - 回答“这段 BAR 当前走到 assignment 生命周期的哪一步”
  - 主要服务于 attach、guest assign、detach、rollback

两者不是重复字段，也不是任意组合：

- `owner` 更像权限真相
- `state` 更像流程位置
- 第一阶段建议只允许少数合法组合，避免状态爆炸

建议的合法组合如下：

```text
HOST_VISIBLE   + OWNER_HOST
    初始态 / restore 完成态

HOST_REVOKED   + OWNER_HYP
    Host -> Hyp 已完成
    guest 还没正式拿到 BAR

GUEST_ASSIGNED + OWNER_HYP
    第一阶段推荐形态
    guest 已有 direct BAR 权限，但最终 authority 仍由 hyp 持有

GUEST_ASSIGNED + OWNER_GUEST
    更接近 ARM 的“Hyp -> Guest”显式移交形态
    第一阶段可以先不采用

RESTORING      + OWNER_HYP
    正在从 guest/hyp 撤回给 Host
    尚未完成 Host restore
```

不应出现的组合包括：

```text
HOST_VISIBLE   + OWNER_HYP / OWNER_GUEST
HOST_REVOKED   + OWNER_HOST
GUEST_ASSIGNED + OWNER_HOST
RESTORING      + OWNER_HOST
```

之所以需要同时保留 `owner` 和 `state`，是因为单靠其中一个都不够：

- 只靠 `owner` 不够：
  - `OWNER_HYP` 既可能表示“Host 已被 revoke，但 guest 还没拿到 BAR”
  - 也可能表示“guest 已经在用 BAR，但最终 authority 仍在 hyp”
  - 这两种情况必须由 `state` 区分
- 只靠 `state` 也不够：
  - Host fault 路径最终更适合只回答“Host 还是不是 owner”
  - 这也是 ARM 参考实现的关键思路：设备 assignment 状态在 `pkvm_device.ctxt` 一侧，Host 能否 remap 则由 host stage-2 owner annotation 决定

从 ARM 语义看，这两条轴大致对应：

```text
设备 assignment 轴
    -> struct pkvm_device
        -> resources[]
        -> ctxt

Host fault / remap 轴
    -> host stage-2 invalid owner annotation
```

相关源码：

- `refs/android-kernel-common/include/kvm/device.h`

  - `struct pkvm_device`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`

  - `__pkvm_device_assign()`
  - `pkvm_host_map_guest_mmio()`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/mem_protect.c`

  - `__host_stage2_set_owner_locked()`
  - `host_stage2_adjust_range()`
- HOST_VISIBLE

  - Host 正常可见、可访问
  - Host EPT 里有正常 UC 映射
  - 这是 attach 前/完全 restore 后的稳态
- HOST_REVOKED

  - Host 访问权已被撤掉
  - Host EPT 里应是 invalid owner annotation，不允许 fault 后 lazy remap
  - 这是 “Host -> Hyp” 已完成、但 guest 还没真正拿到 BAR 的中间稳态
- GUEST_ASSIGNED

  - guest 已经拿到 direct BAR 权限/映射
  - Host 仍然不能 remap 回来
  - 这是设备真正被 pVM 使用时的稳态
- RESTORING

  - 正在从 guest/hyp 还回 Host
  - guest 侧权限正在撤、DMA 应已 quiesce/block
  - 这是 teardown / rollback 的过渡态

并在 `struct pkvm_ptdev` 下挂 BAR resource snapshot：

```text
struct pkvm_ptdev
    -> struct pkvm_ptdev_bar bars[]
        -> base
        -> size
        -> flags
        -> owner
        -> state
        -> generation
```

第一阶段可以只支持 boot-known memory BAR；MSI-X table / PBA 子区间、config space、hotplug 后续再扩展。

这里几个术语在当前专题里的含义如下：

- `boot-known memory BAR`
  - 指 Host 启动期已经枚举到、并被冻结进 boot manifest 的 MMIO 型 BAR
  - 对应启动期可信设备清单中的 `bars[]`
  - 见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`
- `MSI-X table / PBA 子区间`
  - 指落在某个 BAR 内部、专门用于 MSI-X 中断投递管理的特殊偏移区间
  - 当前实现里这类子区间不等价于普通 BAR 寄存器区，通常继续走 emulate/special handling
- `config space`
  - 指 PCI 配置空间，不是普通 BAR MMIO
  - 包含 vendor/device id、BAR 寄存器本身、capability 链等
  - 第一阶段继续走 emulated 路径，不做 direct BAR ownership 切换
- `hotplug`
  - 指系统启动后再动态加/拔设备
  - 当前第一阶段默认只覆盖静态 attach，不覆盖运行期新设备进入和 remove-path

### 能力 2：MMIO 版 Host -> Hyp ownership transfer

这个能力对应到当前代码里的直接缺陷就是：

- `pkvm_attach_ptdev()` 目前只切 `ptdev->pgt` 和 `pkvm_iommu_sync()`，没有显式撤销 Host CPU 对目标 BAR 的访问权
- `pkvm_detach_ptdev()` 目前也没有按 BAR resource / owner 状态恢复 Host 侧映射
- 因而当前缺的不是“一个 fault deny-remap 条件”而已，而是一条 attach / detach 主链上的 `Host CPU BAR authority handoff`

普通 RAM donate 之所以不能直接复用，是因为后面整条链默认对象是普通内存：

- 地址必须落在 `find_mem_range()` 管理的 `hyp_memory`
- 每页有 hyp vmemmap / `struct hyp_page` 元数据
- 可以通过 `hyp_page_count(__hyp_va(cur))` 做 pin / refcount 检查
- 可以按 RAM 属性映射到 guest / hyp

设备 BAR / MMIO 不满足这些条件：

- 不在 `hyp_memory` 里
- 没有可 refcount 的普通 RAM page 元数据
- 不应该使用 WB RAM 属性
- 不应该走 `pkvm_pin_page()` / RAM donation 的 refcount 模型

因此需要一条单独的 MMIO ownership transfer helper，例如：

```text
pkvm_host_donate_ptdev_bar_to_hyp(ptdev, bar)
    -> validate bar resource belongs to boot manifest + ptdev metadata
    -> annotate Host EPT invalid leaf with OWNER_ID_HYP or device-owner id
    -> record bar.owner = HYP
    -> flush Host EPT
```

这里的 `validate bar resource belongs to boot manifest + ptdev metadata`
不要理解成“Host 已经把最终 HPA 传给 hyp，hyp 只是顺手验一下”。

更准确地说，这里有两层不同时间点的校验：

```text
attach / metadata time
    Host -> hyp: kvm_ptdev_mmio_metadata
        -> 只带 bdf / pasid / bar_index / bar_offset / size / guest_gpa
        -> 不直接带最终 HPA
    hyp:
        -> lookup boot manifest entry by bdf
        -> manifest_bar = entry->bars[bar_index]
        -> check bar_offset + size <= manifest_bar.size
        -> hpa = manifest_bar.base + bar_offset
        -> 固化为 hyp 自己维护的 BAR resource

map time
    Host -> hyp: pkvm_vm_mmu_map(gpa, hpa, size, writable)
    hyp:
        -> 校验 hpa 是否命中当前 VM attached BAR 或 Host RAM
```

也就是说：

- attach / metadata 阶段，hyp 自己计算 `hpa = manifest_bar.base + bar_offset`
  - 不是因为 Host 不会算
  - 而是因为这个阶段的 metadata UAPI 本来就不直接携带 HPA，只携带 `bar_index / bar_offset / size / guest_gpa`
- map 阶段，Host 的确会把 `hpa` 传进 `pkvm_vm_mmu_map()`
  - 但那是“这次 guest 建图请求的 HPA”
  - 不是 attach 阶段 BAR resource authority 的来源

attach 阶段由 hyp 自己把 `bar_index + bar_offset` 解析成可信 HPA range，有四个直接用途：

- 生成 `ptdev->bars[]` / BAR snapshot，形成 hyp 自己掌握的 resource truth
- 给 Host EPT invalid leaf 写 owner annotation
- 给后续 `pkvm_vm_mmu_map()` 做命中校验提供 authoritative BAR range
- 给 detach / rollback 时的 Host BAR restore 提供精确目标区间

当前代码现状也正对应这两层：

- `pkvm_set_ptdev_mmio_metadata()` 当前只拿到 metadata，本身还没有直接接收 HPA
- `struct kvm_protected_vm_ptdev_mmio_range` 当前只定义了 `guest_gpa / size / bar_offset / bar_index / kind`
- `pkvm_vm_mmu_map()` 当前已经会对 Host 传入的 `hpa` 做一次 map-time 校验

其中：

- `record bar.owner = HYP`
  - 指在 hyp 自己维护的 `ptdev BAR snapshot` 里，把这段 BAR 的软件状态记成“当前由 Hyp 裁决”
  - 不是往 Guest EPT 注入 annotation
  - 也不是替代 Host EPT annotation
- 真正需要写入 annotation 的，是 Host EPT invalid leaf
  - 这样 `handle_host_ept_violation()` 才能在 Host fault 时读出 non-Host owner，拒绝 lazy remap

关于 `device-owner id`：

- 这不是当前 x86 树里已有的正式概念
- 它只是一个可选设计方向，意思是：
  - 不把 BAR revoke 后统一标成 `OWNER_ID_HYP`
  - 而是给某个具体 `ptdev/BAR` 资源分配一个更细粒度的 owner id
- 第一阶段默认更推荐直接使用 `OWNER_ID_HYP`
  - 已足够表达“这段 BAR 不再归 Host”
  - 也更接近 ARM 当前真正依赖的关键语义：Host fault 只需知道 owner 不是 Host
- 只有在后续需要更细的 debug、审计或 rollback 校验时，再考虑引入 `device-owner id`

这不是“把普通 RAM donate 放宽到 MMIO”，而是为 MMIO 建一条独立 donation 语义：只做 owner / mapping / cacheability / fault remap 约束，不做 hyp_page refcount。

### 能力 3：Host EPT fault 必须识别 owner annotation

当前 `handle_host_ept_violation()` 对非 RAM 地址的基本行为是：

```text
handle_host_ept_violation()
    -> find_mem_range(gpa, &range)
        -> 若是普通 RAM，拒绝
        -> 若不是普通 RAM，range 表示当前地址所在的 memblock hole
    -> pkvm_pgtable_lookup(host_ept, gpa, &hpa, ...)
    -> 若当前没映射
        -> 在 hole 范围内按 HOST_EPT_DEF_MMIO_PROT 重新 pkvm_host_ept_map()
```

这里的关键点是：

- 这段逻辑解释的是当前现状，不是目标设计
- `find_mem_range()` 在“未命中 RAM”时虽然返回 `false`，但会把 `range.start/end` 填成 fault 地址所在的 memblock hole 边界
- 后面的循环会按当前 EPT level 反复对齐 `gpa`，尝试找一个完整落在该 hole 内的 `cur` 区间，再把整段 `cur` 当普通 MMIO map 回 Host
- 这正是 `pkvm-x86#34` 的核心风险：assigned BAR 往往也落在这类非 RAM hole 中，若没有额外 owner 约束，就会被当成普通 MMIO lazy remap

源码：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - `handle_host_ept_violation()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c`
  - `find_mem_range()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.h`
  - `HOST_EPT_DEF_MMIO_PROT`

这正是 `pkvm-x86#34` 需要拦住的点：如果某个 BAR 已经交给 pVM，但 Host EPT fault 又把它作为普通 MMIO hole 自动 map 回 Host，Host CPU 仍然能访问设备控制面。

下一轮不建议继续做“扫描所有 manifest BAR 并按地址拒绝”的临时逻辑。更稳的做法是：

```text
handle_host_ept_violation()
    -> host_ept_lookup_with_annotation(gpa)
        -> 若 invalid PTE 带 owner annotation 且 owner != HOST
            -> return -EPERM
        -> 否则继续普通 MMIO lazy map
```

`host_ept_lookup_with_annotation()` 不是当前已有函数，而是建议补齐的 helper。它的职责是：

- 查 Host EPT 当前地址是否已有有效映射
- 若没有有效映射，继续区分：
  - invalid 且 annotation 为 0：真正空洞
  - invalid 且 annotation 非 0：带 owner annotation 的 non-Host 资源

第一阶段建议的返回结构可收敛为：

```c
enum host_ept_lookup_kind {
	HOST_EPT_LOOKUP_PRESENT,
	HOST_EPT_LOOKUP_ANNOTATED,
	HOST_EPT_LOOKUP_EMPTY,
};

struct host_ept_lookup_result {
	enum host_ept_lookup_kind kind;
	unsigned long hpa;
	u64 prot;
	u64 annotation;
	u64 raw_pte;
	pkvm_id owner_id;
	int level;
};
```

字段建议如下：

- `kind`
  - 第一优先的分流字段，避免 `valid + annotated` 这种多 bool 组合
- `hpa` / `prot`
  - 仅 `HOST_EPT_LOOKUP_PRESENT` 时有效
- `annotation` / `owner_id`
  - 仅 `HOST_EPT_LOOKUP_ANNOTATED` 时有效
- `raw_pte`
  - 第一阶段暂时保留，便于 bring-up / debug / trace 时直接核对 Host EPT 原始 entry
  - 但业务逻辑默认不应依赖它手拆 bit；正常应优先消费 `kind / owner_id / annotation`
- `level`
  - 便于 fault 路径继续计算候选 `cur` 区间

使用方式建议收敛为：

```text
PRESENT
    -> Host EPT 已有映射，返回 -EAGAIN

ANNOTATED
    -> 若 owner != HOST，拒绝 remap

EMPTY
    -> 才允许继续走普通 MMIO hole lazy remap
```

这样 deny-remap 命中的不是“所有 manifest 里的 BAR”，也不是“所有 attached BAR 地址”，而是 Host EPT 中已经被 pKVM 明确标成 non-Host owner 的 BAR resource。

### 能力 4：Guest BAR 映射必须从 Hyp-owned BAR 来

当前 pKVM-IA 已经有 guest direct BAR allowlist 与 direct BAR MMIO 分流，但这更多解决“guest 访问时是否 direct / fallback”，不是 BAR ownership。

下一轮应把 Guest BAR 映射的前置条件改成：

```text
guest wants direct BAR mapping/access
    -> 找到当前 VM attached ptdev
    -> 找到 BAR resource
    -> 要求 bar.owner == HYP 或 bar.owner == GUEST
    -> install guest direct BAR / allowlist
    -> bar.owner = GUEST
```

第一阶段可以继续复用现有 allowlist 作为 guest 查询面，但 hyp 内部应明确区分：

- allowlist：guest 能看到/使用哪些 GPA MMIO 区间
- ownership：Host 是否还能 map / 访问对应 HPA BAR

### 能力 5：teardown / rollback 的资源状态恢复

当前工作记录（2026-04-17）：

- `T4` 第一版已按既定验收口径完成并关闭，不再作为当前进行中主任务
- 当前主线前移到 `B5-3 / T12`
- 下次继续讨论的入口就从本节开始，重点是：
  - teardown / attach-fail / remove-path 下 BAR owner/state 如何收敛
  - DMA quiesce、guest allowlist 撤销、Host EPT restore 三者的安全顺序
  - 哪些能力应先作为第一阶段 contract 固化，哪些继续留给 `T6` / follow-up
上一轮临时 patch 把 restore 放在 detach 里，但缺少 generation 与部分失败 rollback 语义。

下一轮应要求：

```text
detach / teardown / attach-fail
    -> quiesce or block DMA
    -> withdraw guest BAR mapping / allowlist
    -> reclaim BAR owner to HYP
    -> restore Host EPT owner to HOST
    -> bar.owner = HOST
    -> clear ptdev assignment state
```

这里必须和 `T4`、`T6` 对齐：

- `T4`：VM 销毁前 quiesce ptdev DMA
- `T6`：VFIO remove-path 与失败回滚
- 截至 2026-04-17，当前阶段还进一步明确：
  - 不让 `T12` / BAR ownership 反向阻塞已完成的 `T4` 第一版“前置 quiesce / block DMA”修复
  - `T4` 当前第一版任务已按既定验收口径完成；后续如需继续提高 teardown 生命周期置信度或做状态机收敛，应作为 follow-up 承接
  - 等 BAR ownership 相关能力完整落地后，再回头评估是否把 `T4` 的 teardown 编排统一到同一套 `ptdev owner/state` 状态机里

否则容易出现：

- Host EPT 已恢复，但设备还在 DMA
- attach 失败后 BAR 半撤销
- VM teardown 后 `ptdev` 清掉了，但 Host EPT invalid annotation 还在

### 能力 6：IOMMU group / reset / DMA block 的一致性扩展点

ARM 的完整模型会把 device reset、DMA block、IOMMU group assign 与 BAR owner 变更放在同一个临界区。pKVM-IA 当前还没有完整等价能力：

- reset hook：当前 `ptdev` 没有 reset handler / cookie
- IOMMU group 原子切换：当前 attach 是单 `bdf/pasid` 视角
- rollback：当前失败回滚主要依赖局部路径，没有设备组状态机
- remove-path：仍是 `T6` 待处理范围

第一阶段不一定要一次性补全，但 `ptdev` 的新状态设计必须给这些能力留字段和状态边界，避免后续再推翻。

## ARM pKVM 怎么做到

ARM 参考实现中，设备 BAR / MMIO 的核心不是“fault 特判”，而是 `struct pkvm_device` 驱动的 ownership 状态机。

### 1. 启动期注册 assignable device

ARM 在 host 侧启动期解析 assignable devices，生成 `struct pkvm_device` 表：

- `refs/android-kernel-common/arch/arm64/kvm/pkvm.c`
  - `pkvm_register_device()`
  - `pkvm_init_devices()`

`struct pkvm_device` 记录：

- `resources[]`
- `iommus[]`
- `nr_resources`
- `nr_iommus`
- `group_id`
- `ctxt`
- `refcount`
- `reset_handler`
- `cookie`

源码：

- `refs/android-kernel-common/include/kvm/device.h`

这点和 x86 boot manifest 的目标相似：启动期把可分配设备资源冻结下来。但 ARM 进一步把它提升成 hyp 内部的 authoritative device state。

### 2. Host 先把设备 MMIO donate 给 Hyp

ARM 的设备 MMIO 首先走：

```text
pkvm_device_hyp_assign_mmio()
    -> pkvm_get_device(phys, size)
    -> 检查 dev->ctxt / dev->refcount
    -> ___pkvm_host_donate_hyp_prot(pfn, nr_pages, accept_mmio=true, PAGE_HYP_DEVICE)
```

源码：

- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`
  - `pkvm_device_hyp_assign_mmio()`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/mem_protect.c`
  - `___pkvm_host_donate_hyp_prot()`

关键点：

- `accept_mmio=true` 明确说明这不是普通 RAM donation。
- `PAGE_HYP_DEVICE` 明确说明 Hyp 按 device/MMIO 属性持有这段资源。

### 3. Host stage-2 owner annotation 拦住 lazy remap

ARM 的 Host owner 更新在：

```text
__host_stage2_set_owner_locked(addr, size, owner_id, ...)
    -> owner_id == PKVM_ID_HOST
        -> host_stage2_idmap_locked()
    -> owner_id != PKVM_ID_HOST
        -> kvm_pgtable_stage2_annotate()
```

Host fault lazy map 前会检查 invalid PTE 是否带 annotation：

```text
handle_host_mem_abort()
    -> host_stage2_idmap(addr)
        -> host_stage2_adjust_range(addr, &range)
            -> invalid PTE 且 pte != 0
                -> return -EPERM
```

源码：

- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/mem_protect.c`
  - `__host_stage2_set_owner_locked()`
  - `host_stage2_adjust_range()`
  - `host_stage2_idmap()`
  - `handle_host_mem_abort()`

这就是 ARM 对 x86 `#34` 最关键的参考：Host fault 不能只看地址属于不属于 MMIO hole，还必须看这段地址是否已经被 owner annotation 明确标为 non-Host。

### 4. 首次 Guest 映射前做 group assignment

ARM 不是单页 fault 里直接把 MMIO 给 guest，而是：

```text
pkvm_host_map_guest_mmio()
    -> pkvm_get_device_by_addr()
    -> 若 dev->ctxt == NULL
        -> __pkvm_group_assign(dev->group_id, vm)
            -> __pkvm_device_assign(dev, vm)
                -> hyp_check_range_owned(res->base, res->size)
                -> pkvm_device_reset(dev, true)
                -> kvm_iommu_dev_block_dma(...)
                -> dev->ctxt = vm
    -> __pkvm_install_guest_mmio()
        -> pkvm_hyp_donate_guest()
```

源码：

- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`
  - `pkvm_host_map_guest_mmio()`
  - `__pkvm_group_assign()`
  - `__pkvm_device_assign()`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/mem_protect.c`
  - `pkvm_hyp_donate_guest()`

这里体现的是 `Host -> Hyp -> Guest`：

```text
Host
    -> Hyp owns full device MMIO resource
        -> reset / block DMA / assign group
            -> Guest receives MMIO mapping
```

### 5. Guest 可按页请求 MMIO 身份验证

ARM 还提供 `ARM_SMCCC_KVM_FUNC_DEV_REQ_MMIO`：

- guest / pvmfw 传入 IPA
- hyp 找到该 IPA 对应 token
- hyp 检查 token 是否落在当前 VM 已 assigned 的 device resource
- 成功后 guest 可用 token 对照受信设备描述

源码：

- `refs/android-kernel-common/Documentation/virt/kvm/arm/hypercalls.rst`
  - `ARM_SMCCC_KVM_FUNC_DEV_REQ_MMIO`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`
  - `pkvm_device_request_mmio()`

x86 第一阶段可以不实现 token，但设计上应避免把 guest allowlist 误当成最终身份验证机制。

### 6. teardown 时恢复 Host owner

ARM teardown：

```text
pkvm_devices_teardown(vm)
    -> for each dev where dev->ctxt == vm
        -> pkvm_device_reset(dev, false)
        -> dev->ctxt = NULL
        -> pkvm_devices_reclaim_device(dev)
            -> host_stage2_set_owner_locked(res->base, res->size, PKVM_ID_HOST)
```

源码：

- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`
  - `pkvm_devices_teardown()`
  - `pkvm_devices_reclaim_device()`

这说明 restore 不是单纯“map 回 Host”，而是 owner state 回到 Host。

## pKVM-IA 参考设计

### 设计目标

第一阶段目标：

- protected pVM
- 单个 VFIO PCI device
- 静态 attach
- boot-known memory BAR
- Host CPU 不能通过 Host EPT lazy remap 重新访问 assigned BAR
- guest direct BAR 现有路径保持可用
- detach / attach-fail 不留下半撤销 Host EPT 状态

第一阶段非目标：

- hotplug
- migration
- 多设备 group 原子切换
- MSI-X table / PBA 子区间精细化
- config space 直达
- guest token 式 MMIO 身份验证
- 完整 reset framework

但字段和状态机要给这些后续能力留扩展点。

### 建议一：把 `ptdev` 对齐为 x86 的 device authority object

不必机械复制 ARM 的 `struct pkvm_device`。x86 可以把 `ptdev` 升级为 authority object：

```text
struct pkvm_ptdev
    identity:
        bdf
        pasid
        did
    attachment:
        shadow_vm_handle
        vm_node
    dma/iommu:
        pgt
        dma_blocked
        iommu_coherency
    mmio contract:
        mmio_metadata
        mmio_metadata_valid
        bars[]
        bar_owner
        bar_state
        generation
```

这样 `ptdev` 与 ARM `pkvm_device` 的职责对齐：

- 设备身份
- 资源列表
- 当前归属
- DMA/IOMMU 状态
- assignment 生命周期

### 建议二：从 boot manifest + metadata 固化 BAR snapshot

attach 前应生成 BAR snapshot：

```text
pkvm_prepare_ptdev_bar_resources(ptdev, vm)
    -> lookup boot manifest by bdf
    -> validate metadata ranges are inside manifest BAR
    -> copy boot-known memory BAR into ptdev->bars[]
    -> mark bars owner=HOST state=HOST_VISIBLE
```

注意：manifest 只说明“启动期可信地看见过这个设备和 BAR”，metadata / allowlist 只说明“guest 期望 direct 的 GPA/HPA 区间”。真正可被 Host revoke 的 resource 应由 hyp 固化为 `ptdev->bars[]`。

这里要再区分清楚两类“区间”：

- metadata 里的区间
  - 语义是“guest 想 direct 哪个 BAR 子区间”
  - 用 `bar_index + bar_offset + size + guest_gpa` 表达
- `ptdev->bars[]` 里的区间
  - 语义是“hyp 已经确认、可用于 Host revoke / restore / owner tracking 的真实 HPA resource”
  - 应由 hyp 根据 boot manifest 自己解出，而不是直接相信 Host 传来的某个 HPA

因此第一阶段推荐在 attach / metadata 阶段就完成：

```text
metadata range
    + boot manifest BAR base/size
        -> authoritative HPA resource range
            -> ptdev BAR snapshot
            -> Host EPT owner annotation target
            -> detach / rollback restore target
```

### 建议三：新增 BAR MMIO Host -> Hyp donation

建议新增一条 MMIO 专用路径，而不是改宽普通 RAM donate：

```text
pkvm_revoke_ptdev_bar_from_host(ptdev)
    -> for each bar in ptdev->bars
        -> require bar.owner == HOST
        -> pkvm_host_ept_annotate_owner(bar.base, bar.size, OWNER_ID_HYP or OWNER_ID_PTDEV)
        -> bar.owner = HYP
        -> bar.state = HOST_REVOKED
    -> pkvm_flush_host_ept()
```

这里的 `pkvm_host_ept_annotate_owner()` 可以复用 `pkvm_pgtable_annotate()` 的底层能力，但不能复用 `host_initiate_donation()` 的普通 RAM 前置检查。

需要补齐的底层能力：

- 读取 invalid PTE annotation 的 helper
- 对 MMIO BAR 做 owner annotation 的 helper
- Host EPT fault 中识别 annotation 并拒绝 remap
- restore 时把 owner 切回 Host 并按 UC RWX map 回 Host

### 建议四：Host EPT fault 只尊重 owner state

Host fault path 的判断顺序建议改为：

```text
handle_host_ept_violation()
    -> if address is normal RAM
        -> reject
    -> host_ept_lookup_with_annotation(gpa)
        -> if invalid annotated owner != HOST
            -> reject
    -> otherwise
        -> existing ordinary MMIO lazy remap
```

这有两个好处：

- 不会误伤 manifest 中尚未 assigned 给 pVM 的设备 BAR。
- 不会依赖 `ptdev` list 扫描来决定 fault 语义；fault 的真相在 Host EPT owner annotation 里。

### 建议五：Guest BAR enable 从 Hyp-owned 状态出发

attach / guest allowlist 可按如下顺序收敛：

```text
pkvm_attach_ptdev()
    -> get/create checked ptdev
    -> prepare BAR resources
    -> revoke BAR from Host: HOST -> HYP
    -> switch DMA/IOMMU view to vm->pgstate_pgt
    -> publish guest MMIO allowlist
    -> bar.owner = GUEST or keep HYP-with-guest-mapping
```

关于 `bar.owner` 到底设置成 `GUEST` 还是保留为 `HYP-with-guest-mapping`，需要实现时再定。建议讨论时先保留两个选项：

- 选项 A：严格对齐 ARM，把最终 mapping 视为 `HYP -> GUEST`，owner 标成 `GUEST`。
- 选项 B：第一阶段把 BAR owner 保留为 `HYP`，guest direct BAR 作为受 hyp 控制的映射许可；等 Guest EPT BAR install 语义更完整后再切到 `GUEST`。

无论选哪种，Host 都不能再是 owner。

### 建议六：detach / rollback 必须按状态反向恢复

推荐状态恢复顺序：

```text
pkvm_detach_ptdev()
    -> quiesce/block DMA
    -> clear guest allowlist / guest BAR mapping
    -> switch ptdev->pgt back to host EPT
    -> reclaim BAR owner to Host
        -> owner annotation removed
        -> Host EPT UC RWX mapping restored
    -> clear ptdev BAR state
    -> pkvm_iommu_sync()
```

attach 失败要以 generation 做部分 rollback：

```text
attach fail
    -> if BAR revoke generation started
        -> restore only bars revoked by this generation
    -> detach ptdev
```

### 建议七：把 reset / group / token 作为后续扩展点

第一阶段可以只做 Host CPU BAR 隔离，但结构上建议预留：

- `group_id` 或后续 IOMMU group handle
- optional reset hook / reset state
- DMA block state 与 BAR revoke state 的顺序约束
- guest token / BAR identity query 所需的 resource id

这样后续从第一阶段演进到更接近 ARM 的完整状态机时，不需要再次推翻 `ptdev` 数据结构。

## 建议状态机

### BAR owner/state 协同

```text
HOST_VISIBLE
    Host EPT has UC RWX mapping
    bar.owner = HOST

HOST_REVOKED
    Host EPT has invalid owner annotation
    Host EPT fault sees owner != HOST and rejects lazy remap
    bar.owner = HYP

GUEST_ASSIGNED
    guest has direct BAR permission or mapping
    Host still cannot lazy remap
    bar.owner = GUEST or HYP-with-guest-mapping

RESTORING
    guest permission is being withdrawn
    DMA should already be blocked/quiesced
    Host owner restore is in progress
```

上面这组状态机建议按如下顺序流转：

```text
HOST_VISIBLE/OWNER_HOST
    -> attach revoke
HOST_REVOKED/OWNER_HYP
    -> publish guest BAR permission
GUEST_ASSIGNED/OWNER_HYP
    -> begin detach/rollback
RESTORING/OWNER_HYP
    -> host restore done
HOST_VISIBLE/OWNER_HOST
```

这里第一阶段更推荐 `GUEST_ASSIGNED + OWNER_HYP`，而不是立刻切到
`GUEST_ASSIGNED + OWNER_GUEST`，原因是：

- 更接近当前 x86 现状：guest direct BAR 更像“由 hyp 授权的 direct access”，而不是 BAR 完全脱离 hyp
- detach / rollback 更简单：Host restore 前不需要再做一次严格的 `Guest -> Hyp` owner 回收
- 后续如果要继续向 ARM 的 `Host -> Hyp -> Guest` 显式 ownership 迁移靠齐，再把这一态细化即可

### attach 主链

```text
pkvm_attach_ptdev()
    -> pkvm_get_or_create_ptdev_checked()
    -> pkvm_prepare_ptdev_bar_resources()
    -> pkvm_ptdev_bar_host_to_hyp()
        -> Host EPT owner annotation
        -> Host EPT flush
    -> ptdev->shadow_vm_handle = vm_handle
    -> ptdev->pgt = &vm->pgstate_pgt
    -> pkvm_shadow_vm_link_ptdev()
    -> pkvm_iommu_sync()
    -> publish guest MMIO allowlist
```

### Host fault 主链

```text
handle_host_ept_violation()
    -> normal RAM?
        -> reject
    -> invalid owner annotation?
        -> owner != HOST: reject
    -> ordinary MMIO hole?
        -> lazy remap as current path
```

### detach / rollback 主链

```text
pkvm_detach_ptdev()
    -> pkvm_quiesce_ptdev()
    -> clear guest MMIO allowlist
    -> ptdev->pgt = host EPT
    -> pkvm_ptdev_bar_hyp_to_host()
        -> restore Host EPT mapping
        -> Host EPT flush
    -> unlink ptdev
    -> pkvm_iommu_sync()
    -> pkvm_put_ptdev()
```

## 分阶段实现建议

### P0：修正设计真相源

- 在 `ptdev` 增加 BAR resource snapshot 与 owner/state 字段。
- attach 前由 manifest + metadata 固化 BAR resource。
- 不改普通 RAM donate 主链，不把 MMIO 强塞进 `host_initiate_donation()`。

### P1：Host EPT owner annotation for BAR

- 增加 MMIO BAR 专用 Host EPT owner annotation helper。
- 增加读取 invalid annotation 的 helper。
- 修改 `handle_host_ept_violation()`：
  - owner annotation 命中 non-Host 时拒绝 remap
  - 未标注的普通 MMIO hole 继续保持现有 lazy remap

### P2：attach / detach 状态机接入

- attach：Host -> Hyp revoke，再切 DMA/IOMMU view。
- detach：先 quiesce/block DMA，再 restore Host owner。
- attach-fail：按 generation rollback。

### P3：与 T4 / T6 合流

- T4：明确 quiesce 与 BAR restore 的顺序。
- T6：把 remove-path、失败回滚、多设备共享纳入状态机。
- 对每条 teardown / remove / fail path 增加“Host EPT owner 最终回到 Host”的检查点。
- 截至 2026-04-17，当前阶段计划进一步明确为：
  - `T12` 先独立把 BAR ownership 本身做完整：`ptdev` BAR snapshot、`owner/state`、Host EPT invalid owner annotation、Host fault deny-remap
  - `T4` 当前第一版已完成，不再作为进行中 blocker 等待 BAR ownership
  - 等 BAR ownership 功能完善后，再回头评估是否用同一套 `owner/state` 把 `T4` 的 teardown 编排进一步统一
- 这样做的原因是：
  - `T4` 的直接 correctness 目标是“guest 页回到 Host 前，DMA 必须先不可达”
  - `T12` 的直接 correctness 目标是“Host CPU 不能再通过 BAR / Host EPT 访问 assigned BAR”
  - BAR ownership 可以成为后续统一生命周期状态机的骨架，但不应反向阻塞当前 `T4` 第一版修复

### P4：后续增强

- IOMMU group 原子 assignment。
- reset hook。
- MSI-X table / PBA 子区间策略。
- guest token 式 BAR identity query。

## 待讨论问题

1. x86 第一阶段是否把 BAR owner 标成 `GUEST`，还是先保留 `HYP-with-guest-mapping`？
2. Host EPT invalid annotation 的 owner id 第一阶段是否直接统一使用 `OWNER_ID_HYP`，而把 `device-owner id` 留作后续 debug / rollback 增强项？
3. BAR resource snapshot 应完全来自 boot manifest，还是 manifest 与 `SET_PTDEV_MMIO_METADATA` 做交集？
4. `pkvm_iommu_sync()` 与 Host BAR revoke 的顺序是否必须是先 revoke 再切 DMA？
5. detach 时是否强制调用 `pkvm_quiesce_ptdev()`，还是由 T4 的 teardown 主线统一保证？
6. 第一阶段是否只 restore 整 BAR，还是预留 MSI-X table / PBA 子区间跳过逻辑？
7. Host EPT annotation helper 是否应做成通用 `set_owner`，还是先只暴露给 `ptdev` BAR？

## 与现有任务的关系

- `pkvm-x86#34` / T12：
  - 当前文档是它的下一轮设计草案。
  - 旧的“attach unmap + fault denylist + detach map”本地 patch 已丢弃。
- `pkvm-x86#20` / B5：
  - T12 是 B5-2 之后暴露出的 Host CPU BAR authority follow-up。
- `T4`：
  - 决定 teardown 前 DMA quiesce 与 BAR restore 的安全顺序。
- `T6`：
  - 决定 remove-path / attach-fail / rollback 的完整覆盖。
- ARM 参考总结：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-设备BAR-MMIO-donate机制总结.md`

## 源码锚点

### pKVM-IA

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`
  - `struct pkvm_boot_ptdev_manifest_entry`
  - `pkvm_hyp.boot_ptdev_manifest[]`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
  - `struct pkvm_ptdev`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_boot_ptdev_manifest_lookup()`
  - `pkvm_host_hpa_hits_boot_ptdev_bar()`
  - `pkvm_vm_hpa_hits_attached_boot_ptdev_bar()`
  - `pkvm_quiesce_ptdev()`
  - `pkvm_attach_ptdev()`
  - `pkvm_detach_ptdev()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - `handle_host_ept_violation()`
  - `pkvm_host_ept_map()`
  - `pkvm_host_ept_unmap()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.h`
  - `HOST_EPT_DEF_MMIO_PROT`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
  - `host_initiate_donation()`
  - `host_ept_set_owner_locked()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c`
  - `pkvm_pgtable_lookup()`
  - `pkvm_pgtable_annotate()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c`
  - `find_mem_range()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h`
  - `struct pkvm_shadow_vm`

### ARM pKVM

- `refs/android-kernel-common/include/kvm/device.h`
  - `struct pkvm_device`
- `refs/android-kernel-common/arch/arm64/kvm/pkvm.c`
  - `pkvm_register_device()`
  - `pkvm_init_devices()`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`
  - `pkvm_init_devices()`
  - `pkvm_device_hyp_assign_mmio()`
  - `pkvm_host_map_guest_mmio()`
  - `__pkvm_group_assign()`
  - `__pkvm_device_assign()`
  - `pkvm_device_request_mmio()`
  - `pkvm_devices_teardown()`
  - `pkvm_devices_reclaim_device()`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/mem_protect.c`
  - `__host_stage2_set_owner_locked()`
  - `host_stage2_adjust_range()`
  - `host_stage2_idmap()`
  - `handle_host_mem_abort()`
  - `___pkvm_host_donate_hyp_prot()`
  - `pkvm_hyp_donate_guest()`
- `refs/android-kernel-common/Documentation/virt/kvm/arm/hypercalls.rst`
  - `ARM_SMCCC_KVM_FUNC_DEV_REQ_MMIO`
