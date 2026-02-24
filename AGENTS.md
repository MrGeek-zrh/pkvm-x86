## Codex Rules
- 当需要分析代码实现和原理时，必须结合源码进行讲解，并引用相关文件路径。
- 除非用户明确要求，否则分析内核代码时默认只分析 `/home/mrgeek/pkvm-x86/pKVM-IA` 下的代码。
- 代码调用关系的临时展示使用 4 空格缩进来表示不同函数间的调用层级。
- 记录问题时，不在单个总文件持续追加；每个新问题都在 `DOCS/问题清单/` 下新建一个独立 Markdown 文件，按统一模版组织：
  - 文件名建议：`[分类-编号]-问题名.md`（如 `BOOT-001-xxx.md`、`IMG-001-xxx.md`）
  - 标题：`# [分类-编号] 问题名`
  - 必填字段：`现象`、`根因（简述）`、`解决方案`、`验证要点`
  - 证据字段（至少一项）：`原始日志（节选）` 或 `触发条件/复现场景` 或 `触发路径（常见回溯）`
  - 可选字段：`影响`、`环境信息（来自日志）`、`线索`、`备注`
  - 若涉及源码或配置开关，需写明具体文件路径、配置项或命令（必要时给最小复现命令）
下面是一个示例：
pKVM (hypervisor)
  __pkvm_host_donate_guest(...)                    (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
    do_donate(tx)
      host_initiate_donation(tx)                  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
        host_ept_set_owner_locked(..., owner_id)  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
          pkvm_pgtable_annotate(host_ept, addr, size, annotation)
            (unmap from host EPT, keep owner info in invalid PTE)
