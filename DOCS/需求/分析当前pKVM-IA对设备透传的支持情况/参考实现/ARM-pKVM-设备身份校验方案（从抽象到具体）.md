# ARM pKVM 设备身份校验方案（从抽象到具体）

## 目的

这份文档只回答一个问题：

- 当运行期 Host 不可信时，ARM pKVM / AVF 是如何降低“Host 把错误设备 / fake device 交给 pVM”这个风险的？

范围说明：

- 本文只展开当前仓库里的 ARM pKVM 参考设计与实现线索。
- 默认关注 `refs/android-kernel-common/`、`refs/android-virtualization/` 与当前仓库里的 `crosvm/`。
- 本文讨论的是“设备身份校验链路”，不是完整的设备透传 bring-up 手册。
- 若某个结论是从当前代码与文档综合推导出来的，会明确标注为“推断”。

配套阅读：

- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-参考源.md`·
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-到-x86-设计映射表.md`
- `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/参考实现/ARM-pKVM-MMIO_GUARD与stage-2-abort路径讲解.md`

## 一句话结论

ARM pKVM / AVF 的思路不是：

- “Host 把设备描述给 pVM，pVM 直接相信”；
- 也不是“pKVM 单独在后台替 pVM 做完所有身份判定”。

它更接近下面这个闭环：

1. Host / VMM 先把设备入口描述给 pVM。
2. pvmfw 在 guest 内、guest kernel 前运行，先审查 Host 给的设备树。
3. 对于 assignable device，pvmfw 再向 pKVM/hyp 请求与当前实际资源绑定的 token。
4. pvmfw 用启动链提供的可信设备描述（VM DTBO）去比对这些 token。
5. 只有比对通过的设备，才会被保留到最终交给 guest kernel 的 DT 中。

所以这套方案本质上是：

- pKVM/hyp 负责回答“你现在实际连到的到底是什么资源”；
- pvmfw 负责回答“这是不是这个 pVM 本来就应该拿到的那个设备”；
- guest kernel 最终只看到 pvmfw 清洗后的设备描述。

## 总览流程图

如果先不钻细节，可以先把 ARM pKVM / AVF 在 Host 不可信前提下的设备校验理解成下面这条链：

```text
[可信启动链 / Bootloader]
    │
    ├─ 验证并装载 pvmfw
    ├─ 把可信配置一起交给 pvmfw
    │    ├─ VM DTBO          = 这台 pVM 本来允许拿哪些设备
    │    └─ VM reference DT  = 某些属性的可信参考值
    │
    ▼
[Hypervisor / pKVM]
    │
    ├─ 保护 pvmfw 所在内存
    └─ 让 pvmfw 成为 pVM 启动入口
         （不是直接进 guest kernel）
    ▼
[pvmfw：pVM 内第一个执行的可信代码]
    │
    ├─ 接收 Host/VMM 传来的 input DT
    │    └─ 这份 DT 一律视为“不可信”
    │
    ├─ 先做基础校验 / 清洗
    │
    ├─ 如果 DT 里声明了 assignable device：
    │    │
    │    ├─ 向 hyp 查询 MMIO token
    │    │    └─ “这个 guest IPA 现在实际绑定到哪个物理 MMIO 资源？”
    │    │
    │    ├─ 向 hyp 查询 IOMMU token
    │    │    └─ “这个 (pvIOMMU ID, vSID) 现在实际绑定到哪个 DMA 资源？”
    │    │
    │    └─ 用 bootloader 给的 VM DTBO / VM reference DT 做最终比对
    │         ├─ 匹配：保留该设备并 patch 到最终 DT
    │         └─ 不匹配：删掉设备，严重时直接终止启动
    │
    ▼
[sanitized DT]
    │
    ▼
[guest kernel]
    └─ guest 只看到 pvmfw 清洗后的 DT
       看不到 Host 原始 DT
```

可以把这条链先记成一句话：

- Host 只负责“提案”；
- hyp 负责证明“当前实际绑定到什么资源”；
- pvmfw 负责判断“这个资源是不是这台 pVM 本来应得的那个设备”；
- guest kernel 只消费最终的 `sanitized DT`。

## 先把问题拆开

前面讨论的“Host 不可信”其实包含两个不同层面：

### 风险面 A：Host 能不能在运行期凭空塞进一个新设备？

比如：

- 启动后热插一个新 PCI function；
- 运行期新建一个 VF；
- 把一个原本不在可信启动上下文里的 endpoint 再交给 pVM。

这个问题的核心是：**设备全集是否在可信阶段被冻结。**

### 风险面 B：即便设备来自“已知设备全集”，Host 会不会把错误的那个给 pVM？

比如：

- pVM 需要的是设备 A，Host 交过来的是设备 B；
- Host 给了一个设备入口描述，但把其 MMIO / IOMMU 身份串错了；
- Host 故意给出一个看起来像目标设备、但实际并不是目标设备的描述。

这个问题的核心是：**谁来判断“当前实际连到的资源”是不是“pVM 预期的那个设备”。**

ARM pKVM / AVF 这里重点处理的是风险面 B。

## 抽象模型：三份信息、两个判断

从抽象层看，ARM 方案里至少有三份信息：

1. **Host 描述**
   - Host / crosvm 交给 pVM 的设备入口信息；
   - 例如 input DT 里的 MMIO 区间、`pvIOMMU id`、`vSID` 等。
2. **pKVM 观察到的真实受保护资源**
   - pKVM/hyp 实际掌握的设备资源、IOMMU route、当前属于该 VM 的受保护 MMIO 资源。
3. **pVM 侧可信描述**
   - pvmfw 在可信启动链下拿到的“这个 pVM 本来允许拿哪些设备”的描述；
   - 在 AVF 里，这个角色由 bootloader 提供给 pvmfw 的 `VM DTBO` 承担。

最终要做两个判断：

- **判断 A：当前 VM 真正连到的是什么？**
  - 这个由 pKVM/hyp 给答案。
- **判断 B：这个东西是不是我预期那个设备？**
  - 这个由 pvmfw 根据可信描述来下结论。

这就是为什么 ARM 文档强调：

- `DEV_REQ_DMA` / `DEV_REQ_MMIO` 要在使用设备前调用；
- 最好由 protected VM firmware 调用。

对应文档见：

- `refs/android-kernel-common/Documentation/virt/kvm/arm/pviommu.rst`
- `refs/android-kernel-common/Documentation/virt/kvm/arm/hypercalls.rst`

## 从抽象到具体：AVF/ARM 里的实际落点

如果把当前仓库里的 ARM 参考实现再具体一点，实际参与者是这四层：

```text
bootloader
    提供 VM DTBO（可信 assignable device 描述）

crosvm / Host
    生成 input DT（不可信设备入口）

pvmfw
    校验 input DT
    结合 VM DTBO 与 hyp token 做设备身份验证
    生成 sanitized DT

guest kernel
    只消费 sanitized DT
```

这里最关键的一点是：

- 在 AVF 里，**真正直接相信 input DT 的不是 guest kernel**；
- guest kernel 看到的是 **pvmfw 清洗后的 DT**。

这正是“不要把最终信任停留在 Host 描述上”的具体体现。

## 具体流程

下面把这条链路按时间顺序展开。

### 阶段 A：bootloader 先把可信设备描述交给 pvmfw

AVF 文档明确写到：

- `VM DTBO` 描述的是“所有可分配设备”的信息；
- 它包含 physical `reg`、IOMMU、设备属性、依赖关系；
- host 启动时，bootloader 会把 VM DTBO 提供给 Android 和 pvmfw。

见：

- `refs/android-virtualization/docs/device_assignment.md`

这一步的关键意义是：

- pvmfw 手里先有一份**不受运行期 Host 任意篡改**的设备期望描述；
- 后面它验证的不是“Host 说自己是谁”，而是“Host 说的这个设备，能不能和 boot-time 可信描述对上”。

在我们前面的术语里，这基本相当于：

- `per-pVM contract`
- 或者“启动期可信交付给 pVM firmware 的设备授权描述”。

### 阶段 B：crosvm / Host 再把设备入口描述给 pVM

与此同时，运行期 crosvm 仍然会把设备入口写进给 pVM 的 device tree。

比如 DMA / IOMMU 路径：

- ARM pKVM 文档说明 `pvIOMMU ID` 由 Host 选择，并通过平台方式告诉 guest；在参考实现里就是 device tree，见 `refs/android-kernel-common/Documentation/virt/kvm/arm/pviommu.rst`。
- 当前 `crosvm` 的 ARM 路径会生成 `compatible = "pkvm,pviommu"` 和 `id` 属性，见 `crosvm/aarch64/src/fdt.rs`。
- guest 内核侧 `pkvm-pviommu` 驱动会从 device tree 中读出这个 `id`，见 `refs/android-kernel-common/drivers/iommu/pkvm-pviommu.c`。

这里要特别注意：

- **这一步只是在建立“入口”**，不是在建立“信任”。
- 也就是说，pVM 此时只是知道“Host 说有这么个设备入口”，并不能仅凭这个就认定它一定是对的。

### 阶段 C：pvmfw 先清洗 Host 给的 DT，而不是让 guest kernel 直接接收

AVF 文档明确说明了这层职责分工：

- 由于 threat model 不允许 guest 信任 host，所以 DT 必须由一个 trusted entity 校验；
- AVF 选择把这件事交给在 guest 上下文中、早于 guest kernel 运行的 `pvmfw`；
- 如果发现异常，`pvmfw` 会中止 guest 启动；
- guest kernel 最终收到的是 pvmfw 清洗后的 DT。

见：

- `refs/android-virtualization/docs/device_trees.md`

所以在 ARM / AVF 这条线上，实际不是：

```text
crosvm input DT -> guest kernel
```

而是：

```text
crosvm input DT -> pvmfw -> sanitized DT -> guest kernel
```

这一步非常关键，因为它说明：

- “设备身份校验”不是 guest kernel 启动后可选做的一件事；
- 它发生在更早的 firmware 阶段，而且失败就直接不让这台 pVM 正常启动。

### 阶段 D：对 assignable device，pvmfw 再向 pKVM/hyp 查询 token

光清洗 input DT 还不够，因为 pvmfw 不能只检查格式，还要确认：

- Host 给出的 MMIO / IOMMU 身份，是否真的对应当前 VM 实际拿到的受保护资源。

所以 ARM 文档又定义了两类 hypercall。

#### D1. DMA / IOMMU 身份查询：`DEV_REQ_DMA`

`ARM_SMCCC_KVM_FUNC_DEV_REQ_DMA` 的语义是：

- 按 `(pvIOMMU ID + vSID)` 查询；
- 返回一组可用于匹配 trusted firmware description 的 token；
- 必须在 pVM 做任何 IOMMU 访问前调用；
- 最好由 protected VM firmware 调用。

见：

- `refs/android-kernel-common/Documentation/virt/kvm/arm/pviommu.rst`

当前 hyp 实现里：

- `pkvm.c` 会把这个 hypercall 分发到 `pkvm_device_request_dma()`；
- 它先按 `(pviommu, vsid)` 找到当前 VM 的 route；
- 再把 `route.iommu` 转成 guest / firmware 可理解的 token；
- 同时返回 `route.sid`；
- 并确认该 route 对应的设备确实已经归当前 VM。

见：

- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/pkvm.c`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`

这里可以把它理解成：

- Host 给的是“一个名字”；
- pKVM/hyp 返回的是“这个名字在受保护资源世界里真正解析出来的身份凭据”。

#### D2. MMIO 身份查询：`DEV_REQ_MMIO`

`ARM_SMCCC_KVM_FUNC_DEV_REQ_MMIO` 的语义是：

- 按 IPA page 查询；
- 返回可用于匹配可信设备描述的 token；
- 必须在 MMIO 访问前调用；
- 最好由 protected VM firmware 调用。

见：

- `refs/android-kernel-common/Documentation/virt/kvm/arm/hypercalls.rst`

当前 hyp 实现里：

- `pkvm.c` 会把这个 hypercall 分发到 `pkvm_device_request_mmio()`；
- pKVM 先根据 guest IPA 找到对应请求 token；
- 再在“当前属于这个 VM 的已登记设备资源”里检查它是否命中某个资源范围；
- 命中才返回成功。

见：

- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/pkvm.c`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`

抽象一下就是：

- 不是 Host 说“这个 MMIO page 属于设备 X”就算；
- 而是 pKVM 要先确认：这个 MMIO page 背后，实际对应的是“当前 VM 已持有设备资源”中的哪一块。

### 阶段 E：pvmfw 用 VM DTBO 里的可信描述做最终比对

这是从“有机制”走到“真正闭环”的最后一步。

AVF 文档明确写到：

- 为了支持 device assignment，pvmfw 会收到一份 `VM DTBO`；
- pvmfw 会用通用逻辑验证 physical device properties；
- pvmfw 还会向 hypervisor 验证 guest 地址是否真的映射到了期望的 physical device 地址。

见：

- `refs/android-virtualization/docs/device_trees.md`
- `refs/android-virtualization/docs/device_assignment.md`

而在 `pvmfw` 代码里，这个校验已经落成了具体逻辑：

- `validate_reg()` 会调用 hypervisor 的 `get_phys_mmio_token()`，并把返回值和 VM DTBO 中期望的 physical `reg` 对比；
- `validate_iommus()` 会调用 hypervisor 的 `get_phys_iommu_token()`，再和 VM DTBO 中物理 IOMMU token + SID 逐项匹配；
- 一旦不匹配，就返回 `InvalidReg` 或 `InvalidIommus`。

见：

- `refs/android-virtualization/guest/pvmfw/src/device_assignment.rs`

把它抽象成决策逻辑，就是：

1. 从 Host / crosvm 给的 input DT 里拿到“它声称自己是谁”；
2. 从 pKVM/hyp 查询到“它实际上是谁”的 token；
3. 从 bootloader 提供的 VM DTBO 里拿到“我本来期望的设备身份”；
4. 只有三者能对上，设备才被保留到 sanitized DT 中。

如果对不上：

- pvmfw 会认为这是错误设备 / 串线设备 / fake device；
- 该设备不会被当作可信 assignable device 交给 guest kernel；
- 严重异常时，pvmfw 直接终止这次 pVM 启动。

### 阶段 F：guest kernel 最终只消费 sanitized DT

到这一步，guest kernel 看到的已经不是 Host 原始描述，而是 pvmfw 过滤后的结果。

所以从 guest kernel 的视角看，最终进入内核的设备描述已经满足：

- 来自 Host 的输入被审过；
- 与 boot-time 可信设备描述比过；
- 关键 MMIO / IOMMU 身份已经过 hyp token 验证。

这就是 ARM / AVF 这套方案“从抽象到具体”真正落地的位置。

## 一眼看懂：完整信任闭环

```text
bootloader
    提供 VM DTBO
    （可信的设备期望描述）

crosvm / Host
    提供 input DT
    （不可信的设备入口描述）

pvmfw
    读取 input DT
    读取 VM DTBO
    对 assignable device:
        调 DEV_REQ_MMIO / DEV_REQ_DMA
        向 hyp 查询 token
        将 token 与 VM DTBO 中期望身份比对
    生成 sanitized DT
    若发现异常则拒绝启动

guest kernel
    只接收 sanitized DT
```

## 它为什么不等于“pKVM 透明完成全部校验”

这个问题的本质在于：

- pKVM/hyp 能知道“当前这个 VM 实际拿到了哪个资源”；
- 但 pKVM/hyp 不天然知道“这个 VM 业务上本来就应该拿哪个设备”。

后者必须来自一个额外的可信来源。

ARM / AVF 方案里，这个可信来源不是运行期 Host，而是：

- bootloader 交给 pvmfw 的 `VM DTBO`
- 加上 pvmfw 自己执行的匹配逻辑

所以 ARM 的职责拆分是：

- **pKVM/hyp 证明事实**：当前资源身份是什么；
- **pvmfw 做授权判断**：这是不是我应得的那个设备。

这也是为什么 AVF 文档特意说：

- 为了避免把过多策略塞进高度特权的 hypervisor，DT 校验交给 pvmfw；
- 而跨 guest 的隔离仍然由 hypervisor 保证。

换句话说：

- **设备身份的“事实证明”** 由 pKVM/hyp 承担；
- **设备身份的“期望匹配”** 由 pvmfw 承担；
- **多 VM 之间的设备隔离** 仍然由 hypervisor 承担。

## 它解决了什么，没有解决什么

### 已解决 / 明确考虑的问题

#### 1. 不再只信 Host 描述

ARM / AVF 已经明确意识到：

- Host 描述只是候选输入；
- 真正接受设备前，需要经过 `pvmfw + hyp token + VM DTBO` 的联合校验。

这就是对“fake device”担忧的正面回应。

#### 2. 设备身份校验被前置到 guest kernel 之前

这套校验不是“guest 驱动加载后再看情况做”，而是：

- 在 pvmfw 阶段先完成；
- 失败就不把这个设备交给 guest kernel，甚至直接不让 pVM 启动。

#### 3. Host 和 pVM 的真相来源被分离

- Host 负责提供入口；
- pKVM 负责返回与真实资源绑定的 token；
- pvmfw 负责与 VM DTBO 做匹配；
- guest kernel 只消费通过校验后的结果。

这几层不再塌缩成“Host 说了算”。

### 没有单独解决的问题

#### 1. 平台设备全集从哪里来

ARM / AVF 这套机制主要解决的是“设备身份匹配”。

它不天然回答：

- 某个运行期新热插设备，是否允许进入候选集合；
- 平台级设备全集是否应在启动期冻结。

这部分仍然需要平台级策略补齐。

也就是说：

- `DEV_REQ_DMA` / `DEV_REQ_MMIO` 更像是在解决“风险面 B”；
- 对“风险面 A”（运行期新设备注入），还需要额外的 manifest / inventory 约束。

#### 2. pvmfw 看不到跨 guest 的全局滥用

AVF 文档也明确说了：

- pvmfw 运行在单个 pVM 视角中；
- 它不能独立发现 Host 是否把同一设备同时分给多个 guest；
- 这部分隔离职责仍然归 hypervisor。

所以 ARM / AVF 不是把所有安全问题都交给 pvmfw，而是把职责明确拆开了。

#### 3. 当前你的整条软件栈是否默认全启用这套闭环

从当前仓库可以确认：

- 文档 ABI 已定义；
- hyp 侧实现已存在；
- AVF 文档和 pvmfw 侧验证逻辑也已存在。

但如果问题收窄成：

- “我手上的某一版 `crosvm + pvmfw + guest` 运行栈，是否已经默认把这套校验强制串到底？”

那还需要继续按你实际版本去核对 boot chain / pvmfw 接入状态，不能只靠这里的源码片段直接下结论。

## 跟我们当前 x86 讨论的对应关系

如果把 ARM / AVF 方案翻译成我们当前讨论过的术语，它大致对应：

- **平台级可信设备库存**：回答“候选全集有哪些设备”；
- **VM DTBO / trusted description**：回答“某个 pVM 应该拿哪一个设备”；
- **pKVM token 查询**：回答“当前实际挂上来的到底是哪一个资源”；
- **pvmfw 比对**：完成最终授权判断；
- **sanitized DT**：把校验后的结果交给 guest kernel。

所以 ARM 方案给我们的真正启发不是“它把所有事都藏在 pKVM 里自动做完了”，而是：

- 当运行期 Host 不可信时，必须把
  - **事实证明**
  - 和 **授权判断**
  分开。

其中：

- pKVM/hyp 更适合承担“事实证明”；
- 可信 firmware / contract 更适合承担“授权判断”；
- guest kernel 只消费已经校验过的结果。

## 一句话总结

ARM pKVM / AVF 对“fake device”这件事的核心设计，不是让 pVM 无条件信任 Host，也不是让 pKVM 单独替业务做授权决策，而是建立这样一条闭环：

- **bootloader 提供可信设备描述（VM DTBO）**；
- **Host / crosvm 提供不可信设备入口（input DT）**；
- **pvmfw 向 pKVM/hyp 查询 MMIO / DMA token**；
- **pvmfw 用 VM DTBO 做最终匹配并生成 sanitized DT**；
- **guest kernel 只消费校验通过后的设备描述**。

换句话说：

- pKVM/hyp 负责证明“你现在拿到的到底是什么”；
- pvmfw 负责决定“这是不是你应该拿到的那个设备”；
- guest kernel 则只接收这个闭环验证后的结果。
