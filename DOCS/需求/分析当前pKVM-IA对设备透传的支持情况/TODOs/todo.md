* [X] 透传给pVM的设备是怎么释放的

- pVM被销毁的时候

- [ ] 设备在透传给pVM时，Host还能对设备的IOMMU页表做相关操作吗？
- [ ] pVM销毁释放设备的时候，要先确保相关的内存数据情况后才能交还设备访问权给Host

[X] 问题 1：boot-time manifest 设备名单边界

- 透传给pVM的设备要确实是在Host内核启动时识别到的真实PCI设备。

[ ] 问题 2：protected pVM Guest EPT `GPA -> HPA` 建图边界

- [X] 梳理运行期会建立或更新 Guest EPT 的入口：`__pkvm_host_donate_guest()`、`__pkvm_host_undonate_guest()`、share/unshare 及相关 helper。
- [X] 明确 `check_donation()` / page-state / ownership 检查当前已经防住了什么，哪些约束已经在 hyp 里成立。
- [X] 明确 Host 仍能控制的输入：`hpa`、`gpa`、`size`、`prot` 以及调用时机。
- [X] 区分 Guest EPT 主建图与 `pgstate_pgt` DMA mirror，避免继续混写。
- [X] 列全 protected Guest EPT 的相关入口，并区分 Host runtime 建图、teardown 回收、guest 自发 share/unshare 与 DMA mirror / allowlist 路径。
- [X] 确认 `vm_mmu_unmap` / `vm_mmu_age` / `SET_PTDEV_MMIO_METADATA` 不是 protected Guest 主 EPT 的额外运行期改图入口。
- [X] 修正 `SW_PROTECTED_VM` / `PKVM_PROTECTED_VM` 混淆，重新压实真正的 `fault->pfn` 来源链。
- [X] 分离透传 MMIO 的"访问处理路径"和 "Guest EPT 首次建图路径"。
- [ ] 判断 B5 真正在意的 Guest EPT leaf 里，哪些是普通 RAM memslot，哪些是 `VM_IO | VM_PFNMAP` 的 BAR memslot，以及 hyp 当前分别校验到哪一级语义。

- 设计文档：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-2-protected-pVM-Guest-EPT建图边界设计.md`
- 实现跟踪：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T10-B5-2-protected-pVM-Guest-EPT建图边界实现.md`

* [ ] manifest reject 后 vfio group busy 导致后续普通 VM 打开 /dev/vfio/9 失败

- 这个确定是bug吗？
