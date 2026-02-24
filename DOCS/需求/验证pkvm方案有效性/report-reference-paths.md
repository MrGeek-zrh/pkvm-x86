# TODOs（报告写作参考路径清单）

更新时间：2026-02-22

本文件用于记录：后续撰写“总结/汇报类报告”时需要引用的仓库内文件路径，避免遗忘。

## 实验记录与复现步骤

- `DOCS/验证-普通VM-Host可读取Guest明文内存-记录.md`：普通 VM（`PROTECTED=0`）下，Host 可从 `/memfd:crosvm_guest` 搜索并读出 Guest 明文 secret 的证据链。
- `DOCS/验证-Host无法访问pVM内存-测试计划.md`：A/B 对照验证方案（普通 VM vs pVM），包含 PID 选择、memfd 映射区间、gdb 搜索步骤与常见踩坑。
- `DOCS/问题清单.md`：已知问题索引（包含历史 crosvm 日志，例如 “Failed to map mmio page ... os error 22”）。

## 调用链分析（pVM 内存保护）

- `DOCS/分析文档/pkvm-x86-pVM内存保护关键调用链-donate与Host-EPT-violation.md`：donate / Host EPT violation / Host 侧扫描变慢甚至触发 Oops 的关键调用链（缩进调用链 + 解释）。

## IOMMU / pvIOMMU 分析文档

- `DOCS/分析文档/pkvm-x86-IOMMU管理流程-Shadow-vs-PVIOMMU.md`：Shadow IOMMU vs pvIOMMU 的流程梳理（包含 `initialize_qi` 等关键点）。
- `DOCS/分析文档/pkvm-x86-启动失败-DMAR硬件异常panic-分析.md`：`DMAR hardware is malfunctioning`（SRTP/QI/内存池相关）的分析与对策记录。

## 启动脚本与 crosvm 参数

- `scripts/run-crosvm.sh`：`PROTECTED=0/1` 开关与 crosvm 启动参数（如 `--protected-vm-without-firmware`）。

## pKVM-IA 关键源码路径（报告里引用“代码确认/代码依据”用）

- `pKVM-IA/arch/x86/include/asm/kvm_pkvm.h`：`pkvm_is_protected_vm()`（VM type 判定）等。
- `pKVM-IA/arch/x86/kvm/mmu/mmu.c`：`pkvm_page_fault()`，以及 `pkvm_hypercall(vm_mmu_map, ...)` 入口。
- `pKVM-IA/arch/x86/kvm/pkvm/pkvm.c`：`handle_kvm_call()` 与 `__pkvm__vm_mmu_map` 分发。
- `pKVM-IA/arch/x86/kvm/pkvm/mmu.c`：`pkvm_vm_mmu_map()` / `guest_mmu_map_leaf()`，决定 pVM donate vs 普通 VM share。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h`：donate/share/unshare/undonate 的语义注释（“host can't access” 等）。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`：`host_ept_set_owner_locked()` / `pkvm_pgtable_annotate()`（host EPT 解绑 + owner 标注）。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`：`handle_host_ept_violation()`（memory address 返回 `-EPERM`；MMIO slowpath）。
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/vmexit.c`：`EXIT_REASON_EPT_VIOLATION` 分发，失败时 `kvm_inject_gp()`。
- `pKVM-IA/virt/kvm/guest_memfd.c`：guest_memfd/gmem 的实现（如需写“内存后端/属性”背景可引用）。

