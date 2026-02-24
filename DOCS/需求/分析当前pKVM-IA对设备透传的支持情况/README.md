# 分析当前 pKVM-IA 对 pVM 设备透传的支持情况（基于源码）

## 结论

当前 `pKVM-IA/` 的 pKVM（x86/Intel 路径）**具备“将 PCI 透传设备绑定到 pVM（protected VM）并在 pKVM hypervisor 侧做 DMA 隔离”的实现**：当 userspace 通过 KVM 的 VFIO bridge（`KVM_DEV_TYPE_VFIO`）把 VFIO fd 加入某个 VM 时，KVM 会把该 VFIO fd 对应的 `iommu_group` 中的 PCI 设备 BDF 通知给 pKVM hypervisor；hypervisor 将该设备作为 `ptdev` 绑定到 pVM，并通过 **shadow IOMMU** 把该设备的二级（Second-Level）地址翻译指向 pVM 的 `pgstate_pgt`（EPT 形态的页表），从而使该透传设备的 DMA 访问被 pKVM 强制约束在 pVM 的受保护地址空间内。

该能力在当前仓库给出的内核配置中是“可用路径”：`pKVM-IA/.config` 显示 `CONFIG_PKVM_INTEL=y` 且 `# CONFIG_PKVM_INTEL_PVIOMMU is not set`，因此编译路径会包含 `shadow_iommu.o`，并启用 `pkvm_iommu_sync()` 这条“绑定 ptdev 后立刻同步 IOMMU remapping entry”的链路。

## 支持的“设备透传”范围

这里的“设备透传”指：**把一个 PCI 设备通过 VFIO 交给 guest 使用**（userspace 常见形态是 QEMU 的 PCI passthrough），并且对 pVM 来说，pKVM 需要保证该设备 DMA 不会越权访问 primary VM / host 的内存以及 pVM 私有内存不被 primary VM 通过 IOMMU 重新映射。

从代码可见，当前实现的关键特征/约束如下：

- 仅对 **PCI 设备**生效：`kvm_arch_add_device_to_pkvm()` 在遍历 `iommu_group` 时只处理 `dev_is_pci(dev)` 的设备。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c` 的 `add_device_to_pkvm()`。
- 以 **IOMMU group** 为粒度：KVM 侧获取 VFIO fd 关联的 `iommu_group` 并遍历组内设备。见 `pKVM-IA/virt/kvm/vfio.c` 的 `kvm_vfio_file_iommu_group()`/`kvm_vfio_file_add()`。
- 当前 KVM 通知 pKVM 的 `pasid` 固定为 `0`：`add_device_to_pkvm()` 调用 `pkvm_hypercall(add_ptdev, ..., devid, 0)`。这意味着**“显式按 PASID 区分的透传设备形态（SVA/多 PASID）”在这条通知链路上不完整**，即使 hypervisor 侧 `ptdev` 结构支持 `pasid`（见 `ptdev.c`/`shadow_iommu.c`），KVM 侧目前没有把非零 PASID 透传进来。
- 透传设备的“绑定/隔离”依赖 KVM 主动通知：`pkvm_attach_ptdev()` 的注释明确写了当前依赖 “KVM high 发送 vmcall” 来让 pKVM 知道哪些设备需要隔离。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`。
- 热插拔/解绑路径不完整：`kvm_vfio_file_del()`/`kvm_vfio_release()` 没有对应的 `remove_device_from_pkvm`/`del_ptdev` 通知，`ptdev` 的解绑主要发生在 VM teardown 时（`pkvm_teardown_shadow_vm()`）。这会限制“运行时动态移除透传设备”的一致性。见 `pKVM-IA/virt/kvm/vfio.c`、`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`。

## 核心调用链（从 VFIO 透传到 pKVM 隔离）

下面只展示与“pVM 透传设备隔离”直接相关的关键路径（按函数调用层级 4 空格缩进）。

### 1) userspace 把 VFIO fd 加入 VM：KVM 侧触发 add_ptdev hypercall

KVM (ioctl 设备创建)
    kvm_ioctl_create_device(...)                                        (`pKVM-IA/virt/kvm/kvm_main.c`)
        kvm_vfio_create(...)                                            (`pKVM-IA/virt/kvm/vfio.c`)

KVM (ioctl 设置 VFIO FILE_ADD)
    kvm_vfio_set_attr(...)                                              (`pKVM-IA/virt/kvm/vfio.c`)
        kvm_vfio_set_file(..., KVM_DEV_VFIO_FILE_ADD, ...)              (`pKVM-IA/virt/kvm/vfio.c`)
            kvm_vfio_file_add(...)                                      (`pKVM-IA/virt/kvm/vfio.c`)
                kvm_vfio_file_iommu_group(...)                          (`pKVM-IA/virt/kvm/vfio.c`)
                kvm_arch_add_device_to_pkvm(kvm, iommu_grp)             (`pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`)
                    iommu_group_for_each_dev(..., add_device_to_pkvm)   (`pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`)
                        add_device_to_pkvm(dev_is_pci)                  (`pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`)
                            pkvm_hypercall(add_ptdev, vm_handle, bdf, 0) (`pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`)

### 2) pKVM hypervisor 侧接收 hypercall：ptdev 绑定到 pVM，并触发 IOMMU 同步

pKVM hypervisor (vmcall dispatch)
    handle_vmcall(...)                                                  (`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/vmexit.c`)
        pkvm_add_ptdev(shadow_vm_handle, bdf, pasid)                    (`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`)
            pkvm_attach_ptdev(bdf, pasid, vm)                           (`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`)
                pkvm_alloc_ptdev(...) / pkvm_get_ptdev(...)             (`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`)
                ptdev->pgt = &vm->pgstate_pgt                            (`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`)
                pkvm_shadow_vm_link_ptdev(...)                           (`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`)
                pkvm_iommu_sync(bdf, pasid)                              (`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`)
                    sync_shadow_id(...)                                  (`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`)
                        sync_shadow_pasid_table_entry(...)               (`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`)
                        sync_shadow_context_entry(...)                   (`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`)

> 注：`pkvm_iommu_sync()` 在 `#ifndef CONFIG_PKVM_INTEL_PVIOMMU` 下才会生效；当前 `pKVM-IA/.config` 里 PVIOMMU 未开启，因此走的是 shadow IOMMU 同步路径。

## “为什么它能隔离 DMA”：shadow IOMMU 如何把设备二级翻译指向 pVM EPT

### 1) ptdev 绑定到 pVM 后，ptdev->pgt 被切换为 pVM 的 pgstate_pgt

- `pkvm_attach_ptdev()` 在成功绑定后，将 `ptdev->pgt` 指向 `&vm->pgstate_pgt`（该 pgtable 是 EPT 形态，代表 pVM 的受保护二级映射）。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`。

### 2) shadow IOMMU 在同步 remapping entry 时，强制使用 ptdev->pgt 作为 SLPTR

scalable mode（PASID 表项）路径：

- `sync_shadow_pasid_table_entry()` 会根据 `ptdev_attached_to_vm(ptdev)` 来决定策略：如果该设备已经 attach 到 pVM，则会把 **PGTT 设置为 SL-only**，让二级翻译完全由 pKVM 控制（即 `SLPTR = ptdev->pgt->root_pa`）。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`。
- 同时会把 `domain_id`（DID）记录到 `ptdev->did`，用于后续 IOTLB flush 的 per-domain 粒度。见 `pkvm_setup_ptdev_did()` 的调用点在 `sync_shadow_pasid_table_entry()`。

legacy mode（context entry）路径：

- `sync_shadow_context_entry()` 会把 context entry 强制设置为 multi-level translation，并把 `SLPTR` 指向 `ptdev->pgt->root_pa`，从而确保 DMA 经过 EPT 形态的二级页表。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`。

额外的安全细节：

- 对设备 TLB 的处理更保守：在 scalable mode 的 context entry 同步里，如果设备不在 SATC 白名单中，会清掉 DTE（禁用设备 TLB）以降低攻击面。见 `sync_shadow_context_entry()` 中 `is_dev_in_satc()` 相关逻辑（`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`，SATC 扫描在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`）。

## 仍然存在的不支持点/不完备点（结合源码原因）

### 1) 解绑/热插拔路径缺失：KVM 删除 VFIO fd 时没有通知 pKVM

- `kvm_vfio_file_del()` 只做 `kvm_arch_end_assignment()` 等通用操作，没有对应的 `kvm_arch_remove_device_from_pkvm()` 或 `pkvm_hypercall(del_ptdev, ...)`。见 `pKVM-IA/virt/kvm/vfio.c`。
- hypervisor 侧 `ptdev` 的 detach 多发生在 VM teardown：`pkvm_teardown_shadow_vm()` 遍历 `vm->ptdev_head` 调 `pkvm_detach_ptdev()`。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`。

影响：运行时做 VFIO 设备移除/重新绑定时，pKVM 的 ptdev 跟踪与 IOMMU 同步可能不具备严格的一致性保证（至少从这条“file_del”代码路径看不到同步点）。

### 2) KVM 通知链路只传 `pasid=0`，非零 PASID 透传能力不完整

- `add_device_to_pkvm()` 的 hypercall 参数固定为 `..., devid, 0`。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`。

影响：尽管 shadow IOMMU 代码在 scalable mode 下支持按 `(bdf, pasid)` 管理 `ptdev` 并同步 PASID 表项（`sync_shadow_pasid_table_entry()`），但 KVM 侧不会把非零 PASID 透传给 pKVM；因此更复杂的 PASID/SVA 设备形态不应被认为“已支持”。

### 3) 依赖 KVM 通知：绕过 KVM-VFIO bridge 的设备透传，pKVM 未必能感知

- `pkvm_attach_ptdev()` 注释明确指出：如果 “KVM high” 没有通过 vmcall 通知 pKVM 哪些设备需要隔离，pKVM 仍然应该能隔离，但目前缺少机制。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`。

影响：当前实现更像是“对 KVM 已知的 VFIO 透传设备做隔离”，而不是对系统中所有潜在 DMA 设备做自动识别/强制隔离。

### 4) 如果未来开启 `CONFIG_PKVM_INTEL_PVIOMMU`，当前这条 attach+sync 链路需要重新验证

- 开启 PVIOMMU 会导致 `shadow_iommu.o` 不编译（`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/Makefile` 的 `ifndef CONFIG_PKVM_INTEL_PVIOMMU`），并且 `pkvm_iommu_sync()` 在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.h` 下会变成空实现。

影响：PVIOMMU 模式下设备隔离的实现路径与当前报告分析的 “shadow IOMMU + pkvm_iommu_sync” 不同，是否仍能实现 pVM 设备透传需要单独结合 PVIOMMU 设计与运行验证。

## 关键源码索引（便于进一步深挖）

- KVM-VFIO bridge：`pKVM-IA/virt/kvm/vfio.c`
- KVM 设备创建框架：`pKVM-IA/virt/kvm/kvm_main.c`
- KVM(x86) 对 pKVM capability 的入口：`pKVM-IA/arch/x86/kvm/x86.c`
- pKVM host 侧 add_ptdev 通知：`pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
- pKVM hypervisor 侧 ptdev 生命周期：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`、`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`
- pKVM hypervisor 侧 IOMMU MMIO/flush：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`
- shadow IOMMU 同步策略（核心）：`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`

