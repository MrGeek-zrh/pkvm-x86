# pVM 设备透传实施跟踪

本目录专门用于管理“pVM 设备透传落地实施”这个复杂任务。

设计方案、问题记录、验证记录仍然保留在上级目录和 `问题记录/` 中；本目录只负责三件事：

- 把复杂任务拆成可独立推进的子任务。
- 明确每个子任务的依赖、验收标准和源码锚点。
- 跟踪当前状态，避免把实施进展堆在单个总文件里。

GitHub Issue / PR 现在作为状态真相来源；本目录主要保存较长的分析、拆分、验证矩阵和阶段结论。对应协作规则见 `08-GitHub-Issue-PR-协作流.md`。

## 使用方式

- 从 `00-总览与进展看板.md` 进入，先看当前阶段和下一步。
- 每个子任务单独维护，不把多个实现点混在一份文档里。
- 若推进过程中发现新的故障现象或复现场景，继续按规则写到上级 `问题记录/`，不要混写到本目录。

## 文件结构

- `00-总览与进展看板.md`
  - 总览目标、阶段划分、依赖关系、当前状态和下一步。
- `01-P0-清理旧shadow-spgt残留refcount.md`
  - 直接解除当前 donate panic 的最小阻塞项。
- `01A-B0-NoIommu运行期EFAULT归因.md`
  - 在 T1 之后先判断新的运行期 `EFAULT` 是否属于现有主线缺项，避免后续实现跑偏。
- `01B-B0-protected-pVM-VFIO-config-MMIO访问路径收敛.md`
  - 解决 B1 之后确认的更前置 blocker：protected pVM 当前还不能消费 VFIO PCI 的 config/MMIO fallback 路径。
- `01C-B0-protected-pVM-guest-hyp-passthrough-MMIO语义设计.md`
  - 收敛真正的主线前置任务：guest/hyp 如何识别 passthrough BAR/MMIO，以及相关设备元数据如何传递。
- `01C-1-B3-1-protected-pVM-设备透传第一阶段上层方案.md`
  - 先从上层方案收敛第一阶段支持范围、非目标、trust boundary 和实现顺序。
- `01C-2-B3-2-x86-ptdev-metadata-最小结构草案.md`
  - 细化第一阶段所需的 x86 `ptdev metadata` 最小字段集、ownership 和 guest 可见 allowlist。
- `02-P0-pgstate_pgt语义收敛为DMA-mirror.md`
  - 把 `pgstate_pgt` 从“页状态 + teardown 回收”收敛为“纯 DMA mirror”。
- `03-P0-donate后同步runtime-DMA-mirror.md`
  - 在 guest donate 成功后建立和维护 DMA 可见映射。
- `04-P0-VM销毁前quiesce-ptdev-DMA.md`
  - 解决 teardown 生命周期和 DMA 仍可达的问题。
- `05-P1-prepopulate与首次attach路径.md`
  - 解决已有 donated 页面在首次 attach/hotplug 时的预填充。
- `06-P1-VFIO-remove-path与失败回滚.md`
  - 解决 remove-path、失败回滚、多设备共享状态机。
- `07-验证矩阵.md`
  - 汇总阶段性验证项和回归检查项。
- `08-GitHub-Issue-PR-协作流.md`
  - 说明 Issue / PR / submodule 的协作边界和闭环流程。
