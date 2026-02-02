#!/usr/bin/env bash
set -e

# pKVM-IA Host 内核：自动安装依赖、编译、打包成 .deb（仅 Debian/Ubuntu）
# 用法: ./build-host-kernel.sh
# 生成的 .deb 在 pkvm-x86 根目录下；编译完成后按脚本末尾提示执行 dpkg -i 安装

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 仓库根目录（pKVM-IA 在 DOCS 的上一级），使用绝对路径以便任意目录下执行
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
KERNEL_DIR="$BASE_DIR/pKVM-IA"
DEB_OUTPUT_DIR="$(realpath "$BASE_DIR" 2>/dev/null || echo "$BASE_DIR")"

if ! command -v apt-get &>/dev/null; then
	echo "错误: 仅支持 Debian/Ubuntu（需生成 .deb 包）"
	exit 1
fi

if [ ! -d "$KERNEL_DIR" ]; then
	echo "错误: 内核源码目录不存在: $KERNEL_DIR"
	exit 1
fi

if [ ! -f "$KERNEL_DIR/.config" ]; then
	echo "错误: 未找到 $KERNEL_DIR/.config，请先复制或生成 .config（见 PKVM-Kconfig.md）"
	exit 1
fi

echo ">>> 安装/检查编译与打包依赖..."
sudo apt-get update
sudo apt-get install -y \
	build-essential \
	flex \
	bison \
	libssl-dev \
	libelf-dev \
	bc \
	cpio \
	rsync \
	kmod \
	debhelper debhelper-compat dpkg-dev \
	libncurses-dev \
	dpkg-dev

echo ">>> 内核源码: $KERNEL_DIR"
cd "$KERNEL_DIR"

echo ">>> make olddefconfig (用默认值处理新选项，不交互)"
make olddefconfig

echo ">>> make -j"$(nproc)" bindeb-pkg LOCALVERSION=-pkvm-ia"
make -j"$(nproc)" bindeb-pkg LOCALVERSION=-pkvm-ia

echo ""
echo "完成. .deb 包已生成在: $DEB_OUTPUT_DIR"
ls -la "$DEB_OUTPUT_DIR"/*.deb 2>/dev/null || true
echo ""
echo "=== 安装说明（以下为绝对路径，任意当前目录下复制执行即可）==="
INSTALL_CMD="sudo dpkg -i ${DEB_OUTPUT_DIR}/linux-image-*-pkvm-ia_*.deb ${DEB_OUTPUT_DIR}/linux-headers-*-pkvm-ia_*.deb"
echo "$INSTALL_CMD"
echo ""
echo "安装后重启并选择新内核: sudo reboot"
