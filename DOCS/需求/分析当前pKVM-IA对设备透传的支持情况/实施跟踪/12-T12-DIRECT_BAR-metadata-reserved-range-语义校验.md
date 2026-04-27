## 当前表现 / 当前阻塞

当前 #36 解决的是已经打穿的第一 blocker：默认 `T12-A1` 中 Host/VFIO 需要访问 MSI-X table / PBA，但第一阶段实现按整 BAR revoke，导致 #35 的 `raw_readl` #GP。

本 Task 记录一个低优先级后续 hardening 问题：即使 #36 改成“只 revoke guest DIRECT_BAR 数据面范围”，pKVM 仍不应完全信任 userspace/crosvm 提交的 `DIRECT_BAR` metadata。当前校验能证明 range 格式正确、落在 boot manifest 记录的 BAR 内、且不重叠，但还不能由 pKVM 独立证明该 range 没有覆盖 MSI-X table / PBA 等必须由 Host/VMM trap/emulate 的控制面子区间。

这不是当前 `T12-A1` 第一 blocker 的直接修复条件，可作为 #36 之后的 P2 防御加固任务。

关联 GitHub Task：#38
关联当前 blocker：#35
关联当前修复 Task：#36
上层 T12 Task：#34

## 设计记录（2026-04-27）

- MSI-X table / PBA 是 PCI 标准能力描述的子区间，Host 启动枚举阶段理论上可以从 `pdev->msix_cap` 读取 `PCI_MSIX_TABLE`、`PCI_MSIX_PBA` 和 `PCI_MSIX_FLAGS`，计算 table/PBA 所在 BAR、offset 和 size。
- 当前 pKVM boot manifest 只记录 BAR `base/size`，还没有冻结 MSI-X table / PBA reserved ranges；因此 hyp 侧暂时无法独立判断某个 `DIRECT_BAR` metadata 是否覆盖 MSI-X 控制面页。
- 第一阶段仍按 #36 的边界先修复“整 BAR revoke”问题：只 revoke 已声明的 guest DIRECT_BAR 数据面范围，默认保留未声明的 MSI-X table / PBA 给 Host/VMM 控制面。
- 本 Task 后续再决定是否把 MSI-X table / PBA 写入 boot manifest，并在 metadata sync 阶段拒绝覆盖这些 reserved 页的 `DIRECT_BAR` range。

## 修复方案摘要

在 #36 完成“整 BAR revoke -> DIRECT_BAR 数据面子范围 revoke”之后，补齐 pKVM 对 `DIRECT_BAR` metadata 的独立语义校验：

1. 在 boot-time manifest 或 hyp 可见的 ptdev 结构中记录 BAR 内 reserved/trapped 子区间，第一批至少覆盖 MSI-X table 和 MSI-X PBA。
2. host/KVM high 可以从可信启动期 PCI 配置读取 MSI-X capability，冻结 table BAR、table offset、table size、PBA BAR、PBA offset、PBA size。
3. hyp 接受 `SET_PTDEV_MMIO_METADATA` 时，除了检查 range 落在对应 BAR 内，还要拒绝与 reserved/trapped 子区间重叠的 `DIRECT_BAR` range。
4. crosvm 当前的 `remove_bar_mmap_msix()` 仍作为 userspace 侧正确行为，但 pKVM 不把它作为唯一安全边界。
5. 增加负向测试：构造覆盖 MSI-X table / PBA 的 metadata，预期 KVM/pKVM 拒绝，而不是进入运行期 `raw_readl` #GP 或把该范围发布给 guest。

## 实现范围

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`
  - 扩展 boot ptdev manifest 或新增最小 reserved range 描述。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
  - 在 `build_boot_ptdev_manifest()` 期间记录 MSI-X table / PBA 子区间。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - 在 `pkvm_validate_ptdev_mmio_metadata_locked()` 中增加 reserved range overlap 拒绝。
- `tests/pkvm-regress/`
  - 增加 metadata negative case，用于确认 MSI-X table / PBA 不能被声明为 guest DIRECT_BAR。
- `pkvm-x86` 文档
  - 更新 T12 设计与验证矩阵，明确 #36 与本 Task 的边界。

## 非目标

- 不作为 #35 的第一优先级修复前置条件。
- 不要求 #36 第一轮必须完整实现所有控制面 reserved range 类型。
- 不改变 crosvm 现有 `remove_bar_mmap_msix()` 的正确性要求。
- 不处理 hotplug、migration、reset framework 或多设备 group 原子切换。
- 不把 MSI-X table / PBA 暴露给 guest DIRECT_BAR。

## 验收标准

- pKVM 能独立识别并记录 `0000:01:00.0` BAR0 内的 MSI-X table / PBA 子区间。
- `DIRECT_BAR` metadata 若覆盖 MSI-X table / PBA，KVM/pKVM 在 metadata sync 阶段返回错误。
- 被拒绝的非法 metadata 不会写入 guest allowlist，也不会触发 Host EPT revoke。
- 正常 crosvm 生成的、不含 MSI-X table / PBA 的 metadata 仍能通过。
- #36 的默认 `T12-A1`、`T12-B1`、`T12-R1` 回归不被破坏。

## 本地方案文档

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/12-T12-DIRECT_BAR-metadata-reserved-range-语义校验.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/11-T12-MSI-X-table-host-control-range修复计划.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-015/BOOT-015-protected-pVM-VFIO-MSI-X-table-host-read-denied-raw_readl-GP.md`
