# [BOOT-011] manifest reject 后 `vfio` group busy 导致后续普通 VM 打开失败

## 现象

- 在 strict `N1` 已命中 `pkvm_attach_ptdev: reject bdf ... outside boot manifest` 之后，同轮紧接着执行 strict `N2` 时，普通 VM 侧会在很早阶段失败：
  - `failed to open /dev/vfio/9 group: Device or resource busy (os error 16)`
- 当时 host 上没有可见的存活 `crosvm` 进程，`lsof /dev/vfio/9` 也没有稳定显示持有者。
- 但把 `0000:02:00.0` 做一次 `vfio-pci -> nvme -> vfio-pci` rebind 清理后，strict `N2` 可再次成功启动到 guest `login:`

## 根因（简述）

- 当前只确认到现象级相关性：
  - strict `N1` 的 reject-path 很可能留下了某种未完全释放的 `vfio` group / KVM VFIO 侧状态；
  - 该状态不会体现在用户态持有者上，但会让后续普通 VM 首次打开 `/dev/vfio/9` 失败。
- 还没有完成源码级归因；暂时不能断言具体卡在 `crosvm`、KVM `vfio` device cleanup，还是 `pkvm_attach_ptdev()` reject 后的哪一层回滚。

## 解决方案

- 当前临时 workaround：
  - 对 `0000:02:00.0` 执行一次 `vfio-pci -> nvme -> vfio-pci` rebind 清理；
  - 然后再重跑普通 VM 路径。
- 后续正式修复方向：
  - 检查 protected attach reject-path 上的 VFIO/KVM 清理是否完整；
  - 确认 `N1` 失败后是否残留 group/container 关联或其他不可见占用状态；
  - 若确认是新 bug，应拆成独立 `Bug + Task` 跟进，而不继续混在 `T9` 主验收里。

## 验证要点

- 先用真正的 manifest-miss 设备跑 strict `N1`，确认 host `dmesg` 命中：
  - `pkvm_attach_ptdev: reject bdf 0x200 pasid 0x0 outside boot manifest`
- 紧接着跑 strict `N2`，观察是否出现：
  - `failed to open /dev/vfio/9 group: Device or resource busy`
- 再做一次设备 rebind 清理，重跑 strict `N2`，确认普通 VM 能恢复启动到 `login:`

## 原始日志（节选）

- strict `N1` 日志中可见：
  - `failed to set KVM vfio device's attribute: Operation not permitted (os error 1)`
- strict `N2` 首次与第二次失败日志中可见：
  - `failed to open /dev/vfio/9 group: Device or resource busy (os error 16)`

## 触发条件 / 复现场景

- host 内核：`6.12.0-pkvm-ia #6`
- 设备：`0000:02:00.0`
- 场景顺序：
  1. `0000:02:00.0` 在 `pkvm: about to init IOMMU` 之后才被热加到当前 host 拓扑
  2. 将该设备绑定到 `vfio-pci`
  3. 先执行 strict `N1`
  4. 不做 rebind，直接执行 strict `N2`

## 证据

- strict `N1` console：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n1-protected-vfio-0200-20260412-145526.log`
- strict `N1` host `dmesg`：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n1-host-dmesg-20260412-145606.log`
- strict `N2` 首次失败：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n2-normal-vfio-0200-20260412-145653.log`
- strict `N2` 第二次失败：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n2-normal-vfio-0200-rerun-20260412-145758.log`
- rebind 清理：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-reset-0200-vfio-20260412-150046.log`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-rebind-0200-vfio-20260412-150130.log`
- strict `N2` 清理后成功：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n2-normal-vfio-0200-rerun2-20260412-150203.log`

