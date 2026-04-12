# [B5] P1: protected pVM 运行期 Host 不可信设备校验方案设计

## 状态

- 当前状态: 进行中（`B5-1` 已转入实现，问题 2 设计继续保留）
- 优先级: P1
- GitHub Task: `pkvm-x86#20`
- 关联 Epic: `pkvm-x86#1`
- 当前实现子任务: `pkvm-x86#21`

## 目标

在“信任启动阶段、但不信任运行期 Host”的前提下，收敛 x86 `pKVM-IA` 的 pVM 设备校验方案，明确：

- 哪些设备可以进入 pVM 的可信候选集合；
- Host attach 给 pVM 的设备，如何确认它确实是该 pVM 应拿到的那个设备；
- 平台级设备清单、attach 校验和后续实现边界分别应落在哪一层。

这个任务当前输出的是：

- trust model 明确；
- 问题拆分明确；
- 候选方案边界明确；
- attach 校验高层流程明确。

当前仍是 B5 总设计 Task。

- `B5-1` 的第一阶段实现已拆到 `pkvm-x86#21`
- `#20` 继续保留“问题 2：已知设备全集里 attach 错设备”的设计入口

## 为什么必须单独拆分

- 当前 x86 `pKVM-IA` 的设备 attach 路径仍主要由 Host 驱动，现有路径更像“把设备接进来”，而不是“在运行期 Host 不可信前提下确认设备身份”。
- 前面的讨论已经形成一个稳定前提：可以把 **启动阶段由 host kernel 枚举、并由 host-side pKVM 在 early init / finalise 前冻结下来的设备全集** 视为可信 `platform manifest`。
- 但这只能解决“运行期新设备注入”问题，不能单独解决“Host 从启动时已存在的设备里挑错一个 attach 给 pVM”的问题。
- 如果不把这层 trust boundary 单独收敛，后续很容易把：
  - 平台级设备库存
  - 单 pVM 的设备授权
  - attach 时的设备身份校验
  混成一个模糊实现，最后既难验证，也难和 ARM / AVF 参考方案做一一对照。

## 问题拆分

### 问题 1：运行期新设备注入

例如：

- 热插一个新的 PCI function；
- 运行期再创建新的 VF；
- 让一个启动阶段不在设备全集里的 endpoint 进入 attach 候选集合。

这个问题当前已经有清晰方向：

- **启动阶段冻结 `platform manifest`**

### 问题 2：已知设备全集里 attach 错设备

例如：

- pVM 需要的是设备 A，但 Host attach 的是设备 B；
- Host 给出的设备入口描述和真实 MMIO / IOMMU 身份不一致；
- Host 故意给一个“看起来像目标设备”的错误描述。

这个问题当前仍待 B5 收敛，是本任务的重点。

## 当前已确认前提

### 前提 1：启动阶段可信

这意味着：

- 启动阶段 host kernel 已完成的 PCI / IOMMU / DMAR 枚举结果，可以作为可信输入来源；
- host-side pKVM 可以在自身 early init / finalise 前读取这些结果并冻结成快照。

对应源码锚点：

- `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
- `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`

### 前提 2：运行期 Host 不可信

这意味着：

- 运行期 attach 参数不能单独作为最终真相来源；
- 只靠 Host 在运行期说“我要把这个设备给某个 pVM”并不够；
- 必须再有一层不依赖运行期 Host 的校验依据。

### 前提 3：`platform manifest` 已可作为第一层约束

当前已接受的 baseline 是：

- 来源：启动阶段 host kernel 已枚举出的设备全集；
- 冻结点：host-side pKVM 在 early init / finalise 前写入 `pkvm_hyp`；
- 作用：限制只有 manifest 内设备才能沿显式 attach / shadow-IOMMU 路径继续创建 `ptdev` 并进入后续 attach 流程。

这层 baseline 目前已经成立。

### 前提 4：现有 `SET_PTDEV_MMIO_METADATA` 通路继续保留，但它不是设备身份真相源

当前已经落地的 host -> hyp `SET_PTDEV_MMIO_METADATA` / `sync_ptdev_mmio_metadata` 通路，解决的是：

- BAR / MMIO allowlist 如何从 host/crosvm 传给 hyp，并再导出给 guest

它当前**不是**用来回答下面这个问题的真相源：

- “Host attach 给 pVM 的是不是那台它本来该拿到的设备”

所以 `B5/B5-1` 的设备身份校验设计，不推翻这条 metadata 通路，而是把它明确归位为：

- **MMIO allowlist / access contract**

而不是：

- **设备身份真相源**

### 当前实现主线限定

虽然 `B5` 作为总设计任务仍然要保留对后续 scalable/PASID 扩展的视野，但当前如果真正进入实现，建议把主线明确收缩为：

- **Host IOMMU = legacy mode**
- **当前只做 `pasid == 0`**
- **当前只把 legacy shadow-IOMMU 的 context-entry 路径纳入完成定义**

也就是说：

- `B5` 仍讨论完整 trust boundary
- 但 `B5-1` 和未来 `T9` 的当前实现范围，可以先只做 legacy-only

## 当前仍待收敛的问题

当前真正悬而未决的是第二层：

- **manifest 内设备，如何进一步确认是“这个 pVM 应拿到的那个设备”？**

也就是：

- 谁持有“某个 pVM 应得设备”的可信期望描述？
- attach 时由谁来做最终匹配？
- 需要校验哪些身份字段？
- 这层校验能否完全在 pKVM 透明完成，还是需要 guest / firmware 参与？

## 候选方向

### 方向 A：`per-pVM contract`

思路：

- 在创建某个 pVM 时，把“这个 pVM 允许拿 manifest 里的哪一个 / 哪一组设备”写给 pKVM；
- 后续 attach 时由 pKVM 透明比对。

优点：

- attach 校验可以完全收敛在 pKVM；
- guest 不一定需要额外参与运行期查询。

当前状态：

- 这是一个重要候选方向，但是否采用还没有最终拍板。

### 方向 B：guest / firmware 持有可信期望描述

思路：

- Host 只提供设备入口；
- pKVM 提供“当前实际资源身份”的 token / 事实证明；
- guest / firmware 用另一份可信描述做最终匹配。

这更接近当前 ARM / AVF 的模式。

参考文档：

- `/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-设备身份校验方案（从抽象到具体）.md`

### 方向 C：其他 Host-external truth source

例如：

- 外部控制面签发的一次性授权；
- 启动链交付的设备 lease；
- 更强的平台固件声明。

当前判断：

- 这类方向暂不排除，但目前还没有比 A/B 更贴近当前代码基础的明确方案。

## 当前建议的推进方式

当前更合理的推进顺序是：

1. 先把第一层 baseline 固化为：`boot-time platform manifest`
2. 再单独比较第二层方案，而不是一开始就把 `per-pVM contract` 当成唯一解
3. 在第二层方案定稿前，不直接进入 x86 attach UAPI / hyp 校验状态机的代码实现

换句话说，B5 当前不是“写 patch”，而是“先把后续 patch 应该服从的 trust boundary 固定下来”。

## 关键源码锚点

- 启动阶段 host-side pKVM 枚举 / 冻结 IOMMU 与设备信息
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`
- 运行期 Host 驱动的 attach 路径
  - `/home/mrgeek/pkvm-x86/pKVM-IA/virt/kvm/vfio.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
  - `/home/mrgeek/pkvm-x86/pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- ARM / AVF 参考设计
  - `/home/mrgeek/pkvm-x86/refs/android-kernel-common/Documentation/virt/kvm/arm/pviommu.rst`
  - `/home/mrgeek/pkvm-x86/refs/android-kernel-common/Documentation/virt/kvm/arm/hypercalls.rst`
  - `/home/mrgeek/pkvm-x86/refs/android-virtualization/docs/device_trees.md`
  - `/home/mrgeek/pkvm-x86/refs/android-virtualization/docs/device_assignment.md`
  - `/home/mrgeek/pkvm-x86/refs/android-virtualization/guest/pvmfw/src/device_assignment.rs`

## 本轮输出

- GitHub Task：`pkvm-x86#20`
- 当前长文设计入口：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-1-B5-1-启动期platform-manifest可信设备名单方案.md`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-设备身份校验方案（从抽象到具体）.md`

## 当前细化进展

- `B5-1` 已单独细化“第一个问题：运行期新设备注入”的设计方案：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-1-B5-1-启动期platform-manifest可信设备名单方案.md`
- 当前结论是：
  - 第一层 baseline 应收敛为启动期冻结 `platform manifest`
  - 真正可信的 runtime enforcement 必须落在 hyp
  - 但 2026-04-12 的 `N2` 样例也进一步证明：manifest enforcement 应收敛在 `pkvm_attach_ptdev()` 这条 pVM attach 边界，而不是泄露到普通 VM 共享的 shadow IOMMU bookkeeping 路径
  - `B5-1` 已进一步细化到接近实现颗粒度：
    - 建议显式引入 `PKVM_MAX_BOOT_PTDEV_NUM`
    - 建议把 manifest entry 继续固定为第一阶段最小的 `bdf + flags`
    - 但同时显式限定：Host legacy IOMMU、单 segment、无 hot-remove/slot reuse
    - 建议采用“checked / unchecked 双 helper + 锁内原语复用”的 `get/create` 入口，而不是直接把策略塞进 `pkvm_alloc_ptdev()` 裸指针分配器
    - 建议把当前 `T9` 的负向验证矩阵收敛到：
      - `N1`：manifest-miss 设备的 protected attach reject
      - `N2`：manifest-miss 设备在普通 VM 路径上不被 manifest 错误拦截
      - 启动期 legacy 设备 accept path 不回归
    - 已进一步补出 `T9` 的实现级草案：按阶段列出预计触点文件、关键 helper、插入顺序、日志信号和阶段退出条件
  - 当前阶段先不新增 issue；等进入实现时，更建议新增单个实现型 Task（暂定 `T9`），而不是把 `B5-1` 直接拆成多个细碎 Task
  - 进入 `T9` 实现后，已进一步补一轮 review follow-up：
    - boot-known 设备的模式判定改为优先参考 manifest 冻结事实，减少 `attach` 与 legacy shadow IOMMU 路径的模式分叉
    - manifest miss 下的 mixed/scalable 扩展风险，继续明确保留为后续问题，不在 `T9` 内扩大范围
    - KVM high 未发 vmcall 与 `bdf_pasid_to_iommu()` 依赖既有 sync 的系统级缺口，当前只记录、不在这轮 patch 中强行解决
  - 2026-04-12 的 post-fix 回归也补出了新的环境事实：
    - 原先用于 `N1/N2` 的 `0000:02:00.0` 在 kernel `6.12.0-pkvm-ia #6` 上已变为 boot-known 设备
    - 因此当前已验证的是“边界修正后普通 VM / protected VM 均不回归”，而 strict manifest-miss 负向样例仍需新的启动后 BDF 来源

## 非目标

- 本轮不直接修改 `pKVM-IA` attach 代码；
- 本轮不直接拍板第二层一定采用 `per-pVM contract`；
- 本轮不把“平台级设备库存”和“单 pVM 设备授权”混成一层；
- 本轮不要求给出最终 UAPI / hypercall 细节。

## 验收标准

- 明确区分“问题 1：新设备注入”与“问题 2：已知全集里 attach 错设备”；
- 明确 `platform manifest` 的来源、冻结时机和覆盖范围；
- 明确第二层设备授权 / 身份校验仍待哪些决策，以及每个候选方向依赖的可信输入来源；
- 明确 attach 期至少需要校验的设备身份信息范围；
- 明确后续若进入实现，应如何继续拆子 Task / PR。
