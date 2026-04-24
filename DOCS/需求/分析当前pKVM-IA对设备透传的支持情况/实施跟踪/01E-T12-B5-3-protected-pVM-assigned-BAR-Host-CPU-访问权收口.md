# [T12] B5-3 protected pVM assigned BAR 的 Host CPU 访问权收口

## 状态

- 当前状态: 已创建 GitHub Task `pkvm-x86#34`；上一轮未提交的“attach unmap + Host EPT fault 地址 deny-remap + detach remap”本地 patch 已丢弃；当前已补齐第一阶段实现前置决策表，进入 implementation plan hardening，尚未标记为实现方案定稿
- GitHub Task: `pkvm-x86#34`
- 所属主任务: `pkvm-x86#20`
- 当前定位: `B5-2` 已解决的是 Guest EPT 首次建图边界；T12 单独跟踪 Host CPU 对 assigned BAR 的访问权是否被 pKVM 收口
- 总设计入口: `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T12-B5-3-protected-pVM-device-MMIO-donate-机制总设计.md`
- ARM 对齐分文档: `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T12-B5-3-Host-BAR隔离-ARM对齐设计草案.md`

## 当前表现 / 当前阻塞

- `B5-2` 已收敛的是“Guest EPT 首次建图边界校验”：
  - 命中当前 VM 已 attach boot BAR 的 HPA 时，允许 direct BAR leaf 建图
  - 未命中 BAR 且也不在 host RAM `mem_range` 内时，提前 reject
  - BAR leaf teardown 时不再走 `__pkvm_host_undonate_guest()`
- 但这不等价于“Host CPU 后续无法再直接读写 assigned BAR”。
- 当前 `handle_host_ept_violation()` 对普通 MMIO hole 仍有 lazy remap 行为：
  - Host EPT fault 命中非 RAM 地址时，会按 `HOST_EPT_DEF_MMIO_PROT` 重新 `pkvm_host_ept_map()`
  - 如果某个 assigned BAR 只是被简单 unmap，而 Host EPT invalid leaf 没有 owner annotation，那么后续 Host fault 仍可能把它 map 回 Host
- 另外，当前 `pkvm_attach_ptdev()` / `pkvm_detach_ptdev()` 本身并没有对 Host EPT 中现存的 BAR 映射做 revoke / restore：
  - attach 只是在 `ptdev` 上切 `shadow_vm_handle`、`pgt` 并执行 `pkvm_iommu_sync()`
  - 这说明当前只切了 DMA/IOMMU ownership，还没有切 Host CPU 对 BAR 的访问权
  - 因此只改 `handle_host_ept_violation()` 最多是“防止后续 fault 再建图”，不能替代 attach 阶段对既有 Host BAR 映射的回收
- 上一轮本地 patch 直接在 attach / fault / detach 三处按 BAR 地址处理，但缺少：
  - hyp 内部 BAR owner authoritative state
  - Host EPT invalid owner annotation
  - attach 失败 / remove-path / teardown rollback 的 generation 语义
  - reset、DMA quiesce、IOMMU group 原子切换的扩展点
- 因此当前推荐不再继续那版 patch，而是先按 ARM pKVM 方案重写设计。

## 关键源码锚点

```text
Current x86 state
    boot manifest
        -> struct pkvm_boot_ptdev_manifest_entry
        -> pkvm_hyp.boot_ptdev_manifest[]

    ptdev attach
        -> pkvm_attach_ptdev()
            -> pkvm_get_or_create_ptdev_checked()
            -> ptdev->shadow_vm_handle = vm_handle
            -> ptdev->pgt = &vm->pgstate_pgt
            -> pkvm_shadow_vm_link_ptdev()
            -> pkvm_iommu_sync()

    Host EPT fault
        -> handle_host_ept_violation()
            -> find_mem_range(gpa, &range)
            -> non-RAM hole
            -> pkvm_host_ept_map(..., HOST_EPT_DEF_MMIO_PROT)

    normal RAM donate
        -> host_initiate_donation()
            -> find_mem_range(addr, &range)
            -> hyp_page_count(__hyp_va(cur))
            -> host_ept_set_owner_locked()
                -> pkvm_pgtable_annotate()
```

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`
  - `struct pkvm_boot_ptdev_manifest_entry`
  - `pkvm_hyp.boot_ptdev_manifest[]`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
  - `struct pkvm_ptdev`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_boot_ptdev_manifest_lookup()`
  - `pkvm_host_hpa_hits_boot_ptdev_bar()`
  - `pkvm_vm_hpa_hits_attached_boot_ptdev_bar()`
  - `pkvm_quiesce_ptdev()`
  - `pkvm_attach_ptdev()`
  - `pkvm_detach_ptdev()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - `handle_host_ept_violation()`
  - `pkvm_host_ept_map()`
  - `pkvm_host_ept_unmap()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
  - `host_initiate_donation()`
  - `host_ept_set_owner_locked()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c`
  - `pkvm_pgtable_lookup()`
  - `pkvm_pgtable_annotate()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c`
  - `find_mem_range()`

## 修复方案摘要

当前推荐方案从“地址 revoke / denylist”调整为“BAR ownership 状态机”：

1. 在 `ptdev` 下维护 BAR resource snapshot：
   - 来源是 boot manifest 与 `ptdev` metadata 的交叉验证结果
   - 每个 BAR 记录 `base / size / flags / owner / state / generation`
2. 增加 MMIO 专用 Host -> Hyp ownership transfer：
   - 不复用普通 RAM 的 `host_initiate_donation()`
   - 不要求 BAR 落在 `find_mem_range()`
   - 不走 `hyp_page_count(__hyp_va())`
   - 只对 Host EPT 写 invalid owner annotation，并按 device/MMIO 属性维护状态
3. 修改 Host EPT fault：
   - 若 invalid PTE 带 owner annotation 且 owner 不是 Host，则拒绝 lazy remap
   - 未标注的普通 MMIO hole 继续保持现有 remap 行为
4. attach / detach 改为状态机：
   - attach：固化 BAR resource → Host->Hyp revoke → 切 DMA/IOMMU view → 发布 guest allowlist
   - detach：quiesce/block DMA → 清 guest allowlist → restore Host owner → 清 BAR state
5. reset、IOMMU group、失败 rollback 先作为结构扩展点保留，后续与 `T4` / `T6` 合流。

## ARM 参考实现结论

- ARM 的设备 BAR / MMIO assignment 更接近：

```text
Host
    -> Hyp owns full device MMIO resource
        -> reset / block DMA / assign group
            -> Guest receives MMIO mapping
```

- ARM 不是把设备 BAR 直接塞进普通 RAM `Host -> Guest` donate 主链。
- ARM 依赖 host stage-2 invalid owner annotation 拦住 Host fault lazy remap，而不是只靠地址 denylist。
- ARM 的 `struct pkvm_device` 是设备资源与 ownership 的 authoritative object：
  - `resources[]`
  - `iommus[]`
  - `group_id`
  - `ctxt`
  - `refcount`
  - `reset_handler`
- x86 可参考这个职责划分，把 `struct pkvm_ptdev` 升级为 BAR resource / owner / lifecycle 的 authority object。
- 已有详细参考总结：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-设备BAR-MMIO-donate机制总结.md`

## 当前推荐实现边界

- 第一阶段只覆盖：
  - protected pVM
  - 单设备
  - 静态 attach
  - boot-known memory BAR
  - Host EPT lazy remap 拦截
  - detach / attach-fail 基础 rollback
- 第一阶段先不覆盖：
  - config space 直达
  - MSI-X table / PBA 子区间精细化
  - hotplug / multi-device / migration
  - 完整 IOMMU group 原子切换
  - reset framework
  - guest token 式 MMIO 身份验证

## 主要风险与待定点

- `ptdev` BAR owner 到底应使用 `OWNER_ID_HYP`，还是新增 device / ptdev owner id。
- Guest BAR 映射后 owner 是否标成 `GUEST`，还是第一阶段保留为 `HYP-with-guest-mapping`。
- Host EPT invalid annotation 的读取 helper 如何设计，避免 `pkvm_pgtable_lookup()` 丢失 invalid PTE annotation 信息。
- BAR restore 应挂在 `pkvm_detach_ptdev()` 内，还是由 `T4` teardown quiesce 主线先保证 DMA 已停。
- attach 失败和 remove-path 如何用 generation 避免半撤销状态泄漏。
- MSI-X table / PBA 是否需要在第一阶段就显式排除。

## 实现范围

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c`
- `pkvm-x86` 中对应的设计文档、验证记录、GitHub issue / PR 闭环

## 非目标

- 不重新定义 `B5-2` 的“Guest EPT 首次建图边界”结论。
- 不把 BAR/MMIO 强塞进普通 RAM donation。
- 不把 `MMIO metadata` 直接等同于 BAR ownership truth。
- 不在本任务里替代 `T4` 的 DMA quiesce 或 `T6` 的 remove-path 全量收尾。
- 不把 config space / MSI-X / PBA 一次性并进第一阶段。

## 验收标准

- protected pVM attach 后，Host CPU 不能通过 Host EPT fault 把 assigned BAR lazy remap 回 Host。
- guest 侧 direct BAR MMIO 保持可用，不因 Host BAR owner revoke 破坏现有正向样例。
- detach / destroy / attach 失败后，Host BAR owner 与 Host EPT 映射能正确恢复。
- 未被分配给 pVM 的普通 MMIO / manifest 内其他设备 BAR 不应被误拒绝 lazy remap。
- 本地文档、GitHub Task、后续 `pKVM-IA PR` 与 `pkvm-x86 PR` 保持闭环。
- 若推进过程中暴露新的唯一报错签名，再独立拆 `Bug` issue，而不是继续混写在本 Task 里。

## 关联文档

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T12-B5-3-Host-BAR隔离-ARM对齐设计草案.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T10-B5-2-protected-pVM-Guest-EPT建图边界实现.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/04-P0-VM销毁前quiesce-ptdev-DMA.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/06-P1-VFIO-remove-path与失败回滚.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-设备BAR-MMIO-donate机制总结.md`
