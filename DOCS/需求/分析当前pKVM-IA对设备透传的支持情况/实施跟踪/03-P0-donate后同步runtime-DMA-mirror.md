# [T3] P0: donate 后同步 runtime DMA mirror

## 状态

- 当前状态: 进行中（已完成首轮运行验证；重复启动回归与偶发 `BOOT-009` 待收敛）
- 优先级: P0

## 目标

在 guest 页面 donate 成功后，把新建立的 GPA -> HPA 映射同步写入 `pgstate_pgt`，并按该 mirror 页表对应的 root 做 IOTLB flush，使设备 DMA 真正可用。

## 为什么单独拆分

- attach 现在只是“切换 `ptdev->pgt` 指针”，还不是“设备已经有完整 DMA 可见映射”。
- 若不补 runtime hook，pVM 即使不 panic，设备 DMA 也看不到 guest 私有页。

## 关键源码锚点

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - `guest_mmu_map_leaf()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
  - `__pkvm_host_donate_guest()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`
  - `pkvm_iommu_flush_iotlb()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c`
  - `pkvm_pgtable_sync_map_range()`

## 当前已确认结论

- `guest_mmu_map_leaf()` 是 protected VM donate 的天然 hook 点。
- `pkvm_iommu_flush_iotlb()` 已支持按指定 `root_pa` 定向刷 IOTLB。
- guest mmu 本身就是 EPT，可直接作为 runtime mirror 的源页表。
- 2026-03-27 的有效端到端验证中：
  - guest 已经可以启动到 Ubuntu login prompt
  - 但 host dmesg 出现 `DMA Read NO_PASID ... PTE Read access is not set`
  - 这说明“attach 只切换 `ptdev->pgt` 指针”这一判断已经被实机现象再次印证，runtime mirror 仍未补齐

## 当前本地实现进展

- 已在 [mem_protect.c](/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c) 的 `__pkvm_host_donate_guest()` 后补一版 runtime DMA mirror hook。
- 当前实现做法是：
  - 仅在 VM 已存在 attached ptdev 时才同步 `pgstate_pgt`
  - 从 guest EPT 叶子派生 mirror 映射
  - 写入前剥离 `PKVM_PAGE_STATE_PROT_MASK` 软件位
  - 完成后对 `pgstate_pgt->root_pa` 对应的 IOMMU 视图做定向 IOTLB flush
- 2026-03-27 最新运行验证中：
  - protected pVM 已稳定启动到 Ubuntu login prompt
  - guest `readlink -f /sys/block/nvme0n1/device` 已指向 `0000:01:00.0`
  - guest `lsblk` / sysfs / `dmesg` 已能看到透传 NVMe `0000:01:00.0`
  - guest 已完成 `/dev/nvme0n1` 整盘直接读取
  - guest 已完成向 `/dev/nvme0n1` 连续写入 1 GiB 零数据
  - guest 已完成 `mkfs.ext4 -F /dev/nvme0n1`
  - host `dmesg` 全程未再出现 `DMA Read NO_PASID` / `PTE Read access is not set`
- 已完成手动增量编译验证，当前可复用带 `.config` 的构建树完成 host 内核构建；当前结论同时来自编译通过后的实机验证。

## 最新验证证据

- runtime DMA mirror 当前已具备较高置信度可用：
  - `readlink -f /sys/block/nvme0n1/device` 指向 `0000:01:00.0`，说明 guest 看到的是透传 NVMe 本体而非其他虚拟块设备。
  - 原始块设备读取 `dd if=/dev/nvme0n1 of=/dev/null bs=4M iflag=direct status=progress` 成功，8 GiB 顺序读完成，峰值约 1.1 GB/s。
  - 原始块设备写入 `dd if=/dev/zero of=/dev/nvme0n1 bs=4M count=256 oflag=direct conv=fdatasync status=progress` 成功，连续写入 1 GiB 完成。
  - `mkfs.ext4 -F /dev/nvme0n1` 成功，未引出 host IOMMU fault。
  - guest 关机退出后，host `dmesg` 仍未见新的 DMAR / IOMMU fault，说明本轮 runtime mirror patch 至少未在当前 teardown 路径上立即暴露新错误。
- 当前仍保留一个证据边界：
  - 本轮粘贴的 guest 终端记录未显示 `mount /dev/nvme0n1 /mnt/nvme`，因此 `/mnt/nvme/payload.bin` 的文件级 hash 结果暂不作为“已明确落到 NVMe 文件系统”的硬证据保存。
  - 若需要把文件级读写也作为硬证据，应补一轮显式 mount 后的写入/回读，或直接做原始块设备写入/回读校验。
- 当前还保留一个强关联残余风险：
  - 2026-04-01 又归档到一条偶发 `BOOT-009`，表现为 `copy_gpa__pkvm` 写侧 `#PF(err=0x2)`，随后 host 进入 `soft lockup`
  - 这条签名本身不是 `BOOT-008` 的 DMAR 主签名回归，但会让当次运行在更早阶段失效，无法继续证明 runtime DMA mirror 是否已经稳定触发
  - 当前更像是“修复闭环尚未覆盖到所有运行”的残余稳定性问题，而不是已经推翻 2026-03-27 的正向验证结论
  - 2026-04-02 的进一步源码归因表明，当前更直接的修复入口是 `B4`：修正 hyp `memory.c` 对 protected guest GPA 的回写语义，而不是继续围绕“allowlist buffer 未 materialize”做实验

## 建议实施方式

- 在 protected VM donate 成功后判断该 VM 是否存在 attached ptdev。
- 若存在，则把刚建立的 leaf 同步到 `pgstate_pgt`。
- mirror 写入时：
  - 只建立 EPT 映射。
  - 不做 `hyp_page_ref_inc()`。
  - 权限位从 guest leaf 派生，剥离 page-state 软件位。
- 完成后对 `pgstate_pgt->root_pa` 所对应的 IOMMU 视图做定向 IOTLB flush。

## 验收标准

- 运行中新增 donated guest 页可以进入 `pgstate_pgt`。
- 设备 DMA 可以访问新建立的 guest 私有页。
- 不会重新引入“mirror 页表本身占住 refcount，反过来阻塞 donate”的问题。

## 风险点

- mirror 与 guest mmu 权限位不一致，可能导致 DMA 访问行为偏差。
- IOTLB flush 粒度不对，会导致旧翻译残留。
- `BOOT-009` 当前更高置信度的直接原因，是 `write_gpa()` / `copy_gpa()` 仍把 protected guest GPA 当作 host identity GPA 访问；这条早期路径若不先收敛，会污染 T3 的重复启动验证样本。

## 依赖

- T2。
