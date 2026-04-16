# [T12] B5-3 protected pVM assigned BAR 的 Host CPU 访问权收口

## 状态

- 当前状态: 已创建 GitHub Task `pkvm-x86#34`；当前先作为 `B5-2` 的独立 follow-up 收敛
- GitHub Task: `pkvm-x86#34`
- 所属主任务: `pkvm-x86#20`
- 当前定位: 设计 / 实现拆分任务；当前按 `status/blocked` 跟踪，不再混写在 `B5-2` 已完成结论里

## 当前表现 / 当前阻塞

- `B5-2` 当前已收敛的是“Guest EPT 首次建图边界校验”：
  - 命中当前 VM 已 attach boot BAR 的 HPA 时，允许 direct BAR leaf 建图
  - 未命中 BAR 且也不在 host RAM `mem_range` 内时，提前 reject
  - BAR leaf teardown 时不再走 `__pkvm_host_undonate_guest()`
- 但这不等价于“Host CPU 后续无法再直接读写 assigned BAR”。
- 现有源码里只看到 IOMMU MMIO 路径有显式 `pkvm_host_ept_unmap()` 收口；普通 assigned PCI BAR attach 后，还没有看到同类 Host EPT revoke 动作。
- 这意味着：即使 DMA 侧和 Guest EPT 首次建图边界都已经收敛，Host CPU 仍可能直接 MMIO 到 doorbell / control / reset 等 BAR 区间，与 guest 竞争同一设备控制面。
- 当前推进上还受两条相邻主线约束：
  - `T4`：teardown 前先 quiesce ptdev DMA，决定 BAR restore 应该挂在哪个生命周期点
  - `T6`：remove-path / 失败回滚尚未收敛，决定 attach 失败或 reject 后 Host BAR 映射如何恢复

## 关键源码锚点

```text
Host CPU BAR authority 问题
    attach ptdev
        -> pkvm_attach_ptdev()
            -> ptdev->pgt = &vm->pgstate_pgt
            -> pkvm_iommu_sync()
            -> 只切 DMA 视图，未看到 BAR 级 Host EPT unmap

    guest MMIO
        -> pkvm_virt_mmio()
            -> pkvm_mmio_allow_hit()
            -> direct MMIO / fallback MMIO
            -> 只决定 guest 侧访问分流，不撤销 Host CPU BAR 直访

    Host EPT revoke 现有参考
        -> activate_iommu()
            -> pkvm_host_ept_unmap(iommu_mmio_range)
        -> pkvm_undo_iommu()
            -> pkvm_host_ept_map(iommu_mmio_range)
```

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - `guest_mmu_map_leaf()`
  - `guest_mmu_free_leaf()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_attach_ptdev()`
  - `pkvm_detach_ptdev()`
  - `pkvm_set_ptdev_mmio_metadata()`
- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
  - `pkvm_mmio_allow_hit()`
  - `pkvm_virt_mmio()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - `pkvm_host_ept_map()`
  - `pkvm_host_ept_unmap()`
  - `pkvm_flush_host_ept()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`
  - `activate_iommu()`
  - `pkvm_undo_iommu()`

## 修复方案摘要

当前更倾向先按“BAR authority revoke / restore 状态机”拆开做，而不是继续把这条问题藏在 `B5-2` 的 Guest EPT 建图逻辑里：

1. attach 时：
   - 以 boot manifest + attached `ptdev` metadata 为真相源，枚举当前设备可 revoke 的 memory BAR 区间
   - 对这些 BAR 区间执行 `pkvm_host_ept_unmap()`，撤销 Host CPU 的直访映射
   - 在 hyp 内记录 BAR revoke state / generation，避免重复 attach 或失败回滚时丢状态
2. 运行时：
   - guest 侧继续复用现有 `DIRECT_BAR` allowlist 与 Guest EPT direct BAR leaf
   - Host CPU BAR revoke 是额外的 CPU 侧隔离，不替代 DMA mirror，也不替代 Guest EPT 建图边界
3. detach / destroy / remove-path 时：
   - 在 `T4` 先 quiesce DMA 之后，再执行 BAR restore
   - 通过 `pkvm_host_ept_map()` 恢复 Host CPU 的 BAR 映射
   - 清除 revoke generation / metadata ownership，再做后续 detach 收尾
4. reject / attach 失败路径：
   - 若已经做过部分 revoke，必须有完整 restore 语义
   - 不允许出现 manifest reject 或 attach rollback 后，Host BAR 仍处于半撤销状态

## 当前推荐实现边界

- 第一阶段只覆盖：
  - protected pVM
  - 单设备
  - 静态 attach
  - `NoIommu`
  - boot-known memory BAR
- 第一阶段先不覆盖：
  - config space
  - MSI-X table / PBA 直达
  - hotplug / multi-device / migration
  - 通用 lease / token / firmware contract

## 主要风险与待定点

- BAR restore 应挂在 `T4` 的哪个生命周期点最安全：
  - `pkvm_quiesce_ptdev()` 之后
  - `pkvm_detach_ptdev()` 之内
  - 还是独立的 restore helper
- 是否需要显式 `pkvm_flush_host_ept()` / CPU shootdown，避免 Host 侧残留 EPT/TLB 命中旧 BAR 映射
- BAR 区间是否需要排除 MSI-X / PBA 子区间，避免错误 revoke 当前仍由 emulate 路径处理的窗口
- `remove-path` / `attach` 失败 / reject-path 是否需要 generation 化，避免“旧 revoke 状态泄漏到新 attach”
- 这条 BAR authority revoke 是否需要与 `pvmfw` GPA overlap 风险一起统一处理，还是继续分离

## 实现范围

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`
- `pKVM-IA/arch/x86/kvm/pkvm/pkvm.c`
- `pkvm-x86` 中对应的设计文档、验证记录、GitHub issue / PR 闭环

## 非目标

- 不重新定义 `B5-2` 的“Guest EPT 首次建图边界”结论
- 不把 `MMIO metadata` 重新解释成 Guest EPT 建图真相源
- 不在本任务里解决 `pvmfw` trusted content 完整性问题本身
- 不在本任务里替代 `T4` 的 DMA quiesce 或 `T6` 的 remove-path 全量收尾
- 不把 config space / MSI-X / PBA 一次性并进第一阶段

## 验收标准

- protected pVM attach 后，Host CPU 不再能直接通过 assigned memory BAR 访问设备控制面
- guest 侧 direct BAR MMIO 保持可用，不因 Host revoke 破坏现有正向样例
- detach / destroy / remove-path / attach 失败后，Host CPU BAR 映射能正确恢复
- 本地文档、GitHub Task、后续 `pKVM-IA PR` 与 `pkvm-x86 PR` 保持闭环
- 若推进过程中暴露新的唯一报错签名，再独立拆 `Bug` issue，而不是继续混写在本 Task 里

## 关联文档

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T10-B5-2-protected-pVM-Guest-EPT建图边界实现.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/04-P0-VM销毁前quiesce-ptdev-DMA.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/06-P1-VFIO-remove-path与失败回滚.md`
