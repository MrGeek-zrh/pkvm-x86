# [B5-2] protected pVM Guest EPT 建图边界初步梳理

## 状态

- 当前状态: 进行中（第一轮源码梳理已完成）
- 所属主任务: `pkvm-x86#20`
- 关联任务: `B5`

## 要回答的问题

这份文档只讨论 `B5` 的问题 2：

- **protected pVM Guest EPT `GPA -> HPA` 建图在运行期 Host 不可信前提下，当前究竟受哪些 hyp 约束、是否仍存在 Host 可影响或篡改的路径**

这份文档**不**讨论：

- boot-time manifest 设备名单边界
- `pgstate_pgt` 的 DMA mirror 生命周期补全
- VFIO remove-path / teardown / prepopulate 的工程收尾问题

## 当前结论

第一轮源码梳理后，当前可以先固定 4 个结论：

1. **Host 不能通过现有接口直接改写一个已经存在的 protected guest EPT leaf 到另一块 HPA**
   - 如果 leaf 已存在且当前物理页与新请求的 `data->phys` 不同，hyp 会直接返回 `-EBUSY`。
2. **Host 仍然实际参与了 protected guest 首次建图时的 candidate HPA 选择**
   - KVM-high 在 page fault 路径上把 `gpa/hpa/size/writable` 送入 `vm_mmu_map` hypercall。
3. **pKVM 当前主要在做 ownership / page-state / 冲突检查，不是“这个 GPA 本来就该绑定哪个 HPA”的语义证明**
   - 也就是说，pKVM 会检查“能不能把这页映进去”，但当前没有独立于运行期 Host 的 per-GPA truth source 去回答“是不是就该映这页”。
4. **问题 2 的主角是 Guest EPT 本身，不是 `pgstate_pgt`**
   - `pgstate_pgt` 当前已经明确只是 DMA mirror；不能把它混成 Guest CPU 看到的主 EPT 真相源问题。

## 关键调用链

### 1. protected guest 首次建图主链

```text
KVM page fault
    -> pkvm_hypercall(vm_mmu_map, vcpu, gpa, hpa, size, writable)
        (arch/x86/kvm/mmu/mmu.c)
    -> pkvm_vm_mmu_map(shared_vcpu, gpa, hpa, size, writable)
        (arch/x86/kvm/pkvm/mmu.c)
    -> pkvm_pgtable_map(&pkvm_vm->mmu, gpa, hpa, size, ..., guest_mmu_map_leaf, ...)
    -> guest_mmu_map_leaf(...)
    -> __pkvm_host_donate_guest(hpa, guest_pgt, gpa, size, prot, ...)
        (hyp/mem_protect.c)
    -> do_donate(...)
    -> check_donation(...)
```

对应源码锚点：

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`

### 2. teardown / free 时的回收链

```text
guest mmu free leaf
    -> guest_mmu_free_leaf(...)
    -> __pkvm_host_undonate_guest(phys, pgt, gpa, size)
```

对应源码锚点：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`

### 3. protected guest runtime unmap hypercall

```text
vm_mmu_unmap(...)
    -> pkvm_vm_mmu_unmap(...)
        -> if protected vm: return -EPERM
```

这意味着：

- protected VM 不允许走普通 `vm_mmu_unmap` 这条运行期 unmap 路径。

## 当前源码事实

### 事实 1：首次建图时，Host/KVM-high 仍然提供 `gpa -> hpa` 候选关系

在 page fault 处理路径中：

- KVM-high 通过 `pkvm_hypercall(vm_mmu_map, ...)` 传入：
  - `gpa`
  - `hpa`
  - `size`
  - `writable`

对应源码：

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c`

这说明当前首次建图不是“hyp 完全自己决定该映哪一页”，而是：

- Host/KVM-high 先给出候选 `HPA`
- hyp 再决定是否接受这次映射

### 事实 2：protected VM 不允许把只读页直接映进 Guest EPT

在 `pkvm_vm_mmu_map()` 中：

- 对 protected VM，若 `!writable`，直接返回 `-EPERM`

对应源码：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`

这说明 protected guest 的 Guest EPT 建图已经有一层权限约束，而不是无条件接受 Host 给出的 fault 参数。

### 事实 3：已存在 leaf 不能被直接换绑到另一块 HPA

在 `guest_mmu_map_leaf()` 中：

- 如果 PTE 已经 present，且 `pgt_entry_to_phys(ptep) != data->phys`，直接返回 `-EBUSY`
- 如果只是并发地重复建立同一映射，则返回 `-EEXIST`

对应源码：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`

这说明：

- Host 目前**不能**通过同一条 map hypercall 直接把一个已存在的 protected guest leaf 改绑到另一块 HPA。

### 事实 4：真正落地 protected leaf 的动作是 `donate`，不是普通 `share`

在 `guest_mmu_map_leaf()` 中：

- protected VM 走 `__pkvm_host_donate_guest()`
- normal VM 走 `__pkvm_host_share_guest()`

对应源码：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`

这意味着：

- 问题 2 里 protected guest 的首要入口，应优先盯住 `donate` 链，而不是 `share` 链。

### 事实 5：`donate` 前已经有两层关键 page-state 检查

在 `check_donation()` 中：

- `host_request_donation()` 要求源 HPA 当前仍是 Host owned
- `guest_ack_donation()` 要求目标 GPA 当前在 guest EPT 中是 `PKVM_NOPAGE`

对应源码：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`

这两层检查当前至少保证：

- 不是任意 host 页面都能塞给 guest
- 不是任意已存在 guest leaf 都能被覆盖

### 事实 6：`pgstate_pgt` 只是 DMA mirror，不是 Guest EPT 真相源

当前注释已经明确：

- `pgstate_pgt` 仅镜像 guest `GPA -> HPA` 翻译给设备 DMA 使用
- guest ownership 真相仍在 guest MMU

对应源码：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`

因此问题 2 里必须分清：

- Guest CPU 看到的主 Guest EPT
- 设备 DMA 看到的 `pgstate_pgt`

## 当前 Host 仍能控制的输入

从当前代码看，Host/KVM-high 在 protected guest 首次建图时仍可直接提供或影响：

- `gpa`
- `hpa`
- `size`
- `writable`
- 触发这次建图的时机（page fault 到来时机）

另外，`prot` 虽然不是从 KVM-high 直接原样下传，但它依赖：

- `writable`
- `kvm_x86_call(get_mt_mask)(vcpu, gpa >> PAGE_SHIFT, false)`

因此它也仍然是“由 Host-side KVM 运行期状态参与构造”的输入。

## 当前已经收敛清楚的边界

### 已经可以确定“不是问题”的点

- 这不是 `manifest` 问题。
- 这不是 `pgstate_pgt` 语义问题本身。
- 这不是“Host 可以随时直接重写一个已有 Guest EPT leaf”的问题。

### 当前真正悬而未决的点

真正还没回答清楚的是：

- **首次建图时，Host 给出的 candidate HPA 是否已经被足够严格地约束到“guest 本来就该拿这页”**

换句话说：

- pKVM 目前回答的是“这次 donate 在 page-state / ownership 上是否合法”
- pKVM 还没有独立回答“这块 HPA 在 guest 语义上是不是就该对应这个 GPA”

## 当前更准确的表述

所以问题 2 现在更适合写成：

- **protected pVM Guest EPT 首次建图时的 candidate HPA 选择权与 hyp 校验边界**

而不是：

- “BAR 真实资源绑定”
- “fake / interposed device”
- “设备真实性证明”

因为当前这轮源码梳理讨论的对象，本质上还是：

- Guest EPT leaf 是怎么建立的
- Host 在这一步还能控制什么
- hyp 在这一步已经拦住了什么

## 下一步建议

下一轮继续收敛时，建议按下面顺序推进：

1. **列全所有会建立 protected guest `GPA -> HPA` 映射的入口**
   - 当前已确认 page fault / `vm_mmu_map` 主链
   - 还需要确认是否存在不经 `vm_mmu_map` 的其它建图入口
2. **列全所有会回收或改变该映射关系的入口**
   - 当前已确认 teardown/free 中的 `__pkvm_host_undonate_guest()`
   - 还需要确认 runtime share/unshare 是否会实质影响 protected guest 主 Guest EPT
3. **单独判断“candidate HPA 是否可被错误选择”**
   - 这一步才是真正决定问题 2 后续是否需要新增实现型 Task 的分叉点

## 关联文档

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/TODOs/todo.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/02-P0-pgstate_pgt语义收敛为DMA-mirror.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/03-P0-donate后同步runtime-DMA-mirror.md`
