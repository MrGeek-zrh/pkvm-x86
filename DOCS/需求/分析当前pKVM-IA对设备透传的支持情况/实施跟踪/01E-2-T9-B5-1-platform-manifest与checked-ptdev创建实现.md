# [T9] B5-1 启动期 `platform manifest` 与 checked `ptdev` 创建实现

## 状态

- 当前状态: 验证基本完成（2026-04-12 已在 kernel `6.12.0-pkvm-ia #6` 上完成 strict `N1/N2`；主验收闭环已具备，但同轮还暴露出 reject 后 `vfio` group 需要 rebind 清理的 follow-up）
- GitHub Task: `pkvm-x86#21`
- 关联 Epic: `pkvm-x86#1`
- 前置设计 Task: `pkvm-x86#20`
- 关联设计文档:
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-B5-protected-pVM-运行期Host不可信设备校验方案设计.md`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-1-B5-1-启动期platform-manifest可信设备名单方案.md`

## 当前表现 / 当前阻塞

- 启动期 `boot-time manifest`、attach 边界的 checked `ptdev` 创建 helper，以及 shadow IOMMU 共享路径的 lock-safe `get/create` helper，当前都已在 `pKVM-IA` 工作树收敛。
- 2026-04-11 已完成一轮正向实机验证：
  - boot-known NVMe `0000:01:00.0` 在普通 VM 路径（P2）可成功透传，guest 启动到 `login:` prompt
  - 同一设备在 protected VM 路径（P1）也可成功透传，guest 启动到 `login:` prompt
  - host `dmesg` 中未出现 `reject bdf ... outside boot manifest`
- 2026-04-12 在新出现的 NVMe `0000:02:00.0` 上完成了第一轮负向样例：
  - N1：protected attach 已命中 manifest reject，方向正确
  - N2：旧实现里普通 VM 虽到达 `login:`，但 guest 内同时出现 `Identify Controller failed (-4)` / `probe with driver nvme failed with error -5`，host 侧也出现 `reject bdf ... outside boot manifest`
  - 这说明 manifest enforcement 被错误地泄露到了 non-pVM 的 legacy shadow IOMMU 共享路径
- 2026-04-12 在同一内核 `6.12.0-pkvm-ia #6` 的后续运行中，`0000:02:00.0` 又以真正的 hot-add 形式出现：
  - `pkvm: about to init IOMMU` 出现在 `14:43:58 UTC`
  - `pci 0000:02:00.0 ... Adding to iommu group 9` 出现在 `14:50:53 UTC`
  - 因此该设备重新成为 strict manifest-miss 候选，并已完成 strict `N1/N2`
- 当前剩余工作已前移到：
  - 补齐 guest 内 `lsblk` / `lspci` / `dmesg` 的枚举证据
  - 记录并后续跟进 “`N1` reject 后，同轮 `N2` 首次打开 `/dev/vfio/9` 会报 busy，需要 rebind 清理” 这一新观察（见 `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-011-manifest-reject后vfio-group-busy导致后续普通VM打开失败.md`）

## 目标

- 启动期构造并冻结 `boot-time platform manifest`
- 运行期只在 hyp 的 pVM attach 边界执行 manifest 校验
- 使 manifest 外设备：
  - 不能走显式 attach 成功
  - 不能因为普通 VM / legacy shadow IOMMU 共享路径而被错误拦截

## 修复方案摘要

### 1. 启动期 manifest

- 在 `check_and_init_iommu(pkvm)` 阶段基于 `for_each_pci_dev()` 构造 `boot-time manifest`
- 把 manifest 冻结到 `struct pkvm_hyp`
- manifest 第一阶段按最小事实建模：`bdf + flags`
- 当前 `flags` 已实际承载一个最小冻结事实位：boot-known 设备是否落在 legacy-mode IOMMU 路径

### 2. checked create helper

- 在 hyp 侧新增两类 helper：
  - `pkvm_get_or_create_ptdev_checked()`
  - `pkvm_get_or_create_ptdev()`
- 两类 helper 共用同一把 `ptdev_lock` 下的锁内原语：
  - unchecked helper 只做 `(bdf, pasid)` 查重 + miss 时创建
  - checked helper 先做 manifest lookup / policy check，再执行 `get/create`
- checked helper 当前还额外收口一个绕过点：
  - 即使同一个 `(bdf, pasid)` 已经被普通 VM / shadow IOMMU 路径物化成 `ptdev`
  - attach 路径仍要先过 manifest 校验，不能因为“对象已存在”就放行
- `pkvm_alloc_ptdev()` 继续保留为底层裸分配原语，不直接承载 manifest 策略

### 3. 显式 attach 路径

- `pkvm_attach_ptdev()` 不再在 miss 时直接调用 `pkvm_alloc_ptdev()`
- 改为先走 `pkvm_get_or_create_ptdev_checked()`
- manifest miss 时向上返回明确失败（当前计划 `-EPERM`）
- `reject bdf ... outside boot manifest` 日志也收口到 `pkvm_attach_ptdev()`，避免普通 VM 路径误打错误日志

### 4. legacy shadow IOMMU 路径

- `iommu_add_ptdev()` 不再在 miss 时直接调用 `pkvm_alloc_ptdev()`
- 改为走同一把锁下的 `pkvm_get_or_create_ptdev()`
- 这条路径只负责共享的 ptdev bookkeeping / shadow sync 所需对象物化，不承载 manifest enforcement

## 当前实现范围

- Host IOMMU = legacy mode
- 只处理 `pasid == 0`
- 单 segment
- 不覆盖 hot-remove / slot reuse
- Host-side fail-fast 本轮不作为安全边界

## 关键源码锚点

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/include/pkvm.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`

## 非目标

- 不解决“启动期已知全集里 attach 错设备”的第二层授权问题
- 不覆盖 scalable mode / `pasid != 0`
- 不覆盖 Host fail-fast / userspace 预检查
- 不覆盖 hot-remove / slot reuse / revoke / remove-path
- 不把本轮 patch 扩展成完整的 per-pVM contract / firmware 授权模型

## Review Follow-up

### 2026-04-12 补充：N2 暴露 enforcement 边界过宽

- 普通 VM 本身不会走 `kvm_arch_add_device_to_pkvm()` -> `add_ptdev` -> `pkvm_attach_ptdev()` 这条显式 attach 链。
- 但 legacy shadow IOMMU 共享路径仍会通过 `sync_shadow_context_entry()` -> `iommu_add_ptdev()` materialize `ptdev`。
- 旧实现把 manifest enforcement 同时接到了这条共享路径，结果 N2 上出现：
  - guest 到达 `login:` prompt
  - guest 内 `nvme` probe 失败
  - host `dmesg` 打出 `reject bdf ... outside boot manifest`
- 因此 T9 当前把 enforcement 明确收敛为：
  - `pkvm_attach_ptdev()`：checked
  - `iommu_add_ptdev()`：unchecked

### 已收口：boot-known 设备的模式判定分叉

- 首版实现里，`pkvm_attach_ptdev()` 用 host-wide `intel_iommu_sm` 决定是否 enforce，而 `iommu_add_ptdev()` 用的是具体 IOMMU 的 `sm_supported()`，两者在 mixed/scalable 扩展下存在潜在分叉。
- 当前已做的最小收口是：
  - 启动期构造 manifest 时，把“该 boot-known 设备是否落在 legacy-mode IOMMU 路径”冻结进 manifest `flags`
  - `pkvm_attach_ptdev()` 对 boot-known 设备改为优先参考 manifest 冻结事实，而不是只看 host-wide 模式位
- 这样至少把 **boot-known 设备** 的 attach 判定和 legacy shadow IOMMU 路径拉回到同一事实源上。

### 已记录：manifest miss 下的 mixed/scalable 残余风险

- 对于 **manifest miss** 的设备，当前 hyp 侧仍缺少一个独立于运行期 Host 的“可信 per-device IOMMU 路由真相源”。
- 因此 attach 路径在这类设备上仍只能回退到较粗粒度的 host-wide 模式判断；如果未来要正式扩到 mixed/scalable，需要单独补一轮设计与实现，而不是在 T9 里顺手扩大范围。

### 已记录：当前仍保留的系统级架构缺口

- `pkvm_attach_ptdev()` 仍保留上游已有 FIXME：如果 KVM high 没发 vmcall，pKVM 仍不知道该隔离哪个设备。
- `bdf_pasid_to_iommu()` 仍保留上游已有 TODO：当前默认假设该 `bdf/pasid` 已经进入过 sync 路径，否则无法仅靠 hyp 内现有状态找到正确 IOMMU。
- 这两点都不是本轮 patch 引入的新问题，也不是 T9 当前验收标准要解决的对象；本轮只把它们明确记录为后续系统级收敛项。

## 阶段拆分

### 阶段 1：冻结 manifest

- 在 `struct pkvm_hyp` 中补 manifest 存储
- 在 `check_and_init_iommu(pkvm)` 中构造 manifest
- 定义 manifest 容量与溢出策略

### 阶段 2：收口 checked create helper

- 定义 checked / unchecked `get/create` contract
- 收掉当前 `get` / `alloc` 分离带来的重复创建窗口

### 阶段 3：接入显式 attach

- 让 `pkvm_attach_ptdev()` 走 checked helper
- 明确 attach 被拒时的错误码和日志

### 阶段 4：接入 legacy shadow IOMMU

- 让 `iommu_add_ptdev()` 走 unchecked helper
- 明确 legacy 路径不承载 manifest enforcement

## 验收标准

1. 启动阶段成功构造并冻结 `boot-time manifest`
2. manifest 外设备走显式 attach 路径时，无法在 hyp 中创建 `ptdev`
3. manifest miss 设备走普通 VM / legacy shadow IOMMU 共享路径时，不因 manifest 校验出现错误 reject 或设备 probe 失败
4. 第一阶段范围内的启动期 legacy 设备路径不出现明显回归

## 验证方案

### 验证目标与源码对应

- 启动期 manifest 构造：
  - `check_and_init_iommu()` 中调用 `build_boot_ptdev_manifest()`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`
- 显式 attach 路径：
  - `kvm_vfio_file_add()` -> `kvm_arch_add_device_to_pkvm()` -> `add_device_to_pkvm()` -> `pkvm_attach_ptdev()`，见 `pKVM-IA/virt/kvm/vfio.c`、`pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`、`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- legacy shadow IOMMU 隐式创建路径：
  - `sync_shadow_context_entry()` -> `iommu_add_ptdev()` -> `pkvm_get_or_create_ptdev()`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/shadow_iommu.c`、`pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- 拒绝信号：
  - `pkvm_attach_ptdev()` 在 manifest miss 时打印 `reject bdf ... outside boot manifest`，见 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`

### 前置条件

- Host 使用本轮已编译通过的 `pKVM-IA` 内核。
- 当前验证环境继续沿用第一阶段范围：
  - Host IOMMU = legacy mode
  - `pasid == 0`
  - 单 segment
- 继续复用已有 crosvm 启动脚本：
  - `scripts/run-crosvm.sh`
- 正向样例继续沿用当前已知可工作的 boot-known NVMe BDF。
- 负向样例优先选“启动后新出现、启动前不存在”的 BDF：
  - 首选：启动后创建的 SR-IOV VF
  - 备选：启动后热插的新 PCI endpoint

### 用例分组

#### P1：boot-known 设备的 protected attach 不回归

- 目的：
  - 覆盖 `pkvm_attach_ptdev()` 的 accept 路径
  - 间接证明 boot manifest 至少包含当前 boot-known 设备
- 步骤：
  1. 选择一个启动前已存在的 NVMe BDF，例如 `0000:01:00.0`
  2. 按既有方式绑定到 `vfio-pci`
  3. 执行：
     - `sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=<boot-known-bdf> ./scripts/run-crosvm.sh`
- 预期：
  - crosvm 正常进入 guest 启动链
  - guest 内能看到透传设备，例如 `nvme0n1`
  - host `dmesg` 不出现 `reject bdf ... outside boot manifest`

#### P2：boot-known 设备的 legacy shadow IOMMU 路径不回归

- 目的：
  - 覆盖 `iommu_add_ptdev()` 的 accept 路径
  - 避免只验证 protected attach，而漏掉普通 VM 下的 shadow-IOMMU 创建路径
- 步骤：
  1. 仍使用同一个启动前已存在、已绑定 `vfio-pci` 的 boot-known BDF
  2. 执行：
     - `sudo PROTECTED=0 SETUP_NET=0 VFIO_DEV=<boot-known-bdf> ./scripts/run-crosvm.sh`
- 预期：
  - 普通 VM 可正常启动
  - 设备在 guest 中可见
  - host `dmesg` 不出现 manifest reject 日志

#### N1：manifest miss 设备的 protected attach 必须被拒绝

- 目的：
  - 直接验证显式 attach 路径上的 enforcement
  - 对应验收标准第 2 条
- 推荐样例：
  - 选择一个支持 SR-IOV 的 PF，并确保 boot 时 `sriov_numvfs=0`
  - 启动后再创建 `virtfn0`，得到新的 VF BDF
- 样例步骤：
  1. `PF=<boot-known-pf-bdf>`
  2. `echo 0 | sudo tee /sys/bus/pci/devices/$PF/sriov_numvfs || true`
  3. `echo 1 | sudo tee /sys/bus/pci/devices/$PF/sriov_numvfs`
  4. `VF=$(basename \"$(readlink -f /sys/bus/pci/devices/$PF/virtfn0)\")`
  5. 将 `$VF` 绑定到 `vfio-pci`
  6. 执行：
     - `sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=$VF ./scripts/run-crosvm.sh`
- 预期：
  - `kvm_vfio_file_add()` 对应 ioctl 失败，crosvm 启动失败
  - host `dmesg` 出现：
    - `pkvm_get_or_create_ptdev_checked: reject bdf ... outside boot manifest`
  - 不能把失败误判成其他已知 blocker；若没有 reject 日志，需要重新核对是否真的是 boot 后新 BDF

#### N2：manifest miss 设备的普通 VM / legacy shadow IOMMU 路径不应被 manifest 错误拦截

- 目的：
  - 直接验证 manifest enforcement 没有泄露到普通 VM 的共享 shadow IOMMU bookkeeping 路径
  - 对应验收标准第 3 条
- 设计原因：
  - 普通 VM 路径不会先走 `pkvm_attach_ptdev()`，更适合单独观察 non-pVM 的 shared shadow-IOMMU 行为
- 步骤：
  1. 继续使用 N1 中启动后新创建的 VF BDF
  2. 执行：
    - `sudo PROTECTED=0 SETUP_NET=0 VFIO_DEV=$VF ./scripts/run-crosvm.sh`
- 预期：
  - 普通 VM 不应因为 manifest miss 被 hyp 侧直接拒绝
  - host `dmesg` 不应出现 `reject bdf ... outside boot manifest`
  - guest 侧不应再出现由该校验直接导致的 `Identify Controller failed (-4)` / `probe with driver nvme failed with error -5`

### 证据采集

- host 侧：
  - `sudo dmesg -T | rg 'reject bdf|outside boot manifest|DMAR|vfio|pkvm'`
- crosvm 侧：
  - 保留 `scripts/run-crosvm.sh` 标准输出/错误和退出码
- guest 侧正向证据：
  - `lsblk`
  - `lspci -nn`
  - `dmesg | rg 'nvme|vfio'`

### 本轮执行结果（2026-04-11）

- 验证环境：
  - host 当前运行内核：`Linux ubuntu-vm 6.12.0-pkvm-ia #5 SMP PREEMPT_DYNAMIC Sat Apr 11 08:16:26 UTC 2026`
  - IOMMU 运行于 legacy 范围：host `dmesg` 显示 `intel_iommu=on,sm_off`、`DMAR: IOMMU enabled`、`DMAR: Scalable mode is disallowed`
  - 正向样例继续沿用 boot 前已存在的测试 NVMe：`0000:01:00.0`，并已绑定到 `vfio-pci`

#### P2 执行结果：普通 VM / legacy shadow IOMMU 正向样例通过

- 执行命令：
  - `sudo PROTECTED=0 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh`
- 结果：
  - 普通 VM 成功进入 Ubuntu guest 启动链，并到达 `localhost login:` prompt
  - host `dmesg` 过滤结果中未见 `reject bdf ... outside boot manifest`
- 证据：
  - crosvm / guest 启动日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-p2-normal-vm-vfio-20260411-112519.log`
  - host `dmesg` 过滤日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-p2-host-dmesg-20260411-112644.log`

#### P1 执行结果：protected VM 正向样例通过

- 首次执行：
  - `sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh`
  - 首次失败原因不是 manifest reject，而是上一轮 P2 尚未释放 `/dev/vfio/7`，报错为 `failed to open /dev/vfio/7 group: Device or resource busy`
- 释放上一轮占用后重跑：
  - `sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh`
- 结果：
  - protected VM 成功进入 Ubuntu guest 启动链，并到达 `localhost login:` prompt
  - host `dmesg` 过滤结果中同样未见 `reject bdf ... outside boot manifest`
- 证据：
  - 首次失败日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-p1-protected-vm-vfio-20260411-113059.log`
  - 重跑成功日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-p1-protected-vm-vfio-rerun-20260411-113305.log`
  - host `dmesg` 过滤日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-p1-host-dmesg-20260411-113416.log`

#### 当前结论

- 当前可以确认：
  - boot-known 设备在 protected attach 路径上没有回归
  - boot-known 设备在普通 VM / legacy shadow IOMMU 路径上也没有回归
  - strict `N1` 已确认：manifest-miss 设备在 protected attach 路径上会被 reject
  - strict `N2` 已确认：manifest-miss 设备在普通 VM / legacy shadow IOMMU 路径上不会再被 manifest 规则误拦截
  - enforcement 边界修正后，普通 VM 路径不再因为 manifest 规则而被错误打日志或错误拦截
- 当前仍未完成：
  - guest 内 `lsblk` / `lspci` / `dmesg` 的正向枚举证据补齐
  - `N1` reject 后 `vfio` group busy 的 follow-up 归因与收口（见 `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-011-manifest-reject后vfio-group-busy导致后续普通VM打开失败.md`）

### N1 / N2 前置检查结果（2026-04-11）

- 目的：
  - 寻找一个“启动后新出现、启动期 manifest 中不存在”的真实 BDF，用于执行 N1 / N2 负向验证。
- 已检查：
  - `/sys/bus/pci/devices/*/sriov_totalvfs`
  - 当前 L1 内可见 QMP / monitor socket
  - ACPI PCI hotplug 开关
  - PCI rescan 前后的 BDF 集合
- 结果：
  - 当前环境没有 `sriov_totalvfs` 文件，说明没有可直接创建 VF 的 SR-IOV PF
  - 当前 L1 内没有可见 QMP / monitor socket，无法从本机直接向外层 QEMU `device_add`
  - ACPI PCI hotplug capability 存在，但没有外部热插事件源
  - `echo 1 > /sys/bus/pci/rescan` 前后 PCI BDF 集合一致，没有新增 BDF
- 证据：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-n-precheck-hotplug-source-20260411-143158.log`
- 当前判定：
  - N1 / N2 不是代码路径已失败，而是 **负向样例前置条件不满足**
  - 下一步需要在 L0 / 外层 QEMU 侧提供一个启动后新增 PCI endpoint，或重新启动 L1 时暴露可用 QMP monitor，以便在 pKVM 初始化完成后热插新设备

### N1 / N2 执行结果（2026-04-12，边界修正前）

#### N1：protected attach 在 `0000:02:00.0` 上按预期被拒绝

- 样例来源：
  - 当前环境在 `pkvm` 初始化完成后才出现新的 NVMe `0000:02:00.0`，因此可作为 manifest-miss 候选
- 执行命令：
  - `sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:02:00.0 ./scripts/run-crosvm.sh`
- 结果：
  - crosvm 在 `KVM_DEV_VFIO_FILE_ADD` 相关路径上快速失败
  - host `dmesg` 出现 `reject bdf ... outside boot manifest`
- 证据：
  - crosvm 日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-n1-protected-vfio-0200-20260412-123815.log`
  - host `dmesg`：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-n1-host-dmesg-20260412-123901.log`

#### N2：普通 VM 在 `0000:02:00.0` 上暴露了错误的 enforcement 泄露

- 执行命令：
  - `timeout --foreground 120s sudo -n PROTECTED=0 SETUP_NET=0 VFIO_DEV=0000:02:00.0 ./scripts/run-crosvm.sh`
- 结果：
  - 普通 VM 成功进入 guest 启动链，并到达 `localhost login:`
  - 但 guest 随后出现：
    - `nvme nvme0: Identify Controller failed (-4)`
    - `nvme 0000:02:00.0: probe with driver nvme failed with error -5`
  - host `dmesg` 同时出现：
    - `pkvm_get_or_create_ptdev_checked: reject bdf 0x200 pasid 0x0 outside boot manifest`
    - `DMAR: [DMA Read NO_PASID] ... Present bit in context entry is clear`
- 判定：
  - 这不是“普通 VM 本来就该失败”
  - 而是 manifest enforcement 被错误地施加到了 non-pVM 的 legacy shadow IOMMU 共享路径
- 证据：
  - crosvm / guest 日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-n2-normal-vfio-0200-rerun2-20260412-124339.log`
  - host `dmesg`：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-n2-host-dmesg-20260412-124445.log`
  - 问题记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-010-普通VM-manifest-miss设备被错误拦截导致NVMe-probe失败.md`

### Post-fix 回归结果（2026-04-12，kernel `6.12.0-pkvm-ia #6`）

#### 环境变化：`0000:02:00.0` 已不再是 strict manifest-miss 候选

- host `dmesg` 显示：
  - `pci 0000:02:00.0: [1b36:0010] type 00 class 0x010802 PCIe Endpoint`
  - `pkvm: about to init IOMMU: enable_pkvm=1 pkvm_enabled=1 ret=0`
  - `pci 0000:02:00.0: Adding to iommu group 9`
- 这说明在当前 kernel `#6` 的启动序列里，`0000:02:00.0` 已在 manifest 冻结窗口内完成枚举，因此本轮只能把它当作 boot-known 设备做 regression，而不能再当 strict `N1/N2` 负向样例。
- 证据：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-postfix-p1-host-dmesg-20260412-140002.log`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-postfix-n2-host-dmesg-20260412-140248.log`

#### P1 回归：protected VM + `0000:02:00.0` 不回归

- 执行前先把 `0000:02:00.0` 绑定到 `vfio-pci`
- 执行命令：
  - `timeout --foreground 150s sudo -n PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:02:00.0 ./scripts/run-crosvm.sh`
- 结果：
  - guest 启动到 `localhost login:`
  - 日志以 `# exit_code=124` 收尾，对应 `timeout` 到期
  - host `dmesg` 未出现 `reject bdf ... outside boot manifest`
- 证据：
  - 绑定日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-postfix-bind-0200-vfio-20260412-135326.log`
  - crosvm / guest 日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-postfix-p1-protected-vfio-0200-20260412-135354.log`
  - host `dmesg`：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-postfix-p1-host-dmesg-20260412-140002.log`

#### N2 回归：普通 VM + `0000:02:00.0` 不再出现 manifest reject

- 首次重跑：
  - `timeout --foreground 150s sudo -n PROTECTED=0 SETUP_NET=0 VFIO_DEV=0000:02:00.0 ./scripts/run-crosvm.sh`
  - 失败原因为 `/dev/vfio/9` 仍被上一轮 root `crosvm` 占用，报错 `failed to open /dev/vfio/9 group: Device or resource busy`
- 释放旧占用后重跑同一命令。
- 结果：
  - guest 启动到 `localhost login:`
  - 手动结束实例后以 `# exit_code=130` 收尾
  - host `dmesg` 未见 `reject bdf ... outside boot manifest`
  - 也未再复现修正前 `guest nvme probe failed` 这一组症状
- 判定：
  - 这轮结果可以证明：边界修正后，普通 VM / legacy shadow IOMMU 路径不再被 manifest enforcement 错误污染
  - 但由于 `0000:02:00.0` 在 kernel `#6` 上已经是 boot-known 设备，这一轮不能替代 strict post-fix `N2`
- 证据：
  - 首次失败日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-postfix-n2-normal-vfio-0200-20260412-140018.log`
  - 重跑成功日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-postfix-n2-normal-vfio-0200-rerun-20260412-140210.log`
  - host `dmesg`：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-postfix-n2-host-dmesg-20260412-140248.log`

### Strict post-fix `N1/N2` 执行结果（2026-04-12，同一 kernel `#6` 后续热插时段）

#### 环境变化：`0000:02:00.0` 重新成为 manifest-miss 候选

- 在同一次 host 运行里，`0000:02:00.0` 并不是稳定常驻设备，而是在后续时刻重新出现：
  - `pkvm: about to init IOMMU`：`14:43:58 UTC`
  - `pci 0000:02:00.0 ... Adding to iommu group 9`：`14:50:53 UTC`
- 这说明 `0000:02:00.0` 在这轮 strict 测试时，确实满足“启动后新出现、manifest 冻结时不存在”的负向样例前提。
- 证据：
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n1-host-dmesg-20260412-145606.log`
  - `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n2-host-dmesg-20260412-150309.log`

#### Strict `N1`：protected attach 在真正的 manifest-miss 样例上被拒绝

- 执行前把 `0000:02:00.0` 绑定到 `vfio-pci`
- 执行命令：
  - `timeout --foreground 90s sudo -n PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:02:00.0 ./scripts/run-crosvm.sh`
- 结果：
  - crosvm 快速失败，报错 `failed to set KVM vfio device's attribute: Operation not permitted`
  - host `dmesg` 出现 `pkvm_attach_ptdev: reject bdf 0x200 pasid 0x0 outside boot manifest`
- 判定：
  - 这轮 strict `N1` 已证明：manifest-miss 设备在 pVM attach 边界上被明确拒绝
- 证据：
  - 绑定日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-bind-0200-vfio-20260412-145430.log`
  - crosvm 日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n1-protected-vfio-0200-20260412-145526.log`
  - host `dmesg`：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n1-host-dmesg-20260412-145606.log`

#### Strict `N2`：普通 VM 在真正的 manifest-miss 样例上不再被 manifest 误拦截

- 首次与第二次直接执行：
  - `timeout --foreground 120s sudo -n PROTECTED=0 SETUP_NET=0 VFIO_DEV=0000:02:00.0 ./scripts/run-crosvm.sh`
  - 两次都报 `failed to open /dev/vfio/9 group: Device or resource busy`
- 之后执行一次设备清理：
  - 先把 `0000:02:00.0` 从 `vfio-pci` 切回 `nvme`
  - 再重新绑定到 `vfio-pci`
- 清理后重跑同一命令。
- 结果：
  - guest 启动到 `localhost login:`
  - 手动结束实例后以 `# exit_code=130` 收尾
  - host `dmesg` 中没有新的 `reject bdf ... outside boot manifest`
  - guest 日志中也没有再出现修正前的 `Identify Controller failed (-4)` / `probe with driver nvme failed with error -5`
- 判定：
  - strict `N2` 已证明：当前 manifest enforcement 不再误伤普通 VM / legacy shadow IOMMU 路径
  - 但同轮也暴露了一个新的 cleanup 观察：`N1` reject 后，`/dev/vfio/9` 需要一次 rebind 清理才能继续打开
- 证据：
  - 首次失败日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n2-normal-vfio-0200-20260412-145653.log`
  - 第二次失败日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n2-normal-vfio-0200-rerun-20260412-145758.log`
  - 重置日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-reset-0200-vfio-20260412-150046.log`
  - 重绑日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-rebind-0200-vfio-20260412-150130.log`
  - 成功日志：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n2-normal-vfio-0200-rerun2-20260412-150203.log`
  - host `dmesg`：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t9-strict-n2-host-dmesg-20260412-150309.log`
  - follow-up 问题记录：`DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-011-manifest-reject后vfio-group-busy导致后续普通VM打开失败.md`

### 当前不纳入本轮验证

- `pasid != 0`
- scalable mode / mixed mode
- hot-remove / slot reuse
- “启动期已知全集里 attach 错设备”的第二层授权问题

### 后续探索性验证（不计入 T9 当前主验收）

- `E1`：在完成 `N1/N2` 后，追加“boot-known NVMe `01:00.0` + manifest-miss NVMe `02:00.0`”的双设备混合场景探索。
- 目的：
  - 观察“可信设备可继续 attach / 不可信新设备被拒绝”在同一轮运行中是否能同时成立；
  - 为后续多设备 / 混合 attach 方向提供早期样本。
- 当前边界：
  - 该场景超出 T9 当前“单设备、静态 attach”的主验收范围；
  - 因此只作为扩展性 / 探索性验证记录，不作为本轮 `B5-1` 的完成条件。
- 建议前提：
  - 先完成 `N1/N2`，确认 `02:00.0` 确实是 manifest-miss 并会被拒绝；
  - 再评估是否追加“同轮带上 `01:00.0` 与 `02:00.0`”的混合实验，避免把主线验收与范围外样例混在一起。
