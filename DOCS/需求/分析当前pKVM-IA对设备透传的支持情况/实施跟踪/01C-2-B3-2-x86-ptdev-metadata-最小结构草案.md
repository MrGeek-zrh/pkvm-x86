# [B3-2] x86 ptdev metadata 最小结构草案

## 状态

- 当前状态: 进行中（第一轮 host / guest / crosvm 实现已基本成型，首轮端到端验证已完成但 `BOOT-007` 仍未解除）
- 所属主任务: `pkvm-x86#13`
- 关联任务: `B3`
- 关联上层方案: [01C-1-B3-1-protected-pVM-设备透传第一阶段上层方案.md](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01C-1-B3-1-protected-pVM-设备透传第一阶段上层方案.md)
- 关联 Bug: `pkvm-x86#5`

## 目标

给出 x86 第一阶段可落地的 `ptdev metadata` 最小结构，并据此推进第一轮实现，回答下面 4 件事：

- hyp 内部到底需要保存哪些字段
- guest 实际需要看到哪些字段
- 这些字段由谁填充、何时冻结
- 它们在 MMIO 分流里怎么被使用

## 当前实现进展

- 已在 [asm/kvm.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/uapi/asm/kvm.h) 增加第一版 `SET_PTDEV_MMIO_METADATA` UAPI 常量与 userspace 提交结构。
- 已在 [kvm_host.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/kvm_host.h) 为 `struct kvm_protected_vm` 增加 host 侧 metadata 缓存。
- 已在 [pkvm_host.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c) 实现第一版：
  - userspace `copy_from_user`
  - 基础格式校验
  - 冻结前缓存
  - 完全一致提交的幂等成功
- 已在 [pkvm_hypercalls.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/pkvm_hypercalls.h)、[vmexit.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/vmexit.c)、[hyp/pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c) 增加 `sync_ptdev_mmio_metadata` hypercall 通路。
- 已在 [ptdev.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h) 和 [ptdev.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c) 增加 hyp 侧 metadata 挂载，使 host 提交后的 metadata 能绑定到已 attach 的 `ptdev`。
- 已在 [linux/kvm_para.h](/home/mrgeek/pkvm-x86/pKVM-IA/include/uapi/linux/kvm_para.h) 定义 guest 查询 allowlist 的 `INFO/READ` hypercall 和 allowlist 结构。
- 已在 [hyp/pkvm_hyp_types.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h)、[hyp/ptdev.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c)、[pkvm/vmx/vmx.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c) 打通 guest allowlist 的派生、查询和写回 guest buffer。
- 已在 [arch/x86/coco/pkvm/pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c) 加入 allowlist 缓存和 `pkvm_virt_mmio()` 分流：命中 `DIRECT_BAR` 时直接走 `raw_read*/raw_write*`，否则继续走原有 `PKVM_GHC_IOREAD/IOWRITE`。
- 已在 [hypervisor/src/x86_64.rs](/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/x86_64.rs)、[hypervisor/src/kvm/x86_64.rs](/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs)、[devices/src/pci/vfio_pci.rs](/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs)、[arch/src/lib.rs](/home/mrgeek/pkvm-x86/crosvm/arch/src/lib.rs) 和 [src/crosvm/sys/linux/device_helpers.rs](/home/mrgeek/pkvm-x86/crosvm/src/crosvm/sys/linux/device_helpers.rs) / [src/crosvm/sys/linux.rs](/home/mrgeek/pkvm-x86/crosvm/src/crosvm/sys/linux.rs) 打通 crosvm 的第一版 metadata 导出和提交路径：
  - 从 VFIO sparse mmap 导出普通 BAR 子区间
  - 排除 MSI-X table / PBA
  - 在 PCI BAR 布局完成后提交 `SET_PTDEV_MMIO_METADATA`
- 已完成 crosvm 本地构建验证：
  - 已安装 Rust `1.77.2` 工具链，并通过 `cargo build -p crosvm --locked`
  - 构建过程中已修复：
    - [hypervisor/src/kvm/x86_64.rs](/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs) 的常量引用名
    - [arch/src/lib.rs](/home/mrgeek/pkvm-x86/crosvm/arch/src/lib.rs) 的错误枚举排序
    - [x86_64/src/lib.rs](/home/mrgeek/pkvm-x86/crosvm/x86_64/src/lib.rs) 的 `hv_cfg.protection_type` 字段访问
- 当前尚未完成：
  - host / guest / crosvm 三者联动的端到端运行验证
- 已完成第一次端到端运行验证，当前结论是：
  - `Loaded bzImage kernel` 后仍然触发 `vcpu hit unknown error: Bad address (os error 14)`
  - `Failed to map mmio page` 已从多次下降到 1 次
  - 第一轮 `DIRECT_BAR` allowlist 已经不足以解除当前 blocker
  - 当前更可疑的残余路径是 protected VM 下仍然存在的 config / virtual-config MMIO 访问链

## 为什么当前 `struct pkvm_ptdev` 不够

当前的 [ptdev.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h) 里，`struct pkvm_ptdev` 只保存了：

- `bdf`
- `pasid`
- `did`
- `iommu_coherency`
- `vpgt`
- `pgt`
- `shadow_vm_handle`

这足够表达：

- 设备 identity
- 当前 IOMMU 视图
- 是否已 attach 到某个 protected VM

但它完全不表达：

- 这个设备有哪些 BAR/MMIO 资源
- 哪些 guest GPA 对应哪个 BAR 子区间
- 哪些范围允许直达
- 哪些范围必须继续 emulate

因此仅靠当前 `struct pkvm_ptdev`，guest/hyp 无法在 [pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c) 的 `pkvm_virt_mmio()` 决定“这次访问应该走直达还是 hypercall”。

## 设计原则

### 原则 1: 区分 hyp 内部富 metadata 和 guest 可见 allowlist

- hyp 内部为了做绑定和校验，需要的字段比 guest 分流所需的更多。
- guest 做 MMIO 分流时真正需要的最小信息只有：
  - `guest_gpa`
  - `size`
  - `flags`
- 但如果 userspace/host 向 pKVM 只提交 `GPA + size`，那 pKVM 无法判断：
  - 这到底是不是某个已 attach 设备的 BAR 子区间
  - 是否踩到 MSI-X table / PBA
  - 是否和 crosvm 当前 BAR 布局一致

所以需要两层结构：

- hyp 内部：富 metadata
- guest 可见：精简 allowlist

### 原则 2: 第一阶段只覆盖普通 BAR MMIO

这份结构草案只服务于 B3-1 已经确认的第一阶段边界：

- `config space` 继续 emulated
- 普通 `BAR MMIO` 优先打通
- `MSI-X table/PBA` 继续 emulate

对应 crosvm 现有行为：

- `add_bar_mmap()` 会基于 VFIO sparse mmap 生成 BAR 子区间并注册到 guest GPA，见 [vfio_pci.rs](/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs)。
- `remove_bar_mmap_msix()` 会把 MSI-X table / PBA 从 BAR mmap 区间里剔掉，见同文件。
- `read_bar()` / `write_bar()` 也对 MSI-X table / PBA 走特殊 emulation，见同文件。

### 原则 3: metadata 以 ptdev 为宿主，而不是独立散落

- `ptdev` 现在已经是 x86 pKVM 里“这个受管设备”的主对象，见 [ptdev.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c)。
- 第一阶段不再新造另一套平行设备对象图。
- 更合适的是：
  - `ptdev` 继续承担 identity / IOMMU / attachment state
  - 新增的 MMIO metadata 作为 `ptdev` 的附属状态

## 建议的两层结构

### 层 1: hyp 内部富 metadata

```c
enum pkvm_ptdev_mmio_kind {
    PKVM_PTDEV_MMIO_DIRECT_BAR = 1,
    PKVM_PTDEV_MMIO_EMULATED_MSIX = 2,
    PKVM_PTDEV_MMIO_EMULATED_CONFIG = 3,
};

struct pkvm_ptdev_mmio_range {
    u64 guest_gpa;
    u64 size;
    u64 bar_offset;
    u8 bar_index;
    u8 kind;
    u16 reserved;
};

#define PKVM_PTDEV_MAX_MMIO_RANGES 16

struct pkvm_ptdev_metadata {
    u16 nr_ranges;
    u16 generation;
    u32 flags;
    struct pkvm_ptdev_mmio_range ranges[PKVM_PTDEV_MAX_MMIO_RANGES];
};
```

### 字段作用

- `guest_gpa`
  - guest 访问时真正用于匹配的地址范围
- `size`
  - 区间大小
- `bar_offset`
  - 表示该 GPA 区间对应 BAR 内哪个偏移，用于绑定 BAR 子区间语义
- `bar_index`
  - 表示属于 BAR0-BAR5 中哪一个
- `kind`
  - 第一阶段至少要区分：
    - 可直达的普通 BAR
    - 仍需 emulate 的 MSI-X
    - 未来保留的 config 语义
- `generation`
  - 第一阶段虽然是静态 attach，但预留一个简单版本号，后面若有重新注册或 remove-path 不需要重做 UAPI

### 为什么这里不再重复 `bdf/pasid`

- 因为这层 metadata 的宿主就是单个 `struct pkvm_ptdev`。
- `struct pkvm_ptdev` 已经自带：
  - `bdf`
  - `pasid`
  - `did`
- 所以没必要在每个 range 里重复存一遍 identity。

## 层 2: guest 可见 allowlist

```c
struct pkvm_guest_mmio_allow_range {
    u64 guest_gpa;
    u64 size;
    u32 flags;
};
```

### guest 侧为什么只需要这点信息

guest 在 [pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c) 的 `pkvm_virt_mmio()` 已经能拿到：

- 当前访问地址
- 当前访问宽度
- 读/写方向

所以 guest 侧分流的最小需求只是：

- 这段 GPA 是否命中“允许直达”的区间表

因此 guest 不需要知道：

- 真实物理 BAR 地址
- 设备是哪个 host PCI 资源
- 为什么这个区间会被允许

这些都属于 hyp 内部真相，不必暴露给 guest。

## 推荐的 ownership

### userspace / host KVM 提交的内容

第一阶段建议 userspace / host KVM 向 pKVM 提交“候选 metadata”，最小字段应至少包含：

- `bdf`
- `pasid`
- `bar_index`
- `bar_offset`
- `guest_gpa`
- `size`
- `kind`

原因是如果只提交 `GPA + size`，pKVM 无法把这段区间绑定回已 attach 的某个 `ptdev` 和某个具体 BAR 子区间。

### pKVM/hyp 最终持有的内容

pKVM/hyp 接受后，应把这些信息冻结为：

- `ptdev` identity / IOMMU state
- `ptdev_metadata`
- guest 可查询的 allowlist 视图

这与当前 ARM 参考模式一致：

- ARM 侧也是 host/VMM 提供设备描述，但最终由 pvmfw + hypervisor 验证并绑定，见 [device_assignment.md](/home/mrgeek/pkvm-x86/refs/android-virtualization/docs/device_assignment.md) 和 [device_assignment.rs](/home/mrgeek/pkvm-x86/refs/android-virtualization/guest/pvmfw/src/device_assignment.rs)。

## 推荐的更新时机

### 第一阶段

第一阶段只支持静态 attach，因此 metadata 的更新时机可以非常简单：

1. host 通过当前 `add_ptdev` 路径建立 `ptdev`
   - 见 [pkvm_host.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c)
   - 见 [ptdev.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c)
2. crosvm 完成 BAR GPA 布局后，提交候选 MMIO metadata
3. pKVM/hyp 接受并冻结 metadata
4. guest 启动早期查询 allowlist，并缓存
5. 运行期不允许修改

### 为什么第一阶段先不支持运行期修改

- B3-1 已经明确排除了 hotplug / remove-path。
- 运行期修改会同时引入：
  - guest 缓存同步
  - IOTLB / MMIO 生命周期一致性
  - failure rollback
- 不适合放在第一阶段。

## `pkvm_virt_mmio()` 的消费方式

当前代码：

```text
pkvm_mmio_read*/write*()
    pkvm_virt_mmio()
        lookup_address()
        paddr = pte_pfn(...)
        PKVM_GHC_IOREAD/IOWRITE
```

见 [pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c)。

第一阶段建议改造成：

```text
pkvm_mmio_read*/write*()
    pkvm_virt_mmio()
        lookup_address()
        gpa/paddr resolve
        if hit guest_mmio_allowlist(gpa, size, DIRECT_BAR):
            raw_read*/raw_write*
        else:
            PKVM_GHC_IOREAD/IOWRITE
```

这里最重要的不是实现细节，而是：

- guest 消费的是 allowlist
- allowlist 的真相来自 hyp 侧 `ptdev_metadata`

## 为什么第一阶段用固定上限数组

第一阶段推荐：

- 每个设备一个小固定上限，例如 `PKVM_PTDEV_MAX_MMIO_RANGES = 16`

原因是：

- 当前只支持单设备
- 只处理普通 BAR MMIO
- crosvm 现有 BAR sparse mmap + MSI-X 剔除后，区间数通常有限
- 可以避免一开始就引入 hyp 侧动态分配和复杂回滚

如果后续进入多设备/复杂 VFIO region，再升级成可变长结构也不迟。

## 当前结论

- `ptdev metadata` 不是为了替代 `struct pkvm_ptdev`，而是补齐它当前缺失的“设备资源语义”。
- 第一阶段最合理的做法是：
  - `ptdev` 持有 identity / IOMMU / attachment
  - `ptdev_metadata` 持有富 MMIO 资源描述
  - guest 只获取精简 allowlist

## 下一步

- 在这个结构草案基础上，再继续收敛：
  - userspace -> host KVM -> pKVM 的提交接口形态
  - guest 的查询接口形态
- 在这两项明确前，不进入代码实现。

## 最小接口草案

### 设计约束

- userspace 侧当前 x86 protected VM 控制面已经是 `KVM_ENABLE_CAP` 风格，见 [pkvm_host.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c) 和 [x86_64.rs](/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs)。
- guest 侧当前 pKVM hypercall 集只有：
  - `PKVM_GHC_SHARE_MEM`
  - `PKVM_GHC_UNSHARE_MEM`
  - `PKVM_GHC_IOREAD`
  - `PKVM_GHC_IOWRITE`
  - `PKVM_GHC_START_CPU`
  - 见 [kvm_para.h](/home/mrgeek/pkvm-x86/pKVM-IA/include/uapi/linux/kvm_para.h)
- 因此第一阶段最顺的扩展点是：
  - userspace -> host KVM：新增 `KVM_CAP_X86_PROTECTED_VM` 子 flag
  - guest -> pKVM/hyp：新增 pKVM guest hypercall

### 接口 1: userspace -> host KVM -> pKVM 提交接口

建议继续复用：

```text
KVM_ENABLE_CAP
    cap = KVM_CAP_X86_PROTECTED_VM
    flags = <new flag>
```

原因：

- 当前 x86 protected VM 的固件加载和信息查询已经这么做，见 [pkvm_host.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c)。
- crosvm `KvmVm` 也已经有 `enable_raw_capability()` 的封装，见 [x86_64.rs](/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs)。

#### 建议的 flag 形态

```c
KVM_CAP_X86_PROTECTED_VM_FLAGS_SET_PTDEV_MMIO_METADATA
```

#### 建议的提交载荷

```c
struct kvm_protected_vm_ptdev_mmio_range {
    __u16 bdf;
    __u16 segment;
    __u32 pasid;
    __u64 guest_gpa;
    __u64 size;
    __u64 bar_offset;
    __u32 flags;
    __u8  bar_index;
    __u8  kind;
    __u16 reserved;
};

struct kvm_protected_vm_ptdev_mmio_metadata {
    __u32 nr_ranges;
    __u32 reserved;
    __u64 ranges_ptr;
};
```

#### 为什么需要 `segment`

- 第一阶段很可能只跑单 segment。
- 但 crosvm/KVM 能力模型里本来就有 `KVM_CAP_PCI_SEGMENT`，见 [cap.rs](/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/cap.rs)。
- 在 UAPI 里提前留位，后面不用再改结构 ABI。

#### 为什么提交接口不直接传 guest allowlist

- allowlist 只是 guest 消费视图。
- 提交接口需要的是 hyp 可校验、可绑定的“富 metadata”。
- 否则 pKVM 无法判断：
  - 这是不是某个已 attach `ptdev`
  - BAR 子区间语义是否成立
  - 是否踩进 MSI-X / config 区域

### 接口 2: guest -> pKVM/hyp 查询接口

guest 侧目标不是获取全部设备真相，而是获取精简 allowlist。

建议新增两类 guest hypercall：

```text
PKVM_GHC_PTDEV_MMIO_INFO
    查询版本/条目数

PKVM_GHC_PTDEV_MMIO_READ
    按 index 或批量读取 allowlist 项
```

#### 为什么不建议寄存器直接返回整表

- x86 当前 `kvm_hypercall0..4()` 最自然的返回位只有 `RAX`，见 [asm/kvm_para.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/kvm_para.h)。
- 即使可以借 `RBX/RCX/RDX/RSI`，也不适合返回一张可变长表。
- 所以更顺的做法是：
  - guest 先 query count / generation
  - 再用共享缓冲区或 guest pointer 批量读 allowlist

#### 建议的 guest 可见结构

```c
struct pkvm_guest_mmio_allow_range {
    __u64 guest_gpa;
    __u64 size;
    __u32 flags;
    __u32 reserved;
};
```

#### 查询流程建议

```text
guest boot early
    PKVM_GHC_PTDEV_MMIO_INFO
        -> nr_ranges, generation
    allocate local cache
    PKVM_GHC_PTDEV_MMIO_READ
        -> copy allowlist entries
    cache locally
```

运行期：

```text
pkvm_virt_mmio()
    lookup GPA
    query local allowlist
    direct BAR ? raw_read/raw_write : IOREAD/IOWRITE
```

### 为什么第一阶段不做“按访问时动态问 hyp”

- `pkvm_virt_mmio()` 是热路径。
- 每次访问都做 hypercall 查询，会让直达路径失去意义。
- 第一阶段既然不支持 hotplug / remove-path，完全可以在 guest 启动早期查询一次并缓存。

### host KVM 与 pKVM 的责任切分

#### host KVM 侧

- 负责 ioctl 接收和基本语法检查。
- 负责把用户态提交的数据桥接到 pKVM/hyp。
- 可以做前置一致性检查，但不是最终真相持有者。

#### pKVM/hyp 侧

- 根据 `(segment, bdf, pasid)` 找到已 attach 的 `ptdev`
- 接受并冻结 metadata
- 派生 guest allowlist
- 对 guest 查询接口负责

### 第一阶段仍然刻意不解决的接口问题

以下问题先不放入第一阶段接口设计：

- metadata 运行时更新
- remove-path 的 generation 失效协议
- 多设备的分页式大表导出
- guest 侧并发刷新与锁策略
- 非 BAR region 的统一抽象

## 当前结论补充

- 第一阶段接口方向已经比较明确：
  - userspace -> host KVM：沿用 `KVM_ENABLE_CAP(KVM_CAP_X86_PROTECTED_VM)`
  - guest -> pKVM/hyp：新增专用 guest hypercall 查询 allowlist
- 这两条接口都应服务于：
  - hyp 内部富 metadata
  - guest 只消费精简 allowlist

## 第一阶段最小 ABI 决议

### 决议 1: metadata 提交顺序

第一阶段固定顺序如下：

```text
1. add_ptdev
2. crosvm 完成 BAR GPA 布局
3. KVM_ENABLE_CAP 提交 ptdev metadata
4. pKVM/hyp 接受并冻结
5. guest 启动早期查询 allowlist
6. guest 开始进入常规 PCI 枚举 / 驱动访问
```

#### 为什么必须在 guest 运行前完成

- 如果 guest 已经开始跑，而 allowlist 还没准备好，那么：
  - guest 对本应直达的 BAR MMIO 会继续走 `PKVM_GHC_IOREAD/IOWRITE`
  - 这会把问题重新退回当前旧路径
- 因此第一阶段直接规定：
  - metadata 提交必须在第一次 `KVM_RUN` 之前完成

### 决议 2: metadata 冻结语义

第一阶段 `ptdev metadata` 一旦注册成功，就进入冻结状态：

- 不允许运行期修改
- 不允许 remove-path 更新
- 不允许 hotplug 增量修改

对于重复提交：

- 若内容完全一致：
  - 可视为幂等成功
- 若内容不一致：
  - 直接返回 `-EBUSY` 或等价错误

这样可以避免第一阶段实现复杂的同步和回滚协议。

### 决议 3: generation 语义

第一阶段仍保留 `generation`，但语义刻意保持极简：

- metadata 首次成功注册后：
  - `generation = 1`
- 第一阶段运行期间：
  - `generation` 不再变化

保留这个字段的目的不是第一阶段就做动态刷新，而是：

- 给后续 remove-path / hotplug 留 ABI 兼容空间
- 让 guest 查询接口从一开始就有基本版本语义

### 决议 4: guest 查询时机

第一阶段 guest 不在每次 MMIO 访问时向 hyp 动态查询。

固定策略：

- guest 在启动早期查询一次 allowlist
- 查询结果缓存到本地
- `pkvm_virt_mmio()` 只查本地缓存

推荐时机：

- 在 `pkvm_guest_init_coco()` 完成 MMIO hook 安装后、PCI 枚举前
- 也可以在第一阶段实现时放到第一次需要 PCI MMIO 前的显式初始化函数

但无论具体落在哪个函数，原则都是：

- 先拿 allowlist
- 再开始设备枚举和驱动 MMIO

### 决议 5: guest 查询 ABI 采用“两步式”

第一阶段 guest 查询接口固定为两步：

1. `INFO`
   - 返回：
     - `nr_ranges`
     - `generation`
     - `entry_size`
2. `READ`
   - 输入：
     - `start_index`
     - `max_entries`
     - `guest buffer GPA`
   - 输出：
     - 实际拷贝条目数

#### 为什么不做“一次性整表返回”

- x86 当前 `kvm_hypercall0..4()` 最自然只支持少量寄存器参数，见 [asm/kvm_para.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/kvm_para.h)。
- 整表返回会把 ABI 压得很死，不利于后续扩展。
- 两步式在第一阶段就够简单，同时更稳。

### 决议 6: guest buffer 以 GPA 传递

第一阶段 `READ` 接口里，guest 提供的目标缓冲区建议直接用 `guest buffer GPA`，而不是 guest VA。

原因：

- hyp 侧处理 MMIO allowlist 查询时，本来就更适合围绕 GPA 语义工作。
- 可以避免在 ABI 里额外引入 guest VA 到 GPA 的解释责任。
- allowlist 条目数在第一阶段很小，用一页物理连续缓冲区就足够。

### 决议 7: guest allowlist flags 最小化

第一阶段 guest 可见 allowlist 的 `flags` 只保留一个必需语义：

- `DIRECT_BAR`

也就是说，第一阶段 guest 不需要通过 allowlist 知道：

- `EMULATED_MSIX`
- `EMULATED_CONFIG`

因为 guest 分流只需要判断：

- “这段 GPA 能不能直达”

其他访问统一继续走 `PKVM_GHC_IOREAD/IOWRITE` 即可。

### 决议 8: host KVM 与 pKVM 的错误边界

第一阶段按下面切分错误责任：

- userspace / crosvm:
  - 负责生成候选 BAR GPA metadata
- host KVM:
  - 负责 ioctl 接收和基本格式校验
- pKVM/hyp:
  - 负责根据 `(segment, bdf, pasid)` 找到已 attach 的 `ptdev`
  - 负责最终接受 / 拒绝
  - 负责生成 guest allowlist

第一阶段里，只要 pKVM/hyp 无法把候选 metadata 绑定到已 attach `ptdev`，就必须失败，而不是降级成“先信 userspace”。

## 第一阶段 ABI 小结

到这一步，第一阶段 ABI 可以概括成：

```text
userspace / crosvm
    KVM_ENABLE_CAP(KVM_CAP_X86_PROTECTED_VM, SET_PTDEV_MMIO_METADATA)
        提交富 metadata

pKVM/hyp
    接受并冻结 metadata
    派生 DIRECT_BAR allowlist

guest
    PKVM_GHC_PTDEV_MMIO_INFO
    PKVM_GHC_PTDEV_MMIO_READ
        查询并缓存 allowlist

pkvm_virt_mmio()
    本地查 allowlist
    DIRECT_BAR -> raw MMIO
    else -> IOREAD/IOWRITE
```

## 推荐命名

### userspace -> host KVM flag

参考当前 [asm/kvm.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/uapi/asm/kvm.h) 已有命名：

- `KVM_CAP_X86_PROTECTED_VM_FLAGS_SET_FW_GPA`
- `KVM_CAP_X86_PROTECTED_VM_FLAGS_INFO`

第一阶段建议新增：

```c
#define KVM_CAP_X86_PROTECTED_VM_FLAGS_SET_PTDEV_MMIO_METADATA 2
```

命名理由：

- `SET_...` 与现有 `SET_FW_GPA` 风格一致
- `PTDEV_MMIO_METADATA` 明确表达：
  - 不是泛化的设备 metadata
  - 不是 guest allowlist
  - 而是“受保护 VM 的 ptdev MMIO 富 metadata”

### userspace 提交结构

建议名称：

```c
struct kvm_protected_vm_ptdev_mmio_range
struct kvm_protected_vm_ptdev_mmio_metadata
```

命名理由：

- 继续沿用已有 `kvm_protected_vm_info` 的前缀
- `ptdev` 与现有 x86 pKVM 内部术语一致，见 [ptdev.h](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h)
- `range` / `metadata` 两层也比较清楚

### guest hypercall 名称

建议名称：

```c
PKVM_GHC_PTDEV_MMIO_INFO
PKVM_GHC_PTDEV_MMIO_READ
```

命名理由：

- 延续当前 [kvm_para.h](/home/mrgeek/pkvm-x86/pKVM-IA/include/uapi/linux/kvm_para.h) 的 `PKVM_GHC_*` 风格
- `INFO + READ` 的两步式语义一眼可见

### guest 可见 allowlist 结构

建议名称：

```c
struct pkvm_guest_mmio_allow_range
```

不建议第一阶段叫：

- `ptdev_metadata`
- `ptdev_mmio_range`

因为 guest 看不到 `ptdev` 级真相，它只消费 allowlist 视图。

## 推荐错误码与幂等语义

### userspace -> host KVM -> pKVM 提交接口

#### `-EINVAL`

用于“格式或参数本身不合法”，例如：

- `nr_ranges == 0`
- 指针为空但 `nr_ranges != 0`
- `size == 0`
- `guest_gpa` 或 `size` 未按页对齐
- `bar_index` 超出第一阶段支持范围
- `kind` 不在第一阶段允许集合里
- `args[1..3]` 非零

#### `-ENODEV`

用于“metadata 无法绑定到已存在设备对象”，例如：

- `(segment, bdf, pasid)` 找不到已 attach 的 `ptdev`
- 设备当前不属于这个 protected VM

这与当前 x86 pKVM attach / iommu 相关路径中大量使用 `-ENODEV` 的风格一致，见 [ptdev.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c) 和 [iommu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c)。

#### `-EBUSY`

用于“语义上合法，但第一阶段冻结状态不允许变更”，例如：

- 第一次 `KVM_RUN` 后再尝试提交 metadata
- 已成功注册 metadata 后再次提交不同内容

这也和当前 pKVM 路径里对“状态已固定/资源正忙”的常见用法一致，见 [pkvm_host.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c) 和 [mmu.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/mmu.c)。

#### 幂等成功

若 metadata 已存在，且本次提交内容逐项完全一致：

- 返回 `0`
- 不改变 `generation`

这是第一阶段最稳的幂等语义。

### guest 查询接口

#### `INFO`

- 无 allowlist 时：
  - 返回 `0`
  - `nr_ranges = 0`
  - 不建议把“没有设备”当成错误

#### `READ`

- `start_index >= nr_ranges`
  - 返回 `-EINVAL`
- buffer 无效 / 不可访问
  - 返回 `-EFAULT`
- `max_entries == 0`
  - 返回 `-EINVAL`
- 正常但到表尾
  - 返回实际拷贝条目数，可为小于 `max_entries`

### guest `pkvm_virt_mmio()` 选路失败语义

第一阶段不建议在 guest 侧把 “未命中 allowlist” 当作错误。

固定语义：

- 命中 `DIRECT_BAR`
  - 走 `raw_read* / raw_write*`
- 未命中
  - 继续 `PKVM_GHC_IOREAD/IOWRITE`

这样可以保证：

- config space 继续通过旧 emulation 路径工作
- MSI-X / 其他非直达区继续保留现有 fallback

## 当前设计收口点

到当前为止，B3-2 已经把第一阶段需要先定下来的设计点基本定完：

- `ptdev metadata` 两层结构
- userspace 提交接口形态
- guest 查询接口形态
- metadata 冻结与 generation 语义
- 推荐命名
- 错误码与幂等语义

下一步如果继续推进，就不该再停留在方案讨论层，而应开始决定：

1. 先写文档 PR / issue comment 固化这套 ABI
2. 或直接开始第一轮代码实现
