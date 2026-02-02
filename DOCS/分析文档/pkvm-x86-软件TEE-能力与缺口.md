# pKVM-IA（pkvm-x86）Host 侧：支持什么 / 不支持什么（极简版）

范围：只从 Host/Hypervisor 功能面回答（内存隔离、设备/DMA 隔离、透传设备等），尽量只写本仓库代码/文档能直接支撑的结论。

## 支持什么（明确能看到实现/要求的）

- [x] **Host 降权运行（non-root VMX / root VMX）**：`CONFIG_PKVM_INTEL=y` 的 help 明确 host 作为 VM 跑在 non-root VMX，pKVM 跑在 root VMX。见 `pKVM-IA/arch/x86/kvm/Kconfig`。
- [x] **启动开关**：文档使用 `kvm-intel.pkvm=1` 启用。见 `docker/README.Docker.md`。
- [x] **内存隔离基础机制（页所有权/状态机 + donate/reclaim + EPT）**：`__pkvm_host_donate_hyp()`、`PKVM_PAGE_OWNED`、`pgstate_pgt` 与 EPT 相关实现路径存在。见：
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h`
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
  - `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - `pKVM-IA/arch/x86/kvm/pkvm/pkvm.c`
- [x] **CPU/vCPU 状态隔离相关实现路径**：pkvm hypervisor 侧包含 VMX/EPT、vCPU、FPU state 相关实现。见 `pKVM-IA/arch/x86/kvm/pkvm/vmx/vmx.c`、`pKVM-IA/arch/x86/kvm/pkvm/cpu.c`、`pKVM-IA/arch/x86/kvm/pkvm/fpu/`。
- [x] **设备/DMA 隔离依赖 IOMMU**：`CONFIG_PKVM_INTEL` 依赖 `INTEL_IOMMU`（强制要求）。见 `pKVM-IA/arch/x86/kvm/Kconfig` 与 `DOCS/pKVM-IA-docs/PKVM-Kconfig.md`。
- [x] **IOMMU 虚拟化（shadow/paravirt 两种路径）**：hypervisor 侧存在 IOMMU 管理逻辑，并区分 shadow / paravirt。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`。
- [x] **透传/直通设备（passthrough）隔离入口**：存在 `ptdev` 管理与 attach/detach 到 protected VM（shadow VM）的逻辑（`pkvm_attach_ptdev()` / `pkvm_detach_ptdev()`）。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`。
- [x] **（可选）pVIOMMU**：`CONFIG_PKVM_INTEL_PVIOMMU=y`（pKVM 接管 IOMMU、host 通过 hypercall 访问）。见 `pKVM-IA/arch/x86/kvm/Kconfig` 与 `DOCS/pKVM-IA-docs/PKVM-Kconfig.md`。

## 不支持什么 / 已知限制（代码/文档明确指出的）

- [ ] **“不配合也能自动隔离所有透传设备”**：源码 FIXME 指出当前透传设备隔离依赖 “KVM high 通过 vmcall 通知 pKVM 哪些设备需要隔离”；若上层创建了透传设备但未通知 pKVM，pKVM 不能保证仍能自动隔离。见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`。
- [ ] **用普通 QEMU 启动受保护 VM（文档口径）**：文档明确“必须用 crosvm（protected 选项）而不是普通 QEMU”。见 `docker/README.Docker.md`。
- [ ] **与一些常见 Host 特性兼容（硬约束）**：`KVM_INTEL` 必须内置 `=y`、`KSM` 必须关闭、`BLK_DEV_FD` 必须禁用（否则 `CONFIG_PKVM_INTEL` 过不了依赖）。见 `pKVM-IA/arch/x86/kvm/Kconfig` 与 `DOCS/pKVM-IA-docs/PKVM-Kconfig.md`。

## 未在本仓库文档中给出“肯定支持”的（需要你自行验证）

- [ ] **生产云常见能力**：直通设备的完整运维闭环（复位/热插拔/错误处理）、（热）迁移/快照/恢复、balloon/swap/THP/overcommit 等内存生命周期，在“页所有权/不可读”约束下的可用性与稳定性。
w