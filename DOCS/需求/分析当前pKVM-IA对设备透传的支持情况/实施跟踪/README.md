# pVM 设备透传实施跟踪

本目录专门用于管理"pVM 设备透传落地实施"这个复杂任务。

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
- `01D-B4-protected-pVM-allowlist-guest-gpa回写路径修复.md`
  - 单独收敛 `BOOT-009`：修正 hyp 对 protected guest allowlist 缓冲区的 GPA 回写语义。
- `01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`
  - 单独收敛"启动阶段可信、运行期 Host 不可信"前提下的两个问题：boot-time manifest 设备名单边界，以及 protected pVM Guest EPT `GPA -> HPA` 建图边界；当前也承载 `B5-2` 的设计结论。
- `01E-1-B5-1-启动期platform-manifest可信设备名单方案.md`
  - 单独细化 `B5` 的问题 1：如何冻结并 enforce 启动期可信设备名单，拦住运行期新设备注入。
- `01E-2-T9-B5-1-platform-manifest与checked-ptdev创建实现.md`
  - 承接 `B5-1` 的实现阶段，记录 manifest 冻结、checked helper 和 legacy attach 接入顺序；不覆盖 Guest EPT 建图边界问题。
- `01E-T10-B5-2-protected-pVM-Guest-EPT建图边界实现.md`
  - 承接 `B5-2` 设计阶段的实现跟踪；待确定普通 RAM leaf 首次建图完整性缺口的修复方向。
- [`01E-T12-B5-3-protected-pVM-device-MMIO-donate-机制总设计.md`](01E-T12-B5-3-protected-pVM-device-MMIO-donate-机制总设计.md)
  - 作为 `B5-3 / T12` 的总入口，汇总已锁定的 device MMIO donate contract、状态机和 restore contract。
- [`01E-T12-B5-3-Host-BAR隔离-ARM对齐设计草案.md`](01E-T12-B5-3-Host-BAR隔离-ARM对齐设计草案.md)
  - 作为 `B5-3 / T12` 的分文档，保留 ARM 对齐背景、BAR ownership 差距分析和细节推导。
- `02-P0-pgstate_pgt语义收敛为DMA-mirror.md`
  - 把 `pgstate_pgt` 从"页状态 + teardown 回收"收敛为"纯 DMA mirror"。
- `03-P0-donate后同步runtime-DMA-mirror.md`
  - 在 guest donate 成功后建立和维护 DMA 可见映射。
- `04-P0-VM销毁前quiesce-ptdev-DMA.md`
  - 解决 teardown 生命周期和 DMA 仍可达的问题。
- `04A-P0-teardown-DMA生命周期风险验证与触发样例.md`
  - 先记录 T4 的触发样例、证据采集要求和 issue 规划边界。
- `05-P1-prepopulate与首次attach路径.md`
  - 解决已有 donated 页面在首次 attach/hotplug 时的预填充。
- `06-P1-VFIO-remove-path与失败回滚.md`
  - 解决 remove-path、失败回滚、多设备共享状态机。
- `07-验证矩阵.md`
  - 汇总阶段性验证项和回归检查项。
- `08-GitHub-Issue-PR-协作流.md`
  - 说明 Issue / PR / submodule 的协作边界和闭环流程。
- `09-run-crosvm-交互式使用方式.md`
  - 记录当前 `run-crosvm.sh` 的直接交互方式，以及 host/guest 联动验证的最小操作套路。
