# [T6] P1: VFIO remove-path 与失败回滚

## 状态

- 当前状态: 待开始
- 优先级: P1

## 目标

补齐“attach 失败、VFIO FILE_DEL、设备释放、多设备共享 spgt”这些状态机收尾路径，避免只打通 happy path。

## 为什么单独拆分

- 复杂任务往往不是主路径最难，而是状态机收尾最容易埋坑。
- 当前代码中只有 `add_device_to_pkvm()`，没有对称的 remove hook。
- `pkvm_attach_ptdev()`、`pkvm_detach_ptdev()`、VFIO `FILE_DEL` 之间目前也没有完整闭环。

## 关键源码锚点

- `pKVM-IA/virt/kvm/vfio.c`
  - `kvm_vfio_file_add()`
  - `kvm_vfio_file_del()`
  - `kvm_vfio_release()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
  - `kvm_arch_add_device_to_pkvm()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_attach_ptdev()`
  - `pkvm_detach_ptdev()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu_spgt.c`
  - shared spgt 生命周期

## 当前已确认结论

- 当前有 add-path: `kvm_vfio_file_add()` -> `kvm_arch_add_device_to_pkvm()` -> hypercall `add_ptdev`。
- 当前没有与之对称的 remove-path 进入 pKVM。
- 当前 `kvm_vfio_file_del()` / `kvm_vfio_release()` 只做 KVM/VFIO 侧收尾，不会通知 pKVM 做对应状态收敛。

## 建议实施方向

- 增加与 add-path 对称的 remove-path。
- 定义 attach 失败后的回滚边界：
  - 若已经切换 `ptdev->pgt`
  - 若已经 link 进 `ptdev_head`
  - 若已经部分 prepopulate
  - 若已经写入 IOMMU SLPTR
- 明确多设备共享 spgt 时的引用和释放规则。

## 验收标准

- 设备从 KVM/VFIO 移除后，pKVM 内部 `ptdev` 状态同步收敛。
- attach 中途失败不会留下悬挂的 `ptdev`、错误的 `pgstate_pgt` 映射或脏的 IOMMU 状态。
- 多设备共享状态下不会出现重复释放、提前释放或 stale mapping。

## 风险点

- remove-path 需要跨 KVM high / pKVM hyp 两侧一起改，接口设计要谨慎。
- 该任务容易和 T4 的 teardown 路径相互耦合。

## 依赖

- T1
- T2
- T3
- T4
