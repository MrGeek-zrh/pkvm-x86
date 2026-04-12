# [BOOT-010] 普通 VM `manifest-miss` 设备被错误拦截导致 NVMe probe 失败

## 现象

- 2026-04-12 在普通 VM（`PROTECTED=0`）里透传 `0000:02:00.0` 时，guest 本身已启动到 `localhost login:`，但随后出现 NVMe 探测失败。
- 同一轮 host `dmesg` 里同时出现 `reject bdf ... outside boot manifest` 与 DMAR fault，说明 manifest enforcement 被错误施加到了 non-pVM 的共享路径。

## 原始日志（节选）

- guest / crosvm：
  - `localhost login: [   69.213720] nvme nvme0: Identify Controller failed (-4)`
  - `[   69.220440] nvme 0000:02:00.0: probe with driver nvme failed with error -5`
- host `dmesg`：
  - `pkvm_get_or_create_ptdev_checked: reject bdf 0x200 pasid 0x0 outside boot manifest`
  - `DMAR: [DMA Read NO_PASID] Request device [02:00.0] fault addr ... [fault reason 0x02] Present bit in context entry is clear`

完整日志：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-n2-normal-vfio-0200-rerun2-20260412-124339.log`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-n2-host-dmesg-20260412-124445.log`

## 根因（简述）

- `T9` 第一版实现把 `platform manifest` enforcement 同时接到了：
  - `pkvm_attach_ptdev()` 的 pVM attach 路径
  - `shadow_iommu.c` 里的 `iommu_add_ptdev()` 共享路径
- 普通 VM 本身不会走 `kvm_arch_add_device_to_pkvm()` -> `add_ptdev` -> `pkvm_attach_ptdev()` 这条显式 attach 链。
- 但 legacy shadow IOMMU 共享路径仍会在 `sync_shadow_context_entry()` -> `iommu_add_ptdev()` 中 materialize `ptdev`。
- 当这条共享路径也走 checked helper 时，manifest-miss 设备会在普通 VM 下命中 reject，最终表现为：
  - host `dmesg` 打出 `outside boot manifest`
  - context entry 保持 not-present
  - guest 内 NVMe `Identify Controller failed` / `probe ... failed`

## 解决方案

- 把 manifest 校验只保留在 `pkvm_attach_ptdev()` 的 pVM attach 边界。
- `shadow_iommu.c` 的 `iommu_add_ptdev()` 改回只走锁内 unchecked `get/create` helper。
- checked helper 继续在同一把 `ptdev_lock` 下完成 manifest check + get/create，但 attach 侧必须先 check，再允许复用已有 `ptdev`，避免“普通 VM 先物化对象，后续 attach 因对象已存在而绕过校验”。
- `reject bdf ... outside boot manifest` 日志从共享 helper 收口到 `pkvm_attach_ptdev()`，避免普通 VM 路径误打错误日志。

## 验证要点

- `N1`：`PROTECTED=1` + `VFIO_DEV=0000:02:00.0`
  - 预期：attach 失败，host `dmesg` 出现 manifest reject。
- `N2`：`PROTECTED=0` + `VFIO_DEV=0000:02:00.0`
  - 预期：不再出现 manifest reject；guest 不再出现由该校验直接导致的 NVMe probe 失败。
- `P1/P2`：boot-known `0000:01:00.0`
  - 预期：protected VM 与普通 VM 两条正向 accept path 均不回归。

## 触发条件/复现场景

- 复现命令：
  - `timeout --foreground 120s sudo -n PROTECTED=0 SETUP_NET=0 VFIO_DEV=0000:02:00.0 ./scripts/run-crosvm.sh`
- 设备前提：
  - `0000:02:00.0` 在当前环境里是 `pkvm` 初始化完成后才出现的 BDF，可作为 `manifest-miss` 候选。

