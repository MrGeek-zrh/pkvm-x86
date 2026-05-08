# pKVM-IA MMIO Metadata 结构体说明

## 范围

本文只说明 protected pVM 设备透传里“普通 BAR MMIO direct path”涉及的 metadata、BAR resource、allowlist 和运行期状态结构。这里的“普通 BAR”特指 VFIO sparse mmap 中可 mmap 的 BAR 数据面子区间；config space、MSI-X table、MSI-X PBA、ROM BAR、不可 mmap BAR 以及后续 reserved range hardening 不属于本文主路径。

核心结论：

- userspace/crosvm 提交的是“某个 host BDF/PASID 的 BAR 子区间如何映射到 guest GPA”的富 metadata。
- host kernel 负责把 userspace ABI 拷入 `struct kvm_ptdev_mmio_metadata` 并做格式校验。
- hyp 侧把 metadata 绑定到已 attach 的 `struct pkvm_ptdev`，再用 boot manifest 中的 BAR `base/size` 校验并折算 HPA。
- hyp 发布给 guest 的不是原始 metadata，而是 VM 级 `guest_gpa/size/flags` allowlist。
- guest 运行期只根据 allowlist 决定这次 MMIO 是 raw direct 访问，还是继续走 `PKVM_GHC_IOREAD/IOWRITE` fallback。
- T12 后，metadata 还驱动 Host BAR revoke：hyp 只撤销 metadata 声明的 `DIRECT_BAR` range，在 Host EPT invalid PTE 中写 `OWNER_ID_PTDEV_MMIO`，防止 Host EPT fault lazy remap 把 assigned BAR 重新映射回 Host。

## 普通 BAR MMIO 数据流

```text
crosvm / VFIO PCI device
    ProtectedVmPtdevMmioRange / ProtectedVmPtdevMmioMetadata
        由 VFIO sparse mmap BAR 子区间生成
        remove_bar_mmap_msix() 排除 MSI-X table / PBA
        kind = DIRECT_BAR

KVM UAPI
    KVM_ENABLE_CAP(KVM_CAP_X86_PROTECTED_VM,
                   KVM_CAP_X86_PROTECTED_VM_FLAGS_SET_PTDEV_MMIO_METADATA)
        struct kvm_protected_vm_ptdev_mmio_metadata
            ranges -> userspace array of struct kvm_protected_vm_ptdev_mmio_range

Host kernel
    pkvm_vm_ioctl_set_ptdev_mmio_metadata()
        pkvm_copy_ptdev_mmio_metadata_from_user()
            userspace ABI -> struct kvm_ptdev_mmio_metadata
        pkvm_sync_ptdev_mmio_metadata()
            sync_ptdev_mmio_metadata hypercall

pKVM hyp
    pkvm_sync_ptdev_mmio_metadata()
        pkvm_set_ptdev_mmio_metadata()
            struct kvm_ptdev_mmio_metadata -> ptdev->mmio_metadata
            boot manifest BAR base/size 校验
            pkvm_revoke_ptdev_bars_locked()
                bar.hpa + range.bar_offset -> HPA
                pkvm_host_ept_annotate_mmio_owner(..., OWNER_ID_PTDEV_MMIO)
                touched_mmio_ranges[] 记录 restore 所需 range
            pkvm_publish_ptdev_mmio_contract_locked()
                pkvm_update_vm_mmio_allowlist()
                    DIRECT_BAR ranges -> vm->mmio_allow_ranges[]

guest boot
    pkvm_init_mmio_allowlist()
        PKVM_GHC_PTDEV_MMIO_INFO -> struct pkvm_guest_mmio_info
        PKVM_GHC_PTDEV_MMIO_READ -> struct pkvm_guest_mmio_allow_range[]

guest runtime MMIO
    pkvm_virt_mmio()
        pkvm_mmio_allow_hit()
            hit  -> pkvm_direct_mmio_read/write()
            miss -> PKVM_GHC_IOREAD / PKVM_GHC_IOWRITE fallback

Guest EPT / Host EPT 旁路约束
    pkvm_vm_mmu_map()
        attached DIRECT_BAR HPA -> pgtable_map_leaf(), 不走 RAM donate
    handle_host_ept_violation()
        OWNER_ID_PTDEV_MMIO annotation -> deny host BAR remap
```

关键源码入口：

- `crosvm/devices/src/pci/vfio_pci.rs`
- `crosvm/hypervisor/src/x86_64.rs`
- `crosvm/hypervisor/src/kvm/x86_64.rs`
- `pKVM-IA/arch/x86/include/uapi/asm/kvm.h`
- `pKVM-IA/arch/x86/include/asm/kvm_host.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h`
- `pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c`
- `pKVM-IA/include/uapi/linux/kvm_para.h`
- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`

## userspace/crosvm 侧结构

### `ProtectedVmPtdevMmioRange`

定义位置：`crosvm/hypervisor/src/x86_64.rs`

```rust
pub struct ProtectedVmPtdevMmioRange {
    pub segment: u16,
    pub bdf: u16,
    pub pasid: u32,
    pub bar_index: u8,
    pub bar_offset: u64,
    pub guest_gpa: u64,
    pub size: u64,
    pub kind: u32,
    pub flags: u32,
}
```

字段语义：

- `segment`：PCI segment。当前 x86 pKVM host 校验要求为 `0`。
- `bdf`：host 侧 PCI BDF。crosvm 从 VFIO 设备 sysfs path 解析 host PCI address 后转换得到。
- `pasid`：当前 NoIommu / legacy 场景使用 `0`，host 校验也要求为 `0`。
- `bar_index`：BAR0-BAR5 的索引，后续在 hyp 里用于选择 boot manifest 中的 BAR resource。
- `bar_offset`：该 guest GPA range 对应 BAR 内偏移。hyp 用 `bar.hpa + bar_offset` 折算 Host 物理地址。
- `guest_gpa`：crosvm 已完成 BAR 布局后的 guest 物理地址，即 guest 运行期 MMIO 访问要匹配的 GPA。
- `size`：该 mmap 子区间大小。
- `kind`：当前只支持 `PROTECTED_VM_PTDEV_MMIO_KIND_DIRECT_BAR`。
- `flags`：当前必须为 `0`。

生成路径：

- `VfioPciDevice::build_protected_vm_ptdev_mmio_metadata()` 遍历 `self.mmio_regions`。
- 跳过 ROM region、未分配 BAR、不可 mmap region。
- 对 VFIO sparse mmap 子区间生成 range。
- 若设备有 MSI-X capability，先调用 `remove_bar_mmap_msix()` 剔除 MSI-X table / PBA 子区间。
- 每个 range 的 `guest_gpa = bar_addr + mmap.offset`，`bar_offset = mmap.offset`，`kind = DIRECT_BAR`。

### `ProtectedVmPtdevMmioMetadata`

定义位置：`crosvm/hypervisor/src/x86_64.rs`

```rust
pub struct ProtectedVmPtdevMmioMetadata {
    pub generation: u16,
    pub flags: u64,
    pub ranges: Vec<ProtectedVmPtdevMmioRange>,
}
```

字段语义：

- `generation`：当前 crosvm 填 `1`。host 侧接受 `0/1`，但内部缓存时统一写成 `1`。
- `flags`：当前必须能转换为 `u32` 且最终为 `0`。
- `ranges`：属于同一个 host `segment/bdf/pasid` 的 direct BAR range 列表，最多 `16` 个。

提交路径：

```text
submit_protected_vm_ptdev_mmio_metadata()
    PciDevice::get_protected_vm_ptdev_mmio_metadata()
        VfioPciDevice::build_protected_vm_ptdev_mmio_metadata()
    VmX86_64::set_protected_vm_ptdev_mmio_metadata()
        KvmVm::set_protected_vm_ptdev_mmio_metadata()
```

### `KvmProtectedVmPtdevMmioRange` / `KvmProtectedVmPtdevMmioMetadata`

定义位置：`crosvm/hypervisor/src/kvm/x86_64.rs`

这两个 `#[repr(C)]` 结构是 crosvm 对 KVM UAPI 的 C layout 封装：

```rust
struct KvmProtectedVmPtdevMmioRange {
    guest_gpa: u64,
    size: u64,
    bar_offset: u64,
    bar_index: u8,
    kind: u8,
    reserved16: u16,
    reserved32: u32,
}

struct KvmProtectedVmPtdevMmioMetadata {
    segment: u16,
    bdf: u16,
    pasid: u32,
    nr_ranges: u16,
    generation: u16,
    flags: u32,
    ranges: u64,
    reserved: [u64; 4],
}
```

转换约束：

- 所有 range 必须属于同一个 `segment/bdf/pasid`。
- `metadata.ranges.len()` 不能为 `0`，也不能超过 `PROTECTED_VM_PTDEV_MMIO_MAX_RANGES`。
- range `kind` 必须能收窄成 `u8`。
- range `flags` 必须为 `0`。
- `ranges` 字段传的是本次 ioctl 生命周期内有效的 userspace array 指针。

## KVM UAPI 结构

定义位置：`pKVM-IA/arch/x86/include/uapi/asm/kvm.h`

### 常量

```c
#define KVM_CAP_X86_PROTECTED_VM_FLAGS_SET_PTDEV_MMIO_METADATA 2
#define KVM_PROTECTED_VM_PTDEV_MMIO_MAX_RANGES        16
#define KVM_PROTECTED_VM_PTDEV_MMIO_KIND_DIRECT_BAR   1
```

`SET_PTDEV_MMIO_METADATA` 是 `KVM_CAP_X86_PROTECTED_VM` 下的子命令。userspace 通过 `KVM_ENABLE_CAP` 提交 metadata 指针：

```text
cap.cap     = KVM_CAP_X86_PROTECTED_VM
cap.flags   = KVM_CAP_X86_PROTECTED_VM_FLAGS_SET_PTDEV_MMIO_METADATA
cap.args[0] = userspace struct kvm_protected_vm_ptdev_mmio_metadata *
```

### `struct kvm_protected_vm_ptdev_mmio_range`

```c
struct kvm_protected_vm_ptdev_mmio_range {
    __u64 guest_gpa;
    __u64 size;
    __u64 bar_offset;
    __u8 bar_index;
    __u8 kind;
    __u16 __reserved16;
    __u32 __reserved32;
};
```

字段语义：

- `guest_gpa`：guest 侧 BAR 子区间 GPA 起点。guest allowlist 最终只保留它和 `size`。
- `size`：子区间大小。host 侧要求非零且页对齐。
- `bar_offset`：BAR 内偏移。hyp 侧用它和 boot manifest BAR base 计算 HPA。
- `bar_index`：BAR 索引，必须小于 `PCI_STD_NUM_BARS`。
- `kind`：当前必须为 `KVM_PROTECTED_VM_PTDEV_MMIO_KIND_DIRECT_BAR`。
- `__reserved16/__reserved32`：必须为 `0`。

host 侧格式校验在 `pkvm_validate_ptdev_mmio_range()`：

- `size` 非零。
- `guest_gpa`、`size`、`bar_offset` 页对齐。
- `guest_gpa + size` 和 `bar_offset + size` 不能溢出。
- `bar_index < PCI_STD_NUM_BARS`。
- `kind == DIRECT_BAR`。
- reserved 字段为 `0`。
- 当前 metadata 内的 range 不能按 `guest_gpa/size` 相互重叠。

### `struct kvm_protected_vm_ptdev_mmio_metadata`

```c
struct kvm_protected_vm_ptdev_mmio_metadata {
    __u16 segment;
    __u16 bdf;
    __u32 pasid;
    __u16 nr_ranges;
    __u16 generation;
    __u32 flags;
    __u64 ranges;
    __u64 __reserved[4];
};
```

字段语义：

- `segment`：当前必须为 `0`。
- `bdf`：目标 host PCI device BDF，后续用于查找 `struct pkvm_ptdev`。
- `pasid`：当前必须为 `0`。
- `nr_ranges`：range 数量，必须在 `1..=16`。
- `generation`：当前不得大于 `1`；host 内部缓存时统一设为 `1`。
- `flags`：当前必须为 `0`。
- `ranges`：userspace range array 指针，不能为 `0`。
- `__reserved[]`：必须全为 `0`。

这一层还不能证明 range 是否避开 MSI-X table / PBA。当前 pKVM 独立校验能证明“格式正确、range 落在 boot manifest 记录的 BAR 内”，但 reserved/trapped 子区间校验仍在后续 hardening 任务中。

## host kernel 内部缓存结构

定义位置：`pKVM-IA/arch/x86/include/asm/kvm_host.h`

### `struct kvm_ptdev_mmio_metadata`

```c
struct kvm_ptdev_mmio_metadata {
    u16 segment;
    u16 bdf;
    u32 pasid;
    u16 nr_ranges;
    u16 generation;
    u32 flags;
    struct kvm_protected_vm_ptdev_mmio_range
        ranges[KVM_PROTECTED_VM_PTDEV_MMIO_MAX_RANGES];
};
```

它是 host kernel 对 userspace UAPI 的内核态拷贝：

- `ranges` 从 userspace 指针展开成固定数组，避免 hyp 再依赖 userspace 地址。
- 结构内容保存在 `kvm->arch.pkvm.ptdev_mmio_metadata`。
- `kvm->arch.pkvm.ptdev_mmio_metadata_valid` 表示 host cache 是否有效。
- `pkvm_ptdev_mmio_metadata_equal()` 用于允许完全一致的重复提交幂等成功；不同内容的重复提交返回 `-EBUSY`。

### `struct kvm_protected_vm` 中的相关字段

```c
struct kvm_protected_vm {
    int pkvm_vm_handle;
    ...
    bool ptdev_mmio_metadata_valid;
    bool finalized;
    struct kvm_ptdev_mmio_metadata ptdev_mmio_metadata;
    struct mutex finalized_lock;
};
```

字段语义：

- `finalized_lock`：保护 metadata 提交和 VM finalized 状态。
- `finalized`：VM finalized 后不允许再提交新的 ptdev MMIO metadata。
- `ptdev_mmio_metadata_valid`：host cache 是否可被 hyp 同步。
- `ptdev_mmio_metadata`：本 VM 当前 host cache。

host 提交流程：

```text
pkvm_vm_ioctl_set_ptdev_mmio_metadata()
    pkvm_copy_ptdev_mmio_metadata_from_user()
    lock finalized_lock
        finalized -> -EBUSY
        already valid and equal -> 0
        already valid and different -> -EBUSY
        cache metadata
        pkvm_sync_ptdev_mmio_metadata()
            pkvm_hypercall(sync_ptdev_mmio_metadata, pkvm_vm_handle)
        sync failed -> clear host cache
    unlock finalized_lock
```

## boot manifest BAR 结构

定义位置：`pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`

### `struct pkvm_boot_ptdev_bar_entry`

```c
struct pkvm_boot_ptdev_bar_entry {
    u64 base;
    u64 size;
};
```

字段语义：

- `base`：host 启动枚举时看到的 PCI memory BAR 物理起点。
- `size`：该 BAR 的大小。

来源：

- `build_boot_ptdev_manifest()` 遍历 `for_each_pci_dev(pdev)`。
- 对每个 `PCI_STD_NUM_BARS`，只有 `pci_resource_flags(pdev, bar) & IORESOURCE_MEM` 的 BAR 会记录。
- `base = pci_resource_start(pdev, bar)`。
- `size = pci_resource_len(pdev, bar)`。

### `struct pkvm_boot_ptdev_manifest_entry`

```c
struct pkvm_boot_ptdev_manifest_entry {
    u16 bdf;
    u16 flags;
    struct pkvm_boot_ptdev_bar_entry bars[PCI_STD_NUM_BARS];
};
```

字段语义：

- `bdf`：host PCI device identity。
- `flags`：当前包含 `PKVM_BOOT_PTDEV_FLAG_HOST_IOMMU_LEGACY`，用于 NoIommu / legacy IOMMU 相关 attach 检查。
- `bars[]`：启动期冻结的 memory BAR base/size 快照。

`struct pkvm_hyp` 中保存：

```c
u16 boot_ptdev_cnt;
struct pkvm_boot_ptdev_manifest_entry
    boot_ptdev_manifest[PKVM_MAX_BOOT_PTDEV_NUM];
```

普通 BAR MMIO metadata 的 hyp 校验依赖这份 manifest：

- `pkvm_boot_ptdev_manifest_lookup(bdf)` 找到设备。
- `pkvm_prepare_ptdev_bar_resources_locked()` 把 manifest 中非空、页对齐的 BAR 拷入 `ptdev->bars[]`。
- `pkvm_ptdev_bar_contains_range_locked()` 检查 `bar_offset + size <= bar->size`。
- `pkvm_ptdev_range_hpa_locked()` 计算 `hpa = bar->hpa + range->bar_offset`。

## hyp `ptdev` 状态结构

定义位置：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`

### owner 与状态枚举

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
```

语义：

- `owner` 描述 BAR CPU 访问权当前由 Host 还是 Hyp 持有。
- `assignment_state` 描述设备 attach 生命周期：未绑定、正在绑定、Host BAR 已撤、guest contract 已发布、正在恢复。
- `bar_progress` 是 BAR/range 粒度的进度，用于 revoke、publish、restore 的诊断和 rollback。

### `struct pkvm_ptdev_bar_resource`

```c
struct pkvm_ptdev_bar_resource {
    u8 bar_index;
    u64 hpa;
    u64 size;
    enum pkvm_ptdev_bar_progress progress;
};
```

字段语义：

- `bar_index`：BAR 索引。
- `hpa`：该 BAR 的 host 物理起点，来自 boot manifest 的 `base`。
- `size`：该 BAR 的大小，来自 boot manifest 的 `size`。
- `progress`：该 BAR 当前在 Host-visible、revoked、contract-published、restoring 中的状态。

注意：T12 后实际 revoke 可以细化到 metadata 声明的 `DIRECT_BAR` 子区间，`pkvm_ptdev_bar_resource` 仍保存整 BAR resource snapshot，精确撤销范围由 `kvm_protected_vm_ptdev_mmio_range` 与 `pkvm_ptdev_mmio_range_state` 表达。

### `struct pkvm_ptdev_mmio_range_state`

```c
struct pkvm_ptdev_mmio_range_state {
    u8 bar_index;
    u64 hpa;
    u64 size;
    enum pkvm_ptdev_bar_progress progress;
};
```

字段语义：

- `bar_index`：被 revoke 的 range 所属 BAR。
- `hpa`：`bar.hpa + range.bar_offset` 之后的 Host 物理起点。
- `size`：被 revoke 的 direct BAR 子区间大小。
- `progress`：该 range 当前 revoke/restore 进度。

这个结构是 restore 的关键证据：`pkvm_restore_ptdev_mmio_ranges_locked()` 遍历 `touched_mmio_ranges[]`，调用 `pkvm_host_ept_restore_mmio_idmap(range->hpa, range->size, prot)` 把 Host BAR visibility 恢复回来。

### `struct pkvm_ptdev`

```c
struct pkvm_ptdev {
    atomic_t refcount;
    struct hlist_node hnode;
    u16 did;
    u16 bdf;
    u32 pasid;
    unsigned long index;
    struct list_head iommu_node;
    bool iommu_coherency;

    struct pkvm_pgtable vpgt;
    struct pkvm_pgtable *pgt;

    pkvm_spinlock_t lock;

    int shadow_vm_handle;
    bool dma_blocked;
    bool dma_view_ready;
    bool guest_contract_published;
    enum pkvm_ptdev_owner owner;
    enum pkvm_ptdev_assignment_state assignment_state;
    unsigned long managed_bar_mask;
    unsigned long touched_bar_mask;
    struct pkvm_ptdev_bar_resource bars[PCI_STD_NUM_BARS];
    u16 touched_mmio_range_count;
    struct pkvm_ptdev_mmio_range_state
        touched_mmio_ranges[KVM_PROTECTED_VM_PTDEV_MMIO_MAX_RANGES];
    bool mmio_metadata_valid;
    struct kvm_ptdev_mmio_metadata mmio_metadata;
    struct list_head vm_node;
};
```

MMIO metadata 相关字段：

- `bdf/pasid`：metadata 绑定目标，来自 attach / get-or-create ptdev。
- `shadow_vm_handle`：确认这个 ptdev 已 attach 到当前 protected VM。`pkvm_set_ptdev_mmio_metadata()` 要求它等于当前 VM handle。
- `pgt`：设备当前 DMA/IOMMU 视图。attach 后切到 `&vm->pgstate_pgt`，与 CPU BAR direct path 分开。
- `dma_view_ready`：IOMMU sync 完成后置位。guest BAR mapping 需要它为 true。
- `guest_contract_published`：VM allowlist 是否已发布给 guest。
- `owner`：Host BAR CPU 访问权是否已从 Host 转到 Hyp。
- `assignment_state`：attach / revoke / publish / restore 生命周期状态。
- `managed_bar_mask`：哪些 BAR 已从 boot manifest 固化到 `bars[]`。
- `touched_bar_mask`：哪些 BAR 有 range 被本轮 revoke。
- `bars[]`：按 BAR 记录 boot manifest resource snapshot。
- `touched_mmio_range_count`：被 revoke 的 metadata range 数量。
- `touched_mmio_ranges[]`：Host EPT revoke 后需要 restore 的精确 HPA range。
- `mmio_metadata_valid`：`ptdev->mmio_metadata` 是否有效。
- `mmio_metadata`：hyp 侧缓存的 authoritative metadata。

重要 helper：

- `pkvm_prepare_ptdev_bar_resources_locked()`：从 boot manifest 固化 BAR resource。
- `pkvm_validate_ptdev_mmio_metadata_locked()`：确认每个 `DIRECT_BAR` range 落在对应 BAR 内。
- `pkvm_revoke_ptdev_bars_locked()`：按 metadata range 精确撤 Host EPT，并记录 `touched_mmio_ranges[]`。
- `pkvm_publish_ptdev_mmio_contract_locked()`：满足 owner、assignment state、DMA view 条件后发布 guest allowlist。
- `pkvm_withdraw_ptdev_mmio_contract_locked()`：detach/restore 前清空 VM allowlist。
- `pkvm_set_ptdev_mmio_metadata()`：host cache 同步到 hyp ptdev 的主入口。

## VM 级 allowlist 结构

定义位置：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h`

### `struct pkvm_shadow_vm` 相关字段

```c
struct pkvm_shadow_vm {
    struct pkvm_pgtable pgstate_pgt;
    ...
    struct list_head ptdev_head;
    u16 mmio_allow_nr_ranges;
    u16 mmio_allow_generation;
    u32 mmio_allow_flags;
    struct pkvm_guest_mmio_allow_range
        mmio_allow_ranges[PKVM_GUEST_MMIO_ALLOW_MAX_RANGES];
    ...
};
```

字段语义：

- `ptdev_head`：当前 protected VM attach 的 passthrough device 链表。
- `mmio_allow_nr_ranges`：已经发布给 guest 的 allowlist range 数量。
- `mmio_allow_generation`：来自 metadata generation。
- `mmio_allow_flags`：当前为 `0`。
- `mmio_allow_ranges[]`：guest 可读取的 direct BAR allowlist。

`pkvm_update_vm_mmio_allowlist()` 的转换规则：

- 清空旧 `vm->mmio_allow_ranges[]`。
- 遍历 `metadata->ranges[]`。
- 只接受 `kind == DIRECT_BAR` 的 range。
- 为每个 range 生成：
  - `allow->guest_gpa = range->guest_gpa`
  - `allow->size = range->size`
  - `allow->flags = PKVM_GUEST_MMIO_ALLOW_FLAG_DIRECT_BAR`
- 设置 `vm->mmio_allow_nr_ranges = nr_ranges`。
- 设置 `vm->mmio_allow_generation = metadata->generation`。
- 设置 `vm->mmio_allow_flags = 0`。

当前 allowlist 是 VM 级快照，发布时会清空旧数组。当前主线默认是单 VFIO PCI NVMe / 静态 attach 场景；若后续支持多设备并发发布，需要重新设计 allowlist 合并、generation 和 per-device 生命周期。

## guest 可见结构

定义位置：`pKVM-IA/include/uapi/linux/kvm_para.h`

### 常量

```c
#define PKVM_GHC_PTDEV_MMIO_INFO    PKVM_GHC_NUM(6)
#define PKVM_GHC_PTDEV_MMIO_READ    PKVM_GHC_NUM(7)

#define PKVM_GUEST_MMIO_ALLOW_MAX_RANGES    16
#define PKVM_GUEST_MMIO_ALLOW_FLAG_DIRECT_BAR    (1U << 0)
```

`INFO` 用于读取 allowlist 元信息，`READ` 用于读取 range 数组。

### `struct pkvm_guest_mmio_info`

```c
struct pkvm_guest_mmio_info {
    __u16 nr_ranges;
    __u16 generation;
    __u32 flags;
};
```

字段语义：

- `nr_ranges`：guest 后续应读取多少个 allow range。
- `generation`：当前 allowlist generation。
- `flags`：当前为 `0`。

hyp 实现：

- `pkvm_get_ptdev_mmio_info()` 从 `vm->mmio_allow_nr_ranges/generation/flags` 拷贝。
- `pkvm_handle_ptdev_mmio_info()` 通过 `write_gpa()` 写回 guest buffer。

### `struct pkvm_guest_mmio_allow_range`

```c
struct pkvm_guest_mmio_allow_range {
    __u64 guest_gpa;
    __u64 size;
    __u32 flags;
    __u32 __reserved;
};
```

字段语义：

- `guest_gpa`：guest 本地 MMIO 分流匹配起点。
- `size`：匹配范围大小。
- `flags`：当前用 `PKVM_GUEST_MMIO_ALLOW_FLAG_DIRECT_BAR` 表示可 direct raw MMIO。
- `__reserved`：当前未使用。

guest 只看到 `guest_gpa/size/flags`，看不到 `bdf/pasid/bar_index/bar_offset/hpa`。这是有意的分层：设备身份、BAR resource 校验和 Host EPT revoke 都留在 hyp；guest 只拿到运行期分流所需的最小 contract。

guest 本地缓存定义位置：`pKVM-IA/arch/x86/coco/pkvm/pkvm.c`

```c
static struct pkvm_guest_mmio_info pkvm_mmio_info;
static struct pkvm_guest_mmio_allow_range
    pkvm_mmio_allow_ranges[PKVM_GUEST_MMIO_ALLOW_MAX_RANGES];
static u16 pkvm_mmio_allow_nr_ranges;
```

初始化路径：

```text
pkvm_guest_init_coco()
    pkvm_init_mmio_allowlist()
        PKVM_GHC_PTDEV_MMIO_INFO
        if nr_ranges != 0:
            PKVM_GHC_PTDEV_MMIO_READ
    pv_ops.mmio.raw_read*/raw_write* = pkvm_mmio_read*/write*
```

运行期匹配：

```text
pkvm_virt_mmio(size, write, vaddr, val)
    lookup_address(vaddr, &level)
    paddr = PTE PFN + page offset
    pkvm_mmio_allow_hit(paddr, size)
        range flags has DIRECT_BAR
        paddr falls fully within [guest_gpa, guest_gpa + size)
    hit:
        raw_read*/raw_write*
    miss:
        PKVM_GHC_IOREAD / PKVM_GHC_IOWRITE
```

## Guest EPT direct BAR leaf 相关结构关系

普通 BAR MMIO direct path 还依赖 Guest EPT 能把 guest BAR GPA 建到对应 BAR HPA。相关代码在 `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`：

- `pkvm_vm_mmu_map()` 先判断 protected VM 的 HPA 是否命中当前 VM 已 attach 的 direct BAR range。
- 命中时 `direct_mmio = true`，后续 `get_mt_mask(..., direct_mmio)` 使用 MMIO memory type。
- `guest_mmu_map_leaf()` 命中 attached BAR HPA 时直接 `pgtable_map_leaf()`，不走 `__pkvm_host_donate_guest()`。
- unmap 时如果 HPA 是 attached BAR range，直接返回，不走 `__pkvm_host_undonate_guest()`。

这里用到的判断链：

```text
pkvm_vm_mmu_map()
    guest_mmu_is_attached_boot_ptdev_bar_hpa()
        pkvm_vm_hpa_hits_attached_boot_ptdev_bar()
            for ptdev in vm->ptdev_head:
                pkvm_ptdev_allows_guest_bar_mapping_locked()
                    owner == HYP
                    assignment_state == HOST_REVOKED || GUEST_ASSIGNED
                    dma_view_ready == true
                pkvm_ptdev_hpa_hits_direct_mmio_locked()
                    range from ptdev->mmio_metadata
                    hpa in [bar.hpa + range.bar_offset,
                            bar.hpa + range.bar_offset + range.size)
```

所以，guest direct BAR MMIO 成立需要同时满足：

- userspace metadata 描述了这个 BAR 子区间。
- hyp metadata 已绑定到当前 `ptdev`。
- boot manifest 证明该 offset/size 落在该设备 BAR 内。
- attach 主线已完成 Host revoke 与 DMA view commit。
- VM allowlist 已发布给 guest。
- Guest EPT 建图时 HPA 命中这个 direct BAR range。

## Host EPT revoke / restore 相关结构关系

Host CPU 隔离使用 Host EPT invalid owner annotation，不复用 RAM donation 结构。

相关定义：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h` 定义 `OWNER_ID_PTDEV_MMIO`。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c` 中 `pkvm_revoke_ptdev_bars_locked()` 调用 `pkvm_host_ept_annotate_mmio_owner(hpa, size, OWNER_ID_PTDEV_MMIO)`。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c` 中 `handle_host_ept_violation()` 查询 invalid PTE annotation，若 owner 是 `OWNER_ID_PTDEV_MMIO` 则返回 `-EPERM`，打印 `pkvm: deny host BAR remap ...`。
- restore 时 `pkvm_restore_ptdev_mmio_ranges_locked()` 遍历 `touched_mmio_ranges[]`，调用 `pkvm_host_ept_restore_mmio_idmap()` 恢复 Host EPT MMIO idmap。

状态迁移：

```text
初始
    ptdev->owner = HOST
    ptdev->assignment_state = DETACHED
    BAR Host EPT 可见

metadata valid + attach/revoke
    pkvm_revoke_ptdev_bars_locked()
        for metadata DIRECT_BAR range:
            hpa = ptdev->bars[bar_index].hpa + range->bar_offset
            annotate Host EPT invalid owner = OWNER_ID_PTDEV_MMIO
            touched_mmio_ranges[] += { bar_index, hpa, size, REVOKED }
    ptdev->owner = HYP
    ptdev->assignment_state = HOST_REVOKED

DMA view ready + publish
    pkvm_publish_ptdev_mmio_contract_locked()
        pkvm_update_vm_mmio_allowlist()
        touched range progress = CONTRACT_PUBLISHED
        ptdev->guest_contract_published = true
        ptdev->assignment_state = GUEST_ASSIGNED

detach / rollback
    pkvm_withdraw_ptdev_mmio_contract_locked()
        clear VM allowlist
    switch DMA view back / prove DMA unreachable
    pkvm_restore_ptdev_mmio_ranges_locked()
        restore Host EPT idmap for touched_mmio_ranges[]
    ptdev->owner = HOST
    ptdev->assignment_state = DETACHED
```

## 结构体分层速查

| 层级 | 结构体 | 路径 | 谁写入 | 谁消费 | 保留的信息 |
| --- | --- | --- | --- | --- | --- |
| crosvm 抽象 | `ProtectedVmPtdevMmioRange` | `crosvm/hypervisor/src/x86_64.rs` | VFIO PCI device | KVM backend | segment/bdf/pasid、BAR index/offset、guest GPA/size、kind |
| crosvm 抽象 | `ProtectedVmPtdevMmioMetadata` | `crosvm/hypervisor/src/x86_64.rs` | VFIO PCI device | KVM backend | generation、flags、range Vec |
| KVM ABI | `kvm_protected_vm_ptdev_mmio_range` | `pKVM-IA/arch/x86/include/uapi/asm/kvm.h` | userspace | host kernel | guest GPA/size、BAR offset/index、kind |
| KVM ABI | `kvm_protected_vm_ptdev_mmio_metadata` | `pKVM-IA/arch/x86/include/uapi/asm/kvm.h` | userspace | host kernel | segment/bdf/pasid、nr/generation/flags、range pointer |
| host cache | `kvm_ptdev_mmio_metadata` | `pKVM-IA/arch/x86/include/asm/kvm_host.h` | host kernel | hyp sync | 展开的固定 range 数组 |
| boot manifest | `pkvm_boot_ptdev_bar_entry` | `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h` | host init | hyp ptdev | BAR HPA base/size |
| boot manifest | `pkvm_boot_ptdev_manifest_entry` | `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h` | host init | hyp ptdev | BDF、flags、BAR array |
| hyp ptdev | `pkvm_ptdev_bar_resource` | `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h` | hyp | hyp | 固化后的 BAR resource snapshot |
| hyp ptdev | `pkvm_ptdev_mmio_range_state` | `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h` | hyp revoke | hyp restore | 已撤销的精确 HPA range |
| hyp ptdev | `pkvm_ptdev` | `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h` | hyp | hyp | 设备 identity、DMA view、owner/state、metadata、BAR restore 状态 |
| VM allowlist | `pkvm_shadow_vm.mmio_allow_*` | `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h` | hyp | guest hypercall handler | VM 级 allowlist 快照 |
| guest ABI | `pkvm_guest_mmio_info` | `pKVM-IA/include/uapi/linux/kvm_para.h` | hyp | guest | nr/generation/flags |
| guest ABI | `pkvm_guest_mmio_allow_range` | `pKVM-IA/include/uapi/linux/kvm_para.h` | hyp | guest | guest GPA/size/direct flag |
| guest cache | `pkvm_mmio_allow_ranges[]` | `pKVM-IA/arch/x86/coco/pkvm/pkvm.c` | guest boot | guest runtime MMIO | 本地 direct BAR 匹配表 |

## 当前边界和易混点

1. `metadata` 不等于 `allowlist`。

   metadata 是 host/crosvm 提交给 hyp 的富结构，包含 `bdf/pasid/bar_index/bar_offset`。allowlist 是 hyp 派生给 guest 的最小结构，只包含 `guest_gpa/size/flags`。

2. `guest_gpa` 不等于 `bar_offset`。

   `guest_gpa` 是 guest 看到的 MMIO 地址；`bar_offset` 是该地址对应 BAR 内偏移。hyp 用 `bar_offset` 加 boot manifest BAR base 得到 HPA。

3. `boot manifest` 是 BAR HPA 的来源，不是 guest direct allowlist。

   manifest 记录 host 启动期 PCI memory BAR base/size，用于 hyp 独立校验 metadata range 是否落在真实 BAR 内。

4. `ptdev->pgt` / `vm->pgstate_pgt` 是 DMA/IOMMU 视图，不是 guest CPU MMIO allowlist。

   guest direct MMIO 的 CPU 分流发生在 `arch/x86/coco/pkvm/pkvm.c` 的 `pkvm_virt_mmio()`；DMA mirror 则通过 `ptdev->pgt = &vm->pgstate_pgt` 和 `pkvm_iommu_sync()` 切换。

5. T12 的 Host BAR revoke 只应按 `DIRECT_BAR` metadata range 精确撤销。

   早期整 BAR revoke 会覆盖 MSI-X table / PBA 等 Host/VMM 仍需控制的范围。当前 `pkvm_revoke_ptdev_bars_locked()` 已按 metadata range 计算 HPA 并记录 `touched_mmio_ranges[]`。

6. 当前 hyp 还不能独立证明 `DIRECT_BAR` range 未覆盖 MSI-X table / PBA。

   crosvm 侧通过 `remove_bar_mmap_msix()` 排除了 MSI-X table / PBA，但 hyp 侧 boot manifest 当前只记录 BAR base/size。后续需要把 reserved/trapped 子区间写入 manifest 并在 `pkvm_validate_ptdev_mmio_metadata_locked()` 拒绝重叠。

7. 当前 VM allowlist 发布是覆盖式更新。

   `pkvm_update_vm_mmio_allowlist()` 会清空旧 allowlist 并写入当前 metadata 的 `DIRECT_BAR` ranges。当前主线是单设备静态 attach；多设备合并需要单独设计。

## 最小阅读顺序

如果只想快速接手普通 BAR MMIO metadata，请按下面顺序看源码：

```text
crosvm/devices/src/pci/vfio_pci.rs
    build_protected_vm_ptdev_mmio_metadata()
    remove_bar_mmap_msix()

crosvm/hypervisor/src/kvm/x86_64.rs
    KvmVm::set_protected_vm_ptdev_mmio_metadata()
    KvmProtectedVmPtdevMmioRange
    KvmProtectedVmPtdevMmioMetadata

pKVM-IA/arch/x86/include/uapi/asm/kvm.h
    struct kvm_protected_vm_ptdev_mmio_range
    struct kvm_protected_vm_ptdev_mmio_metadata

pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c
    pkvm_copy_ptdev_mmio_metadata_from_user()
    pkvm_vm_ioctl_set_ptdev_mmio_metadata()
    build_boot_ptdev_manifest()

pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h
    struct pkvm_ptdev
    struct pkvm_ptdev_bar_resource
    struct pkvm_ptdev_mmio_range_state

pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
    pkvm_prepare_ptdev_bar_resources_locked()
    pkvm_validate_ptdev_mmio_metadata_locked()
    pkvm_revoke_ptdev_bars_locked()
    pkvm_publish_ptdev_mmio_contract_locked()
    pkvm_set_ptdev_mmio_metadata()
    pkvm_get_ptdev_mmio_info()
    pkvm_read_ptdev_mmio_allow_ranges()

pKVM-IA/include/uapi/linux/kvm_para.h
    struct pkvm_guest_mmio_info
    struct pkvm_guest_mmio_allow_range

pKVM-IA/arch/x86/coco/pkvm/pkvm.c
    pkvm_init_mmio_allowlist()
    pkvm_mmio_allow_hit()
    pkvm_virt_mmio()

pKVM-IA/arch/x86/kvm/pkvm/mmu.c
    pkvm_vm_mmu_map()
    guest_mmu_map_leaf()
    guest_mmu_unmap_leaf()

pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c
    handle_host_ept_violation()
```
