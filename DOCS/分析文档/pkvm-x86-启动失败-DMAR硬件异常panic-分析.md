排查类日志默认用“必出”的 pkvm_info() / pkvm_err()（对应 pr_info/pr_err）

# pKVM-IA（pkvm-x86）在虚拟机里启动失败：`DMAR hardware is malfunctioning` panic 分析

更新时间：2026-02-03  
适用范围：本仓库 `pKVM-IA` + `linux` 树，运行在 **KVM 虚拟机**（QEMU `-machine q35`）里，并在 Guest 内核中启用 `kvm-intel.pkvm=1`。

## 现象概述

启动日志在早期初始化阶段触发 panic：

```

[    0.905884] pkvm_host_deprivilege_cpu: CPU7 in guest mode
[    0.905890] pkvm_host_deprivilege_cpu: CPU15 in guest mode
[    0.905893] pkvm_host_deprivilege_cpu: CPU12 in guest mode
[    0.905894] pkvm_host_deprivilege_cpu: CPU13 in guest mode
[    0.905894] pkvm_host_deprivilege_cpu: CPU3 in guest mode
[    0.905896] pkvm_host_deprivilege_cpu: CPU14 in guest mode
[    0.905903] pkvm_host_deprivilege_cpu: CPU6 in guest mode
[    0.905914] pkvm_host_deprivilege_cpu: CPU10 in guest mode
[    0.905915] pkvm_host_deprivilege_cpu: CPU22 in guest mode
[    0.905916] pkvm_host_deprivilege_cpu: CPU21 in guest mode
[    0.905917] pkvm_host_deprivilege_cpu: CPU25 in guest mode
[    0.905924] pkvm_host_deprivilege_cpu: CPU24 in guest mode
[    0.905929] pkvm_host_deprivilege_cpu: CPU11 in guest mode
[    0.905935] pkvm_host_deprivilege_cpu: CPU26 in guest mode
[    0.905939] pkvm_host_deprivilege_cpu: CPU23 in guest mode
[    0.905941] pkvm_host_deprivilege_cpu: CPU19 in guest mode
[    0.905942] pkvm_host_deprivilege_cpu: CPU16 in guest mode
[    0.905947] pkvm_host_deprivilege_cpu: CPU31 in guest mode
[    0.905949] pkvm_host_deprivilege_cpu: CPU28 in guest mode
[    0.905951] pkvm_host_deprivilege_cpu: CPU30 in guest mode
[    0.906060] pkvm_host_deprivilege_cpu: CPU18 in guest mode
[    0.906080] pkvm_host_deprivilege_cpu: CPU29 in guest mode
[    0.906080] pkvm_host_deprivilege_cpu: CPU17 in guest mode
[    0.906091] pkvm_host_deprivilege_cpu: CPU20 in guest mode
[    0.906091] pkvm_host_deprivilege_cpu: CPU27 in guest mode
[    0.906163] pkvm_host_deprivilege_cpu: CPU8 in guest mode
[    0.937981] pkvm_host_deprivilege_cpus: all cpus are in guest mode!
[    1.005921] pkvm: about to init IOMMU: enable_pkvm=1 pkvm_enabled=1 ret=0
[    1.007163] DMAR: No RMRR found
[    1.007799] DMAR: No SATC found
[    1.008440] DMAR: dmar0: Using Queued invalidation
[    1.009384] DMAR: pkvm-debug: iommu0 set_root_entry: pkvm_enabled=1 enable_pkvm=1 tsc_khz=2800000 timeout_cycles=28000000000
[    1.011332] DMAR: pkvm: host pkvm_writeq offset=0x20 phys=0xfed90020 val=0x102a4f000
[    1.012328] pkvm: iommu0: RTADDR write 0x102a4f000
[    1.012328] DMAR: pkvm: host pkvm_writel offset=0x18 phys=0xfed90018 val=0x46000000
[    1.012328] pkvm: iommu0: GCMD write 0x46000000 (gsts=0x7000000 rta=0x102a4f000)
[    1.012328] pkvm: iommu0: SRTP request (gsts=0x7000000 rta=0x102a4f000)
[    1.012328] pkvm: handle_gcmd_srtp: iommu0 failed to activate(err=-12)
[    1.012328] DMAR: pkvm-debug: IOMMU_WAIT_OP timeout: iommu0 off=0x1c sts=0x7000000 pkvm_enabled=1 enable_pkvm=1 tsc_khz=2800000 timeout_cycles=28000000000 elapsed_cycles=28000013138
[    1.012328] Kernel panic - not syncing: DMAR hardware is malfunctioning
[    1.012328] CPU: 0 UID: 0 PID: 1 Comm: swapper/0 Not tainted 6.12.0-pkvm-ia #24
[    1.012328] Hardware name: QEMU Standard PC (Q35 + ICH9, 2009), BIOS 1.16.3-debian-1.16.3-2 04/01/2014
[    1.012328] Call Trace:
[    1.012328]  <TASK>
[    1.012328]  dump_stack_lvl+0x27/0xa0
[    1.012328]  dump_stack+0x10/0x20
[    1.012328]  panic+0x36f/0x400
[    1.012328]  iommu_set_root_entry+0x31f/0x330
[    1.012328]  intel_iommu_init+0x426/0x10d0
[    1.012328]  ? vprintk_default+0x1d/0x30
[    1.012328]  ? vprintk+0x30/0x80
[    1.012328]  ? _printk+0x60/0x90
[    1.012328]  vmx_pkvm_init+0x5f9/0xf40
[    1.012328]  vmx_init+0x32/0x2d0
[    1.012328]  ? __pfx_vmx_init+0x10/0x10
[    1.012328]  do_one_initcall+0x5e/0x340
[    1.012328]  kernel_init_freeable+0x353/0x520
[    1.012328]  ? __pfx_kernel_init+0x10/0x10
[    1.012328]  kernel_init+0x1b/0x200
[    1.012328]  ret_from_fork+0x47/0x70
[    1.012328]  ? __pfx_kernel_init+0x10/0x10
[    1.012328]  ret_from_fork_asm+0x1a/0x30
[    1.012328]  </TASK>
[    1.012328] ---[ end Kernel panic - not syncing: DMAR hardware is malfunctioning ]---

```

- panic 信息：`Kernel panic - not syncing: DMAR hardware is malfunctioning`
- 调用栈关键路径（从日志提取）：
  - `vmx_init()`
  - `vmx_pkvm_init()`
  - `intel_iommu_init()`
  - `iommu_set_root_entry()`
  - `IOMMU_WAIT_OP()` -> `panic("DMAR hardware is malfunctioning\n")`

本次问题发生在 **Intel VT-d（DMAR/IOMMU）驱动等待硬件完成“设置 Root Table 指针（SRTP）”流程时超时**，属于 IOMMU 初始化失败导致的直接 panic。

## 源码级流程还原（缩进版流程梳理）

你日志里最容易困惑的一点是（也是这次分析要回答的核心问题）：

- 先看到 `pkvm_host_deprivilege_cpu: CPUxx in guest mode` / `all cpus are in guest mode!`
- 然后才看到 `DMAR: ...`，最后 panic

这在 pKVM-IA 的代码里是 **刻意安排的初始化顺序**：当 `kvm-intel.pkvm=1` 时，Intel IOMMU 的初始化从正常的 `x86_init.iommu.iommu_init` 路径 **改道到 `vmx_pkvm_init()`** 里执行，顺序上就是“先 pkvm、再 IOMMU”。关键流程如下（模仿你给的缩进风格，尽量只保留关键节点/关键判断）：

```text
vmx_init
  vmx_pkvm_init
    pkvm_iommu_driver_prepare
      dmar_table_init

    __vmx_pkvm_init
      check_and_init_iommu
        for_each_drhd_unit(drhd)
          read DMAR_GSTS/RTADDR/CAP/ECAP
          check queued invalidation, etc.

      pkvm_host_deprivilege_cpus
        on_each_cpu(pkvm_host_deprivilege_cpu)
          pkvm_host_init_vmx
          local_deprivilege_cpu
            这个函数里：除了把当前CPU降级为vmx-nonroot模式，其他的内核堆栈都保持不变。
            也就是说后续的执行都是处于non-root模式的Host内核执行了
          pr_info "CPU%d in guest mode"
        pr_info "all cpus are in guest mode!"

    pkvm_iommu_driver_init
      intel_iommu_init
        iommu_set_root_entry
          dmar_writeq(DMAR_RTADDR_REG, addr)
          dmar_writel(DMAR_GCMD_REG, ...|SRTP) // 这里其实是non root内核执行的，然后会触发VM exit
            pkvm_writel
                pkvm_hypercall(iommu_mmio_access, false, sizeof(u32),
                   reg_phys + offset, (u64)val);
          IOMMU_WAIT_OP(..., DMAR_GSTS_REG, (sts & RTPS))
            while (1) {
                dmar_readl(iommu, DMAR_GSTS_REG); 
                // 多次循环仍然读不到，直到超时
                timeout -> panic("DMAR hardware is malfunctioning")

// 上面的dmar_xxx函数会向pkvm发起一个hypercall
#define dmar_readq(iommu, o)        pkvm_readq((iommu)->reg, (iommu)->reg_phys, o)
#define dmar_writeq(iommu, o, v)    pkvm_writeq((iommu)->reg, (iommu)->reg_phys, o, v)
#define dmar_readl(iommu, o)        pkvm_readl((iommu)->reg, (iommu)->reg_phys, o)
#define dmar_writel(iommu, o, v)    pkvm_writel((iommu)->reg, (iommu)->reg_phys, o, v)

上面的dmar_writel(DMAR_GCMD_REG)会导致vmexit到pkvm
handle_vmcall
    case __pkvm__iommu_mmio_access:
        pkvm_access_iommu
            access_iommu_mmio
                case DMAR_GCMD_REG:
                    handle_global_cmd
                        if (val & DMA_GCMD_SRTP)
                            handle_gcmd_srtp(iommu);
```

对应的流程解释（每段代码块下面用 `-` 描述“这一步在做什么”）：

• dmar_table_init：获取并解析ACPI提供的DMAR表，创建内核中的IOMMU管理结构，进而掌握IOMMU信息、硬件拓扑（各个IOMMU管理的PCI设备）
    ◦ 当遇到 DRHD 结构时，它会分配内存创建一个内核结构体（struct dmar_drhd_unit）来代表这个硬件单元，并将其加入到一个全局链表中
    ◦ 当遇到 RMRR 结构时，记录保留内存信息
• check_and_init_iommu：遍历刚刚发现的 drhd 单元，去读取IOMMU的硬件寄存器（DMAR_GSTS, RTADDR 等）以获取IOMMU的状态。
    ◦ 这些寄存器有些是即可写有可读的，这里只会进行读。
    ◦ DMAR_RTADDR (Root Table Address Register)：告诉 IOMMU 硬件根表（Root Table）的物理地址在哪里，向这个寄存器写入就是设置IOMMU root table地址
    ◦ DMAR_GSTS (Global Status Register)：报告 IOMMU 硬件当前的状态。内含多个bit位：
        ▪ TES (Translation Enable Status): 这里的位如果是 1，表示 DMA 重映射功能已经开启。
        ▪ RTPS (Root Table Pointer Status):
            • 当你往 RTADDR 寄存器写了新地址，并向 GCMD 寄存器发送“更新根表指针”的命令后，你需要轮询（Poll）这个 RTPS 位。
            • 当 GSTS 中的 RTPS 变为 1，表示 IOMMU 硬件已经成功加载并缓存了你刚才设置的 RTADDR，配置生效了。
        ▪ IRES (Interrupt Remapping Enable Status): 表示中断重映射是否开启。
• pkvm_host_deprivilege_cpus：将所有CPU降级到VMX non-root
    ◦ pkvm_host_init_vmx：给这个 CPU 准备好 VMX 环境
    ◦ local_deprivilege_cpu：执行 VMLAUNCH，真正把当前 CPU 从root切到non-root
        ▪ 此时的Guest RIP被设为了vmwrite GUEST_RIP = &host_vm_entry_point
        ▪ HOST_RIP被设为了__pkvm_vmexit_entry
    ◦ 后续一旦发生 VMEXIT，会跳到 pKVM 的 __pkvm_vmexit_entry
• pkvm_iommu_driver_init：调用Intel IOMMU启动初始化IOMMU。
    ◦ 在pkvm-x86中，是将Host降级后，再初始化IOMMU。具体初始化IOMMU的代码本身是直接使用的Intel的IOMMU驱动代码。只不过和非虚拟化场景相比，初始化时机变了而已。
    ◦ iommu_set_root_entry：设置IOMMU root table
        ▪ dmar_writeq(DMAR_RTADDR_REG, addr)：写根表物理地址
        ▪ dmar_writel(DMAR_GCMD_REG, ...|SRTP)：通知IOMMU root table地址已经写入，硬件可以进行加载生效了
        ▪ IOMMU_WAIT_OP(..., DMAR_GSTS_REG, (sts & RTPS))：轮询 GSTS，直到 RTPS 位被置 1，表示root table已经在硬件设置完毕，已经生效。


关键点只剩两个（都能直接从源码看出来）：

```text
关键点 A：IOMMU init 被 pkvm “改道”
  detect_intel_iommu
    __setup_iommu_init_hooks
      if enable_pkvm:
        pkvm_iommu_register_driver {prepare=dmar_table_init, init=intel_iommu_init}
        x86_init.iommu.iommu_init = intel_iommu_init_nop

关键点 B：因此会出现“先降权、后 IOMMU”
  vmx_pkvm_init
    __vmx_pkvm_init -> pkvm_host_deprivilege_cpus  (打印 all cpus are in guest mode!)
    pkvm_iommu_driver_init -> intel_iommu_init     (随后进入 DMAR/IOMMU 初始化)
```

- 关键点 A 的含义：当 pkvm 启用时，IOMMU 驱动不会在“传统 x86 启动流程”里初始化，而是注册到 pkvm 的 driver 回调里，由 pkvm 选择时机触发。
- 关键点 B 的含义：pkvm 先把 host “降权成 guest”，再调用 `intel_iommu_init()`；所以你日志里看到“CPU in guest mode”在前，“DMAR/IOMMU init”在后。

panic 点也可以用一句话概括：

```text
iommu_set_root_entry() 写 SRTP 后等待 RTPS 置位超时 -> IOMMU_WAIT_OP() 直接 panic
  iommu_set_root_entry
    IOMMU_WAIT_OP
      timeout (DMAR_OPERATION_TIMEOUT ~= 10s)
```

- `iommu_set_root_entry()` 是 Intel IOMMU 初始化中非常早的一步（设置 root table 地址并触发 SRTP）。
- `IOMMU_WAIT_OP()` 是“硬等待”：超过 `DMAR_OPERATION_TIMEOUT` 就直接 `panic()`，因此你会看到非常明确的 `DMAR hardware is malfunctioning`。

## Host “降权/降级”(deprivilege) 到底是怎么做的（源码梳理，缩进 + 对应说明）

这一段就是你圈出来的 `pkvm_host_deprivilege_cpus -> pkvm_host_deprivilege_cpu -> local_deprivilege_cpu`，它的本质是：

- **把“正在跑的 host 内核”包装成一个 VM 的 guest**（VMX non-root）
- **把 pKVM hypervisor 作为 VMX root 的 host**（VMExit 入口指向 pkvm 代码）

对应代码链路（只列关键点）：

```text
pkvm_host_deprivilege_cpus                   (pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c:1079)
  on_each_cpu(pkvm_host_deprivilege_cpu)
    enable_feature_control
    pkvm_host_init_vmx
      pkvm_enable_vmx -> vmxon
      vmcs_load(vmcs01)
      init_guest_state_area_from_native
      init_host_state_area
        HOST_RIP = __pkvm_vmexit_entry
    local_deprivilege_cpu
      vmwrite GUEST_RFLAGS = 当前 RFLAGS
      vmwrite GUEST_RSP    = 当前 RSP
      vmwrite GUEST_RIP    = host_vm_entry_point(label)
      vmlaunch
      host_vm_entry_point: (从这里继续执行，但此时已在 VMX non-root)
    pr_info "CPU%d in guest mode"
  pr_info "all cpus are in guest mode!"
```

对应说明（按上面的缩进顺序）：

- `pkvm_host_init_vmx`：为“把 host 变成 guest”准备 VMX 环境（VMXON + 分配/加载 VMCS）。
- `init_guest_state_area_from_native`：把**当前 CPU 的原生寄存器/段寄存器/描述符表/MSR 等状态**写进 VMCS 的 `GUEST_*` 字段；也就是说，“guest 初始状态 = 现在这颗 CPU 正在运行的 host 内核状态”。
- `init_host_state_area`：把 VMExit 的 `HOST_*` 字段指向 pkvm 的入口（`HOST_RIP = __pkvm_vmexit_entry` 等）；也就是说，一旦 guest 发生 VMExit，就会跳回 pkvm（VMX root）代码处理。
- `local_deprivilege_cpu`：用 `vmwrite` 填 `GUEST_RIP/RSP/RFLAGS`，然后 `vmlaunch` 进入 VMX non-root：
  - `GUEST_RIP` 被设置成 `host_vm_entry_point` 这个 **label**，它就在 `local_deprivilege_cpu()` 的内联汇编里。
  - 因此 `vmlaunch` 成功后，CPU 会在 non-root 下从 `host_vm_entry_point` 继续执行；紧接着 `local_deprivilege_cpu()` 返回到 C 代码，后续启动流程仍然跑同一套内核，只是“已经是 guest 了”。
- `vcpu->mode = IN_GUEST_MODE`：只是软件状态标记，表明这颗 CPU 已经处在 deprivileged 的运行态（并非触发降权的关键指令）。

## 复现场景（你当前的关键配置）

### Guest 内核命令行（摘录）

- `kvm-intel.pkvm=1`
- `intel_iommu=sm_on`

说明：
- `kvm-intel.pkvm=1`：启用 pKVM-IA（Intel x86 host deprivilege 路径）。
- `intel_iommu=sm_on`：请求启用 Intel IOMMU 的 **scalable mode**（若平台支持）。

### QEMU 启动命令（摘录）

你提供的启动参数里，与本次 panic 关系最强的是：

- `-accel kvm`
- `-cpu host,+vmx,...`
- `-device intel-iommu,aw-bits=48,device-iotlb=on`

这表示：你暴露了一个 *虚拟* Intel IOMMU（QEMU emulation），同时 Guest 内核会把它当作真实 VT-d 来初始化。

## 关键日志 -> 源码点（缩进版）

把你日志里最关键的几行，直接映射回源码“发生了什么/在哪发生”：

```text
DMAR: Enable scalable mode if hardware supports
  intel_iommu_setup("sm_on")
    intel_iommu_sm = 1

pkvm_host_deprivilege_cpu: CPU%d in guest mode
pkvm_host_deprivilege_cpus: all cpus are in guest mode!
  pkvm_host_deprivilege_cpus
    on_each_cpu(pkvm_host_deprivilege_cpu)
      local_deprivilege_cpu -> VMX non-root

DMAR: dmar0: Using Queued invalidation
  intel_iommu_init
    (初始化阶段探测 ECAP/CAP 后选择 queued invalidation)

Kernel panic: DMAR hardware is malfunctioning
  iommu_set_root_entry
    IOMMU_WAIT_OP(... (sts & RTPS) ...)
      timeout -> panic()
```

（注）`IOMMU_WAIT_OP` 的超时阈值来自 `DMAR_OPERATION_TIMEOUT`，默认约 10 秒。

- `Enable scalable mode if hardware supports`：仅表示命令行解析阶段把 `intel_iommu_sm` 置为 1（“请求 scalable mode”），不代表 IOMMU 初始化完成。
- `CPU%d in guest mode` / `all cpus are in guest mode!`：表示 deprivilege 已经完成，CPU 进入 VMX non-root，host 内核此后以“guest”的身份继续跑。
- `Using Queued invalidation`：说明 `intel_iommu_init()` 已经开始探测/选择能力路径，并启用了 queued invalidation（ECAP.QI*）。
- `DMAR hardware is malfunctioning`：实际触发点是 SRTP 等待 RTPS 超时，属于“硬件/设备侧状态位不按期望变化”的表现。

## Debug 建议（最小变量排查，缩进版）

目标：先把问题切成两类——“vIOMMU/特性组合不支持” vs “pkvm deprivilege 后访问/时序导致异常”。

```text
实验 1：只验证 vIOMMU（关 pkvm）
  cmdline: kvm-intel.pkvm=0 intel_iommu=sm_on
  解释：如果这里也卡在 SRTP/RTPS，优先怀疑 QEMU 的 intel-iommu/scalable mode 行为
  实验结果：能正常启动。日志如下：
  ```
mrgeek@ubuntu-vm:~/pkvm-x86$ sudo dmesg | egrep -i 'DMAR|IOMMU'
[    0.000000] Command line: BOOT_IMAGE=/vmlinuz-6.12.0-pkvm-ia root=UUID=0905329d-4022-4692-bb5d-b614c117dd8c ro console=tty1 console=ttyS0 kvm-intel.pkvm=0 intel_iommu=on
[    0.005226] ACPI: DMAR 0x000000007FFE2E68 000090 (v01 BOCHS  BXPC     00000001 BXPC 00000001)
[    0.005234] ACPI: Reserving DMAR table memory at [mem 0x7ffe2e68-0x7ffe2ef7]
[    0.053974] Kernel command line: BOOT_IMAGE=/vmlinuz-6.12.0-pkvm-ia root=UUID=0905329d-4022-4692-bb5d-b614c117dd8c ro console=tty1 console=ttyS0 kvm-intel.pkvm=0 intel_iommu=on
[    0.054054] DMAR: IOMMU enabled
[    0.274996] DMAR: Host address width 48
[    0.275655] DMAR: DRHD base: 0x000000fed90000 flags: 0x0
[    0.276523] DMAR: dmar0: reg_base_addr fed90000 ver 1:0 cap d2008c222f0606 ecap f00f5e
[    0.277746] DMAR: ATSR flags: 0x1
[    0.278326] DMAR-IR: IOAPIC id 0 under DRHD base  0xfed90000 IOMMU 0
[    0.279306] DMAR-IR: Queued invalidation will be enabled to support x2apic and Intr-remapping.
[    0.281463] DMAR-IR: Enabled IRQ remapping in x2apic mode
[    0.691763] iommu: Default domain type: Translated
[    0.691763] iommu: DMA domain TLB invalidation policy: lazy mode
[    0.920796] DMAR: No RMRR found
[    0.921191] DMAR: No SATC found
[    0.921193] DMAR: dmar0: Using Queued invalidation
[    0.921374] pci 0000:00:00.0: Adding to iommu group 0
[    0.926145] pci 0000:00:01.0: Adding to iommu group 1
[    0.927036] pci 0000:00:02.0: Adding to iommu group 2
[    0.927910] pci 0000:00:03.0: Adding to iommu group 3
[    0.928792] pci 0000:00:04.0: Adding to iommu group 4
[    0.929680] pci 0000:00:1f.0: Adding to iommu group 5
[    0.930571] pci 0000:00:1f.2: Adding to iommu group 5
[    0.931464] pci 0000:00:1f.3: Adding to iommu group 5
[    0.938371] DMAR: Intel(R) Virtualization Technology for Directed I/O
  ```

实验 2：只验证 pkvm（关 IOMMU）
  cmdline: kvm-intel.pkvm=1 intel_iommu=off   (或 iommu=off)
  解释：确认 deprivilege 后系统能否继续启动（排除 pkvm 自身更早期的问题）
  实验结果：可以启动，dmesg能发现PKVM日志：
  ```
mrgeek@ubuntu-vm:~$ sudo dmesg | grep pkvm
[    0.000000] Linux version 6.12.0-pkvm-ia (mrgeek@ubuntu-vm) (gcc (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0, GNU ld (GNU Binutils for Ubuntu) 2.42) #18 SMP PREEMPT_DYNAMIC Mon Feb  2 08:49:21 UTC 2026
[    0.000000] Command line: BOOT_IMAGE=/vmlinuz-6.12.0-pkvm-ia root=UUID=0905329d-4022-4692-bb5d-b614c117dd8c ro kvm-intel.pkvm=1 intel_iommu=off console=tty1 console=ttyS0 kvm-intel.pkvm=1 intel_iommu=off
[    0.058353] Kernel command line: BOOT_IMAGE=/vmlinuz-6.12.0-pkvm-ia root=UUID=0905329d-4022-4692-bb5d-b614c117dd8c ro kvm-intel.pkvm=1 intel_iommu=off console=tty1 console=ttyS0 kvm-intel.pkvm=1 intel_iommu=off
[    0.058483] Unknown kernel command line parameters "BOOT_IMAGE=/vmlinuz-6.12.0-pkvm-ia", will be passed to user space.
[    0.909810] pkvm: mitigated CPU bug spectre_v1
[    0.910514] pkvm: cannot mitigate CPU bug spectre_v2
[    0.911277] pkvm: mitigated CPU bug spec_store_bypass
[    0.912056] pkvm: mitigated CPU bug swapgs
[    0.912702] pkvm: cannot mitigate CPU bug bhi
[    0.913391] pkvm: unmitigated cpu bug spectre_v2
[    0.914096] pkvm: unmitigated cpu bug taa
[    0.914728] pkvm: unmitigated cpu bug eibrs_pbrsb
[    0.915463] pkvm: unmitigated cpu bug bhi
[    0.916104] pkvm: unmitigated cpu bug ibpb_no_ret
[    0.916826] pkvm: unmitigated cpu bug its
[    0.917470] pkvm: in total has 6 unmitigated cpu bugs
[    0.918244] pkvm: allow pkvm to run with unmitigated CPU bugs
[    0.919108] pkvm: to prevent pkvm running on such CPU, reboot with kvm-intel.pkvm_relax_cpu_bugs=false
[    0.920690] pkvm_host_deprivilege_cpu: CPU0 in guest mode
[    0.920690] pkvm_host_deprivilege_cpu: CPU3 in guest mode
[    0.920703] pkvm_host_deprivilege_cpu: CPU31 in guest mode
[    0.920706] pkvm_host_deprivilege_cpu: CPU28 in guest mode
[    0.920706] pkvm_host_deprivilege_cpu: CPU24 in guest mode
[    0.920713] pkvm_host_deprivilege_cpu: CPU2 in guest mode
[    0.921022] pkvm_host_deprivilege_cpu: CPU4 in guest mode
[    0.921025] pkvm_host_deprivilege_cpu: CPU5 in guest mode
[    0.921033] pkvm_host_deprivilege_cpu: CPU6 in guest mode
[    0.921033] pkvm_host_deprivilege_cpu: CPU11 in guest mode
[    0.921038] pkvm_host_deprivilege_cpu: CPU9 in guest mode
[    0.921039] pkvm_host_deprivilege_cpu: CPU8 in guest mode
[    0.921038] pkvm_host_deprivilege_cpu: CPU10 in guest mode
[    0.921039] pkvm_host_deprivilege_cpu: CPU7 in guest mode
[    0.921050] pkvm_host_deprivilege_cpu: CPU29 in guest mode
[    0.921060] pkvm_host_deprivilege_cpu: CPU18 in guest mode
[    0.921065] pkvm_host_deprivilege_cpu: CPU25 in guest mode
[    0.921066] pkvm_host_deprivilege_cpu: CPU20 in guest mode
[    0.921066] pkvm_host_deprivilege_cpu: CPU12 in guest mode
[    0.921067] pkvm_host_deprivilege_cpu: CPU17 in guest mode
[    0.921067] pkvm_host_deprivilege_cpu: CPU16 in guest mode
[    0.921068] pkvm_host_deprivilege_cpu: CPU21 in guest mode
[    0.921069] pkvm_host_deprivilege_cpu: CPU13 in guest mode
[    0.921072] pkvm_host_deprivilege_cpu: CPU19 in guest mode
[    0.921072] pkvm_host_deprivilege_cpu: CPU30 in guest mode
[    0.921072] pkvm_host_deprivilege_cpu: CPU22 in guest mode
[    0.921072] pkvm_host_deprivilege_cpu: CPU15 in guest mode
[    0.921075] pkvm_host_deprivilege_cpu: CPU14 in guest mode
[    0.921103] pkvm_host_deprivilege_cpu: CPU26 in guest mode
[    0.921108] pkvm_host_deprivilege_cpu: CPU27 in guest mode
[    0.921182] pkvm_host_deprivilege_cpu: CPU23 in guest mode
[    0.921182] pkvm_host_deprivilege_cpu: CPU1 in guest mode
[    0.953528] pkvm_host_deprivilege_cpus: all cpus are in guest mode!
[    1.007623] IOMMU initialization failed. Disabling pkvm!
[    1.011275] pkvm_host_reprivilege_cpu: CPU0 back in host mode
[    1.012205] pkvm_host_reprivilege_cpu: CPU1 back in host mode
[    1.013270] pkvm_host_reprivilege_cpu: CPU2 back in host mode
[    1.014346] pkvm_host_reprivilege_cpu: CPU3 back in host mode
[    1.015440] pkvm_host_reprivilege_cpu: CPU4 back in host mode
[    1.016789] pkvm_host_reprivilege_cpu: CPU5 back in host mode
[    1.018166] pkvm_host_reprivilege_cpu: CPU6 back in host mode
[    1.019775] pkvm_host_reprivilege_cpu: CPU7 back in host mode
[    1.021660] pkvm_host_reprivilege_cpu: CPU8 back in host mode
[    1.024037] pkvm_host_reprivilege_cpu: CPU9 back in host mode
[    1.026509] pkvm_host_reprivilege_cpu: CPU10 back in host mode
[    1.029727] pkvm_host_reprivilege_cpu: CPU11 back in host mode
[    1.033195] pkvm_host_reprivilege_cpu: CPU12 back in host mode
[    1.036676] pkvm_host_reprivilege_cpu: CPU13 back in host mode
[    1.040016] pkvm_host_reprivilege_cpu: CPU14 back in host mode
[    1.043310] pkvm_host_reprivilege_cpu: CPU15 back in host mode
[    1.046562] pkvm_host_reprivilege_cpu: CPU16 back in host mode
[    1.049713] pkvm_host_reprivilege_cpu: CPU17 back in host mode
[    1.053172] pkvm_host_reprivilege_cpu: CPU18 back in host mode
[    1.056645] pkvm_host_reprivilege_cpu: CPU19 back in host mode
[    1.060032] pkvm_host_reprivilege_cpu: CPU20 back in host mode
[    1.063326] pkvm_host_reprivilege_cpu: CPU21 back in host mode
[    1.066464] pkvm_host_reprivilege_cpu: CPU22 back in host mode
[    1.069530] pkvm_host_reprivilege_cpu: CPU23 back in host mode
[    1.072526] pkvm_host_reprivilege_cpu: CPU24 back in host mode
[    1.073973] pkvm_host_reprivilege_cpu: CPU25 back in host mode
[    1.076518] pkvm_host_reprivilege_cpu: CPU26 back in host mode
[    1.078964] pkvm_host_reprivilege_cpu: CPU27 back in host mode
[    1.080011] pkvm_host_reprivilege_cpu: CPU28 back in host mode
[    1.081382] pkvm_host_reprivilege_cpu: CPU29 back in host mode
[    1.084285] pkvm_host_reprivilege_cpu: CPU30 back in host mode
[    1.087109] pkvm_host_reprivilege_cpu: CPU31 back in host mode
[    1.366948]     BOOT_IMAGE=/vmlinuz-6.12.0-pkvm-ia
  ```

实验 3：pkvm + 禁用 scalable mode（验证是否是 sm_on 触发）
  cmdline: kvm-intel.pkvm=1 intel_iommu=on,sm_off
  解释：如果 sm_off 能过而 sm_on 不行，基本坐实是 scalable mode 路径不兼容
  实验结果：不断是否开启sm，都是崩溃。

增强可观测性（不改代码）
  cmdline: loglevel=8 ignore_loglevel initcall_debug nokaslr

增强可观测性（改代码，收益最大）
  在 iommu_set_root_entry / IOMMU_WAIT_OP 超时前打印
    DMAR_GSTS / DMAR_GCMD / DMAR_RTADDR (+ 可能的 FSTS 等错误位)
  解释：拿到寄存器快照后可以判断“写入不生效/状态位不变/错误位触发”
```

## 当前阶段可以写进结论的要点

- **Host 是否已经被降级/降权？**  
  是。`pkvm_host_deprivilege_cpus: all cpus are in guest mode!` 是强证据。

- **panic 发生在降权前还是降权后？**  
  发生在降权后：先打印 `CPUxx in guest mode` / `all cpus are in guest mode!`，后进入 `intel_iommu_init()` 并在 `iommu_set_root_entry()` 超时 panic。

- **panic 的本质是什么？**  
  Intel IOMMU 驱动在 SRTP 流程里等待硬件置位状态位超时；在你的场景下“硬件”实际上是 QEMU emulated 的 `intel-iommu` 设备（vIOMMU）
