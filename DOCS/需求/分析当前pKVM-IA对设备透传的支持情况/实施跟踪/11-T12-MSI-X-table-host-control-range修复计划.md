# T12 MSI-X table Host 控制面子区间修复计划

## 当前表现 / 当前阻塞

- `T12-A1` 默认 protected pVM + VFIO NVMe 运行时，Host 在 VFIO MSI-X enable 路径读取 MSI-X table vector control。
- 当前 T12 第一阶段实现按整 BAR revoke Host EPT 可见性，导致 MSI-X table 所在 BAR0 子区间也被标成 `OWNER_ID_PTDEV_MMIO`。
- pKVM 正确命中 `deny host BAR remap` 后，对 host 注入 #GP；host kernel 随后在 `raw_readl()` Oops。
- `GUEST_KERNEL_EXTRA=pci=nomsi` 临时验证绕过 MSI-X 后，旧签名消失并进入 `login:`，证明第一 blocker 与 MSI-X table host 控制路径相关。

## 关联问题

- 关联 Bug：MrGeek-zrh/pkvm-x86#35
- 关联修复 Task：MrGeek-zrh/pkvm-x86#36
- 关联上层 Task：MrGeek-zrh/pkvm-x86#34
- 关联本地问题记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-015/BOOT-015-protected-pVM-VFIO-MSI-X-table-host-read-denied-raw_readl-GP.md`
- 临时验证后续签名：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-016/BOOT-016-protected-pVM-VFIO-pci-nomsi-scheduling-while-atomic.md`

## 修复方案摘要

将第一阶段 Host BAR revoke 粒度从“整 BAR”调整为“guest DIRECT_BAR 数据面范围”：

1. 保留 pKVM hyp 以 boot manifest BAR 为 authority 的基本原则。
2. 将 crosvm 已提交的 `DIRECT_BAR` metadata 作为 guest 数据面子范围描述，用于限定 Host EPT revoke 的实际范围。
3. 对 MSI-X table / PBA 等没有出现在 `DIRECT_BAR` metadata 中的 BAR 子区间，暂不写 `OWNER_ID_PTDEV_MMIO` annotation，保留 host/VFIO 控制路径可访问性。
4. Host EPT deny-remap 语义仍保留在被 revoke 的 guest 数据面子范围上，不能退回到整 BAR lazy remap。
5. restore / rollback 范围从 `touched_bar_mask` 细化到实际 touched ranges，避免只按 BAR 粗粒度恢复。

## 当前实现进展（2026-04-26）

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h` 已新增 `touched_mmio_ranges[]` 和 `touched_mmio_range_count`，用于记录实际完成 Host EPT annotation 的 DIRECT_BAR range。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c` 已将 `pkvm_revoke_ptdev_bars_locked()` 从整 BAR 遍历改为遍历 `ptdev->mmio_metadata.ranges[]`。
- `pkvm_restore_ptdev_bars_locked()` 通过 range restore helper 只恢复实际 touched DIRECT_BAR range，不再按整 BAR restore。
- `pkvm_publish_ptdev_mmio_contract_locked()` 在发布 guest allowlist 前确保 DIRECT_BAR range 已 revoke；metadata 尚未到达时 attach 可保持 `PKVM_PTDEV_ATTACHING`，待 metadata sync 后再执行 range revoke 和 contract publish。
- `pkvm_vm_hpa_hits_attached_boot_ptdev_bar()` 已收紧为只命中 metadata 声明的 DIRECT_BAR range，避免 guest 通过整 BAR 判定拿到 MSI-X table / PBA 等 host 控制面子区间。
- `tests/pkvm-regress` 已增加源码契约测试，检查 revoke / restore 不再使用整 BAR `bar->hpa, bar->size` 路径。

## 实现范围

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - 调整 `pkvm_revoke_ptdev_bars_locked()`，从遍历整 BAR 改成遍历 validated DIRECT_BAR ranges。
  - 记录实际 revoke 成功的 range，用于失败回滚和 detach restore。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
  - 将 BAR progress / touched state 从 BAR mask 扩展为 range 级状态，或新增最小 range 记录结构。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - 保持 `OWNER_ID_PTDEV_MMIO` deny-remap 行为不变；必要时补充日志字段帮助区分数据面与控制面范围。
- `crosvm/devices/src/pci/vfio_pci.rs`
  - 第一轮不改变其 `remove_bar_mmap_msix()` 语义；仅把它作为 pKVM hyp 侧子范围选择的对齐依据。
- `tests/pkvm-regress/`
  - 更新 T12-A1 / T12-A2a 判据：默认路径不应因 MSI-X table host read 触发 `raw_readl` #GP；数据面 Host BAR touch 仍应 deny。

## 非目标

- 不把 `pci=nomsi` 作为默认回归或正式修复。
- 不允许 Host 重新访问整个 assigned BAR。
- 不在本任务里解决 `BOOT-016 scheduling while atomic` 新签名。
- 不一次性处理 hotplug、migration、reset framework、多设备 group 原子切换。
- 不改变 crosvm 默认启动行为；`GUEST_KERNEL_EXTRA` 仅作为显式 opt-in 临时验证入口。

## 验收标准

- 默认 `T12-A1` 不设置 `GUEST_KERNEL_EXTRA` 时 protected pVM + VFIO 能到 `login:`。
- Host 日志不再出现 `deny host BAR remap gpa=0xfe80200c`、`raw_readl`、`general protection fault`。
- `T12-A2a` / `T12-A2b` 对真正 guest DIRECT_BAR 数据面范围的 deny-remap 判据仍成立。
- `T12-B1` guest DIRECT_BAR / NVMe 只读 direct I/O 仍成功。
- `T12-R1` clean poweroff 后实际 touched ranges 恢复到 Host 可见。

## 建议验证顺序

```text
1. T12-G2 protected pVM 无 VFIO baseline
2. T12-G1 normal VM + VFIO baseline
3. T12-A1 默认 MSI-X 路径，不设置 pci=nomsi
4. T12-B1 guest DIRECT_BAR + NVMe 只读 I/O
5. T12-A2a 被动 deny-remap 观察
6. T12-R1 clean poweroff restore
```
