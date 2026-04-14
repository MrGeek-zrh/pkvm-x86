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
- [ ] 判断是否仍存在可把错误 HPA 重绑进 protected guest GPA 的运行期路径。

- 第一轮梳理文档：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-3-B5-2-protected-pVM-Guest-EPT-建图边界初步梳理.md`

* [ ] manifest reject 后 vfio group busy 导致后续普通 VM 打开 /dev/vfio/9 失败

- 这个确定是bug吗？
