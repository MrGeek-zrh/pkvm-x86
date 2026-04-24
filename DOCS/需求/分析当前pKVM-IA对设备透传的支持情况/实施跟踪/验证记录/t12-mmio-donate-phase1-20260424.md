# T12 MMIO 捐赠（donate）第一阶段源码级验证记录 - 2026-04-24

## 范围

- 内核仓库：`/home/mrgeek/pkvm-x86/pKVM-IA`
- 分支：`codex/t12-mmio-donate-phase1`
- 基线提交：`1cfdacc20432`
- 当前提交：`9f9531b5e36a`
- 本记录只覆盖源码级检查和静态风格检查；未执行对象文件级编译（object build）、未执行完整 Linux 内核编译、未执行 protected pVM 运行验证。

## 已执行命令

```bash
cd /home/mrgeek/pkvm-x86

git -C pKVM-IA branch --show-current
git -C pKVM-IA log --oneline --decorate -8
git -C pKVM-IA diff --check 1cfdacc20432..HEAD
git -C pKVM-IA grep -n "OWNER_ID_PTDEV_MMIO" -- arch/x86/kvm/vmx/pkvm/hyp
git -C pKVM-IA grep -n "pkvm_update_vm_mmio_allowlist(vm, metadata)" -- arch/x86/kvm/vmx/pkvm/hyp || true
git -C pKVM-IA grep -n "WRITE_ONCE(ptdev->dma_view_ready, true)\|dma_view_ready = true" -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c

cd /home/mrgeek/pkvm-x86/pKVM-IA
scripts/checkpatch.pl --no-tree --strict --file \
  arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h \
  arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c \
  arch/x86/kvm/vmx/pkvm/hyp/ept.h \
  arch/x86/kvm/vmx/pkvm/hyp/ept.c \
  arch/x86/kvm/vmx/pkvm/hyp/ptdev.h \
  arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
```

## 结果

- `git diff --check 1cfdacc20432..HEAD`：无输出，未发现空白错误。
- `OWNER_ID_PTDEV_MMIO`：在 `mem_protect.h` 定义，在 `mem_protect.c` 静态检查，在 `ept.c` 拒绝重映射（deny-remap）分支和 `ptdev.c` BAR revoke 路径使用。
- 旧直接发布路径 `pkvm_update_vm_mmio_allowlist(vm, metadata)`：无输出，说明 `SET_PTDEV_MMIO_METADATA` 不再直接发布 guest 访问名单（allowlist）。
- `dma_view_ready = true`：只发现 `WRITE_ONCE(ptdev->dma_view_ready, true)`，位置在 `pkvm_iommu_sync()` 成功后的 attach 路径。
- `checkpatch.pl --strict --file`：未报告 `ERROR`；报告的 `WARNING` / `CHECK` 主要包含既有 SPDX/comment style、既有 extern 声明、既有对齐风格，以及部分新增声明/调用的对齐 `CHECK`。

## 未执行项

- 未运行全量内核编译，符合当前项目规则。
- 未运行对象文件级编译（object build）；如需要，建议由用户确认构建树后再执行以下最小目标：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
make O=/home/mrgeek/pkvm-x86/build-host arch/x86/kvm/vmx/pkvm/hyp/ept.o
make O=/home/mrgeek/pkvm-x86/build-host arch/x86/kvm/vmx/pkvm/hyp/ptdev.o
make O=/home/mrgeek/pkvm-x86/build-host arch/x86/kvm/vmx/pkvm/hyp/mem_protect.o
```

- 未执行 protected pVM + VFIO 运行验证；运行验证仍需覆盖 用例 A-E。

## 后续问题

- 是否需要新建 Bug 类型 issue：否，当前没有新的 panic/报错签名。
- 是否需要新建 `Task` 类型 issue：否，当前仍在 `pkvm-x86#34` 的 T12 第一阶段实现主线内推进。
