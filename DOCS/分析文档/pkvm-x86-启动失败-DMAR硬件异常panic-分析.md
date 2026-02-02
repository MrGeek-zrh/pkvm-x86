# pKVM-IA（pkvm-x86）在虚拟机里启动失败：`DMAR hardware is malfunctioning` panic 分析

更新时间：2026-02-03  
适用范围：本仓库 `pKVM-IA` + `linux` 树，运行在 **KVM 虚拟机**（QEMU `-machine q35`）里，并在 Guest 内核中启用 `kvm-intel.pkvm=1`。

## 现象概述

启动日志在早期初始化阶段触发 panic：

```
Loading initial ramdisk ...Loading initial ramdisk ..
.
[    0.000000] Linux version 6.12.0-pkvm-ia (mrgeek@ubuntu-vm) (gcc (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0, GNU ld (GNU Binutils for Ubuntu) 2.42) #18 SMP PREEMPT_DYNAMIC Mon Feb  2 08:49:21 UTC 2026
[    0.000000] Command line: BOOT_IMAGE=/vmlinuz-6.12.0-pkvm-ia root=UUID=0905329d-4022-4692-bb5d-b614c117dd8c ro kvm-intel.pkvm=1 intel_iommu=sm_on console=tty1 console=ttyS0 kvm-intel.pkvm=1 intel_iommu=sm_on
[    0.000000] KERNEL supported cpus:
[    0.000000]   Intel GenuineIntel
[    0.000000]   AMD AuthenticAMD
[    0.000000]   Hygon HygonGenuine
[    0.000000]   Centaur CentaurHauls
[    0.000000]   zhaoxin   Shanghai
[    0.000000] x86/split lock detection: #DB: warning on user-space bus_locks
[    0.000000] BIOS-provided physical RAM map:
[    0.000000] BIOS-e820: [mem 0x0000000000000000-0x000000000009fbff] usable
[    0.000000] BIOS-e820: [mem 0x000000000009fc00-0x000000000009ffff] reserved
[    0.000000] BIOS-e820: [mem 0x00000000000f0000-0x00000000000fffff] reserved
[    0.000000] BIOS-e820: [mem 0x0000000000100000-0x000000007ffdbfff] usable
[    0.000000] BIOS-e820: [mem 0x000000007ffdc000-0x000000007fffffff] reserved
[    0.000000] BIOS-e820: [mem 0x00000000b0000000-0x00000000bfffffff] reserved
[    0.000000] BIOS-e820: [mem 0x00000000fed1c000-0x00000000fed1ffff] reserved
[    0.000000] BIOS-e820: [mem 0x00000000feffc000-0x00000000feffffff] reserved
[    0.000000] BIOS-e820: [mem 0x00000000fffc0000-0x00000000ffffffff] reserved
[    0.000000] BIOS-e820: [mem 0x0000000100000000-0x000000057fffffff] usable
[    0.000000] NX (Execute Disable) protection: active
[    0.000000] APIC: Static calls initialized
[    0.000000] SMBIOS 3.0.0 present.
[    0.000000] DMI: QEMU Standard PC (Q35 + ICH9, 2009), BIOS 1.16.3-debian-1.16.3-2 04/01/2014
[    0.000000] DMI: Memory slots populated: 2/2
[    0.000000] Hypervisor detected: KVM
[    0.000000] kvm-clock: Using msrs 4b564d01 and 4b564d00
[    0.000001] kvm-clock: using sched offset of 3168377607342 cycles
[    0.000002] clocksource: kvm-clock: mask: 0xffffffffffffffff max_cycles: 0x1cd42e4dffb, max_idle_ns: 881590591483 ns
[    0.000006] tsc: Detected 2800.000 MHz processor
[    0.001119] last_pfn = 0x580000 max_arch_pfn = 0x10000000000
[    0.001169] MTRR map: 4 entries (3 fixed + 1 variable; max 19), built from 8 variable MTRRs
[    0.001173] x86/PAT: Configuration [0-7]: WB  WC  UC- UC  WB  WP  UC- WT
[    0.001233] last_pfn = 0x7ffdc max_arch_pfn = 0x10000000000
[    0.006366] found SMP MP-table at [mem 0x000f5470-0x000f547f]
[    0.006381] Using GB pages for direct mapping
[    0.006462] RAMDISK: [mem 0x321c9000-0x350dbfff]
[    0.006465] ACPI: Early table checksum verification disabled
[    0.006468] ACPI: RSDP 0x00000000000F5250 000014 (v00 BOCHS )
[    0.006472] ACPI: RSDT 0x000000007FFE2F20 00003C (v01 BOCHS  BXPC     00000001 BXPC 00000001)
[    0.006478] ACPI: FACP 0x000000007FFE2B90 0000F4 (v03 BOCHS  BXPC     00000001 BXPC 00000001)
[    0.006483] ACPI: DSDT 0x000000007FFE0040 002B50 (v01 BOCHS  BXPC     00000001 BXPC 00000001)
[    0.006486] ACPI: FACS 0x000000007FFE0000 000040
[    0.006488] ACPI: APIC 0x000000007FFE2C84 000170 (v03 BOCHS  BXPC     00000001 BXPC 00000001)
[    0.006491] ACPI: HPET 0x000000007FFE2DF4 000038 (v01 BOCHS  BXPC     00000001 BXPC 00000001)
[    0.006494] ACPI: MCFG 0x000000007FFE2E2C 00003C (v01 BOCHS  BXPC     00000001 BXPC 00000001)
[    0.006496] ACPI: DMAR 0x000000007FFE2E68 000090 (v01 BOCHS  BXPC     00000001 BXPC 00000001)
[    0.006499] ACPI: WAET 0x000000007FFE2EF8 000028 (v01 BOCHS  BXPC     00000001 BXPC 00000001)
[    0.006501] ACPI: Reserving FACP table memory at [mem 0x7ffe2b90-0x7ffe2c83]
[    0.006502] ACPI: Reserving DSDT table memory at [mem 0x7ffe0040-0x7ffe2b8f]
[    0.006503] ACPI: Reserving FACS table memory at [mem 0x7ffe0000-0x7ffe003f]
[    0.006504] ACPI: Reserving APIC table memory at [mem 0x7ffe2c84-0x7ffe2df3]
[    0.006505] ACPI: Reserving HPET table memory at [mem 0x7ffe2df4-0x7ffe2e2b]
[    0.006506] ACPI: Reserving MCFG table memory at [mem 0x7ffe2e2c-0x7ffe2e67]
[    0.006506] ACPI: Reserving DMAR table memory at [mem 0x7ffe2e68-0x7ffe2ef7]
[    0.006507] ACPI: Reserving WAET table memory at [mem 0x7ffe2ef8-0x7ffe2f1f]
[    0.006878] No NUMA configuration found
[    0.006879] Faking a node at [mem 0x0000000000000000-0x000000057fffffff]
[    0.006887] NODE_DATA(0) allocated [mem 0x57ffd5680-0x57fffffff]
[    0.007358] Zone ranges:
[    0.007359]   DMA      [mem 0x0000000000001000-0x0000000000ffffff]
[    0.007361]   DMA32    [mem 0x0000000001000000-0x00000000ffffffff]
[    0.007362]   Normal   [mem 0x0000000100000000-0x000000057fffffff]
[    0.007363]   Device   empty
[    0.007364] Movable zone start for each node
[    0.007367] Early memory node ranges
[    0.007367]   node   0: [mem 0x0000000000001000-0x000000000009efff]
[    0.007369]   node   0: [mem 0x0000000000100000-0x000000007ffdbfff]
[    0.007370]   node   0: [mem 0x0000000100000000-0x000000057fffffff]
[    0.007372] Initmem setup node 0 [mem 0x0000000000001000-0x000000057fffffff]
[    0.007383] On node 0, zone DMA: 1 pages in unavailable ranges
[    0.007445] On node 0, zone DMA: 97 pages in unavailable ranges
[    0.075182] On node 0, zone Normal: 36 pages in unavailable ranges
[    0.075608] ACPI: PM-Timer IO Port: 0x608
[    0.075629] ACPI: LAPIC_NMI (acpi_id[0xff] dfl dfl lint[0x1])
[    0.075703] IOAPIC[0]: apic_id 0, version 32, address 0xfec00000, GSI 0-23
[    0.075706] ACPI: INT_SRC_OVR (bus 0 bus_irq 0 global_irq 2 dfl dfl)
[    0.075708] ACPI: INT_SRC_OVR (bus 0 bus_irq 5 global_irq 5 high level)
[    0.075709] ACPI: INT_SRC_OVR (bus 0 bus_irq 9 global_irq 9 high level)
[    0.075710] ACPI: INT_SRC_OVR (bus 0 bus_irq 10 global_irq 10 high level)
[    0.075711] ACPI: INT_SRC_OVR (bus 0 bus_irq 11 global_irq 11 high level)
[    0.075715] ACPI: Using ACPI (MADT) for SMP configuration information
[    0.075716] ACPI: HPET id: 0x8086a201 base: 0xfed00000
[    0.075719] TSC deadline timer available
[    0.075723] CPU topo: Max. logical packages:   1
[    0.075724] CPU topo: Max. logical dies:       1
[    0.075725] CPU topo: Max. dies per package:   1
[    0.075729] CPU topo: Max. threads per core:   1
[    0.075730] CPU topo: Num. cores per package:    32
[    0.075731] CPU topo: Num. threads per package:  32
[    0.075731] CPU topo: Allowing 32 present CPUs plus 0 hotplug CPUs
[    0.075758] PM: hibernation: Registered nosave memory: [mem 0x00000000-0x00000fff]
[    0.075760] PM: hibernation: Registered nosave memory: [mem 0x0009f000-0x0009ffff]
[    0.075761] PM: hibernation: Registered nosave memory: [mem 0x000a0000-0x000effff]
[    0.075761] PM: hibernation: Registered nosave memory: [mem 0x000f0000-0x000fffff]
[    0.075762] PM: hibernation: Registered nosave memory: [mem 0x7ffdc000-0x7fffffff]
[    0.075763] PM: hibernation: Registered nosave memory: [mem 0x80000000-0xafffffff]
[    0.075764] PM: hibernation: Registered nosave memory: [mem 0xb0000000-0xbfffffff]
[    0.075765] PM: hibernation: Registered nosave memory: [mem 0xc0000000-0xfed1bfff]
[    0.075765] PM: hibernation: Registered nosave memory: [mem 0xfed1c000-0xfed1ffff]
[    0.075766] PM: hibernation: Registered nosave memory: [mem 0xfed20000-0xfeffbfff]
[    0.075767] PM: hibernation: Registered nosave memory: [mem 0xfeffc000-0xfeffffff]
[    0.075767] PM: hibernation: Registered nosave memory: [mem 0xff000000-0xfffbffff]
[    0.075768] PM: hibernation: Registered nosave memory: [mem 0xfffc0000-0xffffffff]
[    0.075770] [mem 0xc0000000-0xfed1bfff] available for PCI devices
[    0.075772] Booting paravirtualized kernel on KVM
[    0.075774] clocksource: refined-jiffies: mask: 0xffffffff max_cycles: 0xffffffff, max_idle_ns: 1910969940391419 ns
[    0.075779] kvm [0]: Reserved 146 MiB at 0x562c00000
[    0.075789] setup_percpu: NR_CPUS:8192 nr_cpumask_bits:32 nr_cpu_ids:32 nr_node_ids:1
[    0.081419] percpu: Embedded 96 pages/cpu s270336 r8192 d114688 u524288
[    0.081478] kvm-guest: PV spinlocks disabled, no host support
[    0.081482] Kernel command line: BOOT_IMAGE=/vmlinuz-6.12.0-pkvm-ia root=UUID=0905329d-4022-4692-bb5d-b614c117dd8c ro kvm-intel.pkvm=1 intel_iommu=sm_on console=tty1 console=ttyS0 kvm-intel.pkvm=1 intel_iommu=sm_on
[    0.081555] DMAR: Enable scalable mode if hardware supports
[    0.081610] DMAR: Enable scalable mode if hardware supports
[    0.081612] Unknown kernel command line parameters "BOOT_IMAGE=/vmlinuz-6.12.0-pkvm-ia", will be passed to user space.
[    0.081625] random: crng init done
[    0.088900] Dentry cache hash table entries: 4194304 (order: 13, 33554432 bytes, linear)
[    0.092506] Inode-cache hash table entries: 2097152 (order: 12, 16777216 bytes, linear)
[    0.093036] Fallback order for Node 0: 0
[    0.093041] Built 1 zonelists, mobility grouping on.  Total pages: 5242746
[    0.093042] Policy zone: Normal
[    0.093049] mem auto-init: stack:all(zero), heap alloc:on, heap free:off
[    0.093088] software IO TLB: area num 32.
[    0.186042] SLUB: HWalign=64, Order=0-3, MinObjects=0, CPUs=32, Nodes=1
[    0.186173] ftrace: allocating 58078 entries in 227 pages
[    0.198307] ftrace: allocated 227 pages with 5 groups
[    0.199224] Dynamic Preempt: voluntary
[    0.199527] rcu: Preemptible hierarchical RCU implementation.
[    0.199527] rcu:     RCU restricting CPUs from NR_CPUS=8192 to nr_cpu_ids=32.
[    0.199529]  Trampoline variant of Tasks RCU enabled.
[    0.199530]  Rude variant of Tasks RCU enabled.
[    0.199530]  Tracing variant of Tasks RCU enabled.
[    0.199531] rcu: RCU calculated value of scheduler-enlistment delay is 100 jiffies.
[    0.199532] rcu: Adjusting geometry for rcu_fanout_leaf=16, nr_cpu_ids=32
[    0.199572] RCU Tasks: Setting shift to 5 and lim to 1 rcu_task_cb_adjust=1 rcu_task_cpu_ids=32.
[    0.199578] RCU Tasks Rude: Setting shift to 5 and lim to 1 rcu_task_cb_adjust=1 rcu_task_cpu_ids=32.
[    0.199582] RCU Tasks Trace: Setting shift to 5 and lim to 1 rcu_task_cb_adjust=1 rcu_task_cpu_ids=32.
[    0.202458] NR_IRQS: 524544, nr_irqs: 680, preallocated irqs: 16
[    0.202841] rcu: srcu_init: Setting srcu_struct sizes based on contention.
[    0.216875] Console: colour VGA+ 80x25
[    0.216878] printk: legacy console [tty1] enabled
[    0.259214] printk: legacy console [ttyS0] enabled
[    0.386748] ACPI: Core revision 20240827
[    0.387734] clocksource: hpet: mask: 0xffffffff max_cycles: 0xffffffff, max_idle_ns: 19112604467 ns
[    0.389553] APIC: Switch to symmetric I/O mode setup
[    0.390510] DMAR: Host address width 48
[    0.391373] DMAR: DRHD base: 0x000000fed90000 flags: 0x0
[    0.392513] DMAR: dmar0: reg_base_addr fed90000 ver 1:0 cap d2008c222f0606 ecap f00f5e
[    0.394109] DMAR: ATSR flags: 0x1
[    0.394874] DMAR-IR: IOAPIC id 0 under DRHD base  0xfed90000 IOMMU 0
[    0.396119] DMAR-IR: Queued invalidation will be enabled to support x2apic and Intr-remapping.
[    0.399007] DMAR-IR: Enabled IRQ remapping in x2apic mode
[    0.400141] x2apic enabled
[    0.400899] APIC: Switched APIC routing to: cluster x2apic
[    0.406360] ..TIMER: vector=0x30 apic1=0 pin1=2 apic2=-1 pin2=-1
[    0.407706] clocksource: tsc-early: mask: 0xffffffffffffffff max_cycles: 0x285c40e2248, max_idle_ns: 440795340634 ns
[    0.409665] Calibrating delay loop (skipped) preset value.. 5600.00 BogoMIPS (lpj=2800000)
[    0.411234] x86/cpu: User Mode Instruction Prevention (UMIP) activated
[    0.413760] Last level iTLB entries: 4KB 0, 2MB 0, 4MB 0
[    0.414662] Last level dTLB entries: 4KB 0, 2MB 0, 4MB 0, 1GB 0
[    0.415674] Spectre V1 : Mitigation: usercopy/swapgs barriers and __user pointer sanitization
[    0.417071] Spectre V2 : Spectre BHI mitigation: SW BHB clearing on syscall and VM exit
[    0.418039] Spectre V2 : Mitigation: Enhanced / Automatic IBRS
[    0.418944] Spectre V2 : Spectre v2 / SpectreRSB mitigation: Filling RSB on context switch
[    0.420662] Spectre V2 : Spectre v2 / PBRSB-eIBRS: Retire a single CALL on VMEXIT
[    0.422030] Spectre V2 : mitigation: Enabling conditional Indirect Branch Prediction Barrier
[    0.423663] Speculative Store Bypass: Mitigation: Speculative Store Bypass disabled via prctl
[    0.425662] TAA: Mitigation: TSX disabled
[    0.426454] ITS: Mitigation: Aligned branch/return thunks
[    0.426976] x86/fpu: Supporting XSAVE feature 0x001: 'x87 floating point registers'
[    0.428049] x86/fpu: Supporting XSAVE feature 0x002: 'SSE registers'
[    0.428967] x86/fpu: Supporting XSAVE feature 0x004: 'AVX registers'
[    0.430662] x86/fpu: Supporting XSAVE feature 0x020: 'AVX-512 opmask'
[    0.431662] x86/fpu: Supporting XSAVE feature 0x040: 'AVX-512 Hi256'
[    0.432967] x86/fpu: Supporting XSAVE feature 0x080: 'AVX-512 ZMM_Hi256'
[    0.433981] x86/fpu: Supporting XSAVE feature 0x200: 'Protection Keys User registers'
[    0.435662] x86/fpu: Supporting XSAVE feature 0x20000: 'AMX Tile config'
[    0.436975] x86/fpu: Supporting XSAVE feature 0x40000: 'AMX Tile data'
[    0.437972] x86/fpu: xstate_offset[2]:  576, xstate_sizes[2]:  256
[    0.439662] x86/fpu: xstate_offset[5]:  832, xstate_sizes[5]:   64
[    0.440961] x86/fpu: xstate_offset[6]:  896, xstate_sizes[6]:  512
[    0.441962] x86/fpu: xstate_offset[7]: 1408, xstate_sizes[7]: 1024
[    0.442966] x86/fpu: xstate_offset[9]: 2432, xstate_sizes[9]:    8
[    0.444662] x86/fpu: xstate_offset[17]: 2496, xstate_sizes[17]:   64
[    0.445662] x86/fpu: xstate_offset[18]: 2560, xstate_sizes[18]: 8192
[    0.446961] x86/fpu: Enabled xstate features 0x602e7, context size is 10752 bytes, using 'compacted' format.
[    0.582940] Freeing SMP alternatives memory: 48K
[    0.583665] pid_max: default: 32768 minimum: 301
[    0.584828] LSM: initializing lsm=lockdown,capability,landlock,yama,apparmor,ima,evm
[    0.586120] landlock: Up and running.
[    0.586890] Yama: becoming mindful.
[    0.587999] AppArmor: AppArmor initialized
[    0.589170] Mount-cache hash table entries: 65536 (order: 7, 524288 bytes, linear)
[    0.590785] Mountpoint-cache hash table entries: 65536 (order: 7, 524288 bytes, linear)
[    0.593320] smpboot: CPU0: Intel INTEL(R) XEON(R) PLATINUM 8575C (family: 0x6, model: 0xcf, stepping: 0x2)
[    0.594456] Performance Events: PEBS fmt0-, Sapphire Rapids events, full-width counters, Intel PMU driver.
[    0.595115] ... version:                2
[    0.595902] ... bit width:              48
[    0.596664] ... generic registers:      8
[    0.597462] ... value mask:             0000ffffffffffff
[    0.597934] ... max period:             00007fffffffffff
[    0.598939] ... fixed-purpose events:   3
[    0.599664] ... event mask:             00000007000000ff
[    0.600842] signal: max sigframe size: 11952
[    0.601704] rcu: Hierarchical SRCU implementation.
[    0.602629] rcu:     Max phase no-delay instances is 400.
[    0.603008] Timer migration: 2 hierarchy levels; 8 children per group; 2 crossnode level
[    0.607573] smp: Bringing up secondary CPUs ...
[    0.608096] smpboot: x86: Booting SMP configuration:
[    0.608935] .... node  #0, CPUs:        #1  #2  #3  #4  #5  #6  #7  #8  #9 #10 #11 #12 #13 #14 #15 #16 #17 #18 #19 #20 #21 #22 #23 #24 #25 #26 #27 #28 #29 #30 #31
[    0.658876] smp: Brought up 1 node, 32 CPUs
[    0.660904] smpboot: Total of 32 processors activated (179200.00 BogoMIPS)
[    0.663203] Memory: 20234572K/20970984K available (22680K kernel code, 4746K rwdata, 8736K rodata, 5208K init, 6628K bss, 706908K reserved, 0K cma-reserved)
[    0.665267] devtmpfs: initialized
[    0.665953] x86/mm: Memory block size: 128MB
[    0.668782] clocksource: jiffies: mask: 0xffffffff max_cycles: 0xffffffff, max_idle_ns: 1911260446275000 ns
[    0.670265] futex hash table entries: 8192 (order: 7, 524288 bytes, linear)
[    0.671216] pinctrl core: initialized pinctrl subsystem
[    0.672096] PM: RTC time: 08:57:32, date: 2026-02-02
[    0.674166] NET: Registered PF_NETLINK/PF_ROUTE protocol family
[    0.676037] DMA: preallocated 4096 KiB GFP_KERNEL pool for atomic allocations
[    0.677934] DMA: preallocated 4096 KiB GFP_KERNEL|GFP_DMA pool for atomic allocations
[    0.679614] DMA: preallocated 4096 KiB GFP_KERNEL|GFP_DMA32 pool for atomic allocations
[    0.680098] audit: initializing netlink subsys (disabled)
[    0.681002] audit: type=2000 audit(1770022652.416:1): state=initialized audit_enabled=0 res=1
[    0.681002] thermal_sys: Registered thermal governor 'fair_share'
[    0.682090] thermal_sys: Registered thermal governor 'bang_bang'
[    0.682960] thermal_sys: Registered thermal governor 'step_wise'
[    0.683957] thermal_sys: Registered thermal governor 'user_space'
[    0.684967] thermal_sys: Registered thermal governor 'power_allocator'
[    0.685993] cpuidle: using governor ladder
[    0.687673] cpuidle: using governor menu
[    0.689059] acpiphp: ACPI Hot Plug PCI Controller Driver version: 0.5
[    0.690183] PCI: ECAM [mem 0xb0000000-0xbfffffff] (base 0xb0000000) for domain 0000 [bus 00-ff]
[    0.691093] PCI: ECAM [mem 0xb0000000-0xbfffffff] reserved as E820 entry
[    0.691992] PCI: Using configuration type 1 for base access
[    0.693491] kprobes: kprobe jump-optimization is enabled. All kprobes are optimized if possible.
[    0.695894] HugeTLB: registered 1.00 GiB page size, pre-allocated 0 pages
[    0.698413] HugeTLB: 16380 KiB vmemmap can be freed for a 1.00 GiB page
[    0.699975] HugeTLB: registered 2.00 MiB page size, pre-allocated 0 pages
[    0.700973] HugeTLB: 28 KiB vmemmap can be freed for a 2.00 MiB page
[    0.702877] ACPI: Added _OSI(Module Device)
[    0.703664] ACPI: Added _OSI(Processor Device)
[    0.704550] ACPI: Added _OSI(3.0 _SCP Extensions)
[    0.705921] ACPI: Added _OSI(Processor Aggregator Device)
[    0.708471] ACPI: 1 ACPI AML tables successfully acquired and loaded
[    0.730782] ACPI: Interpreter enabled
[    0.733542] ACPI: PM: (supports S0 S3 S4 S5)
[    0.734951] ACPI: Using IOAPIC for interrupt routing
[    0.735833] PCI: Using host bridge windows from ACPI; if necessary, use "pci=nocrs" and report a bug
[    0.738085] PCI: Using E820 reservations for host bridge windows
[    0.739076] ACPI: Enabled 2 GPEs in block 00 to 3F
[    0.743078] ACPI: PCI Root Bridge [PCI0] (domain 0000 [bus 00-ff])
[    0.743968] acpi PNP0A08:00: _OSC: OS supports [ExtendedConfig ASPM ClockPM Segments MSI EDR HPX-Type3]
[    0.746139] acpi PNP0A08:00: _OSC: platform does not support [PCIeHotplug LTR DPC]
[    0.748100] acpi PNP0A08:00: _OSC: OS now controls [SHPCHotplug PME AER PCIeCapability]
[    0.749242] PCI host bridge to bus 0000:00
[    0.749898] pci_bus 0000:00: root bus resource [io  0x0000-0x0cf7 window]
[    0.751979] pci_bus 0000:00: root bus resource [io  0x0d00-0xffff window]
[    0.752989] pci_bus 0000:00: root bus resource [mem 0x000a0000-0x000bffff window]
[    0.754040] pci_bus 0000:00: root bus resource [mem 0x80000000-0xafffffff window]
[    0.756041] pci_bus 0000:00: root bus resource [mem 0xc0000000-0xfebfffff window]
[    0.757035] pci_bus 0000:00: root bus resource [mem 0x380000000000-0x3807ffffffff window]
[    0.759067] pci_bus 0000:00: root bus resource [bus 00-ff]
[    0.760001] pci 0000:00:00.0: [8086:29c0] type 00 class 0x060000 conventional PCI endpoint
[    0.761508] pci 0000:00:01.0: [1234:1111] type 00 class 0x030000 conventional PCI endpoint
[    0.765674] pci 0000:00:01.0: BAR 0 [mem 0xfd000000-0xfdffffff pref]
[    0.770548] pci 0000:00:01.0: BAR 2 [mem 0xfebb0000-0xfebb0fff]
[    0.779505] pci 0000:00:01.0: ROM [mem 0xfeba0000-0xfebaffff pref]
[    0.781046] pci 0000:00:01.0: Video device with shadowed ROM at [mem 0x000c0000-0x000dffff]
[    0.783284] pci 0000:00:02.0: [8086:100e] type 00 class 0x020000 conventional PCI endpoint
[    0.787176] pci 0000:00:02.0: BAR 0 [mem 0xfeb80000-0xfeb9ffff]
[    0.788666] pci 0000:00:02.0: BAR 1 [io  0xc080-0xc0bf]
[    0.798667] pci 0000:00:02.0: ROM [mem 0xfeb00000-0xfeb7ffff pref]
[    0.799987] pci 0000:00:03.0: [1af4:1005] type 00 class 0x00ff00 conventional PCI endpoint
[    0.803253] pci 0000:00:03.0: BAR 0 [io  0xc100-0xc11f]
[    0.804666] pci 0000:00:03.0: BAR 1 [mem 0xfebb1000-0xfebb1fff]
[    0.810667] pci 0000:00:03.0: BAR 4 [mem 0x380000000000-0x380000003fff 64bit pref]
[    0.814364] pci 0000:00:04.0: [1af4:1001] type 00 class 0x010000 conventional PCI endpoint
[    0.818666] pci 0000:00:04.0: BAR 0 [io  0xc000-0xc07f]
[    0.823667] pci 0000:00:04.0: BAR 1 [mem 0xfebb2000-0xfebb2fff]
[    0.834666] pci 0000:00:04.0: BAR 4 [mem 0x380000004000-0x380000007fff 64bit pref]
[    0.851831] pci 0000:00:1f.0: [8086:2918] type 00 class 0x060100 conventional PCI endpoint
[    0.853526] pci 0000:00:1f.0: quirk: [io  0x0600-0x067f] claimed by ICH6 ACPI/GPIO/TCO
[    0.855307] pci 0000:00:1f.2: [8086:2922] type 00 class 0x010601 conventional PCI endpoint
[    0.860368] pci 0000:00:1f.2: BAR 4 [io  0xc120-0xc13f]
[    0.862666] pci 0000:00:1f.2: BAR 5 [mem 0xfebb3000-0xfebb3fff]
[    0.866049] pci 0000:00:1f.3: [8086:2930] type 00 class 0x0c0500 conventional PCI endpoint
[    0.869889] pci 0000:00:1f.3: BAR 4 [io  0x0700-0x073f]
[    0.871898] ACPI: PCI: Interrupt link LNKA configured for IRQ 10
[    0.873038] ACPI: PCI: Interrupt link LNKB configured for IRQ 10
[    0.876034] ACPI: PCI: Interrupt link LNKC configured for IRQ 11
[    0.877023] ACPI: PCI: Interrupt link LNKD configured for IRQ 11
[    0.878019] ACPI: PCI: Interrupt link LNKE configured for IRQ 10
[    0.885734] ACPI: PCI: Interrupt link LNKF configured for IRQ 10
[    0.886729] ACPI: PCI: Interrupt link LNKG configured for IRQ 11
[    0.887732] ACPI: PCI: Interrupt link LNKH configured for IRQ 11
[    0.888693] ACPI: PCI: Interrupt link GSIA configured for IRQ 16
[    0.889671] ACPI: PCI: Interrupt link GSIB configured for IRQ 17
[    0.891670] ACPI: PCI: Interrupt link GSIC configured for IRQ 18
[    0.892670] ACPI: PCI: Interrupt link GSID configured for IRQ 19
[    0.893669] ACPI: PCI: Interrupt link GSIE configured for IRQ 20
[    0.894670] ACPI: PCI: Interrupt link GSIF configured for IRQ 21
[    0.895671] ACPI: PCI: Interrupt link GSIG configured for IRQ 22
[    0.896670] ACPI: PCI: Interrupt link GSIH configured for IRQ 23
[    0.899726] iommu: Default domain type: Translated
[    0.900924] iommu: DMA domain TLB invalidation policy: lazy mode
[    0.902206] SCSI subsystem initialized
[    0.902915] ACPI: bus type USB registered
[    0.903675] usbcore: registered new interface driver usbfs
[    0.904667] usbcore: registered new interface driver hub
[    0.905675] usbcore: registered new device driver usb
[    0.906653] pps_core: LinuxPPS API ver. 1 registered
[    0.907929] pps_core: Software ver. 5.3.6 - Copyright 2005-2007 Rodolfo Giometti <giometti@linux.it>
[    0.909085] PTP clock support registered
[    0.910715] EDAC MC: Ver: 3.0.0
[    0.911753] NetLabel: Initializing
[    0.912474] NetLabel:  domain hash size = 128
[    0.913904] NetLabel:  protocols = UNLABELED CIPSOv4 CALIPSO
[    0.914975] NetLabel:  unlabeled traffic allowed by default
[    0.915970] mctp: management component transport protocol core
[    0.916955] NET: Registered PF_MCTP protocol family
[    0.917688] PCI: Using ACPI for IRQ routing
[    1.081683] pci 0000:00:01.0: vgaarb: setting as boot VGA device
[    1.082661] pci 0000:00:01.0: vgaarb: bridge control possible
[    1.082661] pci 0000:00:01.0: vgaarb: VGA device added: decodes=io+mem,owns=io+mem,locks=none
[    1.084666] vgaarb: loaded
[    1.085757] hpet0: at MMIO 0xfed00000, IRQs 2, 8, 0
[    1.086926] hpet0: 3 comparators, 64-bit 100.000000 MHz counter
[    1.091710] clocksource: Switched to clocksource kvm-clock
[    1.094136] VFS: Disk quotas dquot_6.6.0
[    1.094947] VFS: Dquot-cache hash table entries: 512 (order 0, 4096 bytes)
[    1.096424] AppArmor: AppArmor Filesystem Enabled
[    1.097349] pnp: PnP ACPI init
[    1.098171] system 00:05: [mem 0xb0000000-0xbfffffff window] has been reserved
[    1.099802] pnp: PnP ACPI: found 6 devices
[    1.108612] clocksource: acpi_pm: mask: 0xffffff max_cycles: 0xffffff, max_idle_ns: 2085701024 ns
[    1.110390] NET: Registered PF_INET protocol family
[    1.111948] IP idents hash table entries: 262144 (order: 9, 2097152 bytes, linear)
[    1.116112] tcp_listen_portaddr_hash hash table entries: 16384 (order: 6, 262144 bytes, linear)
[    1.117858] Table-perturb hash table entries: 65536 (order: 6, 262144 bytes, linear)
[    1.119897] TCP established hash table entries: 262144 (order: 9, 2097152 bytes, linear)
[    1.122185] TCP bind hash table entries: 65536 (order: 9, 2097152 bytes, linear)
[    1.123914] TCP: Hash tables configured (established 262144 bind 65536)
[    1.125586] MPTCP token hash table entries: 32768 (order: 7, 786432 bytes, linear)
[    1.127223] UDP hash table entries: 16384 (order: 7, 524288 bytes, linear)
[    1.128667] UDP-Lite hash table entries: 16384 (order: 7, 524288 bytes, linear)
[    1.130226] NET: Registered PF_UNIX/PF_LOCAL protocol family
[    1.131323] NET: Registered PF_XDP protocol family
[    1.132266] pci_bus 0000:00: resource 4 [io  0x0000-0x0cf7 window]
[    1.133431] pci_bus 0000:00: resource 5 [io  0x0d00-0xffff window]
[    1.134596] pci_bus 0000:00: resource 6 [mem 0x000a0000-0x000bffff window]
[    1.135902] pci_bus 0000:00: resource 7 [mem 0x80000000-0xafffffff window]
[    1.137231] pci_bus 0000:00: resource 8 [mem 0xc0000000-0xfebfffff window]
[    1.138515] pci_bus 0000:00: resource 9 [mem 0x380000000000-0x3807ffffffff window]
[    1.140069] PCI: CLS 0 bytes, default 64
[    1.140919] PCI-DMA: Using software bounce buffering for IO (SWIOTLB)
[    1.141073] Trying to unpack rootfs image as initramfs...
[    1.141818] software IO TLB: mapped [mem 0x000000007bfdc000-0x000000007ffdc000] (64MB)
[    1.145362] pin_based_exec_ctrl unsupported with eVMCS: 0x40
[    1.147117] cpu_based_2nd_exec_ctrl unsupported with eVMCS: 0x4000
[    1.148292] pin_based_exec_ctrl 0x16
[    1.149039] cpu_based_exec_ctrl 0x9401e176
[    1.149852] cpu_based_2nd_exec_ctrl 0x410102a
[    1.150697] vmexit_ctrl 0x3f7fff
[    1.151366] vmentry_ctrl 0xf3ff
[    1.152689] pkvm: mitigated CPU bug spectre_v1
[    1.153606] pkvm: cannot mitigate CPU bug spectre_v2
[    1.154580] pkvm: mitigated CPU bug spec_store_bypass
[    1.155577] pkvm: mitigated CPU bug swapgs
[    1.156406] pkvm: cannot mitigate CPU bug bhi
[    1.157277] pkvm: unmitigated cpu bug spectre_v2
[    1.158192] pkvm: unmitigated cpu bug taa
[    1.159011] pkvm: unmitigated cpu bug eibrs_pbrsb
[    1.159961] pkvm: unmitigated cpu bug bhi
[    1.160760] pkvm: unmitigated cpu bug ibpb_no_ret
[    1.161701] pkvm: unmitigated cpu bug its
[    1.162509] pkvm: in total has 6 unmitigated cpu bugs
[    1.163512] pkvm: allow pkvm to run with unmitigated CPU bugs
[    1.164581] pkvm: to prevent pkvm running on such CPU, reboot with kvm-intel.pkvm_relax_cpu_bugs=false
[    1.166607] pkvm_host_deprivilege_cpu: CPU31 in guest mode
[    1.166608] pkvm_host_deprivilege_cpu: CPU23 in guest mode
[    1.166608] pkvm_host_deprivilege_cpu: CPU0 in guest mode
[    1.166800] pkvm_host_deprivilege_cpu: CPU29 in guest mode
[    1.166896] pkvm_host_deprivilege_cpu: CPU12 in guest mode
[    1.166905] pkvm_host_deprivilege_cpu: CPU10 in guest mode
[    1.166912] pkvm_host_deprivilege_cpu: CPU9 in guest mode
[    1.166917] pkvm_host_deprivilege_cpu: CPU6 in guest mode
[    1.166924] pkvm_host_deprivilege_cpu: CPU2 in guest mode
[    1.166926] pkvm_host_deprivilege_cpu: CPU8 in guest mode
[    1.166927] pkvm_host_deprivilege_cpu: CPU26 in guest mode
[    1.166985] pkvm_host_deprivilege_cpu: CPU30 in guest mode
[    1.167047] pkvm_host_deprivilege_cpu: CPU3 in guest mode
[    1.167094] pkvm_host_deprivilege_cpu: CPU1 in guest mode
[    1.167138] pkvm_host_deprivilege_cpu: CPU18 in guest mode
[    1.167139] pkvm_host_deprivilege_cpu: CPU16 in guest mode
[    1.167155] pkvm_host_deprivilege_cpu: CPU19 in guest mode
[    1.167179] pkvm_host_deprivilege_cpu: CPU11 in guest mode
[    1.167212] pkvm_host_deprivilege_cpu: CPU7 in guest mode
[    1.167231] pkvm_host_deprivilege_cpu: CPU14 in guest mode
[    1.167236] pkvm_host_deprivilege_cpu: CPU4 in guest mode
[    1.167236] pkvm_host_deprivilege_cpu: CPU5 in guest mode
[    1.167250] pkvm_host_deprivilege_cpu: CPU13 in guest mode
[    1.167267] pkvm_host_deprivilege_cpu: CPU20 in guest mode
[    1.167271] pkvm_host_deprivilege_cpu: CPU21 in guest mode
[    1.167350] pkvm_host_deprivilege_cpu: CPU22 in guest mode
[    1.167349] pkvm_host_deprivilege_cpu: CPU25 in guest mode
[    1.167358] pkvm_host_deprivilege_cpu: CPU24 in guest mode
[    1.167387] pkvm_host_deprivilege_cpu: CPU27 in guest mode
[    1.167367] pkvm_host_deprivilege_cpu: CPU15 in guest mode
[    1.167387] pkvm_host_deprivilege_cpu: CPU28 in guest mode
[    1.167368] pkvm_host_deprivilege_cpu: CPU17 in guest mode
[    1.204849] pkvm_host_deprivilege_cpus: all cpus are in guest mode!
[    1.309588] DMAR: No RMRR found
[    1.310492] DMAR: No SATC found
[    1.311322] DMAR: dmar0: Using Queued invalidation
[    1.312996] Kernel panic - not syncing: DMAR hardware is malfunctioning
[    1.312996] CPU: 23 UID: 0 PID: 1 Comm: swapper/0 Not tainted 6.12.0-pkvm-ia #18
[    1.312996] Hardware name: QEMU Standard PC (Q35 + ICH9, 2009), BIOS 1.16.3-debian-1.16.3-2 04/01/2014
[    1.312996] Call Trace:
[    1.312996]  <TASK>
[    1.312996]  dump_stack_lvl+0x27/0xa0
[    1.312996]  dump_stack+0x10/0x20
[    1.312996]  panic+0x36f/0x400
[    1.312996]  ? __lruvec_stat_mod_folio+0xc7/0xf0
[    1.312996]  iommu_set_root_entry+0x220/0x230
[    1.312996]  intel_iommu_init+0x426/0x10d0
[    1.312996]  ? arch_jump_label_transform_apply+0x26/0x30
[    1.312996]  ? __jump_label_update+0x126/0x140
[    1.312996]  ? jump_label_update+0xe2/0x120
[    1.312996]  vmx_pkvm_init+0xd08/0xf00
[    1.312996]  vmx_init+0x32/0x2d0
[    1.312996]  ? __pfx_vmx_init+0x10/0x10
[    1.312996]  do_one_initcall+0x5e/0x340
[    1.312996]  kernel_init_freeable+0x353/0x520
[    1.312996]  ? __pfx_kernel_init+0x10/0x10
[    1.312996]  kernel_init+0x1b/0x200
[    1.312996]  ret_from_fork+0x44/0x70
[    1.312996]  ? __pfx_kernel_init+0x10/0x10
[    1.312996]  ret_from_fork_asm+0x1a/0x30
[    1.312996]  </TASK>
[    1.312996] ---[ end Kernel panic - not syncing: DMAR hardware is malfunctioning ]---
QEMU: Terminated
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
          read DMAR_GSTS/RTADDR/CAP/ECAP     (drhd->iommu->reg + DMAR_*_REG)
          check queued invalidation, etc.

      pkvm_host_deprivilege_cpus
        on_each_cpu(pkvm_host_deprivilege_cpu)
          pkvm_host_init_vmx
          local_deprivilege_cpu
          pr_info "CPU%d in guest mode"
        pr_info "all cpus are in guest mode!"

    pkvm_iommu_driver_init
      intel_iommu_init
        iommu_set_root_entry
          dmar_writeq(DMAR_RTADDR_REG, addr)
          dmar_writel(DMAR_GCMD_REG, ...|SRTP)
          IOMMU_WAIT_OP(..., DMAR_GSTS_REG, (sts & RTPS))
            timeout -> panic("DMAR hardware is malfunctioning")
```

对应的流程解释（每段代码块下面用 `-` 描述“这一步在做什么”）：

- `vmx_init -> vmx_pkvm_init`：VMX 模块初始化时，若 `kvm-intel.pkvm=1` 且条件满足，就进入 pkvm 初始化路径。
- `pkvm_iommu_driver_prepare -> dmar_table_init`：先把 DMAR 表/DRHD 等结构准备好（后续 pkvm 和 IOMMU init 都依赖这些结构）。
- `__vmx_pkvm_init -> check_and_init_iommu`：pkvm 在“真正降权前”会读取 DMAR 寄存器做能力/约束检查（例如是否支持 queued invalidation）。
- `pkvm_host_deprivilege_cpus -> on_each_cpu(...)`：对每个 CPU 执行“降权”，让 host 进入 VMX non-root（日志里的 `CPU%d in guest mode` 就在这里打印）。
- `pkvm_iommu_driver_init -> intel_iommu_init`：降权之后再进入 Intel IOMMU 的完整初始化（这是你日志里“先降权，后 DMAR/IOMMU”的直接原因）。
- `iommu_set_root_entry -> IOMMU_WAIT_OP`：IOMMU init 的 SRTP 流程等待 RTPS 置位；超时就 `panic("DMAR hardware is malfunctioning")`。

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
