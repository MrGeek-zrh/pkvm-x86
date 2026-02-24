## Codex Rules
- 当需要分析代码实现和原理时，必须结合源码进行讲解，并引用相关文件路径。
- 代码调用关系的临时展示使用 4 空格缩进来表示不同函数间的调用层级。
下面是一个示例：
pKVM (hypervisor)
  __pkvm_host_donate_guest(...)                    (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
    do_donate(tx)
      host_initiate_donation(tx)                  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
        host_ept_set_owner_locked(..., owner_id)  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
          pkvm_pgtable_annotate(host_ept, addr, size, annotation)
            (unmap from host EPT, keep owner info in invalid PTE)