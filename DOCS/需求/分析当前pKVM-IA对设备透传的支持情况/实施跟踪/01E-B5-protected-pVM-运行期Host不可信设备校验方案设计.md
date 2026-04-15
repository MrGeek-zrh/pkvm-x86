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

### 设计文档

`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`（本文件；问题 2 的设计结论已并入此处）

### 实现跟踪

`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T10-B5-2-protected-pVM-Guest-EPT建图边界实现.md`

### 四轮源码梳理后的核心结论

1. **Host 运行期真正参与建图的主入口只有 `page fault -> vm_mmu_map -> __pkvm_host_donate_guest()` 这一条**
2. **`vm_mmu_unmap()` / `vm_mmu_age()` 对 protected VM 已直接拒绝，不是额外运行期改图入口**
3. **`pkvm_vm_mmu_destroy()` 里的 `__pkvm_host_undonate_guest()` 属于 teardown 回收，不是运行期改图**
4. **`PKVM_GHC_SHARE_MEM / UNSHARE_MEM` 属于 guest 自发状态变换，复用的是当前 Guest EPT 已有 HPA**
5. **MMIO allowlist / ptdev metadata 只在 VM exit 时校验 GPA 合法性，不直接参与 page-fault 建图路径的 HPA 校验**
6. **candidate HPA 在进入 hyp 前就由 Host memslot/HVA 路径解析完成；hyp 只验证 donation 合法性，不验证语义绑定正确性**
7. **对 MMIO BAR 场景，现有 donation 校验体系（`find_mem_range()`/`hyp_page_count()`）语义是针对 host RAM page 的，不适用于 PCI 物理地址；hyp 缺少 device BAR 范围约束**

**当前真正未收敛的问题**：MMIO BAR 直通场景下，Host 在 page-fault 建图时传进来的是 PCI 物理地址（而非 host RAM page），`__pkvm_host_donate_guest` 的现有校验不覆盖 PCI BAR 地址空间，hyp 也没有手段判断这个 PCI 物理地址是否落在该设备 BAR 的正确范围内。普通 RAM 的首次建图完整性缺口（Host 通过 memslot/HVA 控制候选 HPA）应与 MMIO BAR 场景分开描述，两者的攻击面和缺失的校验不同。

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
- 问题 2 设计：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`
- 问题 2 实现跟踪：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T10-B5-2-protected-pVM-Guest-EPT建图边界实现.md`
- DMA mirror 主线：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/02-P0-pgstate_pgt语义收敛为DMA-mirror.md`
- runtime mirror：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/03-P0-donate后同步runtime-DMA-mirror.md`
