# 验证方案：先证明“非机密 L2”可以成功 VFIO 透传设备

目标：在你当前“L0(QEMU) -> L1(Linux) -> L2(crosvm guest)”环境下，先用 **非机密/非 protected** 的 L2 验证 VFIO 直通链路确实可用。这样后续再切到 protected L2 出问题时，可以更明确地归因到 pKVM/pVM 的 MMIO/隔离机制，而不是 VFIO/PCI/IOMMU 的基础配置问题。

本文默认你用的是仓库脚本 `scripts/run-crosvm.sh` 启动 L2，并且 L1 里能看到要直通的 PCI 设备（例如你在 QEMU 命令里额外插入的 NVMe，L1 中看到一个 BDF 如 `0000:02:00.0`）。

## 一句话结论（为什么要先测非机密）

protected L2(pVM) 里，MMIO 访问会被强制改成 hypercall 走 host 模拟（见 `pKVM-IA/arch/x86/coco/pkvm/pkvm.c` 的 `pv_ops.mmio.* = pkvm_mmio_*`），这会天然和 VFIO 透传设备 “guest 直接访问 BAR MMIO” 冲突；因此先验证非机密 L2 的 VFIO 直通可以工作，是最小成本的 sanity check。

## 前置条件检查（L1 Host）

1. 确认 L1 已开启 IOMMU（至少能产生 iommu group）
   - `ls /sys/kernel/iommu_groups/`
   - `dmesg | rg -n \"DMAR|IOMMU|intel-iommu|iommu\" | tail -n 80`

2. 确认待直通设备在 L1 可见，并记下 BDF
   - `lspci -nn | rg -n \"Non-Volatile|NVMe|你要直通的设备关键字\"`
   - 假设得到 `BDF=0000:02:00.0`（示例，按你的实际替换）

3. 确认设备所在 iommu group（建议在组粒度做隔离）
   - `readlink -f /sys/bus/pci/devices/$BDF/iommu_group`
   - `ls -la /dev/vfio/`（确保出现对应 group id 的设备节点，例如 `/dev/vfio/12`）

## 把设备绑定到 vfio-pci（L1 Host）

> 注意：下面以把“QEMU 模拟出来的 NVMe（在 L1 中是一个 PCI 设备）”绑定给 VFIO 为例。实际你也可以直通物理 PCI 设备，流程类似，但更容易踩 ACS/组隔离等问题。

1. 加载 VFIO 模块
```bash
sudo modprobe vfio
sudo modprobe vfio-pci
sudo modprobe vfio_iommu_type1
```

2. 解绑原驱动并绑定 vfio-pci
```bash
BDF=0000:02:00.0

# 记录原驱动（可选）
readlink -f /sys/bus/pci/devices/$BDF/driver || true

# 解绑
if [ -e /sys/bus/pci/devices/$BDF/driver/unbind ]; then
  echo $BDF | sudo tee /sys/bus/pci/devices/$BDF/driver/unbind >/dev/null
fi

# 获取 vendor/device id（形如 8086 1234）
VID=$(cat /sys/bus/pci/devices/$BDF/vendor)
DID=$(cat /sys/bus/pci/devices/$BDF/device)
printf \"vendor=%s device=%s\\n\" \"$VID\" \"$DID\"

# 让 vfio-pci 声明支持该 id（写入 new_id）
echo \"${VID#0x} ${DID#0x}\" | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id >/dev/null

# 绑定
echo $BDF | sudo tee /sys/bus/pci/drivers/vfio-pci/bind >/dev/null

# 确认
readlink -f /sys/bus/pci/devices/$BDF/driver
```

预期结果：driver 指向 `.../vfio-pci`；`/dev/vfio/<group>` 存在且 crosvm 有权限打开（一般需要 root 或正确的 group 权限）。

## 启动“非机密 L2”并添加 VFIO 设备

### 重要说明：`scripts/run-crosvm.sh` 已支持 `VFIO_DEV`

当前脚本 `scripts/run-crosvm.sh` 支持通过环境变量 `VFIO_DEV=<BDF>` 追加 `--vfio /sys/bus/pci/devices/<BDF>`（见 `scripts/run-crosvm.sh` 中的 `VFIO_DEV`/`VFIO_OPT` 拼接逻辑）。

因此你有两种方式：

1. 直接用脚本（推荐，复现成本最低）。
2. 手工跑 crosvm 命令（当你需要更精细的 `--vfio ...` 参数，比如 `iommu=viommu|off` 时使用）。

### 方式 A：手工运行 crosvm（推荐）

从脚本取默认路径：
- `CROSVM=$REPO_ROOT/crosvm/target/debug/crosvm`
- `IMAGE=$REPO_ROOT/images/guest/ubuntuguest.qcow2`
- `KERNEL=$REPO_ROOT/images/guest/bzImage`

在仓库根目录执行：
```bash
REPO_ROOT=$(pwd)
CROSVM=${CROSVM:-$REPO_ROOT/crosvm/target/debug/crosvm}
IMAGE=${IMAGE:-$REPO_ROOT/images/guest/ubuntuguest.qcow2}
KERNEL=${KERNEL:-$REPO_ROOT/images/guest/bzImage}
BDF=0000:02:00.0

sudo $CROSVM --log-level=debug run $KERNEL \
  --cpus num-cores=2 \
  --mem size=4096 \
  --block path=$IMAGE \
  --vfio /sys/bus/pci/devices/$BDF,iommu=viommu \
  --serial type=stdout,hardware=virtio-console,console,stdin \
  --core-scheduling false \
  -p \"root=/dev/vda1 rw\"
```

说明：
- 这里明确 **不带** `--protected-vm-without-firmware`，即非机密 L2。
- `iommu=viommu` 表示把该 VFIO 设备挂在 virtio-iommu 后面（crosvm 支持的枚举见 `crosvm/src/crosvm/cmdline.rs` 的 `--vfio` 参数说明，`iommu=viommu|coiommu|pkvm-iommu|off`）。
- 如果你只想最快验证“能看到设备并能被驱动使用”，也可以试试 `iommu=off`（但建议先用 `viommu` 保持和你后续 protected 实验更接近）。
  - 备注：`pkvm-iommu` 在本仓库的实现里带有较强的平台条件（例如 `crosvm/devices/src/vfio.rs` 中 `KvmVfioPviommu` 仅在 `android+aarch64` 下实现，其他平台会 `unimplemented!()`），在 x86_64 Linux 环境下不要指望它可用，优先用 `viommu`/`off`。

### 方式 B：用脚本跑“非机密 L2”并透传 VFIO（推荐复现链路）

脚本方式的特点是复现成本低，但 `--vfio` 的细粒度参数（例如 `iommu=viommu|off`）不如手工命令灵活：

```bash
BDF=0000:02:00.0
sudo PROTECTED=0 SETUP_NET=0 VFIO_DEV=$BDF ./scripts/run-crosvm.sh
```

## 在 L2 里验证透传是否成功

1. PCI 枚举应看到直通设备（以及它的 BAR）
   - `lspci -nn`
   - `lspci -vv -s <L2中的BDF>`

2. 如果是 NVMe，块设备应出现
   - `lsblk`
   - `dmesg | tail -n 200 | rg -n \"nvme|vfio|iommu|DMAR|pci\"`

3. 做一个最简单 I/O 压测（避免只枚举成功但读写失败）
   - `dd if=/dev/<nvmeXn1> of=/dev/null bs=1M count=256 iflag=direct`
   - 或 `fio`（如果镜像里有）

预期结果：
- 非机密 L2 能稳定启动。
- L2 能枚举到直通设备，且驱动工作（NVMe 能读写/识别 namespace）。

## 对照实验（确保失败不是“设备本身不可直通”）

1. 不带 `--vfio` 启动一次（确认 baseline 能启动）
2. 带 `--vfio` 启动非机密 L2（期望成功）
3. 再切 `--protected-vm-without-firmware`（或 `PROTECTED=1`）启动（期望可能失败）

如果步骤 2 成功、步骤 3 失败：基本就符合“pVM MMIO 走 hypercall，和 VFIO BAR MMIO 冲突”的已知方向。

## 常见失败点速查（非机密 L2）

- L1 里设备没在独立 iommu group：需要检查 `/sys/kernel/iommu_groups/*/devices/*`，并确保直通的是整个 group。
- 设备没有正确 bind 到 `vfio-pci`：检查 `/sys/bus/pci/devices/$BDF/driver`。
- `/dev/vfio/vfio` 或 `/dev/vfio/<group>` 权限问题：先用 root 跑 crosvm。
- L2 内核缺驱动：比如 NVMe 驱动没编进内核或模块没装。
