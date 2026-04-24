# [T12] B5-3 protected pVM 设备 MMIO 捐赠（donate）机制总设计

## 目的

> **文档语言约定：** 默认使用中文描述设计、状态和结论；英文只保留代码符号、UAPI/ABI 名称、日志签名、命令输出和少量必须固定的技术术语。

这份文档作为 `B5-3 / T12` 的总入口，用于汇总当前已经收敛的 设备 MMIO 捐赠（donate）机制设计结论。

这里的“donate”不是指复用普通 RAM 的 `__pkvm_host_donate_guest()` 实现，而是指：

- Host 必须失去对 已透传设备 MMIO/BAR 的直接裁决权；
- 设备 MMIO 资源进入由 hyp 维护的 owner/state（所有权/状态）生命周期；
- guest 如需 直接访问许可（direct permission），也是在 hyp 持有最终权威状态的前提下发布；
- detach / rollback 时再由 hyp 统一把资源恢复（restore）回 Host。

换句话说，第一阶段的目标语义更接近：

```text
Host
  -> 将受管理 BAR 的权威状态交给 Hyp
  -> Hyp 发布 guest 直接访问许可（direct permission）
  -> Hyp 撤回许可并把 BAR 恢复给 Host
```

而不是把设备 BAR 继续塞进普通 RAM donate 主链。

## 文档关系（总-分）

本文件是总文档；分文档和相关依赖如下：

- `[01E-T12-B5-3-Host-BAR隔离-ARM对齐设计草案.md](01E-T12-B5-3-Host-BAR隔离-ARM对齐设计草案.md)`
  - 保留 ARM 对齐背景、BAR 所有权细节推导和细颗粒度讨论。
- `[04-P0-VM销毁前quiesce-ptdev-DMA.md](04-P0-VM销毁前quiesce-ptdev-DMA.md)`
  - 保留 `T4` 的 DMA 安全屏障设计与实现结论。
- `[06-P1-VFIO-remove-path与失败回滚.md](06-P1-VFIO-remove-path与失败回滚.md)`
  - 保留 `T6` 的设备移除路径、attach 失败调用方覆盖和后续回滚收口。

后续如需讨论总方案，以本文为主入口；如需展开 BAR 所有权 / ARM 对齐背景，再回到分文档。

## 第一阶段范围

第一阶段当前锁定的目标范围：

- protected pVM
- 单个 VFIO PCI 设备
- 静态 attach
- boot-known memory BAR
- Host CPU 不能继续通过 Host EPT lazy remap 重新访问 assigned BAR
- guest 直通 BAR 现有路径保持可用
- detach / rollback 的资源恢复必须有一致约定

第一阶段当前明确不做：

- 严格类 ARM（ARM-like） `OWNER_GUEST`
- hotplug / migration
- 多设备 group 原子切换
- MSI-X 表（table）/ PBA 的 BAR 子区间 owner 切片
- 配置空间直达
- 复位框架（reset framework）

## 当前已锁定的总设计

### 当前 donate 机制完整工作过程（第一阶段）

```mermaid
sequenceDiagram
    participant Host
    participant Hyp
    participant pVM

    Note over Host,Hyp: 初始态：Host 持有 BAR authority；Host CPU 可访问 BAR
    Note over Hyp,pVM: guest 尚无 direct BAR contract；DMA_VIEW_READY = 0

    rect rgb(245, 245, 210)
        Note over Host,Hyp: 阶段 1：Hyp 固化权威 BAR 快照
        Host->>Hyp: SET_PTDEV_MMIO_METADATA
        Hyp->>Hyp: 校验 metadata range 落在 manifest BAR 内
        Hyp->>Hyp: 生成 ptdev BAR 快照 / managed_bar_mask
        Hyp->>Hyp: 清空 touched_bar_mask
    end

    rect rgb(255, 245, 210)
        Note over Host,Hyp: A：Host -> Hyp BAR donate
        Hyp->>Hyp: 撤销 Host 当前 BAR visible leaf
        Hyp->>Hyp: 在 Host EPT invalid leaf 写 owner 标注（annotation）
        Hyp->>Hyp: bar.progress: HOST_VISIBLE -> REVOKED
        Hyp->>Hyp: touched_bar_mask 记录本轮已成功撤销可见性的 BAR
        Hyp->>Hyp: 全部 revoke 成功后 owner: HOST -> HYP
        Note over Host,Hyp: 从这里开始，后续 Host 缺页 会因为 annotation 命中而 deny-remap
    end

    rect rgb(230, 245, 255)
        Note over Hyp,pVM: C：切 DMA 视角到 guest
        Hyp->>Hyp: ptdev->pgt = vm->pgstate_pgt
        Hyp->>Hyp: pkvm_iommu_sync()
        Hyp->>Hyp: DMA_VIEW_READY = 1
    end

    rect rgb(235, 255, 235)
        Note over Hyp,pVM: B：发布 guest MMIO 约定
        Hyp->>pVM: publish direct BAR permission / allowlist
        Hyp->>Hyp: all 受管理 BAR.progress = CONTRACT_PUBLISHED
        Hyp->>Hyp: assignment_state = GUEST_ASSIGNED
        Note over Hyp,pVM: 运行态：pVM 有 直接访问许可（direct permission）；最终 authority 仍在 Hyp
        Note over Host,pVM: Host 无法 remap 回 受管理 BAR
    end

    rect rgb(255, 240, 240)
        Note over pVM,Hyp: detach / teardown / rollback 开始
        pVM-->>Hyp: detach request / teardown trigger / rollback trigger
        Note over Hyp: 前置条件：必须先证明 DMA_UNREACHABLE
        Note over Hyp: 证明 1：DMA_VIEW_READY = 0
        Note over Hyp: 证明 2：caller 已显式 静默 / 阻断 DMA
        Hyp-x pVM: withdraw guest MMIO 约定
        Hyp->>Hyp: assignment_state = RESTORING
        Hyp->>Hyp: touched BAR.progress = RESTORING
        opt DMA 曾切给 guest
            Hyp->>Hyp: ptdev->pgt = host EPT
            Hyp->>Hyp: pkvm_iommu_sync()
            Hyp->>Hyp: DMA_VIEW_READY = 0
        end
        Hyp->>Host: 恢复 touched BAR visibility
        Hyp->>Host: 清除 Host EPT owner 标注（annotation）
        Note over Host,Hyp: commit 规则：全部 touched BAR restore 成功前，不提前发布 HOST_VISIBLE
        Hyp->>Host: final commit：owner HYP -> HOST
        Hyp->>Hyp: assignment_state = DETACHED
        Hyp->>Hyp: touched_bar_mask = 0
    end

    Note over Host,Hyp: 最终态：Host 重新拿回 BAR authority
    Note over Hyp,pVM: guest 约定 已撤销
    Note over Host,pVM: 失败侧规则 1：attach 失败时只回滚 touched_bar_mask 内已成功撤销可见性的 BAR
    Note over Host,pVM: 失败侧规则 2：restore 中途失败时 对外状态（public state） 保持 RESTORING + owner=HYP
```

### attach A/C/B 状态转换与失败回退图

```mermaid
stateDiagram-v2
    [*] --> DETACHED

    DETACHED: owner=HOST
    DETACHED: assignment_state=DETACHED
    DETACHED: DMA_VIEW_READY=0
    DETACHED: BAR.progress=HOST_VISIBLE

    ATTACHING: owner=HOST
    ATTACHING: assignment_state=ATTACHING
    ATTACHING: touched_bar_mask=已成功撤销可见性的 BAR
    ATTACHING: BAR.progress=HOST_VISIBLE/REVOKED mixed

    HOST_REVOKED: owner=HYP
    HOST_REVOKED: assignment_state=HOST_REVOKED
    HOST_REVOKED: DMA_VIEW_READY=0
    HOST_REVOKED: all 受管理 BAR.progress=REVOKED

    DMA_READY: owner=HYP
    DMA_READY: assignment_state=HOST_REVOKED
    DMA_READY: DMA_VIEW_READY=1
    DMA_READY: guest 约定 未发布

    GUEST_ASSIGNED: owner=HYP
    GUEST_ASSIGNED: assignment_state=GUEST_ASSIGNED
    GUEST_ASSIGNED: DMA_VIEW_READY=1
    GUEST_ASSIGNED: BAR.progress=CONTRACT_PUBLISHED

    RESTORING_PRE_DMA: C 阶段提交前恢复
    RESTORING_PRE_DMA: DMA_UNREACHABLE already true
    RESTORING_PRE_DMA: restore_bar_mask=touched_bar_mask

    RESTORING_POST_DMA: C 阶段提交后恢复
    RESTORING_POST_DMA: must quiesce/block DMA first
    RESTORING_POST_DMA: restore_bar_mask=touched_bar_mask

    DETACHED --> ATTACHING: start attach - snapshot ready
    ATTACHING --> HOST_REVOKED: A success - Host BAR donate done
    HOST_REVOKED --> DMA_READY: C success - IOMMU sync committed
    DMA_READY --> GUEST_ASSIGNED: B 成功 - 发布 guest 约定

    ATTACHING --> RESTORING_PRE_DMA: A fail - rollback touched BAR only
    HOST_REVOKED --> RESTORING_PRE_DMA: C C 阶段提交前失败 - DMA_VIEW_READY=0
    DMA_READY --> RESTORING_POST_DMA: B C 阶段提交后失败 - DMA_VIEW_READY=1
    GUEST_ASSIGNED --> RESTORING_POST_DMA: detach/remove/teardown - contract already published

    RESTORING_PRE_DMA --> DETACHED: restore done - owner -> HOST, clear touched_bar_mask
    RESTORING_POST_DMA --> DETACHED: restore done - DMA_UNREACHABLE proven, withdraw contract if any, owner -> HOST

    RESTORING_PRE_DMA --> RESTORING_PRE_DMA: restore fail - keep RESTORING + owner=HYP, no partial HOST_VISIBLE publish
    RESTORING_POST_DMA --> RESTORING_POST_DMA: restore fail - keep RESTORING + owner=HYP, no partial HOST_VISIBLE publish
```

### 1. `ptdev` 是 x86 侧的权威状态对象

第一阶段不再单独引入一套平行于 ARM `pkvm_device` 的新对象，而是把 `ptdev` 视为 x86 侧的 设备权威状态对象。

它至少需要承载四类真相：

- 设备身份：`bdf` / `pasid` / `did`
- 绑定关系 / DMA 视角：`shadow_vm_handle`、`pgt`、`dma_blocked`
- guest MMIO 约定：`mmio_metadata`
- BAR 资源权威状态：BAR 快照、受管理集合、owner/state、恢复账本

这与当前实现位置是对齐的：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`

### 2. 第一阶段不采用严格 `OWNER_GUEST`

第一阶段已明确：

- guest 可以有 直接访问许可（direct permission）；
- 但最终 authority 仍由 hyp 持有；
- 因而对外更准确的表述是 `GUEST_ASSIGNED + owner=HYP`，而不是 `owner=GUEST`。

当前先不采用严格 `OWNER_GUEST` 的原因是：

- x86 当前已有的 metadata / allowlist 更像“访问许可”，不是完整的“ownership transfer”。
- 当前最直接的 correctness 目标，是收口 Host BAR revoke / deny-remap / restore，而不是先做完整 `Guest -> Hyp` owner reclaim。
- 先保留 `owner=HYP`，能让 attach / detach / rollback contract 更接近当前实现，也更容易与 `T4` / `T6` 解耦。

因此第一阶段只保留设备级 `owner`：

```text
ptdev.owner = HOST | HYP
```

`GUEST` 作为未来扩展预留，不进入本阶段已锁定方案。

### 3. owner 是设备级；BAR 级只跟踪 progress

第一阶段已明确：

- 一个设备只有一个 authoritative owner；
- 不做“不同 BAR 各自拥有不同 owner”的模型；
- BAR 级记录的是执行进度，而不是 BAR 级 owner。

因此状态分层如下：

```text
设备级:
  ptdev.owner
  ptdev.assignment_state

BAR 级:
  bar.progress
```

对应字段语义：

- `ptdev.owner`
  - 谁持有最终 authority
- `ptdev.assignment_state`
  - 设备当前处于 attach / assigned / restore 的哪一阶段
- `bar.progress`
  - 单个 BAR 在该阶段已经走到哪一步

### 4. 先固化 BAR 快照，再进入 捐赠 / 恢复

第一阶段已明确：attach 之前，hyp 必须先把 `boot manifest + metadata` 收敛成自己的 BAR 快照；后续 owner/state/restore 都只认这份 snapshot。

这里“BAR 快照 已固化”指的是：

- hyp 已经根据 boot manifest 确认了这台设备有哪些可信 BAR resource；
- hyp 已经根据 metadata 判断哪些 BAR / 子区间要对 guest direct；
- hyp 已经把后续要管理的 BAR 集合固定为内部 authoritative state；
- 但这还不等于 Host 已 revoke、guest 约定 已发布、DMA 已切给 guest。

本阶段对应的两个关键账本字段也已锁定为简化版：

```text
managed_bar_mask
  长期字段，表示本设备哪些 BAR 属于 B5-3 管理范围

touched_bar_mask
  单轮字段，表示本轮 attach/remove/restore 真正动过哪些 BAR
```

同时已明确：

- `metadata.generation` 只表示 guest MMIO 约定 版本；
- 它不参与 hyp 内部 restore 范围判定；
- restore 范围只看 `touched_bar_mask`。

相关字段位置：

- `pKVM-IA/arch/x86/include/asm/kvm_host.h`
- `pKVM-IA/arch/x86/include/uapi/asm/kvm.h`

### 5. assigned 设备的 managed set 必须完整

第一阶段已锁定的 managed set 规则：

- 一个已经分配给 pVM 的 `ptdev`，其 boot manifest / BAR 快照 中确认的设备 MMIO BAR，都必须进入 `managed_bar_mask`。
- 不允许出现“设备已经 `GUEST_ASSIGNED`，但某个 受管理 BAR 仍然 `HOST_VISIBLE`”的状态。

这条规则的核心目的是避免出现：

```text
同一台已经 assigned 的设备
  一部分 BAR 已经进入 guest 约定
  另一部分 BAR 仍然保留 Host 侧可见
```

这会让“设备已经透传给 pVM”这个事实在 Host CPU 视角上不再自洽。

### 6. MSI-X 表（table） / PBA 不进 guest direct subset，但 BAR 仍受管理

第一阶段已选定的策略是：

- MSI-X 表（table） / PBA 继续 trap/emulate；
- 不把它们纳入 guest direct subset；
- 也不要求第一阶段先实现 BAR 子区间 owner/state 切片。

但这不等于 Host 保留这些 BAR 的 owner 或直接访问权。

更准确的语义是：

```text
BAR 属于 managed set
Host BAR 映射已 revoke
guest direct subset 排除 MSI-X / PBA 子区间
MSI-X / PBA 继续 trap/emulate
```

## 状态机与不变量

### 设备级 对外状态（public state）

第一阶段当前锁定的设备级 对外状态（public state）：

```text
DETACHED
ATTACHING
HOST_REVOKED
GUEST_ASSIGNED
RESTORING
```

其中 `HOST_REVOKED` 保留为 对外状态（public state）；DMA 视角是否已经切到 guest，只通过内部位表达：

```text
DMA_VIEW_READY = 0 | 1
```

第一阶段不再单独把“DMA 已切给 guest”升成新的 对外状态（public state）。

### BAR 级 progress

第一阶段当前锁定的 BAR 级 progress：

```text
HOST_VISIBLE
REVOKED
CONTRACT_PUBLISHED
RESTORING
```

这里的 `CONTRACT_PUBLISHED` 表示“该 BAR 的 guest-side contract 已发布”，不是说 BAR owner 已切成 guest。

### 状态不变量总表

```text
DETACHED
  ptdev.owner = HOST
  ptdev.assignment_state = DETACHED
  DMA_VIEW_READY = 0
  guest 约定 = 未发布
  所有 受管理 BAR.progress = HOST_VISIBLE
  touched_bar_mask = 0

ATTACHING
  ptdev.owner = HOST
  ptdev.assignment_state = ATTACHING
  DMA_VIEW_READY = 0
  guest 约定 = 未发布
  受管理 BAR.progress = HOST_VISIBLE / REVOKED 可混合
  touched_bar_mask = 本轮已成功撤销可见性的 BAR

HOST_REVOKED
  ptdev.owner = HYP
  ptdev.assignment_state = HOST_REVOKED
  DMA_VIEW_READY = 0 或 1
  guest 约定 = 未发布
  所有 受管理 BAR.progress = REVOKED
  touched_bar_mask = managed_bar_mask

GUEST_ASSIGNED
  ptdev.owner = HYP
  ptdev.assignment_state = GUEST_ASSIGNED
  DMA_VIEW_READY = 1
  guest 约定 = 已发布
  所有 受管理 BAR.progress = CONTRACT_PUBLISHED

RESTORING
  ptdev.owner = HYP
  ptdev.assignment_state = RESTORING
  DMA_VIEW_READY = 0，且 DMA 必须已不可达
  guest 约定 = 对 guest 不再可用
  所有 受管理 BAR.progress = RESTORING
  touched_bar_mask = 本轮需要 restore 的 BAR
```

对应还锁定了两条关键不变量：

- `ATTACHING` 允许部分 BAR 已经 `REVOKED`，因为这只是在提前收紧 Host 能力。
- `RESTORING` 不允许任何 受管理 BAR 提前回到 `HOST_VISIBLE`；`HOST_VISIBLE` 只能在全部恢复成功后作为 final commit 一次性发布。

## attach contract

第一阶段当前锁定的 attach 主线如下：

```text
DETACHED
  -> ATTACHING
      A: 撤销 Host BAR 访问权
  -> HOST_REVOKED
      C: 把 DMA 视图切到 guest-side pgstate
      B: 发布 guest MMIO 约定
  -> GUEST_ASSIGNED
```

其中：

- `A` = 撤销 Host BAR 访问权 / Host BAR 捐赠给 Hyp
- `C` = 切换 DMA 视角
- `B` = 发布 guest MMIO 约定

当前已经锁定的结论是：

- 真正的安全分界点是 `A`；
- 只要 `A` 做到了，Host CPU 就不能继续通过 Host EPT 重新映射回已透传 BAR；
- `B/C` 的先后主要影响 attach 完整性，而不是 Host 隔离本身；
- 第一阶段推荐顺序为 `A -> C -> B`。

这里的 “Host BAR 捐赠给 Hyp” 具体不要求复用普通 RAM donate helper，但语义必须是：

```text
Host BAR visible
  -> Host EPT revoke / invalid owner 标注（annotation）
  -> ptdev.owner = HYP
  -> 受管理 BAR.progress = REVOKED
```

当前相关实现锚点：

- attach 主链：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- guest MMIO 约定 publish：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`

## 恢复 / 回滚约定

### 恢复范围

第一阶段已明确：

```text
restore_bar_mask = touched_bar_mask
```

不再把 `generation` 当作 hyp 内部恢复选择器。

但这里要特别说明：`touched_bar_mask` 只定义 **BAR 恢复的资源范围**，不等于“完整回滚只做 BAR 恢复”。

第一阶段的完整回滚 / 恢复语义，至少同时覆盖 4 个平面：

```text
1. guest 约定平面
   - 如果 guest MMIO 约定 / 访问名单已发布
   - 回滚时需要先撤回

2. DMA 视图 平面
   - 如果 DMA_VIEW_READY = 1
   - 回滚时需要把 ptdev->pgt 切回 host EPT
   - 然后做 pkvm_iommu_sync()

3. Host BAR 可见性平面
   - 对 restore_bar_mask = touched_bar_mask 内的 BAR
   - 清 Host EPT owner 标注（annotation）
   - 恢复 Host BAR 可见 leaf

4. 内部记录 / 设备状态平面
   - ptdev.owner / assignment_state 回到稳定态
   - touched_bar_mask 清零
```

因此当前文档中的：

```text
回滚的 BAR 资源范围 = touched_bar_mask
```

更准确的解读应是：

```text
回滚的 BAR 资源范围 = touched_bar_mask
完整回滚动作 != 只恢复这些 BAR
```

### 恢复前置条件

任何进入 BAR 恢复的路径，都必须先满足：

```text
DMA_UNREACHABLE
```

合法证明只有两种：

```text
证明 1：
  DMA_VIEW_READY = 0
  即 DMA 视角尚未真正切给 guest

证明 2：
  调用者已经显式完成 阻断 / 静默（block / quiesce）
  即 DMA 之前可能切给过 guest，但现在已被 hyp 明确切断
```

对应的职责边界也已锁定：

- `恢复（restore）辅助函数` 不负责替调用者做 quiesce；
- 但任何调用恢复（restore）辅助函数的路径，都必须先证明 `DMA_UNREACHABLE` 成立。

### C 阶段提交前后的 attach 失败分叉

这里先把 `C` 定义为 **guest DMA 视图提交成功**，而不是“代码曾经写过 `ptdev->pgt`”：

```text
C 阶段提交 = ptdev->pgt 指向 vm->pgstate_pgt
         + pkvm_iommu_sync() 成功
         + DMA_VIEW_READY = 1
```

因此 attach 失败只按两个大分叉处理：

```text
C 阶段提交前失败
  guest DMA 视图 尚未真正生效
  -> 回滚不需要先静默 DMA（quiesce）
  -> 直接按回滚四平面处理
  -> DMA 视图平面通常无需操作

C 阶段提交后失败
  guest DMA 视图 已经真正生效
  -> 回滚前必须先证明 DMA_UNREACHABLE
  -> 静默 / 阻断 DMA 成功后才能进入 RESTORING
```

C 阶段提交前的回滚动作：

```text
guest 约定平面
  - 如果 B 尚未发布：无需操作
  - 如果因异常顺序已经发布：仍必须撤回

DMA 视图 平面
  - DMA_VIEW_READY = 0
  - 不需要 quiesce
  - 如果 ptdev->pgt 曾被临时改过但 sync 失败，应恢复为 host EPT

Host BAR 可见性平面
  - 只恢复 `touched_bar_mask` 内已撤销可见性的 BAR
  - 清 owner 标注（annotation） / 恢复 Host 可见 leaf

bookkeeping 平面
  - ptdev.owner -> HOST
  - assignment_state -> DETACHED
  - touched_bar_mask = 0
```

C 阶段提交后的回滚动作：

```text
前置
  - 必须先 静默 / 阻断 DMA
  - 或等价证明 DMA_UNREACHABLE

guest 约定平面
  - 如果 B 已发布：撤回访问名单 / direct BAR 约定
  - 如果 B 未发布：无需操作，但状态仍按 RESTORING 收口

DMA 视图 平面
  - ptdev->pgt = host EPT
  - pkvm_iommu_sync()
  - DMA_VIEW_READY = 0

Host BAR 可见性平面
  - restore touched_bar_mask 内 BAR
  - 不允许部分 BAR 提前对外发布 HOST_VISIBLE

bookkeeping 平面
  - 全部恢复成功后：
      ptdev.owner -> HOST
      assignment_state -> DETACHED
      touched_bar_mask = 0
```

### detach / remove / teardown 三段式

当前已锁定的逻辑分层如下：

```text
阶段 1：DMA 屏障
  调用方 / T4
    -> 静默 / 阻断 DMA
    -> 证明 DMA_UNREACHABLE

阶段 2：进入 RESTORING
  T12
    -> 撤回 guest 约定
    -> 受管理 BAR.progress = RESTORING
    -> ptdev.assignment_state = RESTORING

阶段 3：恢复并最终提交 host 状态
  T12
    -> 恢复 touched BAR
    -> 全部成功后一次性发布 HOST_VISIBLE
    -> ptdev.owner = HOST
    -> ptdev.assignment_state = DETACHED
```

这也意味着：

- `T12` 只定义 BAR owner/state 恢复约定；
- `T4` 继续提供 DMA 安全屏障（DMA-safe barrier）；
- `T6` 继续覆盖设备移除路径 / attach 失败的调用方编排。

## 与当前实现的映射

当前已经存在、并与上述约定 对齐的关键路径如下：

- `pkvm_quiesce_ptdev()` 负责设置 `dma_blocked` 并触发 IOMMU 同步：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- `pkvm_attach_ptdev()` 当前会把 `ptdev->pgt` 切到 `&vm->pgstate_pgt`：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- `pkvm_detach_ptdev()` 当前仍是折叠实现，一次性清 metadata、切回 host `pgt`、unlink、sync IOMMU：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- `pkvm_set_ptdev_mmio_metadata()` 当前一次性接收整份 metadata，并发布 allowlist：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- `dma_blocked` 对 IOMMU shadow context / PASID entry 的阻断效应：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`
- IOMMU 同步入口：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`

因此本轮设计文档的关键收敛点是：

- 当前实现已经具备 DMA 视角切换和 block 的基础能力；
- 但还没有把 Host BAR donate / owner 标注（annotation） / restore contract 纳入同一套 authoritative state；
- `T12` 要补的是这条 owner/state 主线，而不是把 MMIO 重新塞回普通 RAM donation。

## 第一阶段实现前置决策（2026-04-24）

本节用于把进入第一阶段实现规划前必须定下来的工程选择收口。

结论：当前设计可以进入 **第一阶段实现规划**，但这里的“第一阶段”只表示
`T12` 的最小 BAR 权威状态主线，不表示完整设备透传生命周期已经全部完成。
`T6` 继续负责设备移除路径（remove-path），复位/设备组原子性和严格
`OWNER_GUEST` 语义仍按后续阶段处理。

### D0. 第一阶段实现边界

第一阶段只承诺以下闭环：

```text
单个 protected pVM
  + 单个启动期已知的 VFIO PCI 设备
  + 启动 manifest 中的 memory BAR 快照
  + Host EPT owner 标注阻止 BAR 被重新映射
  + 现有 guest DIRECT_BAR 访问名单保持可用
  + detach / teardown / attach 失败回滚统一进入恢复（restore）辅助函数
```

第一阶段不把以下内容纳入完成条件：

- 完整 VFIO `FILE_DEL` / 设备组移除路径（group remove-path）编排；这仍归 `T6`。
- 复位框架、热插拔、迁移、多设备组原子切换。
- MSI-X 表 / PBA 的 BAR 子区间 owner 切片。
- 配置空间直接访问（config space direct access）。
- 严格类 ARM 的 `OWNER_GUEST` 语义。

### D1. `ptdev` 状态字段落点

第一阶段在 x86 侧继续把 `struct pkvm_ptdev` 作为设备权威状态对象，不另建平行
`pkvm_device` 对象。建议字段落在：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`

第一版字段形态按下面语义收敛，具体命名可在实现时保持内核风格：

```c
enum pkvm_ptdev_owner {
        PKVM_PTDEV_OWNER_HOST,
        PKVM_PTDEV_OWNER_HYP,
};

enum pkvm_ptdev_assignment_state {
        PKVM_PTDEV_DETACHED,
        PKVM_PTDEV_ATTACHING,
        PKVM_PTDEV_HOST_REVOKED,
        PKVM_PTDEV_GUEST_ASSIGNED,
        PKVM_PTDEV_RESTORING,
};

enum pkvm_ptdev_bar_progress {
        PKVM_PTDEV_BAR_HOST_VISIBLE,
        PKVM_PTDEV_BAR_REVOKED,
        PKVM_PTDEV_BAR_CONTRACT_PUBLISHED,
        PKVM_PTDEV_BAR_RESTORING,
};

struct pkvm_ptdev_bar_resource {
        u8 bar_index;
        u64 hpa;
        u64 size;
        enum pkvm_ptdev_bar_progress progress;
};
```

`struct pkvm_ptdev` 至少补齐：

```text
owner
assignment_state
dma_view_ready
managed_bar_mask
touched_bar_mask
bars[PCI_STD_NUM_BARS]
```

其中：

- `dma_blocked` 继续表示调用方或 `T4` 是否已经显式阻断/静默 DMA。
- `dma_view_ready` 只表示 C 阶段的 DMA 视图提交是否已经成功。
- `managed_bar_mask` 是长期资源集合。
- `touched_bar_mask` 是单轮 attach / restore 的恢复账本。

### D2. BAR 快照与元数据时序

第一阶段不把 Host BAR 撤销绑定到 metadata 的 direct 子区间。更稳的落点是：

```text
受管理 BAR 快照
  = boot manifest 中该 BDF 的启动期已知 memory BAR

guest DIRECT_BAR 约定
  = metadata 中通过 manifest / BAR 快照校验的直通子区间
```

因此时序决策如下：

1. `pkvm_attach_ptdev()` 进入 A 阶段前必须确保 BAR 快照存在。
   - 若快照不存在，则从 boot manifest 生成 `ptdev->bars[]` 与 `managed_bar_mask`。
   - 若 boot manifest 中没有该 BDF 或没有可管理 memory BAR，则 protected pVM attach 路径失败。
2. `SET_PTDEV_MMIO_METADATA` 负责校验并缓存 guest direct 意图。
   - metadata range 必须落在已知 BAR 快照 / manifest BAR 内。
   - metadata 不决定 Host restore 范围；restore 范围仍只看 `touched_bar_mask`。
3. metadata 到达顺序不应破坏状态机。
   - metadata 早于 A/C：只缓存和验证，不提前发布访问名单。
   - metadata 晚于 A/C：如果 `owner=HYP` 且 `dma_view_ready=1`，可在 metadata hypercall 中完成 B。
   - A/C 已完成但 metadata 尚未到达时，设备停在 `HOST_REVOKED + dma_view_ready=1 + guest 约定 未发布`。

这能同时兼容当前源码中 `pkvm_attach_ptdev()` 与
`pkvm_set_ptdev_mmio_metadata()` 分属两条入口的事实。

### D3. guest 约定发布不再等同于 metadata 缓存

当前 `pkvm_set_ptdev_mmio_metadata()` 收到 metadata 后会直接更新 VM 访问名单。
第一阶段实现必须把它拆成两个语义步骤：

```text
缓存并校验 metadata
  -> 记录 mmio_metadata / mmio_metadata_valid
  -> 校验 ranges 落在 ptdev BAR 快照内

发布 guest 约定
  -> 只允许在 Host BAR 已撤销后执行
  -> 要求 ptdev.owner == HYP
  -> 要求 assignment_state == HOST_REVOKED 或 GUEST_ASSIGNED
  -> 要求 dma_view_ready == 1
  -> 更新 vm->mmio_allow_ranges
  -> 受管理 BAR.progress = CONTRACT_PUBLISHED
  -> assignment_state = GUEST_ASSIGNED
```

detach / rollback 时必须先撤回 guest 约定，再进入 Host BAR restore。

### D4. Host EPT 标注编码

第一阶段 **不能直接使用 `OWNER_ID_HYP` 作为 BAR annotation owner id**。

原因是当前编码里：

```text
OWNER_ID_HYP = 0
PKVM_NOPAGE = 0
invalid PTE annotation = FIELD_PREP(owner_mask, owner_id) | PKVM_NOPAGE
```

如果 owner id 取 0，Host EPT invalid leaf 的 annotation 也可能表现为 0，
无法和真正 empty MMIO 空洞区分；Host 缺页路径也就不能可靠拒绝重映射。

第一阶段决策：

```text
ptdev.owner
  = HOST | HYP       // 设备级 authority 语义

Host EPT invalid annotation owner tag
  = non-zero reserved MMIO/BAR tag
  != OWNER_ID_HYP
  != OWNER_ID_HOST
```

也就是说，annotation tag 是 Host 缺页拒绝重映射的编码标记，
不等同于把设备 owner 语义切成 `OWNER_GUEST`。

实现时应新增一个非零、非 Host 的 reserved tag，例如：

```text
OWNER_ID_PTDEV_MMIO 或 PKVM_MMIO_OWNER_TAG_PTDEV
```

并用 `BUILD_BUG_ON()` 或等价静态检查保证它不会与当前 VM handle owner-id 空间冲突。
如果后续需要按设备/BAR 细分审计，再把 tag 扩展成 per-device / per-BAR owner id。

### D5. Host EPT 辅助函数/API 粒度

`ptdev.c` 不应直接调用 `mem_protect.c` 的静态内部函数，但可以复用底层
pgtable annotation 能力。推荐新增 Host EPT 层或 ptdev MMIO 层包装函数，
而不是把 `ptdev.c` 直接耦合到 `mem_protect.c` 的静态 helper：

```text
pkvm_host_ept_annotate_mmio_owner(hpa, size, owner_tag)
    -> host_ept_lock()
    -> pkvm_pgtable_annotate(host_ept, hpa, size, annotation)
    -> pkvm_flush_host_ept()
    -> host_ept_unlock()

pkvm_host_ept_restore_mmio_idmap(hpa, size, prot)
    -> host_ept_lock()
    -> pkvm_host_ept_map(hpa, hpa, size, 1 << PG_LEVEL_4K, prot)
    -> pkvm_flush_host_ept()
    -> host_ept_unlock()

pkvm_host_ept_lookup_mmio_annotation(gpa, result)
    -> 区分 PRESENT / ANNOTATED / EMPTY
```

这里强制第一版使用 4K 粒度，原因是：

- `pkvm_pgtable_annotate()` 当前按 4K leaf 写 annotation。
- BAR direct 子区间和 MSI-X/PBA 排除可能不是大页对齐。
- restore 不应因为大页映射覆盖到相邻 MMIO 空洞或非受管理 BAR。

### D6. Host EPT 缺页拒绝重映射规则

`handle_host_ept_violation()` 的第一阶段修改点只应依赖 Host EPT 标注，
不再扫描 manifest 全表做地址黑名单：

```text
handle_host_ept_violation(gpa)
    -> pkvm_host_ept_lookup_mmio_annotation(gpa)
        PRESENT
            -> return -EAGAIN
        ANNOTATED with non-Host ptdev MMIO tag
            -> return -EPERM
        EMPTY
            -> 继续普通 MMIO 空洞的 lazy map
```

这样 Host 缺页的判定来源就是 A 阶段写入 Host EPT 的 owner annotation，
而不是“地址是否碰巧属于某个 manifest BAR”。

### D7. attach A/C/B 的工程顺序

第一阶段实现顺序固定为 `A -> C -> B`：

```text
pkvm_attach_ptdev()
    -> 获取或创建 ptdev
    -> 必要时从 boot manifest 准备 BAR 快照
    -> assignment_state = ATTACHING
    -> dma_view_ready = 0
    -> touched_bar_mask = 0

    A: 撤销 Host BAR 可见性
        -> 遍历每个受管理 BAR
            -> pkvm_host_ept_annotate_mmio_owner()
            -> progress = REVOKED
            -> touched_bar_mask |= BIT(bar)
        -> 全部成功后
            -> owner = HYP
            -> assignment_state = HOST_REVOKED

    C: 切换 DMA 视图
        -> ptdev->pgt = &vm->pgstate_pgt
        -> 把 ptdev 链接到 vm
        -> pkvm_iommu_sync()
        -> 成功后: dma_view_ready = 1
        -> C 阶段提交前失败: 不需要 quiesce，按 touched BAR 回滚

    B: 如果 metadata 已经有效，则发布 guest 约定
        -> 更新 VM 访问名单
        -> progress = CONTRACT_PUBLISHED
        -> assignment_state = GUEST_ASSIGNED
```

C 失败时必须注意：`dma_view_ready` 只有在 `pkvm_iommu_sync()` 成功之后才能置 1。
如果代码已经临时改过 `ptdev->pgt`，但 sync 失败，回滚前必须把 `ptdev->pgt`
恢复为 host EPT。

### D8. 恢复（restore）辅助函数的第一版约定

第一阶段统一恢复辅助函数建议按下面语义收敛：

```text
pkvm_restore_ptdev_bars(ptdev, vm, dma_unreachable_proven)
    -> 要求 dma_unreachable_proven 为真，或者 dma_view_ready == 0
    -> assignment_state = RESTORING
    -> 如果 guest 约定已发布，先撤回 guest 约定
    -> 如果 dma_view_ready == 1
        -> ptdev->pgt = host EPT
        -> pkvm_iommu_sync()
        -> dma_view_ready = 0
    -> 遍历每个 touched BAR
        -> pkvm_host_ept_restore_mmio_idmap(HOST_EPT_DEF_MMIO_PROT)
    -> 只有全部 touched BAR 恢复成功后
        -> progress = HOST_VISIBLE
        -> owner = HOST
        -> assignment_state = DETACHED
        -> touched_bar_mask = 0
```

恢复权限使用当前 Host EPT lazy MMIO map 同源的默认 prot：

```text
pkvm_mkstate(HOST_EPT_DEF_MMIO_PROT, PKVM_PAGE_OWNED)
```

恢复失败语义：

- 如果 `pkvm_iommu_sync()` 失败，不能进入 Host BAR restore。
- 如果 Host BAR restore 中途失败，对外状态保持 `RESTORING + owner=HYP`。
- 重试必须能容忍个别 BAR leaf 已经被恢复成 Host 可见。
- 任何情况下都不能提前清空 `touched_bar_mask` 或 `pkvm_put_ptdev()`。

这里的“对外状态不提前发布 HOST_VISIBLE”指 `ptdev` owner/state/progress 不提前
commit；实际 Host EPT leaf 如果已经在 DMA unreachable 且 guest 约定已撤销之后恢复，
后续重试需把它当作恢复内部准备阶段的部分成功结果处理。

### D9. 第一阶段最小验证边界

遵守本仓库规则，第一阶段默认不主动发起全量 Linux 内核构建。

实现规划中的验证应按最小范围组织：

- 静态检查：确认新增枚举/辅助函数调用点与状态转换路径覆盖 A/C/B/restore。
- 局部编译建议：只给出 `pKVM-IA` 相关最小对象或目录目标，由用户确认后执行。
- 运行验证建议：复用现有 protected pVM + VFIO 样例，观察：
  - attach 后 Host EPT 中受管理 BAR 的 leaf 变成 annotated invalid；
  - Host 缺页命中 annotation 时拒绝重映射；
  - guest `DIRECT_BAR` 访问名单仍可发布；
  - teardown/detach 后 Host EPT BAR idmap 恢复。

## 后续阶段保留问题

以下内容不阻塞第一阶段实现规划，但不能在第一阶段 issue / PR 中假装完成：

- 按设备/按 BAR 的 owner id，而不是第一阶段预留 MMIO tag。
- 严格类 ARM 的 `OWNER_GUEST` 与 Guest 到 Hyp 的 owner 回收（reclaim）。
- `T6` 的完整 VFIO 移除路径（remove-path）/ `FILE_DEL` / 设备组回滚编排。
- 复位框架与多设备组原子切换。
- MSI-X 表 / PBA 的 BAR 子区间 owner 切片。

## 分文档入口

- 总入口：`[01E-T12-B5-3-protected-pVM-device-MMIO-donate-机制总设计.md](01E-T12-B5-3-protected-pVM-device-MMIO-donate-机制总设计.md)`
- ARM 对齐与 BAR 所有权细节：`[01E-T12-B5-3-Host-BAR隔离-ARM对齐设计草案.md](01E-T12-B5-3-Host-BAR隔离-ARM对齐设计草案.md)`
- DMA 安全屏障：`[04-P0-VM销毁前quiesce-ptdev-DMA.md](04-P0-VM销毁前quiesce-ptdev-DMA.md)`
- 移除路径 / 失败回滚：`[06-P1-VFIO-remove-path与失败回滚.md](06-P1-VFIO-remove-path与失败回滚.md)`
