#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 配置参数
UBUNTU_VERSION="24.04"
UBUNTU_RELEASE="noble"
IMAGE_NAME="ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
QCOW2_NAME="ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.qcow2"
CUSTOM_IMAGE="ubuntu-${UBUNTU_VERSION}-custom.qcow2"
USERNAME="mrgeek"
PASSWORD="111"
SSH_PORT="2222"

# Ubuntu Cloud Images 下载地址
UBUNTU_CLOUD_BASE="https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release"

# 检测包管理器并安装依赖
install_dependencies() {
    local missing_packages=()
    local install_cmd=""
    local update_cmd=""
    
    # 检测系统类型
    if command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu
        install_cmd="sudo apt-get install -y"
        update_cmd="sudo apt-get update"
        PKG_MGR="apt"
    elif command -v yum >/dev/null 2>&1; then
        # CentOS/RHEL (旧版)
        install_cmd="sudo yum install -y"
        update_cmd="sudo yum check-update || true"
        PKG_MGR="yum"
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora/CentOS/RHEL (新版)
        install_cmd="sudo dnf install -y"
        update_cmd="sudo dnf check-update || true"
        PKG_MGR="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        # Arch Linux
        install_cmd="sudo pacman -S --noconfirm"
        update_cmd="sudo pacman -Sy"
        PKG_MGR="pacman"
    else
        echo "错误: 无法检测包管理器，请手动安装依赖"
        return 1
    fi
    
    # 检查并收集缺失的包
    if ! command -v qemu-img >/dev/null 2>&1; then
        if [ "$PKG_MGR" = "apt" ]; then
            missing_packages+=("qemu-utils")
        elif [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
            missing_packages+=("qemu-img")
        elif [ "$PKG_MGR" = "pacman" ]; then
            missing_packages+=("qemu")
        fi
    fi
    
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        if [ "$PKG_MGR" = "apt" ]; then
            missing_packages+=("wget")
        elif [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
            missing_packages+=("wget")
        elif [ "$PKG_MGR" = "pacman" ]; then
            missing_packages+=("wget")
        fi
    fi
    
    # 如果没有 virt-customize，尝试安装（可选）
    if ! command -v virt-customize >/dev/null 2>&1; then
        if [ "$PKG_MGR" = "apt" ]; then
            missing_packages+=("libguestfs-tools")
        elif [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
            missing_packages+=("libguestfs-tools")
        elif [ "$PKG_MGR" = "pacman" ]; then
            missing_packages+=("libguestfs")
        fi
    fi
    
    # 如果没有 genisoimage/mkisofs，尝试安装（用于cloud-init）
    if ! command -v genisoimage >/dev/null 2>&1 && ! command -v mkisofs >/dev/null 2>&1; then
        if [ "$PKG_MGR" = "apt" ]; then
            missing_packages+=("genisoimage")
        elif [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
            missing_packages+=("genisoimage")
        elif [ "$PKG_MGR" = "pacman" ]; then
            missing_packages+=("cdrtools")
        fi
    fi
    
    # 安装缺失的包
    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo "检测到缺失的依赖包: ${missing_packages[*]}"
        
        # 检查是否有sudo权限
        if ! sudo -n true 2>/dev/null; then
            echo "需要sudo权限来安装依赖包"
            echo "请运行以下命令安装依赖:"
            if [ -n "$update_cmd" ]; then
                echo "  $update_cmd"
            fi
            echo "  $install_cmd ${missing_packages[*]}"
            read -p "是否现在安装? (Y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                # 更新包列表
                if [ -n "$update_cmd" ]; then
                    echo "更新包列表..."
                    $update_cmd || true
                fi
                
                # 安装包
                echo "正在安装依赖..."
                $install_cmd "${missing_packages[@]}" || {
                    echo "警告: 部分依赖安装失败，将继续尝试..."
                }
            else
                echo "跳过依赖安装，请手动安装后重试"
                return 1
            fi
        else
            # 有sudo权限，直接安装
            echo "正在安装依赖..."
            if [ -n "$update_cmd" ]; then
                echo "更新包列表..."
                $update_cmd || true
            fi
            $install_cmd "${missing_packages[@]}" || {
                echo "警告: 部分依赖安装失败，将继续尝试..."
            }
        fi
    fi
}

echo "=========================================="
echo "Ubuntu ${UBUNTU_VERSION} QCOW2 镜像下载和配置"
echo "=========================================="

# 检查并安装依赖
echo "检查依赖..."
install_dependencies

# 再次检查必要的工具
if ! command -v qemu-img >/dev/null 2>&1; then
    echo "错误: qemu-img 未安装，请手动安装 qemu-utils 或 qemu"
    exit 1
fi

if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    echo "错误: wget 或 curl 未安装"
    exit 1
fi

if ! command -v virt-customize >/dev/null 2>&1; then
    echo "提示: virt-customize 未安装，将使用 cloud-init 方法"
fi

# 下载原始镜像（如果不存在）
if [ ! -f "$QCOW2_NAME" ]; then
    echo "正在下载 Ubuntu ${UBUNTU_VERSION} 镜像..."
    if command -v wget >/dev/null 2>&1; then
        wget -c "${UBUNTU_CLOUD_BASE}/${IMAGE_NAME}" -O "$QCOW2_NAME" || {
            echo "下载失败，尝试下载qcow2格式..."
            wget -c "${UBUNTU_CLOUD_BASE}/${QCOW2_NAME}" -O "$QCOW2_NAME" || {
                echo "错误: 无法下载镜像"
                exit 1
            }
        }
    elif command -v curl >/dev/null 2>&1; then
        curl -L -C - "${UBUNTU_CLOUD_BASE}/${IMAGE_NAME}" -o "$QCOW2_NAME" || {
            echo "下载失败，尝试下载qcow2格式..."
            curl -L -C - "${UBUNTU_CLOUD_BASE}/${QCOW2_NAME}" -o "$QCOW2_NAME" || {
                echo "错误: 无法下载镜像"
                exit 1
            }
        }
    else
        echo "错误: 需要 wget 或 curl 来下载镜像"
        exit 1
    fi
    echo "下载完成: $QCOW2_NAME"
else
    echo "镜像已存在: $QCOW2_NAME"
fi

# 创建自定义镜像副本
if [ -f "$CUSTOM_IMAGE" ]; then
    read -p "自定义镜像已存在，是否重新创建? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$CUSTOM_IMAGE"
    else
        echo "使用现有镜像: $CUSTOM_IMAGE"
        exit 0
    fi
fi

echo "创建自定义镜像副本..."
qemu-img create -f qcow2 -F qcow2 -b "$QCOW2_NAME" "$CUSTOM_IMAGE" 20G

# 使用 virt-customize 配置镜像（如果可用）
USE_CLOUD_INIT=0
if command -v virt-customize >/dev/null 2>&1; then
    echo "尝试使用 virt-customize 配置镜像..."
    # 尝试运行 virt-customize，捕获输出和错误
    if virt-customize -a "$CUSTOM_IMAGE" \
        --root-password password:root \
        --run-command "useradd -m -s /bin/bash $USERNAME || true" \
        --password $USERNAME:password:$PASSWORD \
        --run-command "usermod -aG sudo $USERNAME" \
        --run-command "mkdir -p /home/$USERNAME/.ssh" \
        --run-command "chmod 700 /home/$USERNAME/.ssh" \
        --run-command "chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh" \
        --run-command "sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config" \
        --run-command "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config" \
        --run-command "systemctl enable ssh" \
        --run-command "echo '$USERNAME ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/$USERNAME" \
        --run-command "chmod 0440 /etc/sudoers.d/$USERNAME" \
	        --run-command "echo 'vmx' > /sys/module/kvm_intel/parameters/nested || echo 'nested=1' >> /etc/modprobe.d/kvm.conf || true" \
	        --run-command "echo 'options kvm_intel nested=1' >> /etc/modprobe.d/kvm.conf || true" \
	        --run-command "echo 'options kvm_amd nested=1' >> /etc/modprobe.d/kvm.conf || true" \
	        --run-command "mkdir -p /etc/default/grub.d && printf '%s\n' \
	            '# Added by pkvm-x86 ubuntu-24.04/download-and-setup.sh' \
	            '# Enable pKVM + IOMMU by default (avoid hard-coding root= here).' \
	            'GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash console=ttyS0,115200n8 kvm-intel.pkvm=1 intel_iommu=sm_on\"' \
	            'GRUB_CMDLINE_LINUX=\"console=ttyS0,115200n8 kvm-intel.pkvm=1 intel_iommu=sm_on\"' \
	            > /etc/default/grub.d/99-pkvm.cfg" \
	        --run-command "sed -i 's|^\\([^#].*\\s/boot/efi\\s.*\\)$|# \\1|' /etc/fstab || true" \
	        --run-command "(command -v update-grub >/dev/null 2>&1 && update-grub) || (command -v grub-mkconfig >/dev/null 2>&1 && grub-mkconfig -o /boot/grub/grub.cfg) || true" \
	        --run-command "(command -v systemctl >/dev/null 2>&1 && systemctl disable multipathd.service multipathd.socket) || true" \
	        >/tmp/virt-customize.log 2>&1; then
        echo "virt-customize 配置成功！"
    else
        echo "警告: virt-customize 配置失败，将回退到 cloud-init 方法"
        echo "错误信息已保存到 /tmp/virt-customize.log"
        USE_CLOUD_INIT=1
    fi
else
    echo "提示: virt-customize 不可用，将使用 cloud-init 方法"
    USE_CLOUD_INIT=1
fi

# 如果 virt-customize 失败或不可用，使用 cloud-init 方法
if [ "$USE_CLOUD_INIT" = "1" ]; then
    # 生成密码哈希
    PASSWORD_HASH=$(echo -n "$PASSWORD" | openssl passwd -6 -stdin 2>/dev/null || \
                    echo -n "$PASSWORD" | mkpasswd -m sha-512 2>/dev/null || \
                    echo "$(openssl passwd -1 "$PASSWORD" 2>/dev/null || echo "")")
    
    # 创建 cloud-init 配置
    mkdir -p cloud-init
    cat > cloud-init/user-data <<EOF
#cloud-config
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $PASSWORD_HASH
    ssh_authorized_keys: []

chpasswd:
  list: |
    $USERNAME:$PASSWORD
  expire: false

ssh_pwauth: true
disable_root: false

runcmd:
  - echo 'options kvm_intel nested=1' >> /etc/modprobe.d/kvm.conf
  - echo 'options kvm_amd nested=1' >> /etc/modprobe.d/kvm.conf
  - modprobe -r kvm_intel || true
  - modprobe kvm_intel nested=1 || true
  - modprobe -r kvm_amd || true
  - modprobe kvm_amd nested=1 || true
  - mkdir -p /etc/default/grub.d
  - |
      cat > /etc/default/grub.d/99-pkvm.cfg <<'EOF'
      # Added by pkvm-x86 ubuntu-24.04/download-and-setup.sh
      # Enable pKVM + IOMMU by default (avoid hard-coding root= here).
      GRUB_CMDLINE_LINUX_DEFAULT="quiet splash console=ttyS0,115200n8 kvm-intel.pkvm=1 intel_iommu=sm_on"
      GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 kvm-intel.pkvm=1 intel_iommu=sm_on"
      EOF
  - sed -i 's|^\([^#].*\s/boot/efi\s.*\)$|# \1|' /etc/fstab || true
  - systemctl disable --now multipathd.service multipathd.socket || true
  - update-grub || (command -v grub-mkconfig >/dev/null 2>&1 && grub-mkconfig -o /boot/grub/grub.cfg) || true
  - systemctl restart ssh || systemctl restart sshd || true
EOF

    cat > cloud-init/meta-data <<EOF
instance-id: ubuntu-${UBUNTU_VERSION}-custom
local-hostname: ubuntu-vm
EOF

    # 创建 cloud-init ISO
    if command -v genisoimage >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1; then
        GENISO=$(command -v genisoimage || command -v mkisofs)
        echo "正在创建 cloud-init ISO..."
        $GENISO -output cloud-init.iso -volid cidata -joliet -rock cloud-init/user-data cloud-init/meta-data
        echo "已创建 cloud-init.iso，首次启动时会自动挂载此ISO"
    else
        echo "错误: 需要安装 genisoimage 或 mkisofs 来创建 cloud-init ISO"
        echo "尝试自动安装..."
        install_dependencies
        if command -v genisoimage >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1; then
            GENISO=$(command -v genisoimage || command -v mkisofs)
            echo "正在创建 cloud-init ISO..."
            $GENISO -output cloud-init.iso -volid cidata -joliet -rock cloud-init/user-data cloud-init/meta-data
            echo "已创建 cloud-init.iso，首次启动时会自动挂载此ISO"
        else
            echo "错误: 无法安装 genisoimage 或 mkisofs，请手动安装后重试"
            exit 1
        fi
    fi
fi

echo ""
echo "=========================================="
echo "配置完成！"
echo "=========================================="
echo "镜像文件: $CUSTOM_IMAGE"
echo "用户名: $USERNAME"
echo "密码: $PASSWORD"
echo "SSH端口: $SSH_PORT (将在启动脚本中配置)"
echo ""
echo "下一步: 运行 ./start-vm.sh 启动虚拟机"
