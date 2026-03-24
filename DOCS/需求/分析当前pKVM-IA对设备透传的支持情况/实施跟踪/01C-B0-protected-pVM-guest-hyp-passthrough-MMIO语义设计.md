# [B3] B0: protected pVM guest/hyp passthrough MMIO 语义设计

## 状态

- 当前状态: 进行中（设计收敛）
- 优先级: B0（主线前置阻塞）
- GitHub Task: `pkvm-x86#13`
- 关联前置任务: `B1`
- 关联 Bug: `pkvm-x86#5`

## 目标

在继续实现 protected pVM 设备透传之前，先定义一个明确的 guest/hyp contract，让 guest 能区分并正确处理两类 MMIO：

- 需要继续走 hypercall / host emulation 的 MMIO
- 应直接访问的 passthrough 设备物理 MMIO

这个任务的输出不是“功能已经打通”，而是：

- MMIO contract 明确
- 设备资源元数据通道明确
- 最小实现切入面明确

当前阶段需要先补一个更上层的前置输出：

- 第一阶段上层方案明确
- 第一阶段支持范围和非目标明确
- trust boundary 明确
- 先做哪条访问面、后做哪条访问面明确

对应上层方案决议见：

- `01C-1-B3-1-protected-pVM-设备透传第一阶段上层方案.md`
- `01C-2-B3-2-x86-ptdev-metadata-最小结构草案.md`

## 为什么必须单独拆分

- B1 已经确认：当前分支里的 protected pVM 设备透传本身尚未真正支持。
- 本地 guest 源码进一步说明，当前更深的 blocker 在 guest/hyp MMIO 语义，而不是单纯的 crosvm fallback。
- 现有 host->pKVM 设备接口也只传 `BDF/PASID`，没有把 BAR/MMIO 资源信息传进来。
- 如果不先定义 contract，就直接改 guest 或 crosvm，会把“地址分流”“设备元数据”“DMA mirror”三类问题混在一起，后续难以验证。

## 关键源码锚点

- guest MMIO 全局重定向
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
    - `pkvm_virt_mmio()`
    - `pkvm_mmio_read*() / pkvm_mmio_write*()`
    - `pkvm_guest_init_coco()`
- x86 MMIO 访问宏与 paravirt 分发
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/io.h`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/paravirt.h`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/lib/iomap.c`
- 现有按物理 MMIO 地址分类的架构钩子
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/mm/ioremap.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/x86_init.h`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/hyperv/ivm.c`
- host->pKVM 设备 attach 接口
  - `/home/mrgeek/pkvm-x86/pKVM-IA/virt/kvm/vfio.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- crosvm 对 BAR mmap 的现有能力
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs`
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/vfio.rs`

## 当前已确认事实

- guest 侧当前把 `pv_ops.mmio.raw_*` 和 `pv_ops.mmio.pci_mmcfg_*` 全部改写成了 `PKVM_GHC_IOREAD/IOWRITE`：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
- `ioread/iowrite` 最终会落到 `readb/readl/writeb/writel`，而在 `CONFIG_PARAVIRT` 下这些宏被重定向到了 `pv_read*/pv_write*`：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/io.h`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/lib/iomap.c`
- 因而当前 guest 内核里并不存在“按 BAR 地址例外直达”的现成分流路径。
- 不过 `io.h` 里保留了原始 `raw_read* / raw_write*` 实现，这意味着若后续在 `pkvm_virt_mmio()` 增加地址判断，技术上可以直接回退到原始 MMIO 读写，而不必完全重构 x86 MMIO 宏层。
- x86 平台已有 `x86_platform.hyper.is_private_mmio(addr)` 这种“按物理 MMIO 地址分类”的架构钩子：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/x86_init.h`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/mm/ioremap.c`
  - 但它当前控制的是 ioremap/private 属性，不是 `readl/writel` 的访问分发。
- host 侧当前透传 attach 接口只把 `BDF/PASID` 传进 pKVM：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
    - `add_device_to_pkvm() -> pkvm_hypercall(add_ptdev, vm_handle, devid, 0)`
- 这条路径已经体现了当前 pKVM 的基本 trust boundary：
  - host 负责“发现设备并发起请求”
  - 真正的 `ptdev` 状态和 IOMMU second-level 切换最终落在 pKVM/hyp，见
    - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`
    - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
    - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`
- 反过来，当前 guest 的 `PKVM_GHC_IOREAD/IOWRITE` 在 pKVM/hyp 里会被直接“转发给 host”：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c`
  - 这正说明“最终由 host 处理 MMIO 真相”不是我们想继续扩大的主线模式。
- `ptdev.c` 现有注释也直接承认：当前既没有“让 pKVM 独立知道透传设备信息”的通道，也没有“让 protected VM 查询自身透传设备信息”的通道：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- crosvm 现有 VFIO PCI 路径已经能把可 mmap 的 BAR 子区间直接注册进 guest GPA：
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs`
    - `add_bar_mmap() -> register_memory()`
  - 这说明只要 guest 访问语义打通，BAR 直达并非完全没有基础。

## 本任务要回答的问题

- guest 侧如何识别“这是 passthrough BAR MMIO，因此不能走 `PKVM_GHC_IOREAD/IOWRITE`”？
- 这个判断基于什么元数据：
  - BDF
  - BAR index
  - guest GPA range
  - host physical BAR range
  - 还是一个归一化后的 passthrough MMIO 区间表
- 这份元数据由谁产生、谁校验、谁持有：
  - host KVM/VFIO
  - pKVM hyp
  - guest kernel
- PCI config / BAR / MSI-X table/PBA / virtual config 各自的处理边界怎么划分？
- 第一阶段最小切入面是什么：
  - 只先保证 BAR MMIO 直达
  - config space 继续走 host/emulated 路径
  - MSI-X 保持 trap/emulate

## 当前推荐方向

- 不建议先继续在 crosvm 上扩大战术 patch。
- 更合理的最小切入面是：
  - 先把 config space 留在现有 emulated 路径
  - 先只解决 passthrough BAR MMIO 直达 guest
  - MSI-X table/PBA 等特殊区继续保持现有 trap/emulate 语义
- 为此至少要补两件事：
  - host/VFIO -> pKVM/guest 的 passthrough MMIO 资源元数据通道
  - guest 侧按物理 MMIO 范围分流到 `raw_read* / raw_write*` 的机制

## 当前阶段调整

- 当前任务仍然是 B3，但推进方式应先从“上层方案收敛”开始，而不是直接固定 ioctl / hypercall 细节。
- 原因是这个工程已经跨 guest、host KVM、pKVM/hyp、VMM 四层；如果不先定第一阶段的支持边界，底层 contract 很容易因为上层目标变动而返工。
- 因此 B3 现在分成两个连续子阶段：
  - B3-1: 上层方案收敛
  - B3-2: 在 B3-1 约束下细化 MMIO contract / metadata channel

## B3-1: 第一阶段上层方案建议

### 为什么先做上层方案

- 当前最大的风险不是“不会写某个 ioctl”，而是“还没说清第一阶段到底准备支持什么”。
- 若一开始就追求完整通用方案，会同时引入：
  - config path
  - BAR MMIO
  - MSI-X
  - DMA mirror
  - remove/hotplug
  - lifecycle teardown
- 这样复杂度过高，也不利于逐轮验证。

### 建议的低复杂度目标

- 第一阶段目标应明确收敛为：
  - protected pVM
  - 单个 VFIO PCI 设备
  - 静态 attach
  - `NoIommu`
  - 无 hotplug
  - 无 remove-path
  - 无 migration
- 第一阶段只要求“把最基础的寄存器访问链打通”，不要求一次性补齐所有设备生命周期能力。

### 第一阶段支持边界

- 继续支持：
  - PCI config space 走 emulated 路径
  - 普通 BAR MMIO 作为优先打通的访问面
- 暂不在第一阶段支持：
  - MSI-X table / PBA 直达
  - vIOMMU
  - 动态设备增删
  - 多设备共享和复杂回滚
  - 通用化的 VFIO region 覆盖

### 第一阶段 trust boundary

- 第一阶段也不应退化为“host 说了算”的普通 KVM 模式。
- 更合理的边界是：
  - userspace / host KVM 负责发现并提交候选信息
  - pKVM/hyp 负责最终接受、绑定和持有 authoritative metadata
  - guest 只信任 pKVM/hyp 暴露的结果

### 第一阶段推荐实现顺序

1. 先敲定上层方案和非目标。
2. 再确定 BAR/MMIO metadata contract。
3. 再实现 guest MMIO 分流。
4. 之后再回到 T2/T3/T4 处理 DMA mirror 和 teardown 生命周期。

## 最小主线实现建议

### 目标边界

- 第一阶段只要求：
  - protected pVM 对 passthrough 设备的 BAR MMIO 能直接访问
  - PCI config space 继续走现有 emulated/hypercall 路径
  - MSI-X table / PBA 继续保持 trap/emulate
- 第一阶段不要求：
  - 重新设计 config path
  - 一次性打通所有 VFIO region
  - 与 DMA mirror 一起同时实现

### 关键思路

- guest 真正需要判断的不是“这是不是某个 BDF 的 BAR”，而是：
  - 当前将要访问的 GPA 是否落在一个“允许直达”的 passthrough MMIO 区间里
- 因为在 guest 侧，`pkvm_virt_mmio()` 已经把当前虚拟地址解析成了 GPA：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
- 所以最小 contract 的核心数据结构应是一个“允许直达的 GPA 区间表”，而不是复杂的设备对象图。

### 建议的数据结构

- 每个区间至少包含：
  - `gpa_start`
  - `size`
  - `bdf`
  - `bar_index`
  - `bar_offset`
  - `flags`
- `flags` 第一阶段至少需要表达：
  - `DIRECT_BAR_MMIO`
  - `EMULATED_CONFIG`
  - `EMULATED_MSIX`
- 第一阶段真正下发给 guest 的只需要 `DIRECT_BAR_MMIO` 区间。
- `bar_offset` 不是给 guest 分流必需的，但对 host KVM 做最基本的合法性校验很重要。

### 推荐的 ownership / flow

```text
crosvm / VFIO
    发现 BAR guest GPA 和可 mmap 子区间
    剔除 MSI-X table / PBA 等特殊区域
    向 host KVM 提交候选“直达 MMIO 区间表”

pKVM/hyp
    最终接收并授权这张区间表
    保存为每个 protected VM 的受信 metadata
    对 guest 暴露一个只读查询接口

guest kernel
    启动早期获取并缓存这张区间表
    pkvm_virt_mmio() 按 GPA 查询：
        命中直达区间 -> raw_read/raw_write
        未命中 -> 继续 PKVM_GHC_IOREAD/IOWRITE
```

### 为什么推荐这样分工

- crosvm 已经掌握 guest 视角的 BAR GPA 分配和 VFIO sparse mmap 区间：
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs`
  - `/home/mrgeek/pkvm-x86/crosvm/devices/src/vfio.rs`
- host KVM 仍然掌握 Linux PCI/VFIO 的资源发现能力，适合做“候选区间的导出和格式化”。
- guest 只需要 GPA 区间来决定访问后端，不需要知道 host 物理 BAR 地址。
- 但这张表不能长期只放在 crosvm 或 host KVM 私有状态里，否则 protected VM 的直达白名单最终仍由不受信 host 控制。
- 因而主线版本应把这份表提升为 pKVM/hyp 持有并对 guest 暴露的 metadata，而不是单纯 userspace 或 host KVM 自说自话。

### trust boundary 修正

- 对普通 KVM，可以接受“host KVM 校验后就生效”。
- 但对 pKVM protected VM，不应把最终授权停在 host KVM。
- 更合理的边界应是：

```text
userspace / host KVM
    发现并提议 candidate BAR 子区间
        |
        v
host -> pKVM host-side hypercall / ioctl bridge
        |
        v
pKVM/hyp
    最终接受/拒绝
    持有 authoritative allowlist
        |
        v
guest
    只查询 pKVM/hyp 持有的 allowlist
```

- 所以“host 做校验”在主线设计里最多只能表示：
  - host 先做语法检查、资源发现和候选集构造
- 不能表示：
  - host 是最终真相来源
  - host 单方面决定哪些 GPA 可以直达

### 为什么 userspace 不能只注册 `GPA + size`

- 如果 userspace 只报“这段 GPA 允许直达”，host KVM 和 pKVM/hyp 都几乎无法校验它到底是不是某个已绑定设备的 BAR 子区间。
- 当前 host 侧仍然能拿到真实 PCI 设备对象和 BAR 资源：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/drivers/pci/*`
- 所以更稳妥的注册项应该至少包含：
  - `bdf`
  - `bar_index`
  - `bar_offset`
  - `size`
  - `guest_gpa`
- 这样 host KVM 至少可以校验：
  - 该设备确实已经 attach 到当前 protected VM
  - `bar_index` 对应真实 MMIO BAR
  - `bar_offset + size` 不超过真实 BAR 长度
  - 若能解析 MSI-X capability，则进一步拒绝 table / PBA 子区间
- 但在 pKVM 主线设计里，这些检查不应停留在 host KVM 结论本身。
- 更合理的是：
  - host 利用 Linux PCI/VFIO 资源信息做前置检查
  - 然后把结构化后的候选信息提交给 pKVM/hyp
  - pKVM/hyp 将其绑定到已 attach 的 `ptdev` 和 `vm_handle` 上，形成最终 allowlist

## 具体接口草案

### userspace -> host KVM 注册接口

- 推荐复用现有的 `KVM_CAP_X86_PROTECTED_VM` + `KVM_ENABLE_CAP` 风格：
  - 现有 x86 protected VM 专用 ioctl 已经在这样做，见
    - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
    - `/home/mrgeek/pkvm-x86/crosvm/hypervisor/src/kvm/x86_64.rs`
- 不优先选择 `KVM_DEV_TYPE_VFIO` 的原因：
  - 这份 metadata 是“protected VM 范围内的受信状态”，而不只是某个 VFIO fd 的私有属性
  - crosvm 现有 protected VM 路径已经走 `KVM_ENABLE_CAP`
- 但这里的 `KVM_ENABLE_CAP` 更准确地应理解为：
  - userspace / host KVM 向 pKVM host-side bridge 提交候选 metadata
  - 而不是“host KVM 单独持有并终裁”

- 建议新增 flag：

```c
#define KVM_CAP_X86_PROTECTED_VM_FLAGS_SET_PTDEV_MMIO_INFO 2
```

- 建议新增 UAPI 结构：

```c
struct kvm_ptdev_mmio_range {
    __u64 guest_gpa;
    __u64 size;
    __u64 bar_offset;
    __u16 bdf;
    __u16 pasid;
    __u8  bar_index;
    __u8  flags;
    __u8  reserved[4];
    __u64 __reserved[2];
};

struct kvm_ptdev_mmio_info {
    __u32 nranges;
    __u32 flags;
    __u64 ranges_ptr;   /* userspace ptr to array of kvm_ptdev_mmio_range */
    __u64 __reserved[5];
};
```

- `flags` 第一阶段建议只开放：

```c
#define KVM_PTDEV_MMIO_DIRECT_BAR   (1U << 0)
```

- crosvm 调用形式与现有 `SET_FW_GPA` / `INFO` 类似：
  - `KVM_ENABLE_CAP`
  - `cap = KVM_CAP_X86_PROTECTED_VM`
  - `flags = KVM_CAP_X86_PROTECTED_VM_FLAGS_SET_PTDEV_MMIO_INFO`
  - `args[0] = &info`

### host KVM 内部持有形式

- host KVM 内部可以先形成候选表。
- 但真正 authoritative 的版本应存放在 pKVM/hyp 中，并最终退化成：
  - 一张“guest_gpa 直达区间表”
- pKVM/hyp 内部条目最好保留调试和校验信息：
  - `bdf`
  - `pasid`
  - `bar_index`
  - `bar_offset`
  - `size`
  - `guest_gpa`
  - `flags`

### guest 查询接口

- guest hypercall 空间当前定义在：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/include/uapi/linux/kvm_para.h`
- host 分发入口在：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/x86.c`

- 第一阶段推荐新增两个 hypercall：

```c
#define PKVM_GHC_PTDEV_MMIO_INFO_NR   PKVM_GHC_NUM(6)
#define PKVM_GHC_PTDEV_MMIO_INFO_GET  PKVM_GHC_NUM(7)
```

- 推荐使用“共享缓冲区 + 分块拷贝”而不是“寄存器直接返回整条记录”：
  - 现有 KVM hypercall ABI 只可靠承诺 `RAX` 返回值
  - 用共享缓冲区更适合可变长度列表和热插拔后的重查询

- guest 侧使用方式建议：

```text
1. 调用 PTDEV_MMIO_INFO_NR，获得区间总数
2. 分配一页 shared buffer
3. 对 shared buffer 调用 PKVM_GHC_SHARE_MEM
4. 循环调用 PTDEV_MMIO_INFO_GET(buf_gpa, buf_size, start_index, flags)
5. 把结果拷贝到 guest 私有缓存
6. 调用 PKVM_GHC_UNSHARE_MEM 回收 shared buffer
```

- `PTDEV_MMIO_INFO_GET` 的最小语义：
  - 参数：
    - `a0 = shared_buf_gpa`
    - `a1 = shared_buf_size`
    - `a2 = start_index`
    - `a3 = flags`
  - 返回：
    - `RAX = copied_nr`

### guest 本地缓存结构

- guest 本地缓存可以比 host 结构更简单：

```c
struct pkvm_direct_mmio_range {
    u64 guest_gpa;
    u64 size;
    u8  flags;
};
```

- 第一阶段分流只依赖：
  - `guest_gpa`
  - `size`
  - `flags`

### guest 分流伪代码

```text
pkvm_virt_mmio(size, write, vaddr, val)
    gpa = lookup_address(vaddr)
    if pkvm_mmio_range_is_direct(gpa, size):
        if write:
            raw_write*(val, vaddr)
        else:
            *val = raw_read*(vaddr)
        return success
    else:
        return PKVM_GHC_IOREAD/IOWRITE
```

### 为什么 guest 侧用 `raw_read/write(vaddr)` 就够

- `vaddr` 已经是 guest 自己 `ioremap()` 后得到的内核虚拟地址
- `pkvm_virt_mmio()` 当前也正是从这个 `vaddr` 反查 GPA：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
- x86 仍然保留了原始 MMIO 访问原语：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/io.h`
- 因而第一阶段无需重做 ioremap，只需在访问时从 paravirt path 回退到原始 MMIO 原语。

### guest 侧最小改动点

- 中央分流点选在：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
  - `pkvm_virt_mmio()`
- 这是最小改动点，因为：
  - 当前所有 `pv_ops.mmio.raw_*` 和 `pci_mmcfg_*` 最终都汇聚到这里
  - 这里已经拿到了当前访问的 GPA
- 第一阶段逻辑应是：

```text
pkvm_virt_mmio(size, write, vaddr, val)
    lookup_address(vaddr) -> gpa
    if gpa in direct_ptdev_mmio_ranges:
        直接执行 raw_read/raw_write
    else
        继续走 PKVM_GHC_IOREAD/IOWRITE
```

- 之所以能“直接执行 raw_read/raw_write”，是因为 x86 仍然保留了原始 MMIO 指令级实现：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/include/asm/io.h`

### host / guest 接口建议

- 现有 guest hypercall 集合很小：
  - `/home/mrgeek/pkvm-x86/include/uapi/linux/kvm_para.h`
  - 当前只有 `SHARE_MEM`、`UNSHARE_MEM`、`IOREAD`、`IOWRITE`、`START_CPU`
- 第一阶段建议新增一个只读查询类接口，例如：
  - `PKVM_GHC_GET_PTDEV_MMIO_INFO`
  - 或者“两步式”：
    - `GET_PTDEV_MMIO_INFO_SIZE`
    - `GET_PTDEV_MMIO_INFO`
- host KVM 侧已有集中 switch 入口：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/x86.c`
- 所以从实现面看，新增 guest hypercall 并不别扭。

### userspace / KVM 注册接口建议

- 当前 `kvm_arch_add_device_to_pkvm()` 最终只传了 `BDF/PASID`：
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
- 第一阶段应新增一条 “register ptdev mmio ranges” 接口，让 crosvm 在 BAR 分配完成后把区间表注册给 host KVM / pKVM。
- 这条接口的输入应是 guest 视角的 GPA 区间，而不是 host 物理 BAR 地址。

### config / BAR / MSI-X 的边界

- config space
  - 第一阶段继续走现有 emulated / hypercall 路径
- BAR mmap 普通区
  - 第一阶段进入 `DIRECT_BAR_MMIO` 区间表，允许 guest 直达
- MSI-X table / PBA
  - 第一阶段明确不进入直达区间表
  - 继续走 crosvm 现有 trap/emulate 路径：
    - `/home/mrgeek/pkvm-x86/crosvm/devices/src/pci/vfio_pci.rs`

## 不推荐但可用于实验的捷径

- 最快的实验版做法是：
  - 由 crosvm 直接生成直达区间表
  - 通过 cmdline / bootparams 把表的 GPA 告诉 guest
  - guest 直接据此在 `pkvm_virt_mmio()` 分流
- 这条路的优点是改动小、验证快。
- 但它不适合作为主线方案，因为：
  - 受信 ownership 不清晰
  - protected VM 不应长期依赖 userspace 或 host KVM 单方面提供的“哪些 MMIO 可以直达”的真相
  - 后续难以和 pKVM 自己的设备生命周期管理收敛

## 当前阶段结论

- 主线最小版本不是“先把所有 MMIO 都直达”，也不是“继续扩大 crosvm workaround”。
- 主线最小版本应当是：
  - config 继续 emulated
  - BAR 普通区直达
  - MSI-X 继续 emulate
  - 以“受信的 GPA 直达区间表”为 guest/hyp contract
- 这张表的注册接口建议复用 `KVM_CAP_X86_PROTECTED_VM` 的 `KVM_ENABLE_CAP` flag 空间，但最终 authoritative allowlist 必须落在 pKVM/hyp，而不是停在 host KVM。
- 这张表的 guest 查询接口建议使用“共享缓冲区 + 分块 hypercall 拷贝”。

## 非目标

- 当前任务不直接解决 DMA mirror。
- 当前任务不直接解决 teardown 生命周期。
- 当前任务不要求一次性打通 config、BAR、MSI-X、virtual config 全部路径。
- 当前任务也不把 B2 的 crosvm workaround 当成正式主线。

## 验收标准

- 明确写出 guest/hyp 的 passthrough MMIO contract。
- 明确最小实现切入面和非目标。
- 明确 T2/T3/T4 在该 contract 下分别依赖什么前提。
- 明确 B2 仍然只是可选 workaround，而不是主线替代方案。
