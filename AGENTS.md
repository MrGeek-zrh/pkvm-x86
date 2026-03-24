## Codex Rules
- 当需要分析代码实现和原理时，必须结合源码进行讲解，并引用相关文件路径。
- 除非用户明确要求，否则分析内核代码时默认只分析 `/home/mrgeek/pkvm-x86/pKVM-IA` 下的代码。
- 代码调用关系的临时展示使用 4 空格缩进来表示不同函数间的调用层级。
- 对复杂任务进行分阶段推进时，必须同步维护对应的任务管理文件；当任务状态、阶段结论、当前阻塞或下一步发生实质变化后，应及时更新跟踪文档，而不是等到任务结束后一次性补写。
- `pkvm-x86` 默认作为总控仓库使用：GitHub Issue、Project、文档、复现脚本、自动化和任务状态以该仓库为主。
- `pKVM-IA` 默认作为内核实现仓库使用：内核代码改动应在 `pKVM-IA` 中提交并通过独立 PR 管理。
- 复杂问题默认采用 `Issue -> 修复 PR -> superproject PR` 的闭环；其中 superproject PR 负责同步文档、脚本及必要的 submodule 指针。
- 不要求每次都同时提交 `pKVM-IA PR` 和 `pkvm-x86 PR`：
  - 若只改 `pKVM-IA` 内核代码，默认先提交 `pKVM-IA PR`。
  - 若只改 `pkvm-x86` 文档、脚本、自动化，只提交 `pkvm-x86 PR`。
  - 若 `pKVM-IA` 改动已经通过一轮验证，或需要把 superproject 固定到某个已验证的内核 commit，再提交 `pkvm-x86 PR` 更新 submodule 指针和相关文档。
  - `pkvm-x86 PR` 默认作为“集成快照 PR”使用，而不是要求每个内核提交都立即跟一个 superproject PR。
- 一个 panic/报错签名对应一个独立 bug issue；如果修复旧签名后暴露出新签名，必须新建 issue，不能继续混在旧 issue 中追踪。
- 一个 PR 只解决一个明确目标；不要在同一个 PR 中同时修复两个不同签名的问题。
- GitHub Issue/Project 作为任务状态真相来源；本地 `DOCS/.../实施跟踪` 和 `DOCS/.../问题记录` 主要保存长文分析、原始日志、源码证据和复现命令。
- 若 `pKVM-IA` 被纳入当前仓库的 submodule，则 `pkvm-x86` 中对应 PR 必须同步更新 submodule 指针，并记录所关联的 `pKVM-IA` PR/commit。
- 记录问题时，不在单个总文件持续追加；每个新问题都在 `DOCS/问题清单/` 下新建一个独立 Markdown 文件，按统一模版组织：
  - 文件名建议：`[分类-编号]-问题名.md`（如 `BOOT-001-xxx.md`、`IMG-001-xxx.md`）
  - 标题：`# [分类-编号] 问题名`
  - 必填字段：`现象`、`根因（简述）`、`解决方案`、`验证要点`
  - 证据字段（至少一项）：`原始日志（节选）` 或 `触发条件/复现场景` 或 `触发路径（常见回溯）`
  - 可选字段：`影响`、`环境信息（来自日志）`、`线索`、`备注`
  - 若涉及源码或配置开关，需写明具体文件路径、配置项或命令（必要时给最小复现命令）
- 若某个问题明确属于某个专题/需求目录，应优先记录在该专题目录下的 `问题记录/` 子目录，而不是放到通用 `DOCS/问题清单/`。
下面是一个示例：
pKVM (hypervisor)
  __pkvm_host_donate_guest(...)                    (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
    do_donate(tx)
      host_initiate_donation(tx)                  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
        host_ept_set_owner_locked(..., owner_id)  (pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c)
          pkvm_pgtable_annotate(host_ept, addr, size, annotation)
            (unmap from host EPT, keep owner info in invalid PTE)
