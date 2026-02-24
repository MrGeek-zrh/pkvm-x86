# 记录：L0 用 QEMU 模拟 NVMe（L1 可枚举到 BDF）

目的：在 L0(QEMU) 中创建并挂载一个“QEMU 模拟的 NVMe PCI 设备”，确保 L1 启动后能在 `lspci` 中看到 `Non-Volatile memory controller`，从而后续可在 L1 侧做 `vfio-pci` 绑定并由 crosvm 透传给 L2（先做非机密 L2 验证）。

> 重要前提：当前链路是 **L0(QEMU) -> L1(Linux) -> L2(crosvm)**，即在 L1 里把 *L0 模拟出来的 PCIe NVMe* 再透传给 L2（nested passthrough）。
> 这条链路能否成立，关键在于 **L1 是否具备可用的 IOMMU/VFIO 环境**（最直观的检查是：L1 是否存在 `/sys/kernel/iommu_groups/`，以及目标 BDF 是否挂在某个 iommu group 下）。

## 当前已具备的后端镜像

在主机（运行 L0 QEMU 命令的环境）确认镜像存在：

```bash
pwd
ls -la nvme/nvme0.raw
```

示例路径（以当前目录为仓库根）：`/home/iscas/pkvm-x86/nvme/nvme0.raw`

## L0 启动参数参考（已启动成功可跳过）

如果要在 L0 增加 QEMU NVMe，可参考：

```bash
-device pcie-root-port,id=rp_nvme,chassis=1,slot=2 \
-drive if=none,id=nvme0,file=/home/iscas/pkvm-x86/nvme/nvme0.raw,format=raw \
-device nvme,serial=NVME0,drive=nvme0,bus=rp_nvme
```

### （可选但强烈建议）给 L1 提供 vIOMMU，便于 L1 使用 VFIO

如果你希望在 L1 里对该 BDF 做 `vfio-pci` 绑定并给 L2 透传，建议 L0(QEMU) 同时提供一个 vIOMMU（例如 Intel VT-d）。这样 L1 会产生 iommu group，从而更接近“真实设备直通”的使用方式。

提示性检查（在 L1 执行）：

```bash
ls /sys/kernel/iommu_groups/ || true
readlink -f /sys/bus/pci/devices/0000:01:00.0/iommu_group || true
```

如果上面为空/不存在，说明当前 L1 没拿到 vIOMMU（或内核没启用/没加载相关驱动），后续 VFIO 可能只能走 `vfio.noiommu=1` 之类的 “unsafe/no-iommu” 路径（不推荐用于结论性验证）。

如果不想写死用户名路径，可用：

```bash
-drive if=none,id=nvme0,file=$(pwd)/nvme/nvme0.raw,format=raw
```

说明：

- `-drive if=none,...` 提供 NVMe 的后端存储文件。
- `-device nvme,...` 把该后端暴露为一个 PCI NVMe 控制器。
- `-device pcie-root-port,...` 给 NVMe 一个明确的 PCIe 上游端口，便于枚举和调试。

## L1 启动后验证：确认能枚举到 NVMe 设备与 BDF

在 L1 里执行：

```bash
lspci -nn | rg -n 'Non-Volatile|NVMe'
sudo dmesg | rg -n 'nvme|Non-Volatile' | tail -n 80
```

预期：

- `lspci` 输出中出现 `Non-Volatile memory controller` 行。
- 该行最左侧的 `BB:DD.F` 即是 L1 视角的 BDF（完整写法通常是 `0000:BB:DD.F`）。
- 若使用 `rg -n`，前缀数字是匹配行号，不是 BDF。例如 `10:01:00.0` 中真实 BDF 是 `01:00.0`。

## 教程：从“L1 已枚举”到“L2 可见 NVMe”（非机密 L2）

### 步骤 1：在 L1 固化设备标识（BDF + serial）

```bash
lspci -nn | rg 'Non-Volatile|NVMe'
cat /sys/class/nvme/nvme0/serial
readlink -f /sys/class/nvme/nvme0/device
```

预期：

- `lspci` 中看到 `Red Hat, Inc. QEMU NVM Express Controller [1b36:0010]`。
- `serial` 为你在 L0 指定的值（如 `NVME0`）。
- `readlink` 能返回类似 `/sys/devices/.../0000:01:00.0` 的路径。

### 步骤 2：在 L1 绑定到 `vfio-pci`

```bash
BDF=0000:01:00.0
sudo modprobe vfio-pci
echo vfio-pci | sudo tee /sys/bus/pci/devices/$BDF/driver_override
echo "$BDF" | sudo tee /sys/bus/pci/devices/$BDF/driver/unbind || true
echo "$BDF" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
lspci -nnk -s 01:00.0
```

预期：

- 最后一条输出路径以 `/vfio-pci` 结尾。

### 步骤 3：启动 L2（crosvm）并透传该 BDF

推荐直接用仓库脚本（已支持 `VFIO_DEV`）：

```bash
cd ~/pkvm-x86
sudo VFIO_DEV=0000:01:00.0 PROTECTED=0 ./scripts/run-crosvm.sh
```

- 这个脚本的前提是你前面已经把这个PCI设备绑定到VFIO了

等价的原始参数方式（按你的 crosvm 命令整合）：

```bash
--vfio /sys/bus/pci/devices/0000:01:00.0
```

说明：

- `scripts/run-crosvm.sh` 中 `VFIO_DEV` 默认为空；仅当你传入 `VFIO_DEV=0000:01:00.0` 时才会追加 `--vfio`。
- 这里的路径必须是 L1 视角下、已绑定 `vfio-pci` 的 BDF 路径。
- 建议先做非机密 L2 验证链路，确认可枚举后再推进机密场景。

补充说明（机密 L2 / protected）：

- pKVM-IA 的 guest 侧会把 `pv_ops.mmio.*` 切到 `pkvm_mmio_*` 并通过 hypercall 做 MMIO（见 `pKVM-IA/arch/x86/coco/pkvm/pkvm.c`），这与 VFIO 直通设备“guest 直接访问 BAR MMIO”在机制上天然冲突。
- KVM/VFIO 层会在添加 VFIO group 时调用 `kvm_arch_add_device_to_pkvm()`，用于把直通设备信息告知 pKVM（见 `pKVM-IA/virt/kvm/vfio.c` 与 `pKVM-IA/arch/x86/kvm/vmx/pkvm/pkvm_host.c`），但这并不等价于“protected L2 一定能直接用 VFIO 设备”，仍需结合 MMIO/DMA 路径进一步验证。

### 步骤 4：在 L2 验证枚举结果

```bash
lspci -nn | rg -n 'Non-Volatile|NVMe'
sudo dmesg | rg -n 'nvme|Non-Volatile' | tail -n 80
```

预期：

- L2 的 `lspci` 出现 NVMe 控制器。
- L2 的 `dmesg` 出现 `nvme nvme0: pci function ...` 初始化日志。
