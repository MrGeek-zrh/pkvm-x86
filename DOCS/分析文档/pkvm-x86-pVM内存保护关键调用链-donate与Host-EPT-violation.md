# pKVM-IA（pkvm-x86）pVM 内存保护关键调用链：donate + Host EPT violation（解释 gdb 扫描变慢/卡住）

更新时间：2026-02-22  
适用范围：本仓库 `pKVM-IA`（Intel pKVM-x86），Host 启用 `kvm-intel.pkvm=1`，使用 crosvm 启动 protected VM（例如 `--protected-vm-without-firmware`）。

本文目标：用“缩进调用链 + 解释”的方式，基于 `pKVM-IA` 源码确认两件事：

1) pVM 的 guest RAM 页为什么会从 Host 的可访问视图里“消失”（donate）。  
2) Host（例如通过 gdb 扫描 crosvm 进程 `/memfd:crosvm_guest` 映射）访问这些页时，pKVM 代码会走什么路径（Host EPT violation -> 拒绝处理 memory address），从而导致扫描显著变慢甚至看起来卡住。

---

## 0. 核心结论（来自代码）

- pVM 场景下，guest RAM 页在建立 stage-2 映射时会走 `__pkvm_host_donate_guest()`，其语义是“Host donate pages to guest. Then host can't access these pages”（见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h` 的注释）。
- donate 的实现会把对应物理页从 **host EPT** 里 unmap（通过 `pkvm_pgtable_annotate()` 把 PTE 变成 invalid + owner annotation），因此 Host 之后再访问这些页会触发 **EPT violation**。
- pKVM hypervisor 对 Host EPT violation 的处理路径明确写了：如果 faulting GPA 被判断为 normal memory（`find_mem_range()` 命中），`handle_host_ept_violation()` 直接返回 `-EPERM`（即“不处理 memory address”，只处理 MMIO 的按需映射）。随后会在 VMExit 分发处注入 #GP。

---

## 1. Guest 首次触达某个 GPA：KVM-high 触发 hypercall，请 pKVM 建立映射

入口在 Host 内核的 x86 TDP page fault 路径中：pkvm 启用后，`kvm_tdp_page_fault()` 会走 `pkvm_page_fault()`。

```text
Guest vCPU executes load/store @ GPA
  -> stage-2 translation miss (TDP page fault)

kvm-high (Host kernel)
  kvm_tdp_page_fault()                            (pKVM-IA/arch/x86/kvm/mmu/mmu.c)
    pkvm_page_fault(vcpu, fault)                  (pKVM-IA/arch/x86/kvm/mmu/mmu.c)
      kvm_faultin_pfn(...)                        (fault in host PFN)
      topup_pkvm_memcache(...)                    (ensure pkvm mmu cache)
      pkvm_hypercall(vm_mmu_map, vcpu,            (pKVM-IA/arch/x86/kvm/mmu/mmu.c)
                     gpa, hpa, size, writable)
        (VMCALL/VMExit to pKVM hypervisor)

pKVM (kvm-low / hypervisor)
  handle_vmcall()
    handle_kvm_call(fn=__pkvm__vm_mmu_map, ...)   (pKVM-IA/arch/x86/kvm/pkvm/pkvm.c)
      pkvm_vm_mmu_map(shared_vcpu, gpa, hpa, ...) (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
        pkvm_pgtable_map(..., guest_mmu_map_leaf, ...)
          guest_mmu_map_leaf(...)
            if pkvm_is_protected_vm(kvm): __pkvm_host_donate_guest(...)
            else:                         __pkvm_host_share_guest(...)
```

解释要点：

- `pkvm_is_protected_vm(kvm)` 的定义是 `kvm->arch.vm_type == KVM_X86_PKVM_PROTECTED_VM`，见 `pKVM-IA/arch/x86/include/asm/kvm_pkvm.h`。
- 也就是说：是否走 donate，是由 VM type 决定的；crosvm 启动 protected VM 时会选择相应 VM type。

---

## 2. pVM 的关键分叉：`guest_mmu_map_leaf()` 选择 donate（Host 失去访问权）

```text
pKVM (kvm-low)
  pkvm_vm_mmu_map(...)                            (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
    pkvm_pgtable_map(..., guest_mmu_map_leaf, ...)
      guest_mmu_map_leaf(...)                     (pKVM-IA/arch/x86/kvm/pkvm/mmu.c)
        if pkvm_is_protected_vm(kvm)
          __pkvm_host_donate_guest(hpa, guest_ept, gpa, size, prot, mc)
        else
          __pkvm_host_share_guest(hpa, guest_ept, gpa, size, prot, mc)
```

解释要点：

- donate 与 share 的差别在 `mem_protect.h` 注释里写得很明确：donate 的目标是“host can't access these pages”，share 则是“host still owns the page and guest will have temporary access”。

---

## 3. donate 的实现：通过标注 invalid PTE，把页从 host EPT 视图移除

下面这段调用链解释“Host 为何不能再访问 donate 给 guest 的普通内存页”。

```text
pKVM (hypervisor)
  __pkvm_host_donate_guest(...)                    (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
    do_donate(tx)
      host_initiate_donation(tx)                  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
        host_ept_set_owner_locked(..., owner_id)  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
          pkvm_pgtable_annotate(host_ept, addr, size, annotation)
            (unmap from host EPT, keep owner info in invalid PTE)
      guest_complete_donation(tx)
        pkvm_pgtable_map(guest_ept, gpa -> hpa, prot | OWNED, ...)
```

代码层面可以直接引用 `host_ept_set_owner_locked()` 的注释（同文件 `mem_protect.c`）：它会把 `[addr, addr + size)` “unmapped from host ept”，并把 owner 信息写入 invalid PTE annotation，用于后续校验与回收流程。

---

## 4. Host 再访问这些页会发生什么：Host EPT violation 明确“不处理 memory address”

当 Host（在 deprivilege 后的 VMX non-root）访问一个已 donate 给 guest 的页时，会触发 EPT violation。pKVM 对 Host EPT violation 的处理逻辑在 hypervisor 侧的 VMExit 分发里：

```text
pKVM (hypervisor)
  handle_vmexit(...)                              (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/vmexit.c)
    case EXIT_REASON_EPT_VIOLATION:
      if (handle_host_ept_violation(vcpu)) {      (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c)
        pkvm_err("pkvm: handle host ept violation failed")
        kvm_inject_gp(vcpu, 0)
      }

  handle_host_ept_violation(vcpu)                 (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c)
    gpa = vmcs_read64(GUEST_PHYSICAL_ADDRESS)
    is_memory = find_mem_range(gpa, &range) || is_pvmfw_memory(gpa)
    if (is_memory) {
      pkvm_err("handle_host_ept_violation: not handle for memory address ...")
      return -EPERM
    }
    else:
      (MMIO slowpath: create identity map in host EPT, etc.)
```

解释要点：

- `handle_host_ept_violation()` 对 “normal memory / pvmfw” 的策略是直接拒绝（`-EPERM`），这意味着 pKVM **不会**为 Host “按需重新映射”这些内存页。
- 这正是 pVM 隔离的基础：页 donate 给 guest 后，Host 即使知道对应的用户态虚拟地址/物理页，也不能再通过 Host 的执行上下文直接读取。

---

## 5. 为什么 Host 侧线性扫描会显著变慢/看起来卡住（基于上述代码的推导）

只要 Host 侧对“已 donate 给 pVM 的页”发起读访问，就会进入第 4 节的 Host EPT violation 路径，并且：

- `handle_host_ept_violation()` 对 memory address 直接返回 `-EPERM`（不会修复映射）；
- VMExit 分发处会因此注入 #GP；

因此，任何在 Host 侧对这些页做大范围线性扫描/逐页读取的动作（例如用 gdb 在 crosvm 进程的 `/memfd:crosvm_guest` 映射上做 `find`）都会反复触发上述路径，承受大量 VMExit + 处理开销，整体表现为极慢，甚至在终端上看起来像卡住。

该结论来自第 3/4 节的两条直接代码逻辑：

1) donate 会把页从 host EPT 视图移除（`pkvm_pgtable_annotate()`）。  
2) host EPT violation 遇到 memory address 时不会被 pKVM 修复映射（返回 `-EPERM`）。

---

## 6. 运行时如何用日志“对上调用链”

要在运行时把现象和代码路径对齐，最直接的办法是边跑 gdb 扫描边看 Host `dmesg`：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c` 里 `handle_host_ept_violation()` 会打印：
  - `not handle for memory address ...`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/vmexit.c` 里 EPT violation 失败会打印：
  - `pkvm: handle host ept violation failed`

如果你在扫描期间能观察到上述日志出现并不断增长，就能把“扫描变慢”与 “Host EPT violation on memory address” 的代码路径直接对应起来。

---

## 7. 现场日志如何证明“就是它导致的”（示例解读）

下面是一段典型的现场 `dmesg` 序列（来自 Host 侧，在运行 gdb 扫描 crosvm 进程内存期间出现）：

```text
handle_host_ept_violation: not handle for memory address 0x44b888000
pkvm: handle host ept violation failed
Oops: general protection fault ... PID: ... Comm: gdb ...
RIP: __access_remote_vm+...
Call Trace:
  __access_remote_vm
  access_remote_vm
  mem_read
  vfs_read
  __x64_sys_pread64
  ...
```

对应关系（逐行对照代码）：

```text
handle_host_ept_violation: not handle for memory address ...
  -> handle_host_ept_violation() 发现 faulting GPA 属于 normal memory
     因此按策略直接返回 -EPERM
     (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c)

pkvm: handle host ept violation failed
  -> EXIT_REASON_EPT_VIOLATION 分支里调用 handle_host_ept_violation() 失败
     打印错误并对 host 注入 #GP
     (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/vmexit.c)

Oops: general protection fault ... __access_remote_vm ...
  -> gdb 扫描/读取目标进程内存会触发内核侧的 remote-vm access 读路径
     当该读路径触达“已 donate 给 pVM 的页”时会反复触发 EPT violation
     并最终在 host 内核态遭遇 #GP，表现为 GPF/Oops
```

因此，上述 dmesg 序列不仅“相关”，而是把因果链完整串起来了：

1) Host 读到了 donate 页 -> 触发 EPT violation。  
2) pKVM 按设计拒绝处理 memory address 的 Host EPT violation（返回 -EPERM）。  
3) VMExit 分发处注入 #GP -> Host 内核在执行 `__access_remote_vm()` 时触发 GPF/Oops。  

这也解释了你观察到的两个现象：

- gdb `find` 在 pVM 下会“看起来卡住”（大量 VMExit 开销）。  
- 严重时 Host 会直接 Oops（因为 #GP 发生在内核态读路径中）。  
