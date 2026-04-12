# [T4A] P0: teardown DMA 生命周期风险验证与触发样例

## 状态

- 当前状态: 已建样例，待执行
- 所属主任务: T4
- 关联验证任务: T7
- 当前定位: validation-first 子任务，不作为已确认 bug 处理

## 当前表现 / 当前阻塞

- 截至 2026-04-07，当前还没有独立观测到“teardown 期间 DMA 继续命中已回收页”对应的 panic / DMAR fault / pKVM exception 签名。
- 当前风险主要来自源码生命周期顺序推导，而不是已经稳定复现的报错。
- T2/T3 首轮运行里“guest 关机退出后 host `dmesg` 未见新 fault”只能算负例观察，不能直接证明 teardown 前 DMA 已真正 quiesce。

## 目标

- 为 T4 建立可重复执行的 teardown 生命周期验证样例。
- 先确认当前代码路径是否真的可能暴露“设备仍 DMA 到已 undonate 页”的问题，再决定是否进入修复实现。
- 给后续 GitHub Task / Bug 提供统一的触发步骤、证据采集要求和判定规则。

## 为什么先做验证

- 当前 T4 属于 correctness 风险，但还不是已确认问题签名。
- 如果直接进入代码修改，容易把“源码上看起来不稳妥”和“已经被样例证明确实会出错”混为一谈。
- 先把触发样例和证据采集方式固定下来，后续无论是证明风险存在，还是证明当前路径暂时没触发，都有统一落点。

## 关键源码锚点

- `pKVM-IA/arch/x86/kvm/pkvm/pkvm.c`
  - `pkvm_vm_destroy()` 先做 `pkvm_vm_mmu_destroy()`，之后才走 `kvm_arch_destroy_vm()`
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - `guest_mmu_free_leaf()` 对 protected guest 页面执行 `__pkvm_host_undonate_guest()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_detach_ptdev()` 当前会把 `ptdev->pgt` 切回 `host_vm.ept`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`
  - `pkvm_iommu_sync()` 负责把 `ptdev` 当前页表状态同步到 IOMMU
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`
  - shadow context / PASID entry 会使用 `ptdev->pgt->root_pa` 更新 SLPTR
- `pKVM-IA/virt/kvm/kvm_main.c`
  - `kvm_destroy_vm()` 当前是先 `kvm_arch_destroy_vm()`，后 `kvm_destroy_devices()`
- `pKVM-IA/arch/x86/kvm/x86.c`
  - `kvm_arch_destroy_vm()` 会继续走 `vm_destroy()` / `kvm_mmu_uninit_vm()` 等销毁动作

## 建议 GitHub issue 形态

- 当前先作为 `T4` / `T7` 下的验证子步骤记录，不单独宣称为 bug。
- 若样例跑出新的独立签名，再新建对应 `Bug` issue，保留唯一签名和原始日志。
- 若多轮样例都未触发，也只说明“当前样例未观测到异常”，不能直接关闭 T4。

## 适用范围

- 第一阶段只覆盖单设备、静态 attach、`NoIommu`、无 hotplug、无 remove-path。
- 设备类型先以当前主线 NVMe VFIO 为准。
- `scalable mode / PASID` 分支样例本轮先不纳入。

## 触发样例

### Case A: 活跃 DMA + host 强制销毁

- 目的:
  - 压测“guest 仍在做 DMA 时，host 侧直接 destroy VM”这条最激进 teardown 路径。
- 触发步骤:
  - guest 内启动持续 direct I/O（例如循环 `dd` 或 `fio --direct=1`）。
  - host 侧不做优雅关机，直接终止 VMM / 触发 VM destroy。
- 重点观察:
  - host `dmesg` 是否出现新的 DMAR / IOMMU fault、`pkvm: exception`、soft lockup、stall。
  - VMM 退出路径是否出现异常长延迟、卡死或 teardown 卡住。

### Case B: 小流量 I/O + 重复 boot/destroy 循环

- 目的:
  - 覆盖“单轮不报错，但跨轮残留状态累积后暴露”的场景。
- 触发步骤:
  - 每轮 guest 启动后做一次小块 direct I/O。
  - 立即关机或销毁。
  - 重复多轮执行。
- 重点观察:
  - 后续轮次是否重新出现 donate / attach / teardown 相关异常。
  - 是否出现 refcount、IOMMU state 或 shadow 视图跨轮残留的迹象。

### Case C: 活跃 I/O + guest 内强制 reboot/poweroff

- 目的:
  - 覆盖“guest 自己发起快速退出”与“host 强制 destroy”之间的差异。
- 触发步骤:
  - guest 内启动持续 direct I/O。
  - 直接执行 `reboot -f`、`poweroff -f` 或其他快速退出路径。
- 重点观察:
  - 是否暴露不同于 Case A 的 teardown 时序问题。
  - `shadow_vm` / `ptdev` 销毁路径是否出现新的 fault 或卡顿。

## 证据采集要求

- host 侧至少保留：
  - 完整 `dmesg`
  - VMM stdout / stderr
  - 触发命令与时间点
- guest 侧至少保留：
  - I/O 命令
  - `dmesg`
  - 退出方式（正常关机 / 强制重启 / host kill）
- 若出现独立异常：
  - 单独写入上级 `问题记录/`
  - 同目录保留完整原始日志文件，不只保留节选

## 判定规则

- 失败:
  - 出现新的 DMAR / IOMMU fault、`pkvm: exception`、stall、跨轮残留或 teardown 卡死。
  - 新签名按 `Bug + Task` 方式拆分记录。
- 未定:
  - 没有 fault，但证据只停留在“本轮未见报错”。
  - 这种情况只能说明当前样例尚未触发，不足以证明 quiesce 语义已经正确。
- 通过:
  - 当前阶段不设“仅靠负例即可判定完全通过”的标准。
  - 更合理的结果是把风险边界缩小，为后续 T4 实现或额外 trace 提供依据。

## 非目标

- 本文不直接给出 T4 的最终代码修复方案。
- 本文不覆盖 hotplug、remove-path、多设备共享状态机。
- 本文不覆盖 `scalable mode / PASID` 分支验证。
