# ARM pKVM 设备 BAR / MMIO donate 机制总结

## 目的

这份文档只回答一个问题：

- ARM pKVM 在“把设备 BAR / MMIO 交给 protected VM”这件事上，设计上到底是怎么做的？

它主要服务于当前 x86 侧的：

- `pkvm-x86#34`
- `T12 / B5-3`：assigned BAR 的 Host CPU 访问权收口

本文默认只分析当前仓库中的 ARM 参考实现：

- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/mem_protect.c`
- `refs/android-kernel-common/Documentation/virt/kvm/arm/hypercalls.rst`

除非特别说明，下文讨论的是 **device BAR / MMIO 资源的 ownership 与映射状态机**，不是泛泛而谈所有 guest MMIO 访问。

## 先说结论

ARM pKVM 对设备 BAR / MMIO 的设计，不是“直接把 Host 的一段 MMIO donate 给 Guest 就结束”，而是更接近下面这条状态机：

```text
Host
    --(pkvm_device_hyp_assign_mmio)-->
Hyp
    --(pkvm_host_map_guest_mmio / pkvm_hyp_donate_guest)-->
Guest
    --(teardown / reclaim)-->
Host
```

核心结论有四条：

1. **设备 MMIO 走的是 `Host -> Hyp -> Guest`**
   - ARM 没有把设备 BAR 直接塞进普通 RAM donate 的 `Host -> Guest` 主链。
   - 它为设备单独做了一条 MMIO assignment 路径。
2. **Hyp 之所以先成为中间 owner，是为了拿到一个“Host 和 Guest 都暂时不能碰设备”的窗口**
   - 这样 hyp 才能原子地做 reset、DMA block、IOMMU group assign、失败回滚。
3. **Host 侧的“fault 后自动 remap”是靠 host stage-2 owner 注记拦住的**
   - 不是靠一张临时 denylist 硬编码地址。
4. **普通 RAM donation 与设备 MMIO donation 是两条不同语义的路径**
   - ARM 的普通 RAM 仍然基本是 `Host -> Guest`。
   - 真正需要 `Host -> Hyp -> Guest` 中转的，是设备 MMIO / 设备 assignment 这类资源。

## 核心对象与状态

ARM 设备 assignment 的状态，不是散落在 guest fault 路径里，而是集中挂在 `struct pkvm_device` 上：

- `registered_devices`：hyp 持有的设备清单
- `resources[]`：设备资源区间，含 MMIO / BAR 基址与大小
- `group_id`：IOMMU group 粒度的归属单位
- `ctxt`：当前属于哪个 VM
- `refcount`：设备上下文引用计数
- `device_spinlock`：把 MMIO state、IOMMU state、`ctxt` 变更绑成一个原子临界区

相关源码：

- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`

其中 `device_spinlock` 上方的注释已经直接写明了设计目标：**MMIO state / IOMMU 变更必须和 device context 原子一致**。

## 主流程

### 1. Host 先把设备 MMIO 交给 Hyp

入口是 `pkvm_device_hyp_assign_mmio()`：

- 先用 `pkvm_get_device(phys, size)` 做 **资源级精确匹配**
- 只有该 `addr + size` 正好命中某个已注册 device resource 时才继续
- 若设备已经有 `ctxt` 或 `refcount`，直接拒绝
- 然后调用：
  - `___pkvm_host_donate_hyp_prot(pfn, nr_pages, true, PAGE_HYP_DEVICE)`

这里最关键的点是：

- `accept_mmio=true`
  - 表示这条 donate 路径明确接受 MMIO，不再受“只允许普通内存”的限制
- `PAGE_HYP_DEVICE`
  - 表示 Hyp 自己对这段资源按 device/MMIO 语义持有

对应源码：

- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/device/device.c`
  - `pkvm_device_hyp_assign_mmio()`
- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/mem_protect.c`
  - `___pkvm_host_donate_hyp_prot()`
  - `__pkvm_host_donate_hyp_locked()`

这一步结束后，关键不是“Hyp 只是知道这块 BAR”，而是 **Host 对这段 MMIO 的 owner 已经不再是 Host**。

### 2. Host owner 如何被收走

真正收走 Host owner 的动作在：

- `__pkvm_host_donate_hyp_locked()`
  - `host_stage2_set_owner_locked(phys, size, PKVM_ID_HYP)`

而 `host_stage2_set_owner_locked()` 的语义是：

- 如果 owner 变回 `PKVM_ID_HOST`，就按默认 host 权限重新建 host stage-2 映射
- 如果 owner 不是 Host，就不建正常映射，而是在 host stage-2 里留下 **invalid leaf annotation**

对应实现：

- `__host_stage2_set_owner_locked()`
  - `owner_id == PKVM_ID_HOST` 时走 `host_stage2_idmap_locked()`
  - 否则走 `kvm_pgtable_stage2_annotate(...)`

也就是说，ARM 不是简单“unmap 了就算完”，而是把“这段地址现在归谁”写进 host stage-2 里。

## 为什么 Host fault 不会自动把 BAR map 回去

这正是 ARM 对当前 x86 `#34` 最有价值的地方。

ARM host 侧 fault 主链大致是：

```text
Host data abort
    -> handle_host_mem_abort()
        -> host_stage2_idmap(addr)
            -> host_stage2_adjust_range(addr, &range)
                -> 若 leaf PTE 无效但 annotation 非 0
                    -> return -EPERM
        -> host_inject_abort()
```

相关源码：

- `refs/android-kernel-common/arch/arm64/kvm/hyp/nvhe/mem_protect.c`
  - `handle_host_mem_abort()`
  - `host_stage2_idmap()`
  - `host_stage2_adjust_range()`
  - `__host_stage2_set_owner_locked()`

关键点在 `host_stage2_adjust_range()`：

- 如果 leaf PTE 已经是 invalid
- 但 invalid PTE 里带着 owner annotation
- 那就返回 `-EPERM`
- 后面的 `handle_host_mem_abort()` 会给 Host 注入 abort，而不是偷偷重新 `idmap`

所以 ARM 拦住“Host fault 触发后把 MMIO 自动 map 回去”的方式，不是：

- “这段地址在黑名单里，拒绝 remap”

而是：

- “host stage-2 里已经明确记录：这段资源 owner 不是 Host，因此 Host 没资格 remap”

这就是为什么 ARM 的 deny-remap 逻辑比“地址匹配 + fault 特判”更稳。

## 3. 首次给 Guest 时，不是直接单页 map，而是先完成整组 assignment

Host 真正要把设备 BAR 暴露给 Guest 时，入口是：

- `pkvm_host_map_guest_mmio()`

这条路径不是“拿到一个 BAR page 就直接塞给 guest”，而是：

```text
pkvm_host_map_guest_mmio()
    -> pkvm_get_device_by_addr()
    -> 若 dev->ctxt == NULL
        -> __pkvm_group_assign(dev->group_id, vm)
            -> 对整个 group 内设备逐个 __pkvm_device_assign()
                -> hyp_check_range_owned()
                -> pkvm_device_reset(dev, true)
                -> kvm_iommu_dev_block_dma(..., host_to_guest=true)
                -> dev->ctxt = vm
    -> __pkvm_install_guest_mmio()
        -> __pkvm_remove_ioguard_page()
        -> pkvm_hyp_donate_guest()
```

这里体现出三个设计点：

1. **先 group assign，再 guest map**
   - 不是单 BAR、单页、单次 fault 各做各的。
2. **先确认资源已归 Hyp**
   - `__pkvm_device_assign()` 里先 `hyp_check_range_owned(res->base, res->size)`。
3. **在 Guest 可见前先做 reset + block DMA**
   - `pkvm_device_reset(dev, true)` 会调 reset handler
   - 然后对设备关联 IOMMU endpoint 执行 `kvm_iommu_dev_block_dma(...)`

这就是 ARM 里 “Hyp 成为中间 owner / arbiter” 的真正价值：

- 不是为了多一层抽象而多一层抽象
- 而是为了在 **Guest 真正摸到 BAR 之前**，先把设备切到一个受控状态

## 4. Hyp 再把 MMIO 交给 Guest

完成 group assign 后，真正把 MMIO page 交给 guest 的是：

- `__pkvm_install_guest_mmio()`
  - `__pkvm_remove_ioguard_page(vm, ipa)`
  - `pkvm_hyp_donate_guest(hyp_vcpu, pfn, gfn)`

`pkvm_hyp_donate_guest()` 的关键语义是：

- 先检查这页当前确实由 Hyp 持有
- 再检查 guest IPA 位置当前是 `PKVM_NOPAGE`
- 把这页从 Hyp 自己的页表里撤掉
- 再把物理页装进 guest stage-2

这说明 ARM 设备 MMIO 的真正“给 guest”动作，发生在：

- **先 Host -> Hyp**
- **再 Hyp -> Guest**

而不是一步到位 `Host -> Guest`。

## 5. Guest 还可以做设备身份验证

除了 ownership/mapping 之外，ARM 还给了一个额外能力：

- `ARM_SMCCC_KVM_FUNC_DEV_REQ_MMIO`

`hypercalls.rst` 明确说明了它的语义：

- 必须先把对应 IPA 标成 MMIO
- 之后 guest 按页请求验证
- hyp 返回一个 token
- guest / pvmfw 用这个 token 对照受信设备描述做验证
- 调用成功后，该 IPA 的访问会通过 stage-2，不再 exit 到 host

对应实现入口是：

- `pkvm_device_request_mmio()`

它会：

- 先通过 `pkvm_get_guest_pa_request()` 找到该 IPA 对应的 token
- 再检查 token 是否落在 **当前 `dev->ctxt == vm` 的设备资源区间**
- 命中才返回成功

这一步说明 ARM 不仅在做“谁能 map”，还在做“guest 看到的这页 MMIO 到底是不是它那台设备的资源”的受信校验。

## 6. teardown / reclaim 如何回到 Host

ARM 的回收也不是简单 “guest unmap 后 host 再 map 一次”。

两条主要路径是：

1. VM teardown：
   - `pkvm_devices_teardown(vm)`
   - 对 `dev->ctxt == vm` 的设备：
     - `pkvm_device_reset(dev, false)`
     - `dev->ctxt = NULL`
     - `pkvm_devices_reclaim_device(dev)`
       - `host_stage2_set_owner_locked(res->base, res->size, PKVM_ID_HOST)`
2. 启动失败 / VM 未真正拿到设备时的 host reclaim：
   - `pkvm_device_reclaim_mmio()`
   - 内部走 `__pkvm_hyp_donate_host()`

也就是说，ARM 回收路径恢复的不只是映射，还恢复了：

- owner
- device reset state
- DMA block / IOMMU 视角

## 与普通 RAM donate 的区别

这点对当前 x86 特别重要。

ARM 普通 RAM 路径的代表函数是：

- `__pkvm_host_donate_guest()`

它的语义非常直接：

- `___host_check_page_state_range(..., HOST_CHECK_IS_MEMORY)`
- `__host_set_owner_guest(...)`
- `kvm_pgtable_stage2_map(&vm->pgt, ...)`

也就是说，对普通 RAM：

- 它要求 **必须是普通内存**
- owner 直接从 Host 切到 Guest
- 不需要长期经过一个 “Hyp 持有设备所有权” 的中转态

而设备 MMIO 路径则不同：

- 允许 MMIO：`accept_mmio=true`
- 先 `Host -> Hyp`
- 再 `Hyp -> Guest`
- 并且和 reset / DMA block / IOMMU group 一起变更

所以从 ARM 参考实现来看，结论很明确：

- **普通 RAM donate** 可以是 `Host -> Guest`
- **设备 BAR / MMIO donate** 更适合建成 `Host -> Hyp -> Guest`

## 对当前 x86 `#34` 的直接启发

基于 ARM 参考，当前 x86 这条线至少能得到四个直接结论：

1. **Host EPT fault deny-remap 的更强终态应是“owner state 拒绝 remap”**
   - 不是只靠地址命中后特判拒绝。
2. **revoke 范围应绑定到“当前已 attach / 已 revoke 的 ptdev BAR”**
   - 不应扩大成“manifest 里出现过的所有设备 BAR”。
3. **如果后续要覆盖 reset、DMA quiesce、IOMMU group 原子切换、失败 rollback**
   - 那么 x86 会自然逼近 ARM 这套 device state machine。
4. **不要把 BAR/MMIO 问题继续塞回普通 RAM donate 主链**
   - ARM 已经把两类资源清楚地区分成两条语义不同的路径。

## 当前可直接复用到 x86 的设计抽象

如果只抽象设计，不要求一字不差照搬 ARM 代码，那么 ARM 给 x86 的核心启发可以收敛成下面这段：

```text
ptdev BAR / MMIO
    需要独立 ownership 状态
        -> Host 拥有
        -> Host revoke / Hyp 持有
        -> Guest 持有
        -> teardown / rollback 回 Host

Host fault deny-remap
    应该读取 ownership 状态
        -> owner 不是 Host
            -> 拒绝 remap
        -> owner 是 Host
            -> 允许恢复 host mapping

device assignment
    应与 reset / DMA block / IOMMU state 原子切换
```

这比“attach 时 unmap 一下 + fault 时黑名单拦一下 + detach 时再 map 回去”更接近 ARM 的根本设计。
