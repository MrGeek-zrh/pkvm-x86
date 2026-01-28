#!/usr/bin/env bash
# 测试脚本：诊断镜像挂载问题
set -e

IMAGE_NAME="ubuntu-24.04-custom.qcow2"

if [ ! -f "$IMAGE_NAME" ]; then
    echo "错误: 镜像文件不存在"
    exit 1
fi

echo "=========================================="
echo "镜像挂载诊断工具"
echo "=========================================="
echo "镜像文件: $IMAGE_NAME"
echo ""

# 1. 检查镜像信息
echo "1. 检查镜像信息..."
qemu-img info "$IMAGE_NAME" | head -10
echo ""

# 2. 列出所有文件系统
echo "2. 检测到的文件系统:"
virt-filesystems -a "$IMAGE_NAME" -l || sudo virt-filesystems -a "$IMAGE_NAME" -l
echo ""

# 3. 尝试详细挂载每个分区
echo "3. 尝试挂载每个分区（显示详细错误）..."
FILESYSTEMS=$(virt-filesystems -a "$IMAGE_NAME" 2>/dev/null || sudo virt-filesystems -a "$IMAGE_NAME" 2>/dev/null)

MNT_DIR=$(mktemp -d)
for fs in $FILESYSTEMS; do
    if [[ "$fs" == *"swap"* ]] || [[ "$fs" == *"unknown"* ]]; then
        continue
    fi
    
    echo ""
    echo "尝试挂载: $fs"
    echo "命令: sudo guestmount -a $IMAGE_NAME -m $fs $MNT_DIR"
    sudo guestmount -a "$IMAGE_NAME" -m "$fs" "$MNT_DIR" 2>&1 && {
        echo "✓ 挂载成功"
        echo "  检查内容:"
        ls -la "$MNT_DIR" | head -5
        if [ -d "$MNT_DIR/etc" ]; then
            echo "  ✓ 找到 /etc 目录 - 这是根分区！"
            echo "  内容:"
            ls "$MNT_DIR/etc" | head -5
        fi
        sudo guestunmount "$MNT_DIR"
        break
    } || {
        echo "  ✗ 挂载失败"
    }
done

rmdir "$MNT_DIR" 2>/dev/null || true

echo ""
echo "4. 尝试使用 qemu-nbd..."
if command -v qemu-nbd >/dev/null 2>&1; then
    NBD_DEV="/dev/nbd0"
    echo "连接镜像到 $NBD_DEV..."
    sudo modprobe nbd max_part=8 2>/dev/null || true
    
    if sudo qemu-nbd -c "$NBD_DEV" "$IMAGE_NAME" 2>&1; then
        sleep 2
        sudo partprobe "$NBD_DEV" 2>/dev/null || true
        sleep 1
        
        echo "检测到的分区:"
        ls -la /dev/nbd0* 2>/dev/null || true
        
        echo ""
        echo "分区信息:"
        sudo fdisk -l "$NBD_DEV" 2>/dev/null || sudo parted "$NBD_DEV" print 2>/dev/null || true
        
        # 清理
        sudo qemu-nbd -d "$NBD_DEV" 2>/dev/null || true
    else
        echo "qemu-nbd 连接失败"
    fi
else
    echo "qemu-nbd 不可用"
fi

echo ""
echo "=========================================="
echo "诊断完成"
echo "=========================================="
