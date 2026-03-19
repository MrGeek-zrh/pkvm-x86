# <Plan Title>

## Goal Description
<Clear, direct description of what needs to be accomplished>

## Acceptance Criteria

Following TDD philosophy, each criterion includes positive and negative tests for deterministic verification.

- AC-1: <First criterion>
  - Positive Tests (expected to PASS):
    - <Test case that should succeed when criterion is met>
    - <Another success case>
  - Negative Tests (expected to FAIL):
    - <Test case that should fail/be rejected when working correctly>
    - <Another failure/rejection case>
  - AC-1.1: <Sub-criterion if needed>
    - Positive: <...>
    - Negative: <...>
- AC-2: <Second criterion>
  - Positive Tests: <...>
  - Negative Tests: <...>
...

## Path Boundaries

Path boundaries define the acceptable range of implementation quality and choices.

### Upper Bound (Maximum Acceptable Scope)
<Affirmative description of the most comprehensive acceptable implementation>
<This represents completing the goal without over-engineering>
Example: "The implementation includes X, Y, and Z features with full test coverage"

### Lower Bound (Minimum Acceptable Scope)
<Affirmative description of the minimum viable implementation>
<This represents the least effort that still satisfies all acceptance criteria>
Example: "The implementation includes core feature X with basic validation"

### Allowed Choices
<Options that are acceptable for implementation decisions>
- Can use: <technologies, approaches, patterns that are allowed>
- Cannot use: <technologies, approaches, patterns that are prohibited>

> **Note on Deterministic Designs**: If the draft specifies a highly deterministic design with no choices (e.g., "must use JSON format", "must use algorithm X"), then the path boundaries should reflect this narrow constraint. In such cases, upper and lower bounds may converge to the same point, and "Allowed Choices" should explicitly state that the choice is fixed per the draft specification.

## Feasibility Hints and Suggestions

> **Note**: This section is for reference and understanding only. These are conceptual suggestions, not prescriptive requirements.

### Conceptual Approach
<Text description, pseudocode, or diagrams showing ONE possible implementation path>

### Relevant References
<Code paths and concepts that might be useful>
- <path/to/relevant/component> - <brief description>

## Dependencies and Sequence

### Milestones
1. <Milestone 1>: <Description>
   - Phase A: <...>
   - Phase B: <...>
2. <Milestone 2>: <Description>
   - Step 1: <...>
   - Step 2: <...>

<Describe relative dependencies between components, not time estimates>

## Implementation Notes

### Code Style Requirements
- Implementation code and comments must NOT contain plan-specific terminology such as "AC-", "Milestone", "Step", "Phase", or similar workflow markers
- These terms are for plan documentation only, not for the resulting codebase
- Use descriptive, domain-appropriate naming in code instead

--- Original Design Draft Start ---

# pVM在透传NVME设备情况下，启动失败，内核panic。

## 结论

这个panic实际上是下面的两个过程一起导致的：

- 首先，以设备透传形式启动pVM，并且未给改pVM启用IOMMU模拟的情况下，crossvm默认会在Host的IOMMU页表中建立对Guest VM的所有内存的IOMMU表项映射。随后，Host的IOMMU页表会被同步给pKVM的shadow IOMMU页表。这个同步过程主要是sync_shadow_pgt函数做的。sync_shadow_pgt函数除了会将Host IOMMU页表中维护的IOVA（gpa）到hpa的映射关系同步到shadow IOMMU页表中以外，还会把对应hpa指向的物理页的refcount增加1，表示这个页在被shadow IOMMU页表映射，不能被随意清理。
- 此外，在crossvm启动的过程中，Guest刚准备去遍历页表，然后因为缺页触发了ept violation，然后Host去donate 物理页给Guest VM。但是由于前面IOMMU的初始化的时候，已经将所以的物理页的refcount都增加了1.导致donate失败，进而导致ept violation处理失败，虚拟机启动失败。
所以导致panic的原因，不是代码bug，而是当前代码在设计的时候就没考虑透传设备给pVM的情况。

## 问题概述

```
[   73.968055] pkvm-debug: first-owner table full; suppressing further overflow logs
[   84.805341] pkvm: host_initiate_donation: page refcounted (dma/pinned?) addr=0x1e2888000 size=0x1000 owner_id=1 refcnt=1 busy_hpa=0x1e2888000
[   84.806409] pkvm-debug: first-owner hpa=0x1e2888000 tag=shadow_pgt_map_leaf/new_inc aux=0x9000 caller=pgtable_map_cb__pkvm+0xb9/0x270 seq=15694
[   84.807426] pkvm-debug: trace dump target_hpa=0x1e2888000 nr_entries=4096
[   84.807965] pkvm-debug: trace hpa=0x1e2888000 tag=__pkvm_host_donate_guest/pre old=1 new=1 aux=0x9000
[   84.808688] pkvm-debug: trace hpa=0x1e2888000 tag=host_initiate_donation/fail old=1 new=1 aux=0x1
[   84.809384] pkvm: do_donate: __do_donate failed ret=-16 size=0x1000 init=1 addr=0x1e2888000 phys=0x0 comp=2 addr=0x9000 phys=0x1e2888000 prot=0x77
[   84.810540] pkvm: __pkvm_host_donate_guest failed ret=-16 hpa=0x1e2888000 gpa=0x9000 size=0x1000 prot=0x77
[   84.811354] kvm: pkvm: vm_mmu_map failed ret=-16 gpa=0x9000 hpa=0x1e2888000 size=0x1000 writable=1 goal_level=1 pfn=0x1e2888
```

## 根因分析

### 冲突的两条路径

同一个物理页 `0x1e2888000` 被两条独立路径使用，产生了 refcount 冲突：

#### 路径 A（先发生）：IOMMU 影子页表同步

```
sync_shadow_pgt()                                [shadow_iommu.c:422]
  → pkvm_pgtable_sync_map[_range]()              [pgtable.c:786]
    → pgtable_walk(walker=pgtable_sync_map_cb)    [pgtable.c:773]
      → pgtable_sync_map_cb()                    [pgtable.c:718]
        → pkvm_pgtable_map(map_leaf=shadow_pgt_map_leaf)  [pgtable.c:740]
          → pgtable_walk(walker=pgtable_map_cb)            [pgtable.c:604]
            → pgtable_map_cb()                   ← 日志中的 caller
              → pgtable_map_try_leaf()           [pgtable.c:153]
                → shadow_pgt_map_leaf()          [shadow_iommu.c:330]
                  → hyp_page_ref_inc(new_page)   [shadow_iommu.c:380]
                    refcount: 0 → 1  ← 日志 first-owner 记录
```

此路径在 IOMMU context entry 更新时触发：Host IOMMU 驱动更新设备的 DMA 页表后，pKVM 通过 sync_shadow_pgt() 将 Host 页表同步到 Hyp 侧的 shadow IOMMU 页表。同步过程中，对 shadow 页表叶节点指向的物理页做 hyp_page_ref_inc()，标记该页被 IOMMU 映射引用。

#### 路径 B（后发生）：Guest 内存 donate

```
[Host 侧]
kvm_tdp_page_fault()                              [mmu/mmu.c]
  → pkvm_page_fault()
    → pkvm_hypercall(vm_mmu_map, vcpu,            [mmu/mmu.c:4836]
        gpa=0x9000, hpa=0x1e2888000, size=0x1000)

[Hyp 侧 - hypercall 入口]
case __pkvm__vm_mmu_map:                          [pkvm/pkvm.c:2180]
  → pkvm_vm_mmu_map(vcpu, 0x9000, 0x1e2888000)   [pkvm/mmu.c:480]
    → pkvm_pgtable_map(guest_pgt, gpa=0x9000,
        hpa=0x1e2888000,
        map_leaf=guest_mmu_map_leaf)
      → pgtable_walk → pgtable_map_cb
        → pgtable_map_try_leaf
          → guest_mmu_map_leaf()                  [pkvm/mmu.c:385]
            → __pkvm_host_donate_guest(           [mem_protect.c:661]
                hpa=0x1e2888000, gpa=0x9000)
              → do_donate()                       [mem_protect.c:485]
                → __do_donate()                   [mem_protect.c:437]
                  → host_initiate_donation()      [mem_protect.c:355]
                    → hyp_page_count(0x1e2888000)
                      refcount = 1 ≠ 0  ← 失败！return -EBUSY
```

crosvm设定 boot_pml4_addr = GuestAddress(0x9000)，Guest刚准备去遍历页表，因为缺页触发了ept violation，Host去donate物理页给Guest VM。但前面IOMMU初始化已将所有物理页的refcount增加了1，导致donate失败。

这是当前pKVM-IA存在的问题。目标：给pKVM-IA增加pVM透传设备的功能。

--- Original Design Draft End ---
