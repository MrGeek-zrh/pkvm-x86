# pKVM-x86 Docker 编译环境

本文档提供 pKVM-x86 的完整编译和部署指南。

## 内核代码结构

本项目有两套内核：**Host 内核**和 **Guest 内核**，它们的源码位置和用途不同：

| 路径 | 用途 | 说明 |
|------|------|------|
| `linux/` | **Host 内核源码** | 运行在 L1 VM 或物理机上，包含 pKVM hypervisor |
| `build/linux/` | **Guest 内核源码** | 运行在 L2 VM（受保护的虚拟机）里，从 `linux/` 拷贝而来 |

**编译流程示意：**

```
linux/  (原始 pKVM 代码)
   │
   ├── [rsync 拷贝] ──→ build/linux/ ──→ make guest-kernel ──→ Guest 内核
   │                                      (使用 nixos_guest_defconfig)
   │
   └── [打 dev-host 补丁] ──→ make kernel ──→ Host 内核
                               (使用 nixos_defconfig)
```

⚠️ **重要**：必须**先编译 Guest 内核，再打 dev-host 补丁编译 Host 内核**！
如果顺序反了，拷贝到 `build/linux/` 的代码会错误地包含 Host-only 的补丁。

---

## 目录

- [解决的编译坑](#解决的编译坑)
- [快速开始](#快速开始)
- [完整编译流程](#完整编译流程)
- [两种运行模式](#两种运行模式)
  - [模式一：QEMU 嵌套测试](#模式一qemu-嵌套测试推荐先用这个验证)
  - [模式二：物理机部署](#模式二物理机部署生产环境)
- [编译产物说明](#编译产物说明)
- [故障排除](#故障排除)

---

## 解决的编译坑

| 问题 | 容器内解决方案 |
|------|----------------|
| GCC < 12.3.1 (bug 103979) | Ubuntu 24.04 自带 GCC 13.3 |
| 内核配置交互提示 | 使用 `kconfig-auto.sh` 自动接受默认值 |
| Rust 版本过低 | 预装最新 Rust stable + x86_64-unknown-uefi target |
| Git 子模块缺失 | 自动检查 git 仓库并初始化 |
| 各种依赖缺失 | Dockerfile 预装所有编译依赖 |
| EFI 签名工具缺失 | 预装 uuid-runtime、efitools |
| Python cryptography 模块 | 预装 pip cryptography |

---

## 快速开始

```bash
# 1. 构建 Docker 镜像（仅首次）
sudo ./build.sh build-image

# 2. 进入编译环境
sudo ./build.sh shell

# 3. 在容器内执行编译（严格按顺序！）
make guest-kernel           # 先编译 Guest 内核
apply-patches linux-host    # 再打 Host 补丁
make kernel                 # 编译 Host 内核
make qemu                   # 编译 QEMU（用于启动 L1 VM）

# 编译 crosvm（在 L1 里启动受保护的 L2 VM）
cd crosvm && cargo build --features=gdb && cd ..

# 4. 创建磁盘镜像（make run 必须依赖）
make hostimage              # 主机镜像，想嵌套虚拟化使用时可能会用到
make guestimage             # 客户机镜像

# 5. 测试运行（QEMU 嵌套模式）
make run
```

---

## 完整编译流程

### 第一步：构建 Docker 镜像（仅首次）

```bash
./build.sh build-image
```

### 第二步：进入编译环境

**方式 1：进入已运行的容器（推荐）**

如果容器已经在运行（比如之前启动过 `make run`），可以直接进入：

```bash
# 查看运行中的容器
sudo docker ps

# 进入容器（使用容器 ID 或名称）
sudo docker exec -it <容器ID或名称> bash

# 例如：
sudo docker exec -it cfd289922ab2 bash
# 或
sudo docker exec -it docker-build-run-2a25bd063bd7 bash
```

**方式 2：启动新容器**

如果没有运行中的容器，使用脚本启动：

```bash
./build.sh shell
```

**提示**：`./build.sh shell` 使用 `docker-compose run --rm`，会在退出时自动删除容器。如果需要在后台保持容器运行，建议使用 `docker-compose up -d` 或直接 `docker exec` 进入已运行的容器。

### 第三步：初始化子模块（如果代码已经下载好了，就不需要执行了）

```bash
./build.sh init-submodules
```

### 第三步：应用补丁

**补丁状态说明：**

| 组件 | 状态 | 说明 |
|------|------|------|
| Linux 内核 (pKVM核心) | ✅ 已包含 | 子模块已经是带 pKVM 补丁的版本 |
| Linux 内核 (dev-host) | ⚠️ 单独应用 | Host 专用补丁，**先编译 Guest 后再应用** |
| QEMU | ❌ 需要应用 | `patches/qemu/` |
| Coreboot | ❌ 需要应用 | `patches/coreboot/` |
| EDK2 | ❌ 需要应用 | `patches/edk2/` |

```bash
# 应用通用补丁（不含 linux-host）
./build.sh apply-patches all

# 查看可用补丁
./build.sh apply-patches check
```

### 第四步：编译（⚠️ 顺序很重要！）

由于 **Guest 内核是从 `linux/` 拷贝编译的**，必须按以下顺序操作：

```bash
./build.sh shell

# 容器内执行 - 严格按顺序！
# 1. 先编译 Guest 内核（此时 linux/ 未打 dev-host 补丁）
make guest-kernel

# 2. 再应用 Host 内核专用补丁
apply-patches linux-host

# 3. 编译 Host 内核
make kernel

# 4. 编译 QEMU（用于启动 L1 VM）
make qemu

# 5. 编译 crosvm（在 L1 里启动受保护的 L2 VM）
cd crosvm && cargo build --features=gdb && cd ..
```

**为什么顺序很重要？**

```
linux/ (原始 pKVM 代码)
   │
   ├──→ [拷贝] → build/linux/ → Guest 内核 (不含 dev-host)
   │
   └──→ [打 dev-host 补丁] → Host 内核 (含 KVM/nVMX 修复)
```

如果先打 dev-host 补丁再编译 Guest，Guest 内核会错误地包含 Host-only 的代码！

---

## 两种运行模式

pKVM 有两种测试/部署方式，根据你的需求选择：

### 模式一：QEMU 嵌套测试（推荐先用这个验证）

在 QEMU 虚拟机里跑 pKVM，适合开发调试，**不需要重启物理机**。

**架构图（三层嵌套）：**

```
┌─────────────────────────────────────────────────────┐
│  物理机 (你的服务器)                                  │
│  ┌─────────────────────────────────────────────────┐│
│  │  QEMU (编译的定制版)         ← make run 启动这个 ││
│  │  ┌───────────────────────────────────────────┐  ││
│  │  │  L1 VM (Host Kernel + pKVM)               │  ││
│  │  │  内核参数: kvm-intel.pkvm=1               │  ││
│  │  │  ┌─────────────────────────────────────┐  │  ││
│  │  │  │  L2 VM (Guest Kernel - 受保护的VM)  │  │  ││
│  │  │  │  (在 L1 里用 crosvm 创建)            │  │  ││
│  │  │  └─────────────────────────────────────┘  │  ││
│  │  └───────────────────────────────────────────┘  ││
│  └─────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────┘
```

**运行步骤：**

```bash
./build.sh shell

# 1. 先创建磁盘镜像（必须！make run 依赖磁盘镜像），执行过就不需要执行了
make hostimage    # 创建 L1 主机镜像（完整 Ubuntu 系统）
make guestimage   # 创建 L2 客户机镜像（在 L1 里使用）

# 2. 在容器里启动 QEMU
make run
```

**注意**：`make run` 需要 `images/host/ubuntuhost.qcow2` 磁盘镜像存在，否则 QEMU 会报错退出。
镜像里包含完整的 Ubuntu rootfs（apt、systemd、sshd 等），启动后可以 SSH 登录（端口 10022）。

**虚拟机登录信息：**

| 项目 | 值 |
|------|-----|
| **用户名** | `ubuntu` |
| **密码** | 空（直接回车） |
| **SSH 端口** | `10022` |
| **IP 地址** | `192.168.7.2`（虚拟机内） |
| **sudo 权限** | 已配置，可使用 `sudo` |

**登录方式：**

```bash
# 方式 1：从宿主机通过端口转发（推荐）
ssh ubuntu@<宿主机IP> -p 10022

# 方式 2：从容器内直接连接（如果网络配置允许）
ssh ubuntu@192.168.7.2

# 方式 3：在 QEMU 控制台直接登录
# 在 make run 启动的终端中，直接输入用户名 ubuntu，密码留空回车
```

**提示**：SSH 已配置为允许空密码登录，无需输入密码即可登录。

**3. 在 L1 虚拟机里启动 L2 受保护虚拟机（crosvm）**

登录到 L1 虚拟机后，需要将编译产物（crosvm 和 Guest 镜像）传输到 L1 虚拟机中，然后使用 crosvm 启动 L2 VM。

**步骤：**

```bash
# 1. 从宿主机/容器复制 crosvm 和 Guest 镜像到 L1 虚拟机
# 方式 A：通过 SCP（推荐）
scp -P 10022 /workspace/pkvm-x86/crosvm/target/debug/crosvm ubuntu@<宿主机IP>:~/
scp -P 10022 /workspace/pkvm-x86/images/guest/ubuntuguest.qcow2 ubuntu@<宿主机IP>:~/
scp -P 10022 /workspace/pkvm-x86/build/linux/arch/x86_64/boot/bzImage ubuntu@<宿主机IP>:~/guest-bzImage

# 方式 B：如果 L1 虚拟机可以访问宿主机文件系统（通过挂载）
# 在 L1 虚拟机内直接访问挂载的目录

# 2. SSH 登录到 L1 虚拟机
ssh ubuntu@<宿主机IP> -p 10022

# 3. 在 L1 虚拟机内验证 pKVM 已启用
dmesg | grep -i pkvm
# 应该看到：
# pkvm_host_deprivilege_cpu: CPU0 in guest mode
# pkvm_host_deprivilege_cpus: all cpus are in guest mode!

# 4. 给 crosvm 添加执行权限
chmod +x ~/crosvm

# 5. 使用 crosvm 启动 L2 虚拟机
# 注意：本仓库的 crosvm 版本使用“位置参数”指定内核路径（不是 --kernel）。
sudo ~/crosvm run ~/bzImage \
    --protected-vm-without-firmware \
    --cpus num-cores=2 \
    --mem size=4096 \
    --block path=~/ubuntuguest.qcow2 \
    -p "root=/dev/vda1 rw console=ttyS0"

# 或者使用提供的脚本（需要先复制 run-crosvm.sh 到 L1 虚拟机）
# sudo IMAGE=~/ubuntuguest.qcow2 KERNEL=~/guest-bzImage CROSVM=~/crosvm ./run-crosvm.sh
```

启动后，登录用户名还是ubuntu

**注意事项：**

- ⚠️ **必须使用 `--protected-vm-without-firmware` 选项**，否则会报 VMX 错误
- L1 虚拟机需要支持嵌套虚拟化（KVM），`make run` 启动的 QEMU 已配置 `--accel kvm`
- 如果网络配置有问题，可以使用脚本 `scripts/run-crosvm.sh`，它会自动配置 TAP 网络
- Guest 镜像路径：`images/guest/ubuntuguest.qcow2`
- Guest 内核路径：`build/linux/arch/x86_64/boot/bzImage`

**运行选项：**

| 变量 | 说明 |
|------|------|
| `DEBUGGER=1` | 启用 GDB 调试（启动时暂停） |
| `VNC=1` | 启用 VNC 显示 |
| `GRAPHICS=1` | 启用 SPICE 图形 |
| `BIOS=1` | 使用 Coreboot BIOS |
| `OPENFW=1` | 使用 firmware-open (UEFI) |

```bash
# 示例
DEBUGGER=1 make run    # 带调试器
GRAPHICS=1 make run    # 带图形界面
```

---

### 模式二：物理机部署（生产环境）

直接在物理机上安装 pKVM Host Kernel，获得真正的硬件隔离保护。

**架构图（两层）：**

```
┌─────────────────────────────────────────────────────┐
│  物理机 (直接运行 pKVM Host Kernel)                   │
│  内核参数: kvm-intel.pkvm=1                          │
│  ┌─────────────────────────────────────────────────┐│
│  │  crosvm --protected-vm-without-firmware         ││
│  │  ┌───────────────────────────────────────────┐  ││
│  │  │  Guest VM (受 pKVM 保护的虚拟机)           │  ││
│  │  │  使用 Guest Kernel                        │  ││
│  │  └───────────────────────────────────────────┘  ││
│  └─────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────┘
```

#### ⚠️ 重要：必须使用 crosvm，不能用普通 QEMU！

根据 [pKVM-IA Issue #35](https://github.com/intel-staging/pKVM-IA/issues/35)，pKVM 会把 Host 降权到 guest mode，普通 QEMU 不知道这个变化，直接操作 VMCS 会报错：

```
VMX failed: 2/12
kvm_intel: vmwrite failed: field=8 val=fff err=0
pkvm_pgstate_pgt_map_leaf failed: ret -1 ...
```

**必须使用 crosvm 并开启 `--protected-vm-without-firmware` 选项！**

#### 部署步骤：

**1. 安装 Host Kernel 到物理机**

⚠️ 强烈建议：在“只有 SSH、没有控制台/IPMI/快照”的机器上，不要做“覆盖式替换”。正确做法是**并存安装新内核**，确保 GRUB 里还能选回旧内核，以便随时回滚。

**0) 安装前检查（强烈建议）**

```bash
# 确认新内核版本号不会覆盖当前运行内核（两者必须不同）
uname -r
make -s kernelrelease

# 检查 /boot 空间（空间不足会导致 initramfs / grub 生成失败）
df -h /boot

# 检查是否有 DKMS 模块（升级内核后可能需要重编译）
dkms status || true
```

**建议给自编译内核加唯一后缀，避免未来“撞版本号”覆盖：**

- 例如编译/打包时使用：`LOCALVERSION=-pkvm`
- 最终 `uname -r` 形如：`6.12.x+-pkvm`

---

### 方式 A（推荐）：打包成 `.deb` 再安装（更“Ubuntu 化”，便于回滚/卸载）

这种方式更稳：内核、模块、headers 都以包的形式安装，后续回滚/卸载更清晰。

```bash
cd /path/to/pkvm-x86/linux

# 如首次在这台机器上打包，可能需要安装打包依赖
sudo apt update
sudo apt install -y build-essential bc bison flex libelf-dev libssl-dev fakeroot dpkg-dev

# 生成 deb 包（输出在源码上一级目录）
make -j"$(nproc)" bindeb-pkg LOCALVERSION=-pkvm

# 安装 deb 包
cd ..
sudo dpkg -i linux-image-*.deb linux-headers-*.deb

# 可选：调试符号包（仅调试需要）
# sudo dpkg -i linux-image-*-dbg_*.deb

# 可选：用户态开发头（一般不影响“能否启动新内核”）
# sudo dpkg -i linux-libc-dev_*.deb
sudo update-grub
```

**安装完成后，建议在重启前先验证 DKMS 是否能为新内核编译（很关键）：**

```bash
# 以你刚安装的新内核版本为准（应与 /lib/modules/<版本>/ 目录一致）
KVER="$(make -s -C /path/to/pkvm-x86/linux kernelrelease)"
echo "KVER=$KVER"
sudo dkms autoinstall -k "$KVER"
sudo dkms status
```

出现下面这个就是正确的：
```
$ sudo dkms status
Deprecated feature: REMAKE_INITRD (/var/lib/dkms/emulab-ipod-dkms/3.5.0/source/dkms.conf)
Deprecated feature: REMAKE_INITRD (/var/lib/dkms/emulab-ipod-dkms/3.5.0/source/dkms.conf)
emulab-ipod-dkms/3.5.0, 6.12.58-pkvm, x86_64: installed
emulab-ipod-dkms/3.5.0, 6.8.0-71-generic, x86_64: installed
```

若 DKMS 编译失败（尤其是你依赖的模块），建议先解决 DKMS 问题，再重启进入新内核。


**2. 配置内核启动参数**

编辑 `/etc/default/grub`：

```
GRUB_CMDLINE_LINUX="kvm-intel.pkvm=1"
```

然后更新 GRUB：

```bash
sudo update-grub
```

**3. 重启进入 pKVM 内核**

⚠️ 这里只有 SSH、无法接触 GRUB 界面：不要依赖“开机手动选择内核”。建议用 GRUB 的 **reboot-once** 机制先试跑新内核，确认没问题再把它设为默认。

首次试跑（只下一次进入 pKVM 内核，失败更容易回滚）：

```bash
# 1) 列出可用启动项（包含子菜单层级），找到带 6.12 / pkvm 的那一条
sudo awk -F"'" '
  /^[[:space:]]*submenu / {subm=$2}
  /^[[:space:]]*menuentry / {
    title=$2
    if (subm != "") print subm ">" title; else print title
  }' /boot/grub/grub.cfg | nl -ba | head -n 200

```
     1  Ubuntu
     2  Advanced options for Ubuntu>Ubuntu, with Linux 6.12.58-pkvm
     3  Advanced options for Ubuntu>Ubuntu, with Linux 6.12.58-pkvm (recovery mode)
     4  Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-71-generic
     5  Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-71-generic (recovery mode)
     6  Advanced options for Ubuntu>UEFI Firmware Settings
```

# 2) 把上面输出里对应条目的 “子菜单>标题” 整段复制到这里（只生效一次）
sudo grub-reboot "<子菜单>标题 或 标题>"
例如：
```
sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 6.12.58-pkvm"
```
sudo reboot
```

重连后验证：

```bash
uname -r
dmesg | grep -i pkvm | head
dkms status
```

确认稳定后（把 pKVM 内核设为默认）：

```bash
sudo grub-set-default "<子菜单>标题 或 标题>"
sudo update-grub
```

注意：保持旧内核（例如 6.8）在系统里，不要删除，作为随时回滚的救命绳。

**4. 验证 pKVM 是否启用**

```bash
dmesg | grep -i pkvm
# 应该看到类似输出：
# pkvm_host_deprivilege_cpu: CPU0 in guest mode
# pkvm_host_deprivilege_cpus: all cpus are in guest mode!
```

**5. 使用 crosvm 启动受保护的 Guest VM**

本仓库已提供配置好的脚本 `scripts/run-crosvm.sh`：

```bash
# 设置环境变量
export IMAGE="path/to/guest-disk.qcow2"
export KERNEL="build/linux/arch/x86_64/boot/bzImage"

# 运行（需要 root 权限配置网络）
sudo ./scripts/run-crosvm.sh
```

或手动运行：

```bash
crosvm run build/linux/arch/x86_64/boot/bzImage \
    --protected-vm-without-firmware \
    --cpus num-cores=4 \
    --mem size=4096 \
    --block path=/path/to/guest.qcow2 \
    -p "root=/dev/vda1 rw console=ttyS0"
```

---

## 编译产物说明

| 路径 | 说明 | 用途 |
|------|------|------|
| `linux/arch/x86_64/boot/bzImage` | Host 内核 | 安装到物理机或 L1 VM |
| `build/linux/arch/x86_64/boot/bzImage` | Guest 内核 | 给 crosvm/QEMU 启动 L2 VM |
| `images/host/ubuntuhost.qcow2` | Host 磁盘镜像 | `make hostimage` 生成，L1 VM 的完整 Ubuntu 系统 |
| `images/guest/ubuntuguest.qcow2` | Guest 磁盘镜像 | `make guestimage` 生成，L2 VM 使用 |
| `crosvm/target/debug/crosvm` | crosvm 可执行文件 | 在 L1 里启动受保护的 L2 VM |
| `buildtools/usr/bin/qemu-system-x86_64` | 定制版 QEMU | QEMU 嵌套测试模式使用 |
| `build/shim/` | Shim 启动加载器 | Secure Boot 场景 |
| `build/keydata/` | 签名密钥 | 签名相关组件 |
| `build/*.rom` | Firmware ROM | UEFI/Coreboot 启动 |

**注意**：如果使用 `EFI=1` 参数创建镜像，输出文件名会变成 `ubuntuhost-efi.qcow2` / `ubuntuguest-efi.qcow2`。

### 镜像扩容

如果创建的镜像空间不足，可以使用 `qemu-img` 扩容：

**扩容 Guest 镜像（例如扩容到 50GB）：**

```bash
# 1. 扩容 qcow2 镜像文件（在宿主机或容器内执行）
qemu-img resize images/guest/ubuntuguest.qcow2 50G

# 2. 在 L2 虚拟机内扩展文件系统（启动 L2 VM 后执行）
# 登录到 L2 虚拟机，然后：
sudo growpart /dev/vda 1        # 扩展分区（如果使用 growpart）
# 或者使用 fdisk 手动扩展分区

sudo resize2fs /dev/vda1       # 扩展 ext4 文件系统
# 如果是其他文件系统，使用对应命令：
# sudo xfs_growfs /dev/vda1    # XFS 文件系统
```

**扩容 Host 镜像：**

```bash
# 扩容镜像文件
qemu-img resize images/host/ubuntuhost.qcow2 50G

# 在 L1 虚拟机内扩展文件系统（启动 L1 VM 后执行）
sudo growpart /dev/nvme0n1 1   # 扩展分区
sudo resize2fs /dev/nvme0n1p1  # 扩展文件系统
```

**提示**：`qemu-img resize` 只会扩展镜像文件大小，不会自动扩展分区和文件系统。需要在虚拟机内手动扩展分区和文件系统才能使用新增的空间。

---

## 目录结构

```
pkvm-x86/
├── docker/                  # Docker 编译环境配置
│   ├── Dockerfile           # 编译环境定义
│   ├── docker-compose.yml   # Docker Compose 配置
│   ├── build.sh             # 编译助手脚本
│   └── README.Docker.md     # 本文档
├── Makefile                 # 主 Makefile
├── scripts/                 # 各种辅助脚本
│   ├── run-crosvm.sh        # crosvm 启动脚本（已配置 protected-vm）
│   └── ...
├── linux/                   # Linux 内核源码 (已含 pKVM 补丁)
├── qemu/                    # QEMU 源码
├── crosvm/                  # crosvm 源码
├── coreboot/                # Coreboot 源码
├── uefi/                    # UEFI 相关
│   ├── firmware-open/       # EDK2 等
│   └── shim/
├── patches/                 # 补丁文件
│   ├── dev-host/            # Host 内核专用补丁
│   ├── qemu/
│   ├── coreboot/
│   └── edk2/
├── build/                   # 编译产物输出
└── buildtools/              # 编译工具
```

---

## 故障排除

### NFS 配额超限（Disk quota exceeded）

如果在创建磁盘镜像时遇到 `Disk quota exceeded` 错误：

```
mkdir: cannot create directory '/workspace/pkvm-x86/images/guest': Disk quota exceeded
```

这通常是因为 `/workspace/pkvm-x86` 是通过 NFS 挂载的（如 CloudLab 的 `/proj` 目录），而 NFS 服务器有项目配额限制。

**解决方案：将 images 目录挂载到本地磁盘**

`docker-compose.yml` 已默认配置将 images 目录挂载到 `/mnt/nvme/pkvm-images`。使用前需要在宿主机上创建目录：

```bash
# 在宿主机上执行
sudo mkdir -p /mnt/nvme/pkvm-images
sudo chown $(whoami):$(id -gn) /mnt/nvme/pkvm-images
```

如果你的本地磁盘不在 `/mnt/nvme`，请修改 `docker-compose.yml` 中的路径：

```yaml
volumes:
  # 修改为你的本地磁盘路径
  - /your/local/disk/pkvm-images:/workspace/pkvm-x86/images:rw
```

如果不需要此挂载（例如 NFS 配额足够），可以注释掉相关行。

---

### 容器内缺少依赖（旧镜像）

如果使用旧版本的 Docker 镜像，可能缺少某些依赖，手动安装：

```bash
# EFI 签名工具（make hostimage 需要）
apt-get update && apt-get install -y uuid-runtime efitools

# Python cryptography 模块（gen-keys.sh 需要）
pip3 install --break-system-packages cryptography
```

建议重新构建镜像以获得完整依赖：

```bash
./build.sh build-image
```

### 镜像构建失败

```bash
docker system prune -f  # 清理无用镜像
./build.sh build-image
```

### 子模块未初始化

```bash
./build.sh init-submodules
# 或在容器内
git submodule update --init --recursive
```

### 补丁应用失败

```bash
# 查看补丁状态
./build.sh apply-patches check

# 手动进入容器处理
./build.sh shell
cd /workspace/pkvm-x86/linux  # 或其他子模块
git status
git reset --hard
git clean -xfd
# 然后重新应用补丁
```

### 权限问题（容器 root 导致）

```bash
sudo chown -R $(whoami):$(whoami) pkvm-x86/build/
sudo chown -R $(whoami):$(whoami) pkvm-x86/docker/
```

### 内存不足

```bash
# 限制并行任务数
NJOBS=4 ./build.sh compile all
```

### pKVM 启动失败（物理机）

1. 检查 CPU 是否支持 VMX：`grep vmx /proc/cpuinfo`
2. 检查 BIOS 是否开启 VT-x
3. 检查内核参数：`cat /proc/cmdline | grep pkvm`
4. 查看 dmesg：`dmesg | grep -i pkvm`

### crosvm 启动 VM 失败

确保使用 `--protected-vm-without-firmware` 选项，不能用普通 QEMU。

---

## 容器内预装工具

- **编译器**: GCC 13.3, G++, GNAT (Ada), Clang/LLD
- **构建系统**: Make, CMake, Meson, Ninja
- **Rust**: 最新 stable + x86_64-unknown-uefi target
- **内核工具**: bc, flex, bison, libelf-dev, libssl-dev
- **QEMU 依赖**: libglib2.0, libpixman, libspice, libslirp 等
- **UEFI 工具**: nasm, acpica-tools, gnu-efi, efitools
- **EFI 签名**: uuid-runtime (uuidgen), efitools (cert-to-efi-sig-list), sbsigntool
- **镜像工具**: dosfstools, mtools, parted, debootstrap
- **Python**: python3, pip3, cryptography 模块

---

## 参考链接

- [pKVM-IA GitHub](https://github.com/intel-staging/pKVM-IA)
- [Issue #35: 部署指南讨论](https://github.com/intel-staging/pKVM-IA/issues/35)
