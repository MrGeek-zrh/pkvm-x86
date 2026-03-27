# [T2] P0: `pgstate_pgt` 语义收敛为 DMA mirror

## 状态

- 当前状态: 进行中（已完成首轮运行验证；teardown / 重复启动回归待补）
- 优先级: P0

## 目标

把 `pgstate_pgt` 明确收敛为“供 IOMMU 使用的 DMA mirror pgtable”，不再让它参与 pVM 页面 ownership 的回收逻辑。

## 为什么单独拆分

- 方案 B 是否能稳定落地，关键就在于 ownership 和 DMA 翻译视图必须分离。
- 如果 `pgstate_pgt` 仍然在 teardown 时执行 `__pkvm_host_undonate_guest()`，会与 guest mmu teardown 的 undonate 逻辑产生语义重叠。

## 关键源码锚点

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - `pgstate_pgt` 注释
  - `pkvm_pgstate_pgt_free_leaf()`
  - `pkvm_pgstate_pgt_deinit()`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - `guest_mmu_free_leaf()`

## 当前已确认结论

- 当前注释仍把 `pgstate_pgt` 描述为“内存是 pinned，映射不允许删除”。
- 当前 `pkvm_pgstate_pgt_free_leaf()` 对 protected VM 会执行 `__pkvm_host_undonate_guest()`。
- 当前 `guest_mmu_free_leaf()` 对 protected VM 也会执行 `__pkvm_host_undonate_guest()`。
- 2026-03-27 的有效端到端验证已经表明：
  - 旧 `BOOT-007` 不再复现
  - 新签名变为 host DMAR `DMA Read NO_PASID / PTE Read access is not set`
  - 这说明 `pgstate_pgt` 当前已经真正被设备 DMA 路径使用，但其语义还没有稳定收敛成“正确的 DMA mirror”

## 当前本地实现进展

- 已在 [ept.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c) 收敛 `pgstate_pgt` 注释，明确其在 protected VM 下是 DMA mirror，而不是 ownership 回收入口。
- 已在 [ept.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c) 的 `pkvm_pgstate_pgt_free_leaf()` 去掉 protected VM 路径上的 `__pkvm_host_undonate_guest()`，改为只释放 mirror leaf / 页表引用。
- 已在 [pkvm.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c) 把 shadow VM teardown 顺序调整为“先 detach ptdev，再 deinit pgstate_pgt”，避免 IOMMU 仍指向待销毁 mirror。
- 2026-03-27 最新运行验证中，protected pVM 已可启动到 login prompt，guest 内可见 `nvme0n1`，host 侧未再出现 `DMA Read NO_PASID` / `PTE Read access is not set`。
- 当前这台工作树仍缺 `pKVM-IA/.config`，因此没有在本工作树内补做独立增量编译记录；当前结论来自已启动到新内核后的实机验证。

## 最新验证证据

- guest `dmesg` 已出现 `nvme nvme0: pci function 0000:01:00.0` 与队列初始化日志。
- guest `readlink -f /sys/block/nvme0n1/device` 指向 `0000:01:00.0`，说明透传 NVMe 已在 pVM 内正确枚举。
- guest 已完成对 `/dev/nvme0n1` 的直接读取，以及 `mkfs.ext4 -F /dev/nvme0n1`，host `dmesg` 全程未见 DMAR / IOMMU / pKVM 新报错。
- guest 关机退出后，host `dmesg` 仍未见新的 DMAR / IOMMU / pKVM 报错，说明当前 shadow teardown 至少未立即触发新的可见异常。
- 当前仍未覆盖：
  - 同一内核下连续第二次启动的重复回归
  - remove-path / hotplug / prepopulate

## 建议收敛方向

- `pgstate_pgt`:
  - 负责维护 DMA 可见的 GPA -> HPA 映射。
  - 允许随 guest 页生命周期动态增删映射。
  - teardown 时只负责释放 mirror 页表自身，不负责 ownership 回收。
- `pkvm_vm->mmu`:
  - 继续作为 pVM 页面 ownership 的唯一真实来源。
  - donate / undonate / wipe 页面仍由 guest mmu 路径负责。

## 验收标准

- `pgstate_pgt` 与 guest mmu 不再双重承担 undonate。
- 文档、注释和实现语义一致。
- 后续 T3、T4 可以基于该语义继续补 runtime mirror 和 teardown。

## 风险点

- 如果语义收敛不彻底，后面补 runtime mirror 时容易出现双重释放或 teardown 顺序问题。
- 需要确保非 protected VM 路径不被误伤。

## 依赖

- 可与 T1 并行分析，但正式代码落地最好在 T1 之后。
