# [BOOT-012] protected pVM 的 BAR HPA 误入 donate 路径，导致 `vm_mmu_map` 失败

## 现象

- 2026-04-15 在 protected pVM + VFIO NVMe `0000:01:00.0` 样例中，`crosvm` 侧 boot-time `ptdev MMIO metadata` 提交链路已补齐，且 ABI 已对齐到当前内核 UAPI。
- 之后运行期暴露出新的 host / hyp 报错签名：

```text
[Wed Apr 15 08:31:12 2026] pkvm: host_initiate_donation: addr not in mem_range addr=0xfe800000 size=0x1000 owner_id=1
[Wed Apr 15 08:31:12 2026] pkvm: do_donate: __do_donate failed ret=-1 size=0x1000 init=1 addr=0xfe800000 phys=0x0 comp=2 addr=0xd0000000 phys=0xfe800000 prot=0x77
[Wed Apr 15 08:31:12 2026] pkvm: __pkvm_host_donate_guest failed ret=-1 hpa=0xfe800000 gpa=0xd0000000 size=0x1000 prot=0x77
[Wed Apr 15 08:31:12 2026] kvm: pkvm: vm_mmu_map failed ret=-1 gpa=0xd0000000 hpa=0xfe800000 size=0x1000 writable=1 goal_level=1 pfn=0xfe800
```

- 同一批日志里还能看到：
  - `pci 0000:01:00.0: BAR 0 [mem 0xfe800000-0xfe803fff 64bit]`
  - 也就是说，当前失败的 `hpa=0xfe800000` 正是这块 NVMe BAR0 起始地址，而不是普通 RAM。
- 当前最小影响：
  - protected pVM 的 direct MMIO 链路已经不再卡在 `crosvm` metadata 提交缺口；
  - 但 Guest EPT 在建立 BAR leaf 时仍走入 normal memory donation 语义，最终导致 `vm_mmu_map` 失败。

## 最新状态

- 这条签名是 `crosvm` 两个前置修复之后才暴露出的新问题，不应再和“metadata 没提交 / 提交 ABI 不匹配”混在一起：
  - `generate_pci_root()` 已补齐 metadata 提交；
  - `crosvm` → KVM 的 metadata ABI 已对齐；
  - host trace 已确认 `pkvm_vm_ioctl_set_ptdev_mmio_metadata()` 真正命中。
- 当前主阻塞已前移到 `pKVM-IA` kernel / hyp：
  - BAR HPA 映射仍走 `__pkvm_host_donate_guest()`；
  - `host_initiate_donation()` 明确只接受 normal memory；
  - 因此 MMIO BAR HPA 会被 `addr not in mem_range` 拒绝。

## 根因（简述）

- 当前 `pkvm_vm_mmu_map()` 收到的是 host 已解析出的成品 `hpa`，对于这次 NVMe BAR 访问来说，这个 `hpa` 就是 `0xfe800000`。
- 在 `pKVM-IA/arch/x86/kvm/pkvm/mmu.c` 里，`guest_mmu_map_leaf()` 当前对 protected VM 默认仍走：
  - `__pkvm_host_donate_guest(data->phys, ...)`
- 进入 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c` 后：
  - `__pkvm_host_donate_guest()` 会构造 donation transition；
  - `do_donate()` 会进入 `host_initiate_donation()`；
  - `host_initiate_donation()` 在注释里已经写明：只允许 host donate normal memory，`MMIO` 不允许；
  - 随后它调用 `find_mem_range(addr, &range)` 检查这个地址是否属于 hyp 跟踪的 normal memory。
- 对 `0xfe800000` 这种 PCI BAR 物理地址来说：
  - 它不在 host RAM `mem_range`；
  - 因此 `find_mem_range()` 失败；
  - 于是直接打印 `addr not in mem_range` 并返回 `-EPERM`；
  - 最终向上冒泡成 `__pkvm_host_donate_guest failed` 和 `vm_mmu_map failed`。
- 所以当前问题已经不是“metadata 有没有记录/提交”：
  - metadata 路径已经打通；
  - 真正缺的是：Guest EPT 建 BAR leaf 时，要把合法 BAR HPA 从 donation 路径分流出去，直接按 MMIO leaf 安装，而不是把它当成 RAM page donation。

## 解决方案

- 保留这条新签名为独立问题，不覆盖旧的 metadata 问题历史。
- `B5-2` 当前应以这个运行时签名为直接驱动，补下面这条 kernel / hyp 语义缺口：
  - 基于 boot-time manifest 记录的设备 memory BAR 范围，判断 `[hpa, hpa + size)` 是否落在合法 BAR 内；
  - 命中合法 BAR 时，Guest EPT leaf 直接建图；
  - 不再走 `__pkvm_host_donate_guest()` / `host_initiate_donation()`；
  - teardown 时也不再对这些 BAR leaf 走 undonate / unshare 语义。
- 本轮先只解决“合法 BAR HPA 不应误入 donation 路径”：
  - 不额外检查 BAR 内 offset 是否正确；
  - 不依赖 `MMIO metadata` 作为 HPA 可信来源；
  - 只要求 `[hpa, hpa + size)` 必须完整落在 boot-time manifest 记录的某个 memory BAR 内。

## 验证要点

- 在相同样例下重新启动 protected pVM：
  - host `dmesg` 不应再出现
    - `host_initiate_donation: addr not in mem_range`
    - `__pkvm_host_donate_guest failed`
    - `vm_mmu_map failed`
- 同时应继续满足：
  - boot-time metadata ioctl 仍然命中；
  - 当前 BAR HPA 对应的 Guest EPT leaf 能成功建立；
  - 后续 guest 内 NVMe BAR MMIO 访问可以继续往真正的 direct MMIO 路径收敛。

## 原始日志（节选）

```text
[Sun Apr 12 14:43:57 2026] pci 0000:01:00.0: BAR 0 [mem 0xfe800000-0xfe803fff 64bit]
[Wed Apr 15 08:31:12 2026] pkvm: host_initiate_donation: addr not in mem_range addr=0xfe800000 size=0x1000 owner_id=1
[Wed Apr 15 08:31:12 2026] pkvm: do_donate: __do_donate failed ret=-1 size=0x1000 init=1 addr=0xfe800000 phys=0x0 comp=2 addr=0xd0000000 phys=0xfe800000 prot=0x77
[Wed Apr 15 08:31:12 2026] pkvm: __pkvm_host_donate_guest failed ret=-1 hpa=0xfe800000 gpa=0xd0000000 size=0x1000 prot=0x77
[Wed Apr 15 08:31:12 2026] kvm: pkvm: vm_mmu_map failed ret=-1 gpa=0xd0000000 hpa=0xfe800000 size=0x1000 writable=1 goal_level=1 pfn=0xfe800
```

## 完整原始报错信息文件

- host 原始日志：
  - [20260415-host-vm_mmu_map-fail-direct-bar-donation.log](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-012/raw/20260415-host-vm_mmu_map-fail-direct-bar-donation.log)
- 同轮验证记录：
  - [t10-p1-protected-vfio-mmio-path-0100-20260415.md](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p1-protected-vfio-mmio-path-0100-20260415.md)
  - [t10-p5-host-dmesg-vm_mmu_map-fail-after-metadata-20260415.log](/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t10-p5-host-dmesg-vm_mmu_map-fail-after-metadata-20260415.log)

## 触发条件/复现场景

- Host 内核：`pKVM-IA`
- VM 类型：protected pVM
- 透传设备：NVMe `0000:01:00.0`
- 当前前提：
  - `crosvm` 已补齐 boot-time metadata 提交；
  - `crosvm` 已对齐 protected ptdev metadata ABI；
  - 设备已绑定 `vfio-pci`
- 最小复现命令：

```bash
sudo -n env PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

## 触发路径（常见调用链）

```text
guest 访问 NVMe BAR GPA
    host KVM 缺页路径解析出 HPA = 0xfe800000                (BAR0 起始地址)
        pkvm_hypercall(vm_mmu_map, gpa, hpa, size, ...)      (host -> hyp)
            pkvm_vm_mmu_map(...)                             (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
                guest_mmu_map_leaf(...)
                    __pkvm_host_donate_guest(hpa, guest_pgt, gpa, ...)
                        do_donate(...)
                            host_initiate_donation(...)
                                find_mem_range(hpa, &range)
                                    // BAR HPA 不属于 host RAM mem_range
                                    // 返回失败
                                打印 addr not in mem_range
                        打印 __pkvm_host_donate_guest failed
                打印 vm_mmu_map failed
```

## 关联源码

- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`
  - `guest_mmu_map_leaf()` 当前 protected VM 默认走 `__pkvm_host_donate_guest()`
  - `pkvm_vm_mmu_map()` 当前根据 `hpa` 和 `gpa` 建 Guest EPT
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
  - `host_initiate_donation()` 注释明确写着只允许 donate normal memory，不允许 `MMIO`
  - `__pkvm_host_donate_guest()` 是当前失败直接入口
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - 当前已能接收并保存 ptdev MMIO metadata / allowlist，但这不负责 BAR HPA 是否误入 donation 路径的判定

## 备注

- 这条新签名的出现，正好说明当前项目已经进入 `B5-2` 的真正实现阶段：
  - 用户态 metadata 不再是主 blocker；
  - 现在需要修的是 kernel / hyp 对 BAR HPA 的 Guest EPT 建图语义。
