# [B5] P1: protected pVM 运行期 Host 不可信前提下的设备名单与 Guest EPT 建图边界

## 状态

- 当前状态: 进行中（`B5-1/T9` 已完成问题 1；当前主问题收敛到问题 2）
- 优先级: P1
- GitHub Task: `pkvm-x86#20`
- 关联 Epic: `pkvm-x86#1`
- 已完成子任务: `pkvm-x86#21`

## 当前收敛口径

本任务当前只保留两个问题：

1. **设备名单边界**
   - 不在 Host 启动时扫描到的设备名单里的设备，默认都不可信，不允许透传给 pVM。
2. **Guest EPT 建图边界**
   - protected pVM 的 Guest EPT `GPA -> HPA` 映射在建立和更新时，运行期 Host 是否还能经由 donate/share/映射更新路径任意影响或篡改。

本地文档从本次起不再沿用旧的泛化设备真实性表述。

ARM 参考仍然有价值，但它现在只作为更强威胁模型的参考，不再代表当前 x86 这轮要先回答的问题。

## 问题 1：设备名单边界

### 目标

- 启动后新出现的设备、新 VF、以及不在 boot-time manifest 里的 BDF，都不允许 attach 给 protected pVM。

### 当前源码事实

- Host 启动阶段会遍历 PCI 设备并构造 boot-time manifest：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
  - `check_pci_device_count()`
  - `build_boot_ptdev_manifest()`
- manifest 存储在 `struct pkvm_hyp`：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`
- hyp 侧 attach 边界已有 manifest membership check：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - `pkvm_boot_ptdev_manifest_lookup()`
  - `pkvm_check_boot_ptdev_manifest()`
  - `pkvm_get_or_create_ptdev_checked()`

### 当前结论

- 这个问题当前代码已经实现。
- 本地对应设计与实现文档分别是：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-1-B5-1-启动期platform-manifest可信设备名单方案.md`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-2-T9-B5-1-platform-manifest与checked-ptdev创建实现.md`
- 后续只剩 reject-path cleanup 之类的 follow-up，不再把问题 1 当成主设计不确定项。

## 问题 2：Guest EPT 建图边界

### 现在真正要问的是什么

当前更准确的问题不是“BAR 是不是真设备”，而是：

- protected pVM 的 Guest EPT `GPA -> HPA` 映射是谁在建；
- Host 在运行期提交的 `hpa/gpa/prot` 等输入，会被 hyp 约束到什么程度；
- Host 是否还能借由 donate/share/undonate 或其它映射更新路径，把 guest 原本不该看到的 HPA 重新绑到某个 GPA 上。

### 必须先和 DMA mirror 区分开

这个问题首先讨论的是 **Guest EPT 本身**，不是 `pgstate_pgt`。

- `pgstate_pgt` 在当前代码里的语义已经明确为 **DMA mirror**：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm_hyp_types.h`
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
- `__pkvm_host_donate_guest()` 成功后会额外同步 `pgstate_pgt`：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`

也就是说，下面两件事必须分开看：

- Guest CPU 访问看到的主 Guest EPT 建图；
- 设备 DMA 侧消费的 `pgstate_pgt` mirror。

后续文档不再把它们混写成一条“BAR backing 真相源”问题。

### 当前源码已经明确保证的点

当前代码并不是“Host 可完全无约束随意篡改 Guest EPT”。至少已经有这几层限制：

- `__pkvm_host_donate_guest()` 走 `do_donate()` 前，会先经过 `check_donation()`：
  - `host_request_donation()` 要求源 HPA 仍是 Host owned
  - `guest_ack_donation()` 要求目标 GPA 在 guest EPT 中当前是 `PKVM_NOPAGE`
- 也就是说，旧映射不是随便覆盖；源页也不是随便拿一页就能塞给 guest。
- protected guest 的 `read_gpa()` / `write_gpa()` 会先查 `pkvm_vm->mmu`，并拒绝把非 RAM HPA 当作普通内存访问：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/memory.c`

对应当前最关键的建图链路是：

```text
Host runtime donate request
    -> __pkvm_host_donate_guest(hpa, guest_pgt, gpa, size, prot, ...)
        -> do_donate(...)
            -> check_donation(...)
                -> host_request_donation(...)
                -> guest_ack_donation(...)
            -> __do_donate(...)
        -> protected VM only:
            -> pkvm_shadow_vm_sync_dma_mirror(guest_pgt, gpa, size)
```

### 当前仍未收敛清楚的点

但这还不等于问题 2 已经结束。当前仍需继续回答：

- 运行期 Host 还能通过哪些入口参与 Guest EPT 建图或更新？
- 除 `__pkvm_host_donate_guest()` / `__pkvm_host_undonate_guest()` 外，是否还存在其它会改动 protected guest `GPA -> HPA` 的路径？
- 现有 ownership / page-state 检查是否已经足以覆盖“Host 不能把错误 HPA 绑进 guest”这个目标？
- `SET_PTDEV_MMIO_METADATA`、MMIO allowlist、`ptdev` attach 这些路径，究竟和 Guest EPT 建图有没有直接关系，哪些只是访问 contract，哪些真的会改映射？

## 当前结论

- **问题 1 已实现**：manifest 外设备不允许透传给 protected pVM。
- **问题 2 才是 B5 剩余主问题**：要基于源码继续确认 Guest EPT `GPA -> HPA` 建图的真实控制边界。
- 因此 `pkvm-x86#20` 从现在开始在本地文档里应理解为：
  - 不再讨论泛化的设备真实性问题；
  - 只继续收敛 Guest EPT 建图路径的 Host 影响面与 hyp 约束。

## 非目标

当前这份 B5 文档不再承担以下目标：

- 不再把泛化的设备真实性问题当作这轮主问题。
- 不再把 Guest EPT 建图问题重新包装成另一个更宽泛的设备身份标题。
- 不在本轮直接推出 `per-pVM contract`、firmware 设备 token、设备 lease 等更强闭环方案。
- 不把 `SET_PTDEV_MMIO_METADATA` 重新解释成 Guest EPT 建图真相源。

## 关联文档

- 问题 1 设计：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-1-B5-1-启动期platform-manifest可信设备名单方案.md`
- 问题 1 实现：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-2-T9-B5-1-platform-manifest与checked-ptdev创建实现.md`
- 问题 2 第一轮源码梳理：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-3-B5-2-protected-pVM-Guest-EPT-建图边界初步梳理.md`
- DMA mirror 主线：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/02-P0-pgstate_pgt语义收敛为DMA-mirror.md`
- runtime mirror：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/03-P0-donate后同步runtime-DMA-mirror.md`
