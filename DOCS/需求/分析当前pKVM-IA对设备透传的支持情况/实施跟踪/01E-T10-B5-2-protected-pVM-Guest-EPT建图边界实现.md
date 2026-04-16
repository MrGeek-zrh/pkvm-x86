# [T10] B5-2 protected pVM Guest EPT 建图完整性缺口实现

## 状态

- 当前状态: `pKVM-IA` 已补 boot-time BAR manifest、按当前 VM 已 attach 设备做 BAR 建图约束、direct BAR leaf 建图、VM destroy 跳过 BAR undonate，以及 BAR miss 提前 reject 日志；2026-04-15 复测确认旧 `BOOT-012` donation 签名已前移，但新阻塞落在 host-high `pkvm_pin_page()` 误 pin BAR/MMIO PFN
- 所属主任务: `pkvm-x86#20`
- 关联设计文档:
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`（其中“问题 2：Guest EPT 建图边界”一节为当前设计入口）

## 当前阻塞

核心缺口已确认，且本轮方案已经收敛为下面这组实现口径：

- Host 在 `vm_mmu_map` 前通过 memslot/HVA 解析出 candidate HPA，hyp 收到成品 HPA
- hyp 只验证 donation 合法性（ownership/page-state/mem_range/refcount），不验证语义绑定正确性
- 对 MMIO BAR 场景：现有 `__pkvm_host_donate_guest` 的校验体系语义是针对 host RAM page 的，不适用于 PCI 物理地址
- hyp 缺少 device BAR 范围约束，无法判断收到的 PCI 物理地址是否落在正确的 BAR 范围内
- 当前 `vm_mmu_map` hypercall 参数已占满，本轮不新增 `bdf` 参数
- 本轮不依赖 `MMIO metadata` 做 HPA 校验
- 本轮只校验 `[hpa, hpa + size)` 是否完整落在“当前 VM 已 attach 且 boot-time manifest 记录的某个 memory BAR”内
- 命中 BAR 的 leaf 不再走 `__pkvm_host_donate_guest()`，而是按 direct BAR leaf 直接装入 Guest EPT
- 对既非当前 VM attached BAR 又非 host RAM 的 HPA，在 `vm_mmu_map` 提前 reject 并打印明确日志
- VM teardown 时，BAR leaf 不再走 `__pkvm_host_undonate_guest()` / `__pkvm_host_unshare_guest()`

仍保留的已知边界：

- 本轮不检查 BAR 内 offset 是否正确
- 本轮不证明某个 `gpa` 一定“应该”是 passthrough MMIO GPA
- 本轮不检查 guest GPA 与具体 BAR offset 的精确一致性
- 本轮不显式撤销 Host 对 assigned BAR 的 CPU 访问权；当前实现收敛的是“Guest EPT 建图边界 + guest 侧 direct/fallback MMIO 分流”，不是“Host CPU 后续无法再碰 BAR”

## 待处理风险

- `pkvm_vm_mmu_map()` 当前已经允许 direct BAR leaf 建图，但 `gpa_range_overlaps_pvmfw()` / `load_pvmfw()` 路径还没有排除 direct BAR HPA：
  - `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
    - `load_pvmfw()`
    - `pkvm_vm_mmu_map()`
- 因此若 host 把某个 attached BAR 映到 `pvmfw` GPA，当前实现存在把 `pvmfw` 内容写入 BAR/MMIO 的风险。
- 这条风险本轮先记录，不在当前提交里改行为；后续需要单独决定是：
  - 拒绝 `direct_mmio && gpa_range_overlaps_pvmfw()`
  - 还是把 `load_pvmfw()` 明确限制为 host RAM 路径

### 风险：Host 对 assigned BAR 的 CPU 访问权尚未显式收口

这个问题和 `B5-2` 当前已完成的“Guest EPT 建图边界校验”不是同一件事，但同样重要，先在这里固定口径，后续待 `T4` 处理完成后再单独回到这条线继续展开。

当前源码能确认的事实是：

- `B5-2` 当前在 `pkvm_vm_mmu_map()` / `guest_mmu_map_leaf()` 中做的是“命中当前 VM attached boot BAR 时允许 direct BAR leaf 建图；未命中则 reject 或走普通 RAM donation/share 语义”：
  - `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
    - `pkvm_vm_mmu_map()`
    - `guest_mmu_map_leaf()`
- BAR 合法性判断本质上只是“boot manifest + 当前 VM attached ptdev”范围包含关系：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
    - `pkvm_boot_ptdev_bar_contains()`
    - `pkvm_host_hpa_hits_boot_ptdev_bar()`
    - `pkvm_vm_hpa_hits_attached_boot_ptdev_bar()`
- guest 侧 `DIRECT_BAR` allowlist 只影响 guest MMIO 访问是走 `raw_read*/raw_write*` 还是回退 `PKVM_GHC_IOREAD/IOWRITE`，不等价于“撤销 Host CPU 对 BAR 的直访能力”：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
    - `pkvm_update_vm_mmio_allowlist()`
  - `pKVM-IA/arch/x86/coco/pkvm/pkvm.c`
    - `pkvm_mmio_allow_hit()`
    - `pkvm_virt_mmio()`
- 目前能看到显式 `pkvm_host_ept_unmap()` 收口的是 IOMMU MMIO，而不是普通 assigned PCI BAR：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`
    - `activate_iommu()`
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
    - `pkvm_host_ept_unmap()`
- 在当前 `pkvm_attach_ptdev()` / `pkvm_detach_ptdev()` 路径里，也还没有看到“附加设备后顺手把 Host 对该 BAR 的 CPU 映射撤掉”的配套动作：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
    - `pkvm_attach_ptdev()`
    - `pkvm_detach_ptdev()`

因此，当前更准确的结论应写成：

- `B5-2` 当前已经收敛的是“Host 不能在 Guest EPT 首次建图时把任意 HPA 塞给 pVM”
- 但 `B5-2` 还没有证明“Host CPU 在设备已经 assign 给 pVM 后，就一定无法再直接读写该 BAR”
- 换句话说，当前实现更接近“建图边界校验 + DMA 侧隔离 + guest MMIO 分流”，还不是“assigned BAR 的 Host CPU authority revoke”

这条缺口为什么重要：

- DMA 隔离解决的是“设备 DMA 能不能越界”
- Guest EPT 建图边界解决的是“Host 能不能把任意 HPA 塞进 Guest EPT”
- 但如果 Host CPU 仍可直接 MMIO 到 assigned BAR，它依然可能修改 doorbell / control / reset 等设备状态，与 guest 竞争同一设备控制面

后续处理边界先记为：

- 这条问题先不并入当前 `B5-2` 已完成结论
- 也先不和正在推进的 `T4` teardown DMA 生命周期问题混做
- 等 `T4` 当前处理完成后，再回到这里单独评估是否需要：
  - BAR 级别的 Host EPT unmap / revoke
  - 配套的 CPU fault / invalidate / shootdown 状态机
  - attach / detach / remove-path 下的 generation 与回收语义

## 2026-04-15 运行验证补充

2026-04-15 对 boot-known NVMe `0000:01:00.0` 做了两轮专门验证，结果已经把“当前正向样例到底有没有真的命中 direct MMIO”收敛清楚：

- 独立验证记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p1-protected-vfio-mmio-path-0100-20260415.md`
- host 侧 kprobe 结果：`kvm_sev_es_mmio_read` 命中 `310` 次，`kvm_sev_es_mmio_write` 命中 `3653` 次
- guest 侧 `pkvm_virt_mmio()` 分支打点结果：
  - `BASE_DIRECT=0`
  - `BASE_FALLBACK=2`
  - `DD_DIRECT=0`
  - `DD_FALLBACK=130`
- guest 内 `nvme0n1` 确实存在，且 `dd if=/dev/nvme0n1 of=/dev/null ...` 返回 `DD_RC=0`

这组结果说明：

- 当前这条 protected pVM + VFIO NVMe 正向样例“能启动、能枚举、能读盘”
- 但当前 MMIO 访问并**没有**命中 `pkvm_direct_mmio_read()` / `pkvm_direct_mmio_write()`
- 当前实际走通的仍然是 `PKVM_GHC_IOREAD/IOWRITE -> host fallback`

同日继续往下收敛后，又确认了两层更关键的事实：

- guest 侧在 NVMe `dd` 期间读到的 `pkvm_mmio_allow_nr_ranges` 是 `0`
- host 侧 `pkvm_vm_ioctl_set_ptdev_mmio_metadata()` 在启动期命中数也是 `0`

这说明：

- 问题已经不是“allowlist 下发了，但和实际访问的 GPA 有偏差”
- 而是 **这条样例里根本没有形成任何 guest MMIO allowlist**
- 进一步说，`crosvm` 在当前这条路径里并没有真正发出 `SET_PTDEV_MMIO_METADATA` ioctl

最初我们一度怀疑是下面这条用户态路径里：

```text
configure_pci_device()
    -> device.get_protected_vm_ptdev_mmio_metadata(&linux.vm)
    -> if let Some(metadata) { linux.vm.set_protected_vm_ptdev_mmio_metadata(&metadata) }
```

但 2026-04-15 继续核对 `crosvm` 启动调用路径后，已经把更前置的根因收敛清楚：

```text
x86_64/src/lib.rs
    -> 把所有 PCI 设备分到 pci_devices
    -> arch::generate_pci_root(pci_devices, ...)

arch/src/lib.rs
    configure_pci_device()
        -> 有 metadata 查询/提交逻辑

arch/src/lib.rs
    generate_pci_root()
        -> 当前没有 metadata 查询/提交逻辑
```

这说明：

- boot 阶段的 PCI / VFIO 设备当前走的是 `generate_pci_root()`
- `set_protected_vm_ptdev_mmio_metadata()` 只存在于 `configure_pci_device()`
- 因此这条正向样例里，boot-time VFIO 设备注册路径根本没有机会提交 `ptdev MMIO metadata`

也就是说，当前更直接的功能性缺口不是“先调用了 metadata 生成，但得到空 `ranges`”，而是：

- `crosvm` boot-time PCI/VFIO 注册路径本身漏掉了 metadata 提交步骤

进一步又排除了一个常见误判：

- 对这块 NVMe，`lspci -vvv` 显示：
  - BAR0 大小为 `16K`
  - MSI-X table 在 `BAR0 + 0x2000`
  - PBA 在 `BAR0 + 0x3000`
- `remove_bar_mmap_msix()` 若只是按 MSI-X/PBA 裁剪，理论上还应至少保留
  `BAR0 + 0x0000..0x1fff`
- 而 guest 当前访问到的 GPA（`0xd0001008` / `0xd000100c`）正落在这段前半区间
- 实际加到 `crosvm/devices/src/pci/vfio_pci.rs` 的调试输出也已经看到：

```text
vfio 0000:01:00.0 device remove_bar_mmap_msix:
    bar=0 raw_mmaps=[(0, 16384)]
    msix_regions=[(8192, 9231), (12288, 12303)]
    adjusted_mmaps=[(0, 8192)]
```

因此，当前最强怀疑点已经不再是“MSI-X 裁剪把整个 BAR0 清空了”，而是：

- 即便这块 BAR 的 mmap 信息是可用的
- boot-time 设备注册路径也没有把这些信息提交到 `SET_PTDEV_MMIO_METADATA`

因此，当前实现里至少还存在一个更前置的功能性缺口：

- `pkvm_mmio_allow_hit()` 没有把当前 NVMe BAR 访问判成 direct BAR 命中

这不会改变 B5-2 这轮“Guest EPT BAR HPA 边界校验”的必要性，但会影响我们对当前行为的理解：

- 目前这条正向样例并不能证明“Guest EPT direct BAR 访问语义已经真正跑通”
- 它只证明“在 host fallback 仍参与 MMIO 的情况下，这条样例可以工作”
- 若后续要真正修复当前 direct MMIO miss，第一优先落点应先补齐 `crosvm/arch/src/lib.rs` 里 `generate_pci_root()` 的 metadata 提交流程，再继续验证 `build_protected_vm_ptdev_mmio_metadata()` 细节

## 2026-04-15 继续验证补充（`crosvm` 修复后）

在 `crosvm` 中继续完成下面两步后：

- 给 `generate_pci_root()` 补齐与 `configure_pci_device()` 对齐的 boot-time metadata 提交
- 修正 `crosvm/hypervisor/src/kvm/x86_64.rs` 到当前 pKVM UAPI 的 metadata ABI 布局

protected pVM 样例已经出现了新的、更贴近 B5-2 本体的运行期签名：

```text
pkvm: host_initiate_donation: addr not in mem_range addr=0xfe800000 size=0x1000 owner_id=1
pkvm: do_donate: __do_donate failed ret=-1 ... addr=0xd0000000 phys=0xfe800000 prot=0x77
pkvm: __pkvm_host_donate_guest failed ret=-1 hpa=0xfe800000 gpa=0xd0000000 size=0x1000 prot=0x77
kvm: pkvm: vm_mmu_map failed ret=-1 gpa=0xd0000000 hpa=0xfe800000 size=0x1000 writable=1 goal_level=1 pfn=0xfe800
```

同时 host trace 已确认：

- `pkvm_vm_ioctl_set_ptdev_mmio_metadata()` 已经命中

对应原始记录：

- 新问题记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-012/BOOT-012-protected-pVM-BAR-HPA误入donate路径导致vm_mmu_map失败.md`
- 总体验证记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p1-protected-vfio-mmio-path-0100-20260415.md`
- host trace：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p5-host-kprobe-enable-cap-vs-metadata-after-abi-fix-20260415.trace.log`
- host dmesg：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p5-host-dmesg-vm_mmu_map-fail-after-metadata-20260415.log`

这说明当前主阻塞已经前移为：

- `crosvm` 侧不是主要 blocker 了
- Guest EPT BAR 建图已经真正走到 kernel / hyp
- 但 kernel / hyp 仍然把 BAR HPA 映射送进 `__pkvm_host_donate_guest()`，因此在 `host_initiate_donation()` 被 `addr not in mem_range` 拒绝

也就是说，B5-2 当前已经从“设计目标”变成“有运行时证据直接驱动的实现缺口”：

- 命中合法 BAR 的 HPA 需要从 normal memory donation 路径分流出去
- 直接走 direct BAR leaf 建图

## 2026-04-15 安装新 Host 内核后的复测补充

在安装并重启到包含当前 B5-2 改动的 Host 内核后，重新运行 protected pVM + VFIO NVMe `0000:01:00.0` 样例：

- Host 内核：`Linux ubuntu-vm 6.12.0-pkvm-ia #8 SMP PREEMPT_DYNAMIC Wed Apr 15 09:37:32 UTC 2026`
- 启动命令：

```text
sudo -n env -u DEBUG PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

原始记录：

- 汇总记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-protected-vfio-direct-mmio-dd-rerun-0100-20260415.md`
- crosvm 串口/PTTY：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-crosvm-protected-vfio-direct-mmio-dd-0100-20260415-104859.pty.log`
- host dmesg：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-host-dmesg-protected-vfio-direct-mmio-dd-0100-20260415-104859.log`
- host fallback trace 计数：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p6-host-trace-counts-protected-vfio-direct-mmio-dd-0100-20260415-104859.log`
- 新问题记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-013/BOOT-013-protected-pVM-BAR直建图后pkvm_pin_page误pin-MMIO-PFN.md`

本轮结果：

- protected pVM 未到达 `login:`
- 因此 guest 内 `dd` 未执行，也还不能给出“MMIO 已稳定走 direct path”的正向结论
- 旧 `BOOT-012` 签名没有再出现：
  - 未见 `host_initiate_donation: addr not in mem_range`
  - 未见 `__pkvm_host_donate_guest failed`
  - 未见 `vm_mmu_map failed`
- 新签名是 host-high `pkvm_pin_page()` 对 BAR/MMIO PFN 执行普通 RAM pin：

```text
[2026-04-15T10:50:32.365903391+00:00 ERROR crosvm::crosvm::sys::linux::vcpu] vcpu hit unknown error: Bad address (os error 14)
[Wed Apr 15 10:50:32 2026] WARNING: CPU: 18 PID: 4255 at arch/x86/kvm/mmu/mmu.c:4775 kvm_tdp_page_fault+0x3f0/0x420
```

对应源码路径：

```text
pkvm_page_fault()                                             (pKVM-IA/arch/x86/kvm/mmu/mmu.c)
    pkvm_hypercall(vm_mmu_map, gpa, hpa, size, ...)
        pkvm_vm_mmu_map(...)                                  (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
            // B5-2 后，命中 attached BAR 可直接建 Guest EPT leaf
    pkvm_pin_page(vcpu->kvm, fault)
        kvm_pfn_to_refcounted_page(fault->pfn)
            // BAR/MMIO PFN 不是普通 RAM refcounted page
        WARN_ON_ONCE(!page)
        return -EFAULT
```

本轮 host fallback 计数仍然很多：

```text
HOST_SEV_MMIO_R=279
HOST_SEV_MMIO_W=2885
```

当前判断：

- B5-2 的 hyp 侧 BAR HPA direct leaf 分流已让 `BOOT-012` 的 BAR HPA donation 签名前移
- 但 host-high 侧 `pkvm_page_fault()` 仍沿用“建图成功后一定 pin 普通 RAM page”的旧假设
- 对 direct BAR / MMIO PFN，不能再走普通 RAM pin 语义
- 下一步修复点应落在 host-high `pkvm_page_fault()` / `pkvm_pin_page()` 这条后处理路径

## 2026-04-15 安装修复后 Host 内核的再次复测

在本地补上 `BOOT-013` 对应的 host-high 修复后，重新编译、安装并重启到新的 Host 内核，再次运行同一条 protected pVM + VFIO NVMe `0000:01:00.0` 样例。

原始记录：

- 汇总记录：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-protected-vfio-direct-mmio-dd-rerun-after-boot013-fix-0100-20260415.md`
- crosvm 串口/PTTY：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-crosvm-protected-vfio-direct-mmio-dd-0100-20260415-130256.pty.log`
- host dmesg：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-host-dmesg-final-0100-20260415-130256.log`
- host fallback trace：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-host-trace-counts-protected-vfio-direct-mmio-dd-0100-20260415-130256.log`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p8-host-trace-counts-guest-kprobe-window-0100-20260415-130256.log`

本轮结果已经和 `t10-p6` 明显不同：

- protected pVM 成功启动到 `localhost login:`
- guest 登录成功，`/dev/nvme0n1` 已正常出现
- guest 内两轮 `dd` 都成功：

```text
DD_RC=0
DD_BIG_RC=0
```

- 对 `pkvm_virt_mmio()` direct / fallback 分支打点后，`dd` 对应窗口里得到：

```text
GUEST_DIRECT=128
GUEST_FALLBACK=2
```

- 且 trace 尾部显示：
  - `dd-*` 命中 `direct_hit`
  - 两条 `fallback_hit` 来自 `sleep-*`

这说明：

- `BOOT-013` 的主阻塞已经被当前本地修复消掉
- 对这条 NVMe `dd` 正向样例，guest 侧已经出现明确的 direct MMIO 正向证据

同时本轮也保留了一个新的观察点：

- host `kvm_sev_es_mmio_write` 计数仍然还能看到写事件
- 但 guest 侧 `pkvm_virt_mmio()` trace 已经把 `dd` 的 MMIO 窗口钉在 direct 分支
- 因此这部分 host write 更像是“剩余 host MMIO 事件来源待分类”，而不是 `BOOT-013` 的旧失败签名仍在复现

## 关键源码锚点

### Host 侧（HVA → HPA 解析）

- `pKVM-IA/arch/x86/kvm/mmu/mmu.c` — `kvm_faultin_pfn()`、`__kvm_faultin_pfn()`、`pkvm_page_fault()`
- `pKVM-IA/virt/kvm/kvm_main.c` — `hva_to_pfn()`、`hva_to_pfn_remapped()`、`follow_pfnmap_start()`
- `pKVM-IA/drivers/vfio/vfio_iommu_type1.c` — `follow_fault_pfn()`，VFIO 建立 BAR VMA 后触发 `follow_pfnmap_start()` 返回 PCI 物理地址

### MMIO metadata 配置

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c` — `pkvm_vm_ioctl_set_ptdev_mmio_metadata()`、`pkvm_sync_ptdev_mmio_metadata()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c` — `pkvm_sync_ptdev_mmio_metadata()`（hyp 侧同步）
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c` — `pkvm_set_ptdev_mmio_metadata()`，将 BAR 范围写入 `vm->mmio_allow_ranges[]`

### MMIO allowlist（仅限 GPA 合法性）

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c` — `pkvm_update_vm_mmio_allowlist()`、`pkvm_guest_mmio_check()`
- `pKVM-IA/arch/x86/coco/pkvm/pkvm.c` — VM exit 时用 allowlist 校验 GPA 是否在允许范围内
- `pKVM-IA/arch/x86/include/uapi/asm/kvm.h` — `struct kvm_protected_vm_ptdev_mmio_metadata`、`struct kvm_protected_vm_ptdev_mmio_range`（含 `bar_offset`、`bar_index`、`kind`）

### hyp 侧建图（缺少 BAR 范围校验）

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c` — `pkvm_vm_mmu_map()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c` — `__pkvm_host_donate_guest()`、`check_donation()`、`find_mem_range()`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pgtable.c` — `pgtable_map_leaf()`

## 非目标

- 不覆盖 boot-time manifest 设备名单边界（B5-1）
- 不覆盖 `pgstate_pgt` DMA mirror（P0）
- 不引入 per-VM contract / firmware token / device lease 等超出现阶段范围的方案
- 不覆盖 `pvmfw` 页 trusted 内容完整性（独立信任根问题）
- 不修改 `vm_mmu_map` hypercall ABI
- 不依赖 `MMIO metadata` 做本轮 HPA 边界校验
- 不检查 BAR offset 一致性

## 本轮实现方案

### 1. 扩展 boot-time manifest，记录 memory BAR

文件：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`

改动：

- 扩展 `struct pkvm_boot_ptdev_manifest_entry`
- 为每个设备记录各个 memory BAR 的 `base` / `size`
- BAR 数据仍在启动期 `build_boot_ptdev_manifest()` 中收集

目的：

- 让 hyp 在运行期有一份独立于 Host 当前输入的 BAR 范围真相源

### 2. 提供 `[hpa, size)` 命中 boot-time manifest BAR 的统一 helper

文件：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`（或等价内部头文件）

改动：

- 在现有 `pkvm_boot_ptdev_manifest_lookup()` 附近增加统一的 BAR 范围匹配 helper
- 输入：`hpa`、`size`
- 输出：是否命中合法 memory BAR；必要时返回命中的 manifest entry / BAR 索引

公式：

```text
hpa_end = hpa + size

命中条件：
    hpa >= bar_base
    hpa_end <= bar_base + bar_size
```

### 3. `pkvm_vm_mmu_map()` 中把 BAR leaf 和 normal memory leaf 分流

文件：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`

改动：

- 在 `pkvm_vm_mmu_map()` / `guest_mmu_map_leaf()` 路径里先判断 `[hpa, size)` 是否命中合法 BAR
- 命中 BAR：
  - `get_mt_mask(..., true)` 按 MMIO memory type 生成 EPT 属性
  - 直接调用 `pgtable_map_leaf()` 装配 Guest EPT leaf
  - 不走 `__pkvm_host_donate_guest()`
- 未命中 BAR：
  - 保持现有 normal memory donation 路径

目的：

- 让 BAR 建图不再错误依赖 `host_initiate_donation()` 的 normal memory 语义

### 4. VM destroy 时跳过 BAR leaf 的 undonate/unshare

文件：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`

改动：

- 在 `guest_mmu_free_leaf()` 中按 leaf `phys + size` 再做一次 BAR 范围判断
- 命中 BAR：
  - 只撤 Guest EPT leaf
  - 不做 `__pkvm_host_undonate_guest()`
- 未命中 BAR：
  - 保持现有 protected VM teardown 路径

目的：

- 避免把 direct BAR leaf 当成 normal memory donation 回收

### 5. reject-path 日志收口

文件：

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`

改动：

- BAR range miss 时打印明确 reject 日志，至少带出 `gpa`、`hpa`、`size`

目的：

- 让后续验证能明确区分：
  - normal memory donation reject
  - BAR range reject

## 验收标准

本轮最小验收标准：

- boot-time manifest 能冻结每个可信设备的 memory BAR `base/size`
- protected pVM `vm_mmu_map` 路径中：
  - 对命中合法 BAR 的 direct BAR HPA，不再走 normal memory donation reject
  - 对 BAR 范围外 HPA，明确拒绝 Guest EPT 建图
- VM destroy 不再对 direct BAR leaf 执行 `__pkvm_host_undonate_guest()`

本轮不作为验收项：

- `bar_offset` 精确一致性
- `expected_hpa` 公式闭环
- GPA -> 设备/BAR 的受保护侧绑定证明
