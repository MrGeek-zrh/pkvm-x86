#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 配置参数
IMAGE_NAME="ubuntu-24.04-custom.qcow2"
CLOUD_INIT_ISO="cloud-init.iso"
SSH_PORT="${SSH_PORT:-2222}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-4}"
USERNAME="mrgeek"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
# pkvm-x86 defaults: align QEMU machine options closer to pkvm-x86's `make run`
# (q35 + mem-merge=off + kernel-irqchip=on + similar CPU flags). Set
# PKVM_X86_ALIGN=0 to restore the previous minimal q35 configuration.
PKVM_X86_ALIGN="${PKVM_X86_ALIGN:-1}"
# IOMMU device exposure to the guest (VT-d/DMAR). Default is on for pKVM usage.
# Set IOMMU=0 to disable.
IOMMU="${IOMMU:-1}" # 0|1
EXTRA_QEMU_ARGS="${EXTRA_QEMU_ARGS:-}"
# Boot from a bzImage directly (like pkvm-x86 `make run`). When set, the BIOS
# doesn't need to support booting from the disk device model.
KERNEL_BZIMAGE="${KERNEL_BZIMAGE:-}"
KERNEL_APPEND="${KERNEL_APPEND:-}"  # If empty, a conservative default is used.
ROOT_DEV="${ROOT_DEV:-}"            # Optional override for the default root=...
DISK_MODEL="${DISK_MODEL:-virtio}"  # virtio|nvme (nvme requires -kernel boot or UEFI)

is_qemu_available() {
    if [[ "$QEMU_BIN" == */* ]]; then
        [ -x "$QEMU_BIN" ]
    else
        command -v "$QEMU_BIN" >/dev/null 2>&1
    fi
}

# 检测包管理器并安装依赖
install_dependencies() {
    local missing_packages=()
    local install_cmd=""
    local update_cmd=""
    
    # 检测系统类型
    if command -v apt-get >/dev/null 2>&1; then
        install_cmd="sudo apt-get install -y"
        update_cmd="sudo apt-get update"
        PKG_MGR="apt"
    elif command -v yum >/dev/null 2>&1; then
        install_cmd="sudo yum install -y"
        update_cmd="sudo yum check-update || true"
        PKG_MGR="yum"
    elif command -v dnf >/dev/null 2>&1; then
        install_cmd="sudo dnf install -y"
        update_cmd="sudo dnf check-update || true"
        PKG_MGR="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        install_cmd="sudo pacman -S --noconfirm"
        update_cmd="sudo pacman -Sy"
        PKG_MGR="pacman"
    else
        echo "错误: 无法检测包管理器，请手动安装依赖"
        return 1
    fi
    
    # 检查并收集缺失的包
    if [[ "$QEMU_BIN" != */* ]] && ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
        if [ "$PKG_MGR" = "apt" ]; then
            missing_packages+=("qemu-system-x86")
        elif [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
            missing_packages+=("qemu-system-x86")
        elif [ "$PKG_MGR" = "pacman" ]; then
            missing_packages+=("qemu")
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
                    echo "错误: 依赖安装失败"
                    exit 1
                }
            else
                echo "跳过依赖安装，请手动安装后重试"
                exit 1
            fi
        else
            # 有sudo权限，直接安装
            echo "正在安装依赖..."
            if [ -n "$update_cmd" ]; then
                echo "更新包列表..."
                $update_cmd || true
            fi
            $install_cmd "${missing_packages[@]}" || {
                echo "错误: 依赖安装失败"
                exit 1
            }
        fi
    fi
}

# 检查镜像是否存在
if [ ! -f "$IMAGE_NAME" ]; then
    echo "错误: 镜像文件 $IMAGE_NAME 不存在"
    echo "请先运行 ./download-and-setup.sh"
    exit 1
fi

# 检查并安装依赖
echo "检查依赖..."
install_dependencies

# 再次检查 QEMU
if ! is_qemu_available; then
    echo "错误: QEMU 未找到: $QEMU_BIN"
    echo "请检查 QEMU_BIN 路径或手动安装 qemu-system-x86_64"
    exit 1
fi

# 检查是否以root运行（某些功能需要）
NEED_ROOT=0
if [ ! -w /dev/kvm ]; then
    echo "警告: /dev/kvm 不可写，某些功能可能受限"
fi

# 检查嵌套虚拟化支持
if [ -f /sys/module/kvm_intel/parameters/nested ]; then
    NESTED=$(cat /sys/module/kvm_intel/parameters/nested)
    if [ "$NESTED" != "Y" ] && [ "$NESTED" != "1" ]; then
        echo "警告: 主机未启用嵌套虚拟化 (kvm_intel)"
        echo "尝试启用嵌套虚拟化..."
        if [ "$(id -u)" -eq 0 ]; then
            modprobe -r kvm_intel 2>/dev/null || true
            modprobe kvm_intel nested=1
            echo "已启用嵌套虚拟化"
        else
            echo "需要root权限来启用嵌套虚拟化"
        fi
    fi
elif [ -f /sys/module/kvm_amd/parameters/nested ]; then
    NESTED=$(cat /sys/module/kvm_amd/parameters/nested)
    if [ "$NESTED" != "Y" ] && [ "$NESTED" != "1" ]; then
        echo "警告: 主机未启用嵌套虚拟化 (kvm_amd)"
        echo "尝试启用嵌套虚拟化..."
        if [ "$(id -u)" -eq 0 ]; then
            modprobe -r kvm_amd 2>/dev/null || true
            modprobe kvm_amd nested=1
            echo "已启用嵌套虚拟化"
        else
            echo "需要root权限来启用嵌套虚拟化"
        fi
    fi
fi

# Machine/device options (controlled by PKVM_X86_ALIGN; default is 1)
MACHINE_OPTS=(-machine q35)
IOMMU_OPTS=()
DRIVE_OPTS=(-drive "file=${IMAGE_NAME},if=virtio,format=qcow2")
# Default to virtio-net for a generic Ubuntu VM, but in pkvm-x86 align mode use
# the same-ish device models as pkvm-x86/platform/q35/Makefile (e1000 + NVMe).
NET_OPTS=(-netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0)
if [[ "$PKVM_X86_ALIGN" == "1" ]]; then
    MACHINE_OPTS=(-machine q35,mem-merge=off)
    NET_OPTS=(-netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" -device e1000,netdev=net0)
fi

# IOMMU exposure (independent of PKVM_X86_ALIGN)
if [[ "$IOMMU" == "1" ]]; then
    # Matches pkvm-x86/platform/q35/Makefile's IOMMU device.
    IOMMU_OPTS=(-device intel-iommu,aw-bits=48,device-iotlb=on)
fi

# 如果存在cloud-init ISO，首次启动时挂载
# 检查是否已经配置过（通过检查镜像中是否有用户）
CDROM_OPTION=""
if [ -f "$CLOUD_INIT_ISO" ]; then
    # 检查镜像是否已经配置过用户
    if command -v virt-cat >/dev/null 2>&1; then
        if virt-cat -a "$IMAGE_NAME" /etc/passwd 2>/dev/null | grep -q "^${USERNAME}:"; then
            echo "检测到镜像已配置，跳过 cloud-init ISO"
        else
            CDROM_OPTION="-cdrom $CLOUD_INIT_ISO"
            echo "检测到 cloud-init.iso，将在首次启动时应用配置"
        fi
    else
        # 如果没有virt-cat，总是挂载（用户可以在配置完成后删除ISO）
        CDROM_OPTION="-cdrom $CLOUD_INIT_ISO"
        echo "检测到 cloud-init.iso，将在启动时挂载"
        echo "提示: 配置完成后可以删除 $CLOUD_INIT_ISO 以避免每次挂载"
    fi
fi

# CPU配置 - 启用嵌套虚拟化
# 默认使用 host CPU
CPU_TYPE="host"

# 启用KVM加速和嵌套虚拟化
ACCEL_OPTS=(-accel kvm)
if [ -c /dev/kvm ]; then
    ACCEL_OPTS=(-accel kvm)
    # 检查并启用嵌套虚拟化
    if [ -f /sys/module/kvm_intel/parameters/nested ]; then
        NESTED_VAL=$(cat /sys/module/kvm_intel/parameters/nested)
        if [ "$NESTED_VAL" = "Y" ] || [ "$NESTED_VAL" = "1" ]; then
            CPU_TYPE="host,+vmx"
            echo "检测到 Intel 嵌套虚拟化支持，启用 vmx"
        fi
    elif [ -f /sys/module/kvm_amd/parameters/nested ]; then
        NESTED_VAL=$(cat /sys/module/kvm_amd/parameters/nested)
        if [ "$NESTED_VAL" = "Y" ] || [ "$NESTED_VAL" = "1" ]; then
            CPU_TYPE="host,+svm"
            echo "检测到 AMD 嵌套虚拟化支持，启用 svm"
        fi
    fi
else
    echo "警告: /dev/kvm 不存在，将使用软件模拟（性能较差）"
    ACCEL_OPTS=(-accel tcg)
    CPU_TYPE="qemu64"
fi

# pkvm-x86 q35 target uses in-kernel irqchip; enable it in align mode to avoid
# subtle interrupt/timer issues when running pkvm-x86 kernels.
if [[ "$PKVM_X86_ALIGN" == "1" && "${ACCEL_OPTS[*]}" == "-accel kvm" ]]; then
    ACCEL_OPTS=(-accel kvm,kernel-irqchip=on)
fi

# Match pkvm-x86/platform/q35/Makefile's overcommit flag in align mode.
OVERCOMMIT_OPTS=()
if [[ "$PKVM_X86_ALIGN" == "1" ]]; then
    OVERCOMMIT_OPTS=(-overcommit cpu-pm=off)
fi

# In align mode, add the same-ish CPU flags used by pkvm-x86 q35 target.
# Only apply to Intel-vmx path to avoid breaking AMD hosts.
if [[ "$PKVM_X86_ALIGN" == "1" && "$CPU_TYPE" == "host,+vmx" ]]; then
    CPU_TYPE="host,+vmx,+ssse3,+tsc,+nx,+x2apic,+hypervisor,-kvm-pv-ipi,-kvm-pv-tlb-flush,-kvm-pv-unhalt,-kvm-pv-sched-yield,-kvm-asyncpf-int,-kvm-pv-eoi"
fi

# 显示配置信息
NESTED_STATUS="未启用"
if [[ "$CPU_TYPE" == *"+vmx"* ]] || [[ "$CPU_TYPE" == *"+svm"* ]]; then
    NESTED_STATUS="已启用"
fi

echo "=========================================="
echo "启动 Ubuntu 24.04 虚拟机"
echo "=========================================="
echo "镜像: $IMAGE_NAME"
echo "QEMU: $QEMU_BIN"
echo "内存: ${VM_MEMORY}MB"
echo "CPU: ${VM_CPUS} 核心 (${CPU_TYPE})"
echo "SSH端口转发: localhost:${SSH_PORT} -> guest:22"
echo "嵌套虚拟化: ${NESTED_STATUS}"
if [[ "$PKVM_X86_ALIGN" == "1" ]]; then
    echo "pkvm-x86 对齐模式: 已启用 (q35, mem-merge=off, kernel-irqchip=on)"
fi
echo "IOMMU: ${IOMMU}"
if [[ -n "$KERNEL_BZIMAGE" ]]; then
    echo "Kernel boot: -kernel ${KERNEL_BZIMAGE}"
fi
echo ""
echo "SSH连接命令:"
echo "  ssh -p ${SSH_PORT} ${USERNAME}@localhost"
echo ""
echo "提示: 按 Ctrl+A 然后按 X 退出 QEMU"
echo "=========================================="
echo ""

# Disk model:
# - Default is virtio so the qcow2 boots out-of-the-box.
# - NVMe is supported only with -kernel boot (or UEFI), so keep it opt-in.
if [[ "$DISK_MODEL" == "nvme" && -z "$KERNEL_BZIMAGE" ]]; then
    echo "警告: DISK_MODEL=nvme 需要使用 KERNEL_BZIMAGE（-kernel 启动）或 UEFI；将回退到 virtio 以便正常从 qcow2 启动"
    DISK_MODEL="virtio"
fi

if [[ "$DISK_MODEL" == "nvme" ]]; then
    DRIVE_OPTS=(-device nvme,serial=ubuntu-24.04-vm,drive=disk0 -drive "file=${IMAGE_NAME},if=none,id=disk0,format=qcow2")
else
    DRIVE_OPTS=(-drive "file=${IMAGE_NAME},if=virtio,format=qcow2")
fi

# Kernel boot options (safe quoting for -append)
KERNEL_OPTS=()
if [[ -n "$KERNEL_BZIMAGE" ]]; then
    if [[ -z "$ROOT_DEV" ]]; then
        if [[ "$DISK_MODEL" == "nvme" ]]; then
            ROOT_DEV="/dev/nvme0n1p1"
        else
            ROOT_DEV="/dev/vda1"
        fi
    fi
    if [[ -z "$KERNEL_APPEND" ]]; then
        # Default mirrors pkvm-x86/platform/q35/vars.mk, but keeps it minimal.
        # Add intel_iommu=sm_on only when IOMMU=1.
        KERNEL_APPEND="root=${ROOT_DEV} console=ttyS0 earlyprintk=ttyS0,115200 rw kvm-intel.pkvm=1 ignore_loglevel nokaslr"
        if [[ "$IOMMU" == "1" ]]; then
            KERNEL_APPEND="${KERNEL_APPEND} intel_iommu=sm_on"
        fi
    fi
    KERNEL_OPTS=(-kernel "$KERNEL_BZIMAGE" -append "$KERNEL_APPEND")
fi

# Extra args (best-effort split on whitespace)
EXTRA_QEMU_ARGS_ARR=()
if [[ -n "$EXTRA_QEMU_ARGS" ]]; then
    # shellcheck disable=SC2206
    EXTRA_QEMU_ARGS_ARR=(${EXTRA_QEMU_ARGS})
fi

# CDROM opts (cloud-init)
CDROM_OPTS=()
if [[ -n "$CDROM_OPTION" ]]; then
    CDROM_OPTS=(-cdrom "$CLOUD_INIT_ISO")
fi

# 启动QEMU (array form to preserve quoting)
qemu_cmd=(
    "$QEMU_BIN"
    -name "ubuntu-24.04-vm"
    "${MACHINE_OPTS[@]}"
    "${ACCEL_OPTS[@]}"
    -cpu "${CPU_TYPE}"
    -smp "${VM_CPUS}"
    "${OVERCOMMIT_OPTS[@]}"
    -m "${VM_MEMORY}"
    "${KERNEL_OPTS[@]}"
    "${DRIVE_OPTS[@]}"
    "${CDROM_OPTS[@]}"
    "${NET_OPTS[@]}"
    "${IOMMU_OPTS[@]}"
    -device virtio-rng-pci
    -nographic
    -display none
    -serial mon:stdio
    -monitor unix:/tmp/qemu-monitor-ubuntu-24.04.sock,server,nowait
    "${EXTRA_QEMU_ARGS_ARR[@]}"
)
"${qemu_cmd[@]}"
