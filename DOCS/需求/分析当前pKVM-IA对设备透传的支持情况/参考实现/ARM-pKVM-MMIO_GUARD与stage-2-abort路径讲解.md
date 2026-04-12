# ARM pKVM MMIO_GUARD_MAP/RGUARD_MAP 与 stage-2 abort 路径讲解

## 目的

这份文档只回答一个问题：

- 当前仓库 `refs/android-kernel-common` 里的 arm64 pKVM 参考实现，是怎么处理 MMIO 的？

它主要作为下面这句话的展开说明：

- 当前仓库里的 arm64 更接近“映射期 guard + 运行期 stage-2 abort”的组合。

范围说明：

- 默认只分析当前仓库里的 `refs/android-kernel-common/arch/arm64` 与相关 guest 驱动代码。
- 除非特别说明，下文出现的裸相对路径默认都相对 `refs/android-kernel-common/`。
- 不展开 Android AVF 的 DTBO / pvmfw / device assignment manifest。
- 若某个结论依赖源码外推，会明确标成“推断”。

术语约定：

- 文中说“MMIO guard 机制”时，指的是“guest 在建图期把 IPA 区间注册给 hyp，声明这段地址按 MMIO 语义处理”这一整套思路。
- 文中说具体 ABI 名时，优先写精确名字：`ARM_SMCCC_KVM_FUNC_MMIO_GUARD_MAP` / `ARM_SMCCC_KVM_FUNC_MMIO_RGUARD_MAP`。
- 若讨论“trusted passthrough 直通 MMIO”，则要单独看 `ARM_SMCCC_KVM_FUNC_DEV_REQ_MMIO`；它不是 `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` 的同义词。

## 先说结论

ARM 这条线和当前 x86 allowlist 的核心差异是：

1. ARM protected guest 并没有把 `readl/writel` 这种 MMIO 入口整体改写成“每次访问都先走一个 guest 侧软件分流器”。
2. ARM 是在 `ioremap()` 这类“建立 MMIO 映射”的时点，通过 `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` hypercall 把对应 IPA 区间告诉 hyp。
3. 运行期 guest 仍然直接执行 arm64 原生 `ldr/str` 式 MMIO 指令；如果访问触发 stage-2 fault，再进入 `kvm_handle_guest_abort()` / `io_mem_abort()` 这条通用 fault/emulation 路径。
4. 所以 ARM 更像“启动期发现服务、建图期做 guard、运行期走原生 MMIO、fault 时再分流”。

### 一眼看懂：四段式主流程

```text
A. 启动期：发现并启用 pKVM guest 服务
    guest init                                   (guest 早期初始化阶段)
        -> kvm_init_hyp_services()
            -> 检查 HVC conduit                 (确认 hypervisor 调用走 HVC)
            -> 读取 KVM vendor UID             (确认对端确实是 KVM vendor service)
            -> 读取 feature bitmap             (拿到“支持哪些 guest hypercall”的总表)
            -> kvm_arch_init_hyp_services()
                -> pkvm_init_hyp_services()
                    -> 查询 HYP_MEMINFO        (拿到 pKVM granule 大小)
                    -> 注册 MEM_SHARE / MEM_UNSHARE ops
                                                  (让 guest 后续能显式 share/unshare 内存)
                    -> 若支持 MMIO_GUARD_MAP 且 guest RAM 区间边界按 granule 对齐
                        -> arm64_ioremap_prot_hook_register(mmio_guard_ioremap_hook)
                                                  (把 MMIO guard 挂到 ioremap 建图路径上)

B. 建图期：ioremap() 时把 device IPA 注册成“合法 MMIO fault 区”
    driver / subsystem ioremap(device IPA)      (guest 驱动开始映射设备 IPA)
        -> ioremap_prot()
            -> ioremap_prot_hook(...)
                -> mmio_guard_ioremap_hook()
                    -> 检查 pgprot 是否为 device attributes
                                                  (只对 device 映射做 MMIO guard)
                    -> arm_smccc_do_range(MMIO_RGUARD_MAP / MMIO_GUARD_MAP, ...)
                        -> HVC 进入 pKVM hyp
                            -> pkvm_install_ioguard_page()
                                -> __pkvm_install_ioguard_page()
                                    -> kvm_pgtable_stage2_annotate(..., KVM_INVALID_PTE_MMIO_NOTE)
                                                              (把这段 IPA 标成“允许按 MMIO fault 处理”的 ioguard 注记)
            -> generic_ioremap_prot()
                -> 返回 guest 可用的 __iomem vaddr
                                                  (后续 readl/writel 就用这个 vaddr)

C. 运行期快路径：已有可用 stage-2 时直接访问
    guest readl/writel                          (驱动正常访问 MMIO 寄存器)
        -> __raw_read* / __raw_write*
            -> arm64 ldr/str                   (继续走 CPU 原生 load/store 指令)
                -> 若已有可用 stage-2 映射
                    -> 访问直接完成            (包括已经建好的 device-type stage-2 映射)

D. 运行期慢路径：没有现成 stage-2 时按 pVM fault 语义分流
    guest readl/writel
        -> __raw_read* / __raw_write*
            -> arm64 ldr/str
                -> 触发 DABT / IABT             (当前没有可直接命中的 stage-2 映射)
                    -> 第 1 段：pKVM hyp 侧先判这次 fault 是否具备“合法 MMIO”资格
                        -> handle_pvm_exit_dabt()
                            -> __pkvm_check_ioguard_page()
                                -> 命中 ioguard
                                                          (保留后续 MMIO decode / emulate 所需 syndrome 信息)
                                -> 未命中 ioguard
                                                          (清掉关键 syndrome 位；后续不会被当成合法 MMIO emulate)
                    -> 第 2 段：host KVM 侧再按 backing 情况继续分流
                        -> kvm_handle_guest_abort()
                            -> gfn_to_memslot_prot() / kvm_is_write_fault()
                                                          (先看 fault IPA 有没有可用 memslot backing)
                            -> 若 !memslot 或 (write fault 且 !writable)
                                -> io_mem_abort()
                                    -> hyp 侧已判为合法 MMIO fault
                                        -> kvm_io_bus_read/write()
                                                                (先尝试内核态 MMIO emulation)
                                        -> in-kernel emulation 或 KVM_EXIT_MMIO
                                                                (内核没接住时再退出给 userspace)
                                    -> hyp 侧未判为合法 MMIO fault
                                        -> protected VM 直接给 guest 注入 abort
                                                                (不会把这次 fault 当成合法 MMIO emulate)
                            -> 若存在可用 memslot backing
                                -> pkvm_mem_abort_prefault()
                                    -> pkvm_mem_abort()
                                        -> __gfn_to_pfn_memslot()
                                        -> kvm_is_device_pfn()
                                                                (这里才区分普通 RAM PFN 还是 device-backed PFN)
                                        -> stage-2 map / relax perms
                                                                (普通内存补 normal stage-2；device PFN 则补 device-type stage-2，可形成后续直通)
```

### 这个四段式流程的关键点

- 控制点在建图期：不是每次 `readl/writel` 都先查一张 guest 本地 allowlist，而是在 `ioremap()` 时通过 `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` 先把 IPA 区间交给 hyp。
- 快路径仍是原生 CPU load/store：guest 运行时继续直接执行 arm64 的 `ldr/str` 式 MMIO 指令。
- 慢路径落在 abort 处理：对 pVM 而言，它不是“一步进 host KVM”，而是先经过 hyp 侧 ioguard 检查，再进入 host KVM 的 abort 分流。
- 因此 ARM 的主线是“映射期 guard + fault path 消费”，不是“访问期 guest wrapper + 本地 allowlist 命中判断”。

### 重要澄清：这里的“快路径”和“慢路径”不是同一种 MMIO

- 上面的“快路径”是广义上的 stage-2 访问快路径，意思是“这次访问已经有合法的 stage-2 映射，所以 CPU 直接完成访问，不触发 abort”。
- 这里更准确的术语应当是 `stage-2`，不是 x86 里的 `EPT`。
- 如果把问题收窄到 `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` 这组 ABI，它们的目标是：
  - 把某段 IPA 声明成“允许被当作 MMIO 处理”
  - 这样访问这段 IPA 时，fault 可以进入 `io_mem_abort()` / `KVM_EXIT_MMIO` 的 emulation 路径
  - 而不是“给这段 IPA 直接建立一个 guest 可长期直通的 MMIO 映射”
- 所以就当前 `refs/android-kernel-common` 这份 arm64 guest 参考代码而言：
  - `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` 更接近“允许 host/in-kernel emulation 的白名单”
  - 不在这份 guest 代码里等价于“直通 MMIO fast path”
- 如果要讨论“trusted passthrough 后不再退出到 host 的直通 MMIO”，还要再看 `DEV_REQ_MMIO`：
  - `hypercalls.rst` 明确写了：它必须在对应 IPA 已经先被标成 MMIO 后调用
  - 并且它成功后，对该 IPA 的访问会经 `stage-2` 直达，不再退出到 host
- 反过来，真正更像“直通访问”的那一类路径，是 `kvm_handle_guest_abort()` 进入 `user_mem_abort()` 后，为某个 backing 建好 `stage-2` 映射，并在 `user_mem_abort()` 里按 `device pfn` 补上 `KVM_PGTABLE_PROT_DEVICE` 这一类情况；这和 `MMIO_GUARD_MAP / MMIO_RGUARD_MAP -> io_mem_abort()` 不是一回事。

### 两条对照调用栈

#### 1) 更像“直通 / stage-2 建图”的路径

```text
guest readl/writel                               (第一次访问时，stage-2 叶子项可能还没建好)
    -> __raw_read* / __raw_write*
        -> arm64 ldr/str
            -> 触发 stage-2 abort               (说明当前还不能直接访问)
                -> handle_exit.c
                    -> kvm_handle_guest_abort()
                        -> gfn_to_memslot()
                        -> gfn_to_hva_memslot_prot()
                                                   (先确认这次 fault 落到哪个 memslot / hva)
                        -> user_mem_abort()
                            -> __gfn_to_pfn_memslot()
                                                       (拿到 backing PFN)
                            -> kvm_is_device_pfn()
                                                       (判断 backing 是不是 device PFN)
                            -> prot |= KVM_PGTABLE_PROT_DEVICE
                                                       (device PFN 时，stage-2 叶子项带 device 属性)
                            -> kvm_pgtable_stage2_map()
                                                       (真正建立/更新 stage-2 映射)

guest 下一次再访问同一 IPA                      (stage-2 叶子项已经存在)
    -> __raw_read* / __raw_write*
        -> arm64 ldr/str
            -> 直接命中 stage-2 leaf
                                                   (访问直接完成，不再进入 abort handler)
```

#### 2) `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` 下的 MMIO 模拟路径

```text
guest 启动
    -> kvm_init_hyp_services()
        -> kvm_arch_init_hyp_services()
            -> pkvm_init_hyp_services()
                -> arm64_ioremap_prot_hook_register(mmio_guard_ioremap_hook)
                                                   (只有发现 MMIO_GUARD_MAP 且 DRAM 对齐才注册 hook)

driver / subsystem ioremap(device IPA)
    -> ioremap_prot()
        -> mmio_guard_ioremap_hook()
            -> arm_smccc_do_range(MMIO_RGUARD_MAP / MMIO_GUARD_MAP, phys, nr_pages, ...)
                                                   (把这段 IPA 告诉 hyp：按 MMIO 语义处理)
        -> generic_ioremap_prot()
                                                   (返回 guest 侧 __iomem vaddr)

guest readl/writel
    -> __raw_read* / __raw_write*
        -> arm64 ldr/str
            -> 触发 stage-2 abort
                                                   (这里不是去“补一个长期直通映射”)
                -> handle_exit.c
                    -> kvm_handle_guest_abort()
                        -> kvm_is_error_hva() / !writable
                                                   (落到 MMIO / invalid-hva 判断分支)
                        -> io_mem_abort()
                            -> kvm_io_bus_read/write()
                                                       (先尝试内核态 MMIO emulation)
                            -> in-kernel emulation
                               或 KVM_EXIT_MMIO
                                                       (内核没接住时再退出给 host userspace)
```

而不是当前 x86 那种：

```text
guest readl/writel
    -> guest 侧 pkvm_virt_mmio()
        -> 本地 allowlist 命中判断
            -> raw MMIO 或 hypercall MMIO
```

## 关键源码入口

- guest 发现并初始化 pKVM 服务
  - `refs/android-kernel-common/drivers/firmware/smccc/kvm_guest.c`
  - `refs/android-kernel-common/arch/arm64/include/asm/hypervisor.h`
  - `refs/android-kernel-common/drivers/virt/coco/pkvm-guest/arm-pkvm-guest.c`
- arm64 `ioremap()` hook
  - `refs/android-kernel-common/arch/arm64/mm/ioremap.c`
  - `refs/android-kernel-common/arch/arm64/include/asm/io.h`
- arm64 pKVM guest hypercall ABI
  - `refs/android-kernel-common/include/linux/arm-smccc.h`
  - `refs/android-kernel-common/Documentation/virt/kvm/arm/hypercalls.rst`
- 运行期 stage-2 abort / MMIO emulation
  - `refs/android-kernel-common/arch/arm64/kvm/handle_exit.c`
  - `refs/android-kernel-common/arch/arm64/kvm/mmu.c`
  - `refs/android-kernel-common/arch/arm64/kvm/mmio.c`

## 1. 启动期：guest 先发现 hyp 服务，再决定要不要启用 MMIO guard hook

arm64 guest 侧的起点不是 MMIO 本身，而是先做 hypervisor service discovery。

`drivers/firmware/smccc/kvm_guest.c` 的 `kvm_init_hyp_services()` 会：

- 检查当前 conduit 是不是 `HVC`
- 调 `ARM_SMCCC_VENDOR_HYP_CALL_UID_FUNC_ID` 确认对端是 KVM vendor service
- 调 `ARM_SMCCC_VENDOR_HYP_KVM_FEATURES_FUNC_ID` 拿一张 feature bitmap
- 最后调用 `kvm_arch_init_hyp_services()`

而 `arch/arm64/include/asm/hypervisor.h` 里，arm64 的 `kvm_arch_init_hyp_services()` 会进一步调用：

- `pkvm_init_hyp_services()`

真正的 protected guest 初始化逻辑在：

- `refs/android-kernel-common/drivers/virt/coco/pkvm-guest/arm-pkvm-guest.c`

这里的 `pkvm_init_hyp_services()` 先检查：

- `ARM_SMCCC_KVM_FUNC_HYP_MEMINFO`
- 然后根据 feature bitmap 决定是否注册 `MEM_SHARE / MEM_UNSHARE`

然后再做两件事：

1. 用 `ARM_SMCCC_VENDOR_HYP_KVM_HYP_MEMINFO_FUNC_ID` 查询 pKVM granule 大小
2. 记录 `pkvm_func_range = !!res.a1`，表示是否支持 range 型 hypercall

若 `MEM_SHARE` 和 `MEM_UNSHARE` 都存在，则注册：

- `arm64_mem_crypt_ops`

最后，只有在 `ARM_SMCCC_KVM_FUNC_MMIO_GUARD_MAP` 存在、且 `__dram_is_aligned(pkvm_granule)` 成立时，才会进一步注册：

- `arm64_ioremap_prot_hook_register(&mmio_guard_ioremap_hook)`

也就是说，ARM 的 MMIO guard hook 不是无条件存在的全局逻辑，而是：

- 先发现 hypercall feature
- 再按 feature 与 DRAM 对齐条件，有条件地接管 `ioremap()` 建图路径

## 2. 映射期：真正的“允许 MMIO”动作发生在 ioremap hook

### 2.1 `ioremap_prot()` 预留了一个机密计算用的 hook 点

`arch/arm64/mm/ioremap.c` 里很关键的一点是：

- `arm64_ioremap_prot_hook_register()` 可以注册一个全局 hook
- `ioremap_prot()` 在真正执行 `generic_ioremap_prot()` 前，会先调用这个 hook

也就是说，ARM 把“某段 guest physical / IPA 是否需要额外的 hyp 处理”这个决策点，放在了映射建立时，而不是每次 MMIO load/store 时。

### 2.2 `mmio_guard_ioremap_hook()` 只处理 device 属性映射

`drivers/virt/coco/pkvm-guest/arm-pkvm-guest.c` 的 `mmio_guard_ioremap_hook()` 会先检查：

- `pgprot` 是否等于 `PROT_DEVICE_nGnRE`
- 或 `PROT_DEVICE_nGnRnE`

如果不是 device 属性映射，就直接返回，不介入。

这说明 ARM 这套机制的目标很明确：

- 不是给所有 `ioremap()` 做统一白名单
- 而是只给“guest 明确以 device attribute 建图的 MMIO 区间”打 guard

### 2.3 guard 的粒度不是“整段一次”，而是按 granule 发 `MMIO_RGUARD_MAP / MMIO_GUARD_MAP`

`mmio_guard_ioremap_hook()` 的实现是：

- 先把起始/结束地址按页对齐
- 再进一步按 `pkvm_granule` 向下/向上扩展
- 最后调用 `arm_smccc_do_range()`

其中选择的 hypercall 是：

- 支持 range 时：`ARM_SMCCC_VENDOR_HYP_KVM_MMIO_RGUARD_MAP_FUNC_ID`
- 否则：`ARM_SMCCC_VENDOR_HYP_KVM_MMIO_GUARD_MAP_FUNC_ID`

对应 ABI 常量定义在：

- `refs/android-kernel-common/include/linux/arm-smccc.h`

对应文档语义在：

- `refs/android-kernel-common/Documentation/virt/kvm/arm/hypercalls.rst`

结合 `mmio-guard.rst` 和 `hypercalls.rst`，这里更准确的表述应当是：

- `ARM_SMCCC_KVM_FUNC_MMIO_GUARD_MAP` / `ARM_SMCCC_KVM_FUNC_MMIO_RGUARD_MAP`：请求 hypervisor 把一段 IPA 区间按 MMIO 处理
- 这会让该区间进入“只允许作为 MMIO 被处理”的语义；若访问落到 emulation 路径，可由 KVM host / in-kernel handler 处理
- 它们本身不等价于“这段 IPA 已经获得 trusted passthrough 直通授权”

因此，单从当前本地源码和 ABI 文档可以确认：

- ARM 这条线的“允许 MMIO”不是 guest 本地缓存一张 allowlist 后在访问点软件判断
- 而是 guest 在建图时通过 hypercall 把 IPA 区间注册给 hyp

## 3. 运行期：guest 仍然执行原生 MMIO load/store

这一步和当前 x86 最不一样。

在 ARM 上，`arch/arm64/include/asm/io.h` 里的 `__raw_read* / __raw_write*` 仍然是直接生成：

- `ldr`
- `str`
- `ldrb`
- `strb`
- `ldrh`
- `strh`

也就是说，ARM 运行期没有一个像 `pKVM-IA/arch/x86/coco/pkvm/pkvm.c` 里 `pkvm_virt_mmio()` 那样的 guest 侧总分流器。

更准确地说，ARM 的思路是：

- 建图时用 `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` 告诉 hyp：这段 IPA 是 MMIO
- 运行时 guest 继续走正常的 MMIO 指令路径
- 如果访问顺利命中已有 stage-2 / device 映射，就直接完成
- 如果访问触发 fault，再由 KVM/EL2 的 fault path 决定怎么处理

## 4. 运行期 fault path：stage-2 abort 决定是 RAM 还是 MMIO

### 4.1 指令 / 数据 abort 都统一进 `kvm_handle_guest_abort()`

`arch/arm64/kvm/handle_exit.c` 明确把：

- `ESR_ELx_EC_IABT_LOW`
- `ESR_ELx_EC_DABT_LOW`

都分发给：

- `kvm_handle_guest_abort()`

所以 ARM 运行期真正的“二次判定点”在 abort/fault 路径，而不是 guest `readl/writel` 的调用包装。

### 4.2 `kvm_handle_guest_abort()` 先看 memslot/writable，再决定走补映射还是 MMIO 路径

`arch/arm64/kvm/mmu.c` 里的 `kvm_handle_guest_abort()` 会做几层区分：

- translation / permission / access-flag fault 才继续处理
- nested 场景先解 L2 IPA -> L1 IPA
- 再用 `gfn_to_memslot_prot()` 取 `memslot` 和 `writable`

这里真正决定“大方向分流”的条件其实很具体：

- 若 `!memslot`
- 或这是 write fault，但 `!writable`

就直接走：

- `io_mem_abort()`

也就是说，这条分支的源码语义更接近：

- “这次 IPA 没有合适的可写 memslot backing，可以按 MMIO / invalid-backing fault 去处理”

而不是先拿到 `pfn` 以后再去区分。

相反，只有当：

- 这次 IPA 确实命中了一个可用的 `memslot`
- 并且写访问也满足 `writable`

才会进入“memslot-backed 补映射”那条线。

对 protected VM，命中 memslot-backed 路径后，外层先走的是：

- `pkvm_mem_abort_prefault()`

再往下会进入 pVM 自己的补映射逻辑；而在这条 memslot-backed 路径里，才会进一步通过：

- `__gfn_to_pfn_memslot()`
- `kvm_is_device_pfn()`

去区分：

- 这是普通 RAM PFN
- 还是 device-backed PFN

如果 `pfn` 被识别成 device PFN，就会把 stage-2 map 的 `prot` 补上 `KVM_PGTABLE_PROT_DEVICE`；否则默认按 normal memory 处理。

所以更准确地说，源码里的判定顺序是：

```text
先看 memslot / writable
    -> 决定走 io_mem_abort() 还是 memslot-backed 补映射路径

进入 memslot-backed 路径后再看 pfn
    -> 决定 stage-2 map 最终带 normal 属性还是 device 属性
```

### 4.3 真正的 MMIO emulation 入口是 `io_mem_abort()`

如果 `kvm_handle_guest_abort()` 发现：

- `hva` 出错
- 或写 fault 但宿主 backing 不可写

它会把这次访问交给：

- `io_mem_abort(vcpu, ipa)`

`arch/arm64/kvm/mmio.c` 里的 `io_mem_abort()` 会：

1. 先从 syndrome 里解码出读/写、宽度、寄存器号
2. 优先尝试 `kvm_io_bus_write()` / `kvm_io_bus_read()` 的内核态 emulation
3. 如果内核态没接住，则构造 `KVM_EXIT_MMIO` 返回 userspace

不过它也有一个对 protected VM 很重要的分支：

- 如果 syndrome 本身无效，`vcpu_is_protected(vcpu)` 时，不再把问题抛给 userspace 兜底，而是直接给 guest 注入 abort

这说明 ARM protected VM 虽然仍可走 MMIO emulation fault path，但并不是“任何异常形态都还能交给 userspace 慢慢猜”。

### 4.4 `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` 在 pVM 慢路径里到底在哪里生效

前面如果只看 host 侧的 `kvm_handle_guest_abort()` / `io_mem_abort()`，确实不容易一眼看出 `MMIO_GUARD_MAP` 的作用，因为它的关键消费点其实更早，发生在 pVM 从 hyp 退出到 host 之前。

更准确地说，链路是：

```text
guest ioremap(device IPA)
    -> mmio_guard_ioremap_hook()
        -> arm_smccc_do_range(MMIO_GUARD_MAP / MMIO_RGUARD_MAP, ...)
            -> HVC 进入 pKVM hyp
                -> pkvm_install_ioguard_page()
                    -> __pkvm_install_ioguard_page()
                        -> kvm_pgtable_stage2_annotate(..., KVM_INVALID_PTE_MMIO_NOTE)
                                                   (把这段 IPA 在 pVM stage-2 里标成 ioguard/MMIO 注记)

guest 后续访问该 IPA 触发 DABT
    -> handle_pvm_exit_dabt()
        -> __pkvm_check_ioguard_page()
            -> 读取 fault IPA 对应 leaf
            -> 检查它是不是 KVM_INVALID_PTE_MMIO_NOTE
```

如果命中 ioguard 注记：

- hyp 会保留 host 继续做 MMIO decode / emulate 所需的 syndrome 信息

如果没命中 ioguard 注记：

- hyp 会清掉 `ESR_ELx_ISV`
- 后面 host 侧即使进了 `io_mem_abort()`，也会因为 protected VM 上 syndrome 无效而直接给 guest 注入 abort，而不是把它当成合法 MMIO 去 emulate

所以 `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` 的真正作用不是“直接建好 MMIO 直通映射”，而是：

- 先在 hyp 的 stage-2 里给这段 IPA 打上 `KVM_INVALID_PTE_MMIO_NOTE`
- 让后续这段地址的 DABT 能被认定为“合法 MMIO fault”
- 从而允许 host/KVM 继续走 `io_mem_abort()` 的 MMIO emulation 语义

这里如果只从“帮助理解主流程”的角度看，其实没必要显式暴露 `mmio_needed` 这个变量名。它只是 hyp 和 host 之间传递“这次 MMIO 是否还能继续 emulate”的一个内部状态位；对主流程真正重要的是：

- ioguard 命中：保留合法 MMIO fault 所需信息
- ioguard 不命中：让这次 fault 在 pVM 上失去 MMIO emulate 资格

换句话说，它控制的是：

- “这次 fault 有没有资格被当成 MMIO 处理”

而不是：

- “这次访问是不是立即直通成功”

## 5. 对照 x86：为什么说 ARM 更像“映射期 guard + 运行期 abort”

如果把当前 `refs/android-kernel-common` 里的 ARM 参考实现和当前本地 x86 并排看，差异会很明显：


| 维度         | ARM pKVM                                                 | 当前 x86 pKVM                                  |
| -------------- | ---------------------------------------------------------- | ------------------------------------------------ |
| guest 初始化 | 发现 SMCCC hypercall 服务，按 feature 注册`ioremap` hook | 启动早期拉一份 allowlist                       |
| 判定时机     | `ioremap()` 建图时发 `MMIO_GUARD_MAP / MMIO_RGUARD_MAP`  | 每次`pkvm_virt_mmio()` 访问时本地查 allowlist  |
| 运行期访问   | 继续原生`__raw_read* / __raw_write*`                     | guest 侧总入口先软件分流                       |
| 运行期异常   | `kvm_handle_guest_abort()` -> `io_mem_abort()`           | `PKVM_GHC_IOREAD/IOWRITE` 直接 forward to host |
| 主要控制对象 | IPA / stage-2 / device attribute / abort path            | guest 本地缓存的 GPA allowlist                 |

所以用一句话总结就是：

- ARM 的核心不是“每次访问都查一张 guest 本地表”
- ARM 的核心是“先在映射时把 MMIO IPA 告诉 hyp，运行期继续走正常 CPU MMIO 路径；只有 fault 时才进入 stage-2 / emulation 分支”

## 6. 当前本地源码能确认到哪里，哪里还只是推断

### 已确认

下面这些结论可以直接从当前本地源码确认：

- guest 启动时会先做 SMCCC feature discovery，再进入 `pkvm_init_hyp_services()`
- `pkvm_init_hyp_services()` 会在 `MMIO_GUARD_MAP` 可用且 DRAM 对齐时注册 `arm64_ioremap_prot_hook_register()`
- `mmio_guard_ioremap_hook()` 只对 device 属性映射生效
- `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` 这组 ABI 的语义是“让该 IPA 区间按 MMIO 处理，允许 emulation 路径消费”
- 运行期 guest 仍然使用 arm64 原生 `__raw_read* / __raw_write*`
- abort 最终统一进 `kvm_handle_guest_abort()`，MMIO fault 会进 `io_mem_abort()`
- `DEV_REQ_MMIO` 是另一层 ABI；文档语义是它成功后，对该 IPA 的访问会经 `stage-2` 直达，且不再退出到 host

### 推断

下面这点在当前本地树里没有找到一个单独的 EL2 实现文件把内部数据结构完全展开，所以属于“基于源码和 ABI 文档的高置信度推断”：

- `MMIO_GUARD_MAP / MMIO_RGUARD_MAP` 在 hyp 侧应当会把对应 IPA 区间标记成某种“按 MMIO 处理 / 可 emulation”的状态，使后续访问走 stage-2 fault + MMIO emulation 语义
- 若某个设备页后续还走 trusted passthrough 直通，则还需要叠加 `DEV_REQ_MMIO` 这一层校验 / 授权语义

之所以这样推断，是因为：

- guest 侧 hook 明确会在建图时发 `MMIO_GUARD_MAP / MMIO_RGUARD_MAP`
- ABI 文档明确说它会让 hypervisor 把 region handled as MMIO
- 而运行期又没有看到一个等价于 x86 `pkvm_virt_mmio()` 的 guest 侧每次访问包装器

所以从当前树能得到的最稳妥表述就是：

- ARM 当前更像“映射期 guard + 运行期 stage-2 abort/emulation”
- 不是“每次访问都 guest 本地查 allowlist”
- 也不是“首次 trap 后长期 direct-map”

## 对当前 x86 设计调研的启发

这条 ARM 路径对当前 x86 allowlist 讨论，至少有 3 个直接启发：

1. “允许 MMIO”这件事不一定非得落在 guest 每次访问的软件热路径上，也可以落在建图时和 fault path。
2. ARM 的对照提醒我们：如果未来 x86 真要做 fault-path authorize / trap-once 方案，那就已经不是“改 allowlist 字段”这么简单，而是要补一整条 CPU fault + revoke + invalidate 状态机。
3. 当前 x86 allowlist 更接近“guest 本地静态直达提示”；ARM 这条线则更接近“映射期注册 MMIO 语义，运行期由 stage-2 / abort path 消费”。

因此，把 ARM 作为对照时，最准确的借鉴点不是“照搬 device assignment 细节”，而是：

- 决策点放在哪一层
- MMIO 语义是建图时注册，还是访问时软件判断
- 运行期到底依赖 CPU fault path，还是依赖 guest wrapper
