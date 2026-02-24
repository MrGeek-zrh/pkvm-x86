---
title: 追踪 pKVM 为 Guest 建立映射（kprobe + perf-prof）
---

目标：在 Host 上用 kprobe 把关键函数“打点”，再用 `perf-prof` 把调用顺序/耗时串起来，验证调用链是否为：

`kvm_tdp_page_fault()` → `pkvm_page_fault()` →（VMCALL/VMExit）→ hyp `handle_vmcall()` → hyp `handle_kvm_call()` → hyp `pkvm_vm_mmu_map()` → hyp `guest_mmu_map_leaf()` → hyp `__pkvm_host_donate_guest()`/`__pkvm_host_share_guest()`

说明：
- 以下命令默认需要 `sudo`。
- 事件名是否归属 `kvm`/`kvm_intel` module 取决于你的内核编译方式；先用 `/proc/kallsyms` 确认。

## 0) 前置检查

确认 tracing 接口路径（不同发行版可能是 `tracefs` 或 `debugfs`）：

```bash
if [ -d /sys/kernel/tracing ]; then
  TRACEFS=/sys/kernel/tracing
else
  TRACEFS=/sys/kernel/debug/tracing
fi
echo "TRACEFS=$TRACEFS"
```

确认符号存在、以及属于哪个模块（末尾的 `[kvm]`/`[kvm_intel]` 很关键）：

```bash
sudo rg -n " kvm_tdp_page_fault$" /proc/kallsyms || true
sudo rg -n " pkvm_page_fault$" /proc/kallsyms || true
sudo rg -n " handle_vmcall$" /proc/kallsyms || true
sudo rg -n " handle_kvm_call$" /proc/kallsyms || true
sudo rg -n " pkvm_vm_mmu_map$" /proc/kallsyms || true
sudo rg -n " guest_mmu_map_leaf$" /proc/kallsyms || true
sudo rg -n " __pkvm_host_donate_guest$" /proc/kallsyms || true
sudo rg -n " __pkvm_host_share_guest$" /proc/kallsyms || true
```

如果你看到类似：
- `... kvm_tdp_page_fault [kvm]`：后续 `perf probe` 用 `-m kvm`
- `... __pkvm_host_donate_guest [kvm_intel]`：后续 `perf probe` 用 `-m kvm_intel`
- 没有 `[...]`：说明是 built-in，`perf probe` 不需要 `-m`

## 1) 创建 kprobe（用 perf probe，生成 `probe:*` 事件）

### 1.1 选择 module（按需）

下面用两个变量表示“函数属于哪个模块”，你需要按 0) 的输出自行填：

```bash
KVM_MOD=kvm            # 或留空（built-in）
PKVM_MOD=kvm_intel     # 或留空（built-in）
```

### 1.2 添加 probes（入口点 + 关键参数寄存器）

> 说明：这里用 SysV ABI 寄存器抓参数：`%di %si %dx %cx %r8 %r9`。如果你的 `perf probe` 支持直接用参数名，也可以把 `%di` 这种替换成参数名。

Host TDP page fault → pkvm slowpath：

```bash
sudo perf probe ${KVM_MOD:+-m $KVM_MOD} --add 'kvm_tdp_page_fault vcpu=%di fault=%si'
sudo perf probe ${KVM_MOD:+-m $KVM_MOD} --add 'pkvm_page_fault vcpu=%di fault=%si'
```

hyp：VMCALL 处理与分发：

```bash
sudo perf probe ${PKVM_MOD:+-m $PKVM_MOD} --add 'handle_vmcall vcpu=%di'
sudo perf probe ${PKVM_MOD:+-m $PKVM_MOD} --add 'handle_kvm_call fn=%di p1=%si p2=%dx p3=%cx p4=%r8 p5=%r9'
```

hyp：建立 guest stage-2 映射（关键：gpa/hpa/size/writable）：

```bash
sudo perf probe ${PKVM_MOD:+-m $PKVM_MOD} --add 'pkvm_vm_mmu_map shared_vcpu=%di gpa=%si hpa=%dx size=%cx writable=%r8'
sudo perf probe ${PKVM_MOD:+-m $PKVM_MOD} --add 'guest_mmu_map_leaf pgt=%di vaddr=%si level=%dx ptep=%cx'
```

hyp：donate/share 分叉（关键：hpa/gpa/size/prot）：

```bash
sudo perf probe ${PKVM_MOD:+-m $PKVM_MOD} --add '__pkvm_host_donate_guest hpa=%di guest_pgt=%si gpa=%dx size=%cx prot=%r8'
sudo perf probe ${PKVM_MOD:+-m $PKVM_MOD} --add '__pkvm_host_share_guest  hpa=%di guest_pgt=%si gpa=%dx size=%cx prot=%r8'
```

检查 probes 是否创建成功（应该能看到 `probe:kvm_tdp_page_fault` 之类）：

```bash
sudo perf probe -l | rg -n 'probe:(kvm_tdp_page_fault|pkvm_page_fault|handle_vmcall|handle_kvm_call|pkvm_vm_mmu_map|guest_mmu_map_leaf|__pkvm_host_(donate|share)_guest)'
sudo perf list | rg -n 'probe:(kvm_tdp_page_fault|pkvm_page_fault|handle_vmcall|handle_kvm_call|pkvm_vm_mmu_map|guest_mmu_map_leaf|__pkvm_host_(donate|share)_guest)'
```

## 2) 用 perf-prof 抓调用顺序（建议只盯住 crosvm 进程）

先拿到 crosvm 进程 PID（按你的实际进程名调整）：

```bash
PID=$(pgrep -n crosvm)   # 或：pgrep -n qemu-system-x86_64 / pgrep -n <你的vmm>
echo "PID=$PID"
```

开始追踪（你可以先跑短一点，比如 10~30 秒）：

```bash
sudo perf-prof \
  multi-trace \
  -e 'probe:kvm_tdp_page_fault//untraced/stack/,probe:pkvm_page_fault//untraced/stack/,probe:handle_vmcall//untraced/stack/,probe:handle_kvm_call//untraced/stack/,probe:pkvm_vm_mmu_map//untraced/stack/,probe:guest_mmu_map_leaf//untraced/stack/,probe:__pkvm_host_donate_guest//untraced/stack/,probe:__pkvm_host_share_guest//untraced/stack/' \
  -k common_pid \
  --perins \
  --order \
  --than 10us \
  --detail=samecpu \
  -i 1000 \
  -p "$PID" \
  -- sleep 30 | tee pkvm-map.trace.txt
```

运行期间，在 guest 里触发“首次触达某个 GPA”的场景（例如第一次访问一段新分配的大 buffer），再回来看 `pkvm-map.trace.txt` 里的顺序是否符合预期。

## 3) 清理 probes

删除本页创建的 probes：

```bash
sudo perf probe --del 'probe:kvm_tdp_page_fault' || true
sudo perf probe --del 'probe:pkvm_page_fault' || true
sudo perf probe --del 'probe:handle_vmcall' || true
sudo perf probe --del 'probe:handle_kvm_call' || true
sudo perf probe --del 'probe:pkvm_vm_mmu_map' || true
sudo perf probe --del 'probe:guest_mmu_map_leaf' || true
sudo perf probe --del 'probe:__pkvm_host_donate_guest' || true
sudo perf probe --del 'probe:__pkvm_host_share_guest' || true
```

## 4) 常见问题

1) `perf probe` 报 “Failed to find ...”：
- 先用 `/proc/kallsyms` 确认符号是否存在、是否被 inline。
- 如果符号属于模块，务必加对 `-m kvm` / `-m kvm_intel`（以你的内核为准）。

2) 参数抓不到/值不对：
- 先不抓参数，只打纯函数入口：`sudo perf probe ... --add 'func'`，确认事件能触发。
- 再逐步加 `%di/%si/...` 这种寄存器变量。

3) `-p $PID` 过滤后看不到事件：
- 说明这些函数运行的线程不在该 PID 下（例如内核线程/工作队列/不同进程上下文）。可先去掉 `-p "$PID"` 跑全局，再根据输出里的 `common_pid` 回溯到具体线程。 
