# GitHub Issue / PR 协作流

## 目标

把当前 pVM 设备透传任务从“本地文档主导”收敛到“GitHub Issue / PR 主导，本地文档承载长文证据”的协作模式，降低在连续修复 panic 时的状态混乱。

## 仓库角色

- `pkvm-x86`
  - 作为总控仓库使用。
  - 承载 GitHub Issue、Project、任务状态、长文文档、复现脚本和自动化。
- `pKVM-IA`
  - 作为内核实现仓库使用。
  - 承载内核代码提交、分支和 PR。

## 闭环流程

```text
pkvm-x86 Issue
    -> pKVM-IA PR
    -> pkvm-x86 PR
```

含义如下：

- `pkvm-x86 Issue`
  - 用来表达目标、阻塞、优先级和当前状态。
- `pKVM-IA PR`
  - 用来提交真正的内核代码修复。
- `pkvm-x86 PR`
  - 用来同步 `pKVM-IA` submodule 指针，并更新必要的文档、脚本、验证记录。

## 什么时候需要双 PR

- 不是每次都需要同时提交 `pKVM-IA PR` 和 `pkvm-x86 PR`。
- 只改 `pKVM-IA` 内核代码时：
  - 默认只提交 `pKVM-IA PR`。
  - 等该内核改动通过一轮验证，或需要把 superproject 固定到这个已验证 commit 时，再补 `pkvm-x86 PR`。
- 只改 `pkvm-x86` 的文档、脚本、自动化时：
  - 只提交 `pkvm-x86 PR`。
- 同时涉及内核改动和 superproject 配套收敛时：
  - 先提交 `pKVM-IA PR`。
  - 再提交 `pkvm-x86 PR` 更新 submodule 指针，并同步文档、脚本和验证记录。
- 因此，`pkvm-x86 PR` 默认是“集成快照 PR”，不是要求每个内核提交都立即跟一个 superproject PR。

## Issue 分类

- `EPIC`
  - 用来表达一条较长主线，例如“pVM 设备透传落地”。
- `TASK`
  - 用来表达一个阶段性实现目标或归因目标，例如 `T1`、`B1`、`T2`。
- `BUG`
  - 用来表达一个单独的 panic / 报错签名，例如 `BOOT-006`、`BOOT-007`。

## 关键规则

- 一个 panic/报错签名对应一个独立 bug issue。
- 如果修复旧 panic 后暴露出新 panic，必须新建 bug issue。
- 旧 bug issue 只记录“已修复并暴露出新的阻塞”，不继续混写新签名。
- 一个 PR 只解决一个明确目标，不在一个 PR 中同时修复两个不同签名的问题。
- Task issue 只描述“要完成什么”，不承担所有 panic 细节记录。

## 本地文档与 GitHub 的分工

- GitHub Issue / Project
  - 作为状态真相来源。
  - 维护优先级、归属、关联 PR 和当前 blocker。
- 本地 `DOCS/.../实施跟踪`
  - 维护较长的设计收敛、阶段判断、任务拆分和验证矩阵。
- 本地 `DOCS/.../问题记录`
  - 维护长日志、源码锚点、完整复现命令和排查过程。

## 推荐标签

- 类型
  - `type/epic`
  - `type/task`
  - `type/bug`
- 区域
  - `area/pkvm-hyp`
  - `area/pkvm-core`
  - `area/crosvm`
  - `area/vfio`
  - `area/docs`
  - `area/automation`
- 状态
  - `status/triage`
  - `status/in-progress`
  - `status/waiting-test`
  - `status/blocked`
  - `status/done`
- 优先级
  - `prio/b0`
  - `prio/p0`
  - `prio/p1`
  - `prio/p2`

## 当前建议落地映射

- `EPIC`
  - pVM 设备透传落地
- `TASK`
  - T1 清理旧 shadow spgt 残留 refcount
  - B1 NoIommu 主线运行期 EFAULT 归因
  - T2 pgstate_pgt 语义收敛为 DMA mirror
  - T3 donate 后同步 runtime DMA mirror
  - T4 VM 销毁前 quiesce ptdev DMA
- `BUG`
  - BOOT-006 机密 VM donate 失败 / refcount 冲突
  - BOOT-007 protected pVM NoIommu VFIO vcpu EFAULT

## submodule 约束

- `pKVM-IA` 纳入 `pkvm-x86` 的 submodule 管理后：
  - `pKVM-IA` PR 合并后，需要在 `pkvm-x86` 提交一个 PR 更新 submodule 指针。
  - `pkvm-x86` PR 需要记录所对应的 `pKVM-IA` PR / commit。
  - 不建议为 `pKVM-IA` 设置 `ignore = all`，否则 superproject 不容易显式暴露 submodule 指针推进。

## 当前已落地对象

- GitHub Project
  - `pkvm-x86`: `pVM 设备透传落地`
  - URL: `https://github.com/users/MrGeek-zrh/projects/3`
- 首批 issues
  - `pkvm-x86#1` `EPIC`: pVM 设备透传落地
  - `pkvm-x86#2` `TASK`: T1 清理旧 shadow spgt 残留 refcount
  - `pkvm-x86#3` `BUG`: BOOT-006 机密 VM donate 失败 / refcount 冲突
  - `pkvm-x86#4` `TASK`: B1 NoIommu 主线运行期 EFAULT 归因
  - `pkvm-x86#5` `BUG`: BOOT-007 protected pVM NoIommu VFIO vcpu EFAULT
  - `pkvm-x86#12` `TASK`: B2 protected pVM 的 VFIO config/MMIO 访问路径收敛
  - `pkvm-x86#6` `TASK`: T2 pgstate_pgt 语义收敛为 DMA mirror
  - `pkvm-x86#7` `TASK`: T3 donate 后同步 runtime DMA mirror
  - `pkvm-x86#8` `TASK`: T4 VM 销毁前 quiesce ptdev DMA
  - `pkvm-x86#9` `TASK`: T5 prepopulate 与首次 attach 路径
  - `pkvm-x86#10` `TASK`: T6 VFIO remove-path 与失败回滚
  - `pkvm-x86#11` `TASK`: T7 端到端验证矩阵与回归

## 当前流程边界

- T1 对应的内核提交 `45c072ab159184d2e98ef358e4cfde9b7451b07d` 已经直接位于 `pKVM-IA` 默认分支 `pvVMCS-POC-v6.12`。
- 因为远端默认分支已经包含该提交，当前无法再为 T1 创建一条“对默认分支有实际 diff”的正常内核 PR。
- 从下一条内核改动开始，应先在 `pKVM-IA` 创建 topic branch，再 push 并创建 PR，避免再次出现“提交已在默认分支、无法补 PR”的状态。
