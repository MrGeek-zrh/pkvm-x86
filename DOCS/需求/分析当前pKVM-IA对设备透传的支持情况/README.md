# README

本目录用于记录“分析当前 pKVM-IA 对设备透传的支持情况”这项需求的资料、验证方案和问题分析。

## 文件说明

- `当前进度.md`
  - 记录这项需求目前的目标、当前进度、卡点，以及实施跟踪入口。
  - 当前基线已经更新到：`BOOT-007`、`BOOT-008`、`BOOT-009` 三条已知启动/早期运行签名都已不再复现；当前剩余工作已前移到 teardown 生命周期、首次 attach / remove-path 与更完整回归验证。

- `pVM设备透传设计方案.md`
  - 记录当前推荐主线方案，重点是方案 B: `donate + pVM DMA mirror pgtable`。

- `pVM透传设备支持-实现方案.md`
  - 早期实现草案，保留作为历史材料对照。

- `记录-L0用QEMU模拟NVMe供L1枚举.md`
  - 记录测试环境准备过程，重点是如何在 L0 提供可供 L1 枚举的 NVMe 设备，作为后续透传实验的前置条件。

## 子目录说明

- `问题记录/`
  - 存放与该需求相关的问题分析、调用链梳理和故障定位记录。

- `实施跟踪/`
  - 专门用于管理“pVM 设备透传落地实施”这个复杂任务。
  - 采用“总览看板 + 子任务单独跟踪”的方式，避免把设计、进展、风险、验证都堆在一个文件里。
  - 当前主入口是 `实施跟踪/00-总览与进展看板.md`。
  - 若需要快速手工启动 crosvm、登录 guest 并执行 host/guest 联动验证，可直接看 `实施跟踪/09-run-crosvm-交互式使用方式.md`。

## 当前已知问题记录

- `问题记录/BOOT-005/BOOT-005-disable-sandbox后vCPU-hw-run-failure-0x80000021.md`
  - 保留最早一轮 protected pVM + VFIO bring-up 现场，用于对照“旧现场现象”和后续 BOOT-006 的根因收敛。

- `问题记录/BOOT-004-调用链-非机密VFIO触发host到hyp-donate并UD软锁死.md`
  - 说明非机密 VM 在 VFIO 场景下，为什么会走到 host -> hyp donate，并进一步触发 #UD 与 soft lockup。

- `问题记录/BOOT-004/BOOT-004-透传设备给非机密VM后启动失败-do_donate异常6.md`
  - 按问题单格式记录 BOOT-004 的现象、根因、解决方案和验证要点。

- `问题记录/BOOT-004/BOOT-004-panic分析报告.md`
  - 对 BOOT-004 的 panic / donate 失败机制做更详细的分析，包含当前已证实结论和待确认问题。

- `问题记录/BOOT-006/BOOT-006-机密VM-donate失败-IOMMU影子页表refcount冲突.md`
  - 当前已关闭的旧主签名，记录“旧 shadow spgt 残留 refcount 阻塞 donate”这一已解决 blocker。

- `问题记录/BOOT-007/BOOT-007-protected-pVM-NoIommu-VFIO-vcpu-EFAULT.md`
  - 当前已降级为历史 blocker，记录 protected pVM 在 MMIO/config 路径未收敛前触发 `Bad address (os error 14)` 的旧签名。

- `问题记录/BOOT-008/BOOT-008-protected-pVM-NoIommu-VFIO-host-DMAR-PTE-Read-access-not-set.md`
  - 当前已关闭的主线历史 blocker，记录 host DMAR `DMA Read NO_PASID / PTE Read access is not set` 签名及其修复验证证据。

- `问题记录/BOOT-009/BOOT-009-protected-pVM-NoIommu-VFIO-copy-gpa-exception14-soft-lockup.md`
  - 当前已关闭的关联历史 blocker，记录 `copy_gpa__pkvm` 写侧 `#PF(err=0x2)` 继发 host `soft lockup` / `RCU stall` 的签名、根因与 B4 修复证据。
