#!/usr/bin/env bash
set -e

# pKVM Host 内核：自动安装依赖、编译、打包成 .deb（仅 Debian/Ubuntu）
#
# 支持两套内核源码树：
# - pKVM-IA:   /home/mrgeek/pkvm-x86/pKVM-IA
# - pkvm-v6.18:/home/mrgeek/pkvm-x86/pkvm-v6.18（默认）
#
# 用法:
#   ./build-host-kernel.sh                    # 默认编译 pkvm-v6.18
#   ./build-host-kernel.sh --kernel pKVM-IA   # 编译 pKVM-IA
#   ./build-host-kernel.sh --out /path/to/out # 指定输出目录（默认: 仓库根目录/output）
#
# 注意:
# - 每次编译前会清理输出目录中的 *.deb/*.buildinfo/*.changes
# - bindeb-pkg 的产物默认输出到“当前源码目录的上一级”，因此脚本通过在输出目录下创建
#   指向源码的 symlink 来确保产物直接落在输出目录中。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 仓库根目录（pKVM-IA 在 DOCS 的上一级），使用绝对路径以便任意目录下执行
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

KERNEL_CHOICE="pkvm-v6.18"
OUT_DIR_DEFAULT="$BASE_DIR/output"
OUT_DIR="$OUT_DIR_DEFAULT"

usage() {
	cat <<-EOF
	Usage: $0 [--kernel pkvm-v6.18|pKVM-IA] [--out /abs/path]

	  --kernel   Select kernel source tree. Default: pkvm-v6.18
	  --out      Output directory for generated .deb/.buildinfo/.changes. Default: ${OUT_DIR_DEFAULT}
	  -h,--help  Show this help.
	EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--kernel)
		KERNEL_CHOICE="${2:-}"
		if [ -z "$KERNEL_CHOICE" ]; then
			echo "错误: --kernel 需要参数"
			usage
			exit 1
		fi
		shift 2
		;;
	--out)
		OUT_DIR="${2:-}"
		if [ -z "$OUT_DIR" ]; then
			echo "错误: --out 需要参数"
			usage
			exit 1
		fi
		shift 2
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		echo "错误: 未知参数: $1"
		usage
		exit 1
		;;
	esac
done

case "$KERNEL_CHOICE" in
pkvm-v6.18)
	KERNEL_DIR="$BASE_DIR/pkvm-v6.18"
	KERNEL_NAME="pkvm-v6.18"
	;;
pKVM-IA|pkvm-ia)
	KERNEL_DIR="$BASE_DIR/pKVM-IA"
	KERNEL_NAME="pkvm-ia"
	;;
*)
	echo "错误: --kernel 仅支持: pkvm-v6.18 或 pKVM-IA"
	exit 1
	;;
esac

DEB_OUTPUT_DIR="$(realpath "$OUT_DIR" 2>/dev/null || echo "$OUT_DIR")"

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

mkdir -p "$DEB_OUTPUT_DIR"

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
	libncurses-dev

echo ">>> 内核源码: $KERNEL_DIR"
echo ">>> 输出目录: $DEB_OUTPUT_DIR"

# 通过在输出目录下创建 symlink，确保 bindeb-pkg 的产物直接输出到 $DEB_OUTPUT_DIR
LINK_SRC="$DEB_OUTPUT_DIR/.src-${KERNEL_NAME}"
if [ -L "$LINK_SRC" ]; then
	# 如果已有旧链接但指向不一致，则替换
	if [ "$(readlink -f "$LINK_SRC")" != "$(readlink -f "$KERNEL_DIR")" ]; then
		rm -f "$LINK_SRC"
		ln -s "$KERNEL_DIR" "$LINK_SRC"
	fi
elif [ -e "$LINK_SRC" ]; then
	echo "错误: $LINK_SRC 已存在但不是 symlink，请手动处理后重试"
	exit 1
else
	ln -s "$KERNEL_DIR" "$LINK_SRC"
fi

cd "$LINK_SRC"

echo ">>> make olddefconfig (用默认值处理新选项，不交互)"
make olddefconfig

# 每次编译前：清理输出目录中的 deb/buildinfo/changes 文件
echo ">>> 清理输出目录中已有的 deb/buildinfo/changes（如有）: $DEB_OUTPUT_DIR"
rm -f "$DEB_OUTPUT_DIR"/*.deb "$DEB_OUTPUT_DIR"/*.buildinfo "$DEB_OUTPUT_DIR"/*.changes

echo ">>> make -j$(nproc) bindeb-pkg LOCALVERSION=-${KERNEL_NAME}"
make -j"$(nproc)" bindeb-pkg LOCALVERSION="-${KERNEL_NAME}"

echo ""
echo "完成. .deb 包已生成在: $DEB_OUTPUT_DIR"
ls -la "$DEB_OUTPUT_DIR"/*.deb 2>/dev/null || true
echo ""
echo "=== 安装说明（以下为绝对路径，任意当前目录下复制执行即可）==="
INSTALL_CMD="sudo dpkg -i ${DEB_OUTPUT_DIR}/linux-image-*-${KERNEL_NAME}_*.deb ${DEB_OUTPUT_DIR}/linux-headers-*-${KERNEL_NAME}_*.deb"
echo "${INSTALL_CMD}"
echo ""
echo "安装后重启并选择新内核: sudo reboot"
