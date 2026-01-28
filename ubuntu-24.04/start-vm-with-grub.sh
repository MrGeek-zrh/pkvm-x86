#!/usr/bin/env bash
# 启动虚拟机并启用grub菜单访问
# 在启动时按住任意键可以进入grub菜单
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 配置参数（与start-vm.sh保持一致）
IMAGE_NAME="ubuntu-24.04-custom.qcow2"
CLOUD_INIT_ISO="cloud-init.iso"
SSH_PORT="${SSH_PORT:-2222}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-4}"
USERNAME="mrgeek"

# 检查镜像
if [ ! -f "$IMAGE_NAME" ]; then
    echo "错误: 镜像文件 $IMAGE_NAME 不存在"
    exit 1
fi

# CPU和加速配置
CPU_TYPE="host"
ACCEL_OPTIONS="-accel kvm"
if [ -c /dev/kvm ]; then
    if [ -f /sys/module/kvm_intel/parameters/nested ]; then
        NESTED_VAL=$(cat /sys/module/kvm_intel/parameters/nested)
        if [ "$NESTED_VAL" = "Y" ] || [ "$NESTED_VAL" = "1" ]; then
            CPU_TYPE="host,+vmx"
        fi
    elif [ -f /sys/module/kvm_amd/parameters/nested ]; then
        NESTED_VAL=$(cat /sys/module/kvm_amd/parameters/nested)
        if [ "$NESTED_VAL" = "Y" ] || [ "$NESTED_VAL" = "1" ]; then
            CPU_TYPE="host,+svm"
        fi
    fi
else
    ACCEL_OPTIONS="-accel tcg"
    CPU_TYPE="qemu64"
fi

# 网络配置
NET_OPTIONS="-netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 -device virtio-net-pci,netdev=net0"

# Cloud-init ISO
CDROM_OPTION=""
if [ -f "$CLOUD_INIT_ISO" ]; then
    CDROM_OPTION="-cdrom $CLOUD_INIT_ISO"
fi

echo ""
echo "=========================================="
echo "启动虚拟机（启用grub菜单访问）"
echo "=========================================="
echo "重要提示:"
echo "  1. 虚拟机启动时，看到grub提示时立即按住 Shift 键或任意键"
echo "  2. 如果grub菜单没有显示，请先运行: bash fix-grub-menu.sh"
echo "  3. 在grub菜单中可以选择旧内核启动"
echo ""
echo "显示模式:"
echo "  - 默认使用 curses 显示（VGA输出），更容易看到grub菜单"
echo "  - 如需沿用 start-vm.sh 的纯串口模式：设置 GRUB_UI=serial"
echo "=========================================="
echo "镜像: $IMAGE_NAME"
echo "内存: ${VM_MEMORY}MB"
echo "CPU: ${VM_CPUS} 核心"
echo "SSH端口: localhost:${SSH_PORT}"
echo "=========================================="
echo ""

GRUB_UI="${GRUB_UI:-curses}"   # curses|serial
SERIAL_LOG="${SERIAL_LOG:-/tmp/ubuntu-24.04-serial.log}"

DISPLAY_OPTIONS=""
SERIAL_OPTIONS=""
if [ "$GRUB_UI" = "serial" ]; then
    # Serial-only (same style as start-vm.sh). Works best with "enable serial GRUB" in fix-grub-menu.sh.
    DISPLAY_OPTIONS="-nographic -display none -serial mon:stdio"
else
    # VGA output rendered in terminal via curses (no GUI needed).
    # Note: curses uses stdio, so serial output must not use stdio.
    DISPLAY_OPTIONS="-display curses"
    SERIAL_OPTIONS="-serial file:${SERIAL_LOG}"
    echo "提示: 串口日志输出到: ${SERIAL_LOG}"
fi

# 启动QEMU
qemu-system-x86_64 \
    -name "ubuntu-24.04-vm" \
    -machine q35 \
    ${ACCEL_OPTIONS} \
    -cpu ${CPU_TYPE} \
    -smp ${VM_CPUS} \
    -m ${VM_MEMORY} \
    -drive file=${IMAGE_NAME},if=virtio,format=qcow2 \
    ${CDROM_OPTION} \
    ${NET_OPTIONS} \
    -device virtio-rng-pci \
    ${DISPLAY_OPTIONS} \
    ${SERIAL_OPTIONS} \
    -monitor unix:/tmp/qemu-monitor-ubuntu-24.04.sock,server,nowait
