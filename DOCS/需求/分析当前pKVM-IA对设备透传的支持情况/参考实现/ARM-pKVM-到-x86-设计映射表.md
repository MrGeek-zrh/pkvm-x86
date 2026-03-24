# ARM pKVM 到 x86 设计映射表

## 目的

本文件不尝试照搬 ARM64 pKVM/AVF 的具体实现，而是提炼其中对当前 x86 设备透传主线最有价值的设计模式，并映射到当前 `pKVM-IA` 的缺口上。

当前主要服务于：

- [B3 上层与 MMIO 语义设计](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01C-B0-protected-pVM-guest-hyp-passthrough-MMIO语义设计.md)
- [B3-1 第一阶段上层方案](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01C-1-B3-1-protected-pVM-设备透传第一阶段上层方案.md)

## 当前参考版本

- Android common kernel
  - branch: `android16-6.12`
  - commit: `3ec022196c4e9d5c1434599cdda63f622dd6f586`
- Android Virtualization module
  - commit: `48c987bff45acbdd73054d7c2aaef0a607e8f3db`

## 总结结论

ARM 的成熟点不在“已经把 PCI 透传做完”，而在于它已经把下面三件事拆清楚了：

1. 设备 assignment 需要一份受信的设备 metadata，而不是只靠 VMM 临时知道设备信息。
2. guest 对 MMIO 不是无条件都走 host emulation，而是显式区分“允许作为 MMIO 的 IPA”和“真正设备 MMIO 验证”。
3. authoritative device state 不停留在 host/VMM，而是由 pKVM/hyp 与 pvmfw 共同约束。

这三点正好对应当前 x86 主线最缺的三件事。

## 映射表

| ARM pKVM / AVF | ARM 位置 | 当前 x86 对应缺口 | 建议的 x86 映射 |
|---|---|---|---|
| VM DTBO / assignable device manifest | [device_assignment.md](/home/mrgeek/pkvm-x86/refs/android-virtualization/docs/device_assignment.md), [device_trees.md](/home/mrgeek/pkvm-x86/refs/android-virtualization/docs/device_trees.md) | host -> pKVM 目前只传 `BDF/PASID`，没有 BAR/resource 元数据，见 [pkvm_host.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c) | 在 x86 引入“受信的 ptdev metadata”，至少描述 `BDF + BAR/MMIO ranges + IOMMU identity + flags` |
| `android,pvmfw,target` + physical `<reg>` | [device_assignment.md](/home/mrgeek/pkvm-x86/refs/android-virtualization/docs/device_assignment.md) | 现在缺“guest GPA 映射的是哪个真实设备资源”的验证链 | x86 用结构化 BAR metadata 替代 DT label，至少能表达 `bar_index + bar_offset + size + guest_gpa` |
| `android,pvmfw,token` for IOMMU | [device_assignment.md](/home/mrgeek/pkvm-x86/refs/android-virtualization/docs/device_assignment.md) | 当前 x86 也缺“guest 看到的 DMA context”和真实 IOMMU/设备身份之间的受信绑定 | x86 侧为 `ptdev` / IOMMU second-level state 定义稳定 identity，而不是只让 userspace 口头声明 |
| `PKVM_DEVICE_ASSIGN_COMPAT` + `PKVM_MREG_ASSIGN_MMIO` | [pkvm.c](/home/mrgeek/pkvm-x86/refs/android-kernel-common/arch/arm64/kvm/pkvm.c), [kvm_pkvm.h](/home/mrgeek/pkvm-x86/refs/android-kernel-common/arch/arm64/include/asm/kvm_pkvm.h) | 当前 x86 还没有“这是 assignable MMIO 资源”的独立类别 | x86 里也需要一类独立的 ptdev MMIO metadata，不应把它混同于普通 guest RAM 或一般 emulated MMIO |
| `MMIO_GUARD` / `MMIO_RGUARD_MAP` | [hypercalls.rst](/home/mrgeek/pkvm-x86/refs/android-kernel-common/Documentation/virt/kvm/arm/hypercalls.rst), [mmio-guard.rst](/home/mrgeek/pkvm-x86/refs/android-kernel-common/Documentation/virt/kvm/arm/mmio-guard.rst) | 当前 x86 guest 把所有 MMIO 都走 `PKVM_GHC_IOREAD/IOWRITE`，见 [pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c) | x86 需要一套“按 GPA 分类”的 MMIO 允许表，让 guest 能区分 emulated MMIO 与 passthrough BAR MMIO |
| `DEV_REQ_MMIO` token verification | [hypercalls.rst](/home/mrgeek/pkvm-x86/refs/android-kernel-common/Documentation/virt/kvm/arm/hypercalls.rst), [device_assignment.rs](/home/mrgeek/pkvm-x86/refs/android-virtualization/guest/pvmfw/src/device_assignment.rs) | 当前 x86 完全缺“guest 如何确认某段 GPA 真的是可信设备 MMIO”的机制 | x86 第一阶段未必需要 token-by-token 验证，但至少要让 pKVM/hyp 最终持有并下发 authoritative allowlist |
| pvmfw sanitizes VMM DT and validates device assignment | [device_trees.md](/home/mrgeek/pkvm-x86/refs/android-virtualization/docs/device_trees.md), [pvmfw/src/device_assignment.rs](/home/mrgeek/pkvm-x86/refs/android-virtualization/guest/pvmfw/src/device_assignment.rs) | 当前 x86 没有 pvmfw 这一层设备 metadata 验证者 | x86 可以不引入完整 pvmfw，但需要一个等价的“guest trust anchor + hyp authoritative metadata”模式 |

## 关键映射 1: 设备 metadata

ARM 做法：

- Bootloader 提供 VM DTBO 给 Android 和 pvmfw。
- pvmfw 从 VM DTBO 中拿到 assignable device 描述。
- 物理设备节点包含：
  - physical `reg`
  - `iommus`
  - `android,pvmfw,target`
- pvmfw 通过 hypervisor 返回的 token 验证 guest 侧 MMIO/IOMMU 描述是否对应真实物理设备，见 [device_assignment.rs](/home/mrgeek/pkvm-x86/refs/android-virtualization/guest/pvmfw/src/device_assignment.rs)。

x86 当前状态：

- host 侧 attach 只传 `BDF/PASID`，见 [pkvm_host.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c)。
- hyp 侧 `ptdev.c` 现有注释也承认还没有独立设备信息通道，见 [ptdev.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c)。

x86 建议：

- 不引入 DTBO，但引入等价的结构化 ptdev metadata。
- 第一阶段最小集合至少包含：
  - `bdf`
  - `bar_index`
  - `bar_offset`
  - `size`
  - `guest_gpa`
  - `flags`
- 这份 metadata 的最终持有者必须是 pKVM/hyp，而不是 crosvm 或 host KVM 私有状态。

## 关键映射 2: MMIO 分类

ARM 做法：

- `MMIO_GUARD` 允许 guest 告诉 hypervisor 哪些 IPA 区间可以作为 MMIO。
- 除了被 guard 的 IPA，其他非法 MMIO 会直接变成异常，而不是一律交给 host/userspace emulate，见 [mmio-guard.rst](/home/mrgeek/pkvm-x86/refs/android-kernel-common/Documentation/virt/kvm/arm/mmio-guard.rst)。

x86 当前状态：

- guest 侧 `pv_ops.mmio.raw_*` 和 `pv_ops.mmio.pci_mmcfg_*` 都统一走 `PKVM_GHC_IOREAD/IOWRITE`，见 [pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/coco/pkvm/pkvm.c)。
- 当前没有“按 BAR 地址例外直达”的现成分流路径。

x86 建议：

- x86 也需要一张“GPA 级别的 MMIO allowlist”。
- 第一阶段只把普通 BAR MMIO 放进去。
- config space 和 MSI-X table/PBA 继续走 emulated 路径。
- guest 在 `pkvm_virt_mmio()` 里按 GPA 查询：
  - 命中 allowlist -> 直达 `raw_read* / raw_write*`
  - 未命中 -> 继续 `PKVM_GHC_IOREAD/IOWRITE`

## 关键映射 3: trust boundary

ARM 做法：

- pvmfw 能在 guest 上下文中验证 host/VMM 交给 guest 的 device description。
- 但文档也明确写了，跨 VM 的设备隔离仍由 hypervisor 保证，见 [device_trees.md](/home/mrgeek/pkvm-x86/refs/android-virtualization/docs/device_trees.md)。

x86 当前状态：

- 当前 guest MMIO 访问在 pKVM/hyp 里还会继续转发给 host，见 [vmx.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c)。
- 这说明“最终真相停在 host”正是当前路径的问题之一。

x86 建议：

- 不应做成“host 校验完就算数”的普通 KVM 模式。
- 更合理的边界是：

```text
crosvm / host KVM
    发现设备并提交候选 metadata
        |
        v
pKVM/hyp
    最终接受 / 绑定 / 持有 authoritative state
        |
        v
guest
    只消费 pKVM/hyp 暴露的 metadata
```

## 对 B3-2 的直接约束

基于 ARM 参考，x86 的 B3-2 不应直接问“怎么设计一个 ioctl 最顺手”，而应先满足这三个约束：

1. metadata 必须是结构化的设备资源描述，而不是只有 `GPA + size`
2. MMIO 必须按 GPA 分类，而不是继续默认“所有 MMIO 都 host emulate”
3. authoritative state 必须最终落在 pKVM/hyp

## 当前建议

先按这张映射表推进 x86 的第一阶段：

1. 先定义 x86 的 ptdev metadata 结构
2. 再定义 hyp 持有的 MMIO allowlist
3. 再让 guest 在 `pkvm_virt_mmio()` 上按 GPA 分流
4. 之后再回到 DMA mirror 主线

这比先做 crosvm workaround 或先写 ioctl 细节更稳。
