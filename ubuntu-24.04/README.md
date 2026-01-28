# Ubuntu 24.04 QCOW2 虚拟机配置

这个目录包含用于下载、配置和启动 Ubuntu 24.04 虚拟机的脚本。

## 功能特性

- ✅ **自动依赖检测和安装** - 自动检测系统类型并安装所需依赖
- ✅ 下载 Ubuntu 24.04 Server Cloud Image
- ✅ 自动配置用户名和密码 (mrgeek / 111)
- ✅ SSH 端口转发配置 (默认: 2222)
- ✅ 嵌套虚拟化支持
- ✅ 自动启用 KVM 加速
- ✅ 支持多种Linux发行版 (Ubuntu/Debian/CentOS/Fedora/Arch)

## 快速开始

### 1. 下载并生成新的 QCOW2（你准备重建镜像时用）

```bash
cd pkvm-x86/ubuntu-24.04
chmod +x download-and-setup.sh start-vm.sh
./download-and-setup.sh
```

这个脚本会：
- **自动检测并安装所需依赖**（qemu-utils, wget/curl, libguestfs-tools, genisoimage等）
- 下载 Ubuntu 24.04 Cloud Image
- 创建自定义镜像（qcow2 overlay，backing file 方式，体积小）
- 配置用户 `mrgeek` 和密码 `111`
- 启用 SSH 密码认证
- 配置嵌套虚拟化支持
- 在镜像里写入 `grub.d` 启动参数（默认追加 `kvm-intel.pkvm=1 intel_iommu=sm_on`，供后续安装 pKVM 内核 deb 后生效）

**注意**: 脚本会自动检测系统类型（Ubuntu/Debian/CentOS/Fedora/Arch等）并使用相应的包管理器安装依赖。如果提示需要sudo权限，请输入密码。

### 2. 启动虚拟机（纯 QCOW2 引导）

```bash
./start-vm.sh
```

或者指定自定义端口：

```bash
SSH_PORT=3333 ./start-vm.sh
```

如果需要指定 QEMU（例如使用 pkvm-x86 自带 buildtools 里的 qemu）：

```bash
QEMU_BIN=/proj/pkvmtest-PG0/hyperenclave/pkvm-x86-docker/pkvm-x86/buildtools/usr/bin/qemu-system-x86_64 ./start-vm.sh
```

是否向 Guest 暴露 IOMMU（默认暴露，便于 pKVM）：

```bash
IOMMU=1 ./start-vm.sh   # 默认（QEMU 加 -device intel-iommu,...）
IOMMU=0 ./start-vm.sh   # 禁用 IOMMU
```

### 3. 连接到虚拟机

在另一个终端中：

```bash
ssh -p 2222 mrgeek@localhost
# 密码: 111
```

### 4. 拷贝 pkvm-x86 根目录下的 deb 包到虚拟机

虚拟机已启动后，在宿主机执行（会等待 SSH 就绪后上传）：

```bash
cd pkvm-x86/ubuntu-24.04
bash scp-debs-to-vm.sh
```

若目录为 NFS/noexec 挂载无法直接 `./scp-debs-to-vm.sh`，必须使用 `bash scp-debs-to-vm.sh`。  
deb 会传到虚拟机内 `/home/mrgeek/debs/`，可通过 `SSH_PORT`、`SSH_USER`、`SSH_PASS`、`DEST_DIR` 等环境变量覆盖默认值。

### 5. 在虚拟机内安装 deb（内核/headers）

在虚拟机内执行：

```bash
cd ~/debs
sudo dpkg -i linux-image-*.deb linux-headers-*.deb
sudo apt-get -f install
sudo update-grub
sudo reboot
```

重启后验证：

```bash
uname -r
```

> 提示：`linux-image-*-dbg_*.deb` 是调试符号包，只在需要调试时再装；`linux-libc-dev_*.deb` 会被 `libc6-dev` 依赖，一般不建议在 VM 里反复卸/装它。

---

## 重要：打包 deb 前，别把 root= 写死进 bzImage（物理机/新镜像必踩坑）

我们遇到过的典型问题：内核 `.config` 里启用了 `CONFIG_CMDLINE_OVERRIDE=y` 且 `CONFIG_CMDLINE` 写死了
`root=/dev/nvme0n1p1 ...`，会导致：

- 用 `-append` 也不一定能覆盖；
- 换一张 QCOW2 或装到物理机时，直接因为 root 设备不匹配而 panic/initramfs。

建议做法：在 `pkvm-x86/linux` 里关闭 override，并清空（或至少移除 `root=`）：

```bash
cd pkvm-x86/linux

./scripts/config --disable CMDLINE_OVERRIDE
./scripts/config --set-str CMDLINE ""
make olddefconfig

# 验证 .config
grep -nE '^CONFIG_CMDLINE_OVERRIDE=|^CONFIG_CMDLINE=' .config

# 重新打包 deb（输出在上一级 pkvm-x86/）
make -j"$(nproc)" bindeb-pkg LOCALVERSION=-pkvm
```

然后用 `strings arch/x86_64/boot/bzImage | grep root=` 或 `extract-ikconfig` 再次确认 bzImage 里不再写死 root。

---

## 安装到物理机（除了装 deb，还需要设置启动参数）

是的：安装 `linux-image-*.deb` / `linux-headers-*.deb` 只是把内核放到 `/boot` 并生成 initramfs，**pKVM 相关开关通常还需要通过 bootloader 把参数传给内核**（例如 Intel 平台常用 `kvm-intel.pkvm=1`，以及 IOMMU 相关参数）。

注意：你不需要（也不建议）在物理机上“模仿” `download-and-setup.sh` 里那些只为 QCOW2/VM 兼容性做的改动，比如：

- 注释 `/etc/fstab` 里的 `/boot/efi` 挂载（这是为 QEMU/SeaBIOS 非 UEFI 启动兜底；物理机通常需要正常挂载 EFI）
- 加 `console=ttyS0,...` 之类的串口参数（更偏 QEMU 串口调试场景）
- cloud-init/virt-customize 的用户创建、SSH 配置（物理机按你自己的系统账号/SSH 策略来）

推荐做法是用 `grub.d` 追加参数（避免直接改 `/etc/default/grub` 被发行版脚本覆盖）：

```bash
sudo tee /etc/default/grub.d/99-pkvm.cfg >/dev/null <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} kvm-intel.pkvm=1 intel_iommu=sm_on"
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} kvm-intel.pkvm=1 intel_iommu=sm_on"
EOF

sudo update-grub
sudo reboot
```

重启后验证：

```bash
cat /proc/cmdline
dmesg | grep -i pkvm | head -n 80
dmesg | grep -i -E 'DMAR|IOMMU' | head -n 80
```

## 重建镜像（删除旧 qcow2 后重新来一遍）

你准备丢掉旧镜像时，直接在本目录执行：

```bash
rm -f ubuntu-24.04-custom.qcow2 cloud-init.iso
./download-and-setup.sh
IOMMU=1 ./start-vm.sh
```

然后重复“拷 deb -> 安装 deb -> update-grub -> reboot”的流程即可。

## 配置参数

### 环境变量

- `SSH_PORT`: SSH 端口转发端口（默认: 2222）
- `VM_MEMORY`: 虚拟机内存大小，单位MB（默认: 4096）
- `VM_CPUS`: 虚拟机CPU核心数（默认: 4）
- `QEMU_BIN`: QEMU 可执行文件路径（默认使用系统 `qemu-system-x86_64`）
- `IOMMU`: 是否向 Guest 暴露 IOMMU（默认: 1；设为 0 可禁用）
- `PKVM_X86_ALIGN`: 是否启用“pkvm-x86 对齐模式”（默认: 1；设为 0 可回退更简的 q35 配置）
- `KERNEL_BZIMAGE`: 直接用 `-kernel` 启动 bzImage（类似 pkvm-x86 的 `make run`；默认空表示从 qcow2 引导）
- `KERNEL_APPEND`: `-append` 的内核命令行（仅在 `KERNEL_BZIMAGE` 非空时生效）
- `ROOT_DEV`: `root=` 设备（仅在 `KERNEL_BZIMAGE` 非空时生效）
- `DISK_MODEL`: `virtio|nvme`（默认 `virtio`；`nvme` 通常需要 `-kernel` 或 UEFI）
- `EXTRA_QEMU_ARGS`: 额外传给 QEMU 的参数（空格分隔）

### 修改默认配置

编辑 `start-vm.sh` 文件中的变量：

```bash
SSH_PORT="${SSH_PORT:-2222}"      # SSH端口
VM_MEMORY="${VM_MEMORY:-4096}"    # 内存(MB)
VM_CPUS="${VM_CPUS:-4}"           # CPU核心数
```

## 嵌套虚拟化

脚本会自动检测并启用嵌套虚拟化支持。如果主机未启用，脚本会尝试启用（需要root权限）。

### 手动启用嵌套虚拟化（主机）

对于 Intel CPU:
```bash
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel nested=1
echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm.conf
```

对于 AMD CPU:
```bash
sudo modprobe -r kvm_amd
sudo modprobe kvm_amd nested=1
echo "options kvm_amd nested=1" | sudo tee /etc/modprobe.d/kvm.conf
```

验证嵌套虚拟化：
```bash
# Intel
cat /sys/module/kvm_intel/parameters/nested

# AMD
cat /sys/module/kvm_amd/parameters/nested
```

应该显示 `Y` 或 `1`。

## 文件说明

- `download-and-setup.sh`: 下载和配置镜像的脚本
- `start-vm.sh`: 启动虚拟机的脚本
- `ubuntu-24.04-server-cloudimg-amd64.qcow2`: 原始Ubuntu镜像（下载后）
- `ubuntu-24.04-custom.qcow2`: 自定义配置的镜像
- `cloud-init.iso`: Cloud-init配置ISO（如果使用cloud-init方法）
- `cloud-init/`: Cloud-init配置目录

## 故障排除

### 进入 emergency mode（常见：/boot/efi 挂载失败、multipathd 失败）

在 QEMU/SeaBIOS（非 UEFI）启动时，如果 `/etc/fstab` 里有 `/boot/efi`（例如 `LABEL=UEFI`），可能导致 `boot-efi.mount` 失败并进入 emergency mode。
处理方式：

```bash
sudo grep -n '/boot/efi' /etc/fstab
sudo sed -i 's|^\\([^#].*\\s/boot/efi\\s.*\\)$|# \\1|' /etc/fstab
sudo systemctl disable --now multipathd.service multipathd.socket || true
sudo mount -a
sudo reboot
```

### 权限问题

如果遇到 `/dev/kvm` 权限问题：

```bash
sudo chmod 666 /dev/kvm
# 或添加用户到kvm组
sudo usermod -aG kvm $USER
```

### 嵌套虚拟化未启用

1. 检查主机是否支持：
   ```bash
   cat /sys/module/kvm_intel/parameters/nested  # Intel
   cat /sys/module/kvm_amd/parameters/nested     # AMD
   ```

2. 如果显示 `N` 或 `0`，需要启用（见上方"手动启用嵌套虚拟化"）

### SSH连接失败

1. 确保虚拟机已启动并完成初始化
2. 检查端口是否被占用：
   ```bash
   netstat -tlnp | grep 2222
   ```
3. 尝试使用其他端口：
   ```bash
   SSH_PORT=3333 ./start-vm.sh
   ```

### 镜像下载失败

如果下载速度慢或失败，可以手动下载镜像：

1. 访问 https://cloud-images.ubuntu.com/releases/24.04/release/
2. 下载 `ubuntu-24.04-server-cloudimg-amd64.img` 或 `.qcow2`
3. 重命名为 `ubuntu-24.04-server-cloudimg-amd64.qcow2`
4. 放在当前目录下
5. 重新运行 `./download-and-setup.sh`

## 依赖要求

脚本会自动检测并安装以下依赖（如果缺失）：

- `qemu-system-x86_64`: QEMU虚拟机
- `qemu-img`: QEMU镜像工具
- `virt-customize` (可选): libguestfs工具，用于直接修改镜像
- `genisoimage` 或 `mkisofs`: 创建ISO镜像（如果virt-customize不可用）
- `wget` 或 `curl`: 下载镜像

### 手动安装依赖（可选）

如果自动安装失败，可以手动安装：

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install qemu-system-x86 qemu-utils libguestfs-tools genisoimage wget
```

**CentOS/RHEL/Fedora:**
```bash
# Fedora/CentOS 8+
sudo dnf install qemu-system-x86 qemu-img libguestfs-tools genisoimage wget

# CentOS/RHEL 7
sudo yum install qemu-system-x86 qemu-img libguestfs-tools genisoimage wget
```

**Arch Linux:**
```bash
sudo pacman -S qemu libguestfs cdrtools wget
```

## 注意事项

1. 首次启动可能需要一些时间来应用cloud-init配置
2. 如果使用virt-customize，配置会立即生效
3. 如果使用cloud-init，需要首次启动时挂载cloud-init.iso
4. 嵌套虚拟化需要主机CPU支持（Intel VT-x 或 AMD-V）
5. 建议至少分配4GB内存给虚拟机以获得良好性能
