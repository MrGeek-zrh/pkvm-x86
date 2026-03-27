# [T3] P0: donate 后同步 runtime DMA mirror

## 状态

- 当前状态: 待开始（2026-03-27 的 `BOOT-008` 已直接暴露出 runtime DMA mirror 缺口）
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

## 依赖

- T2。
