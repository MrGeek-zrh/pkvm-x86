#!/usr/bin/env bash
set -euo pipefail

# pKVM Host 内核：自动安装依赖、编译、打包成 .deb（仅 Debian/Ubuntu）
#
# 设计目标：
# - Host/Guest 共用同一份内核源码树，通过独立的 O= 输出目录隔离各自 .config/产物。
# - Host 默认输出到 <repo>/build-host/<kernel-name>/，Guest 默认输出到 <repo>/build-guest/。
# - 若源码树里还留有旧的 in-tree .config，本脚本会优先迁移到 Host 输出目录，再提示你清理源码树。
#
# 支持三套内核源码树：
# - pKVM-IA:   /home/mrgeek/pkvm-x86/pKVM-IA
# - pkvm-v6.18: /home/mrgeek/pkvm-x86/pkvm-v6.18
# - pvVMCS-POC-v6.12: /home/mrgeek/pkvm-x86/pvVMCS-POC-v6.12
#
# 用法:
#   ./build-host-kernel.sh                    # 默认编译 pKVM-IA
#   ./build-host-kernel.sh --kernel pKVM-IA   # 编译 pKVM-IA
#   ./build-host-kernel.sh --kernel pkvm-v6.18
#   ./build-host-kernel.sh --out /path/to/out # 指定输出目录（默认: 仓库根目录/output）
#   ./build-host-kernel.sh --build-dir /path/to/build-host/pkvm-ia
#
# 注意:
# - 真正的编译输出目录是 O=<build-dir>，host .config 也保存在该目录下。
# - 若你以前做过 in-tree 构建，请先把配置迁移到 O= 输出目录，再对源码树执行一次 mrproper。
# - 每次编译前会清理输出目录中的 *.deb/*.buildinfo/*.changes
# - bindeb-pkg 在 O= 构建下会把产物输出到“构建输出目录的上一级”，脚本会将本次新生成的
#   *.deb/*.buildinfo/*.changes 归集移动到输出目录中。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 仓库根目录（pKVM-IA 在 DOCS 的上一级），使用绝对路径以便任意目录下执行
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

KERNEL_CHOICE="pKVM-IA"
PKG_OUT_DIR_DEFAULT="$BASE_DIR/output"
PKG_OUT_DIR="$PKG_OUT_DIR_DEFAULT"
BUILD_ROOT_DEFAULT="$BASE_DIR/build-host"
BUILD_DIR=""
ARCH="${ARCH:-x86_64}"
SRCARCH="x86"

usage() {
	cat <<-EOF
		Usage: $0 [--kernel pvVMCS-POC-v6.12|pkvm-v6.18|pKVM-IA] [--out /abs/path] [--build-dir /abs/path]

	  --kernel   Select kernel source tree. Default: pKVM-IA
	  --out      Output directory for generated .deb/.buildinfo/.changes. Default: ${PKG_OUT_DIR_DEFAULT}
	  --build-dir
	             Host kernel O= output directory. Default: <repo>/build-host/<kernel-name>
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
		PKG_OUT_DIR="${2:-}"
		if [ -z "$PKG_OUT_DIR" ]; then
			echo "错误: --out 需要参数"
			usage
			exit 1
		fi
		shift 2
		;;
	--build-dir)
		BUILD_DIR="${2:-}"
		if [ -z "$BUILD_DIR" ]; then
			echo "错误: --build-dir 需要参数"
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
pvVMCS-POC-v6.12|pvvmcs-poc-v6.12)
	KERNEL_DIR="$BASE_DIR/pvVMCS-POC-v6.12"
	KERNEL_NAME="pvvmcs-poc-v6.12"
	;;
pkvm-v6.18)
	KERNEL_DIR="$BASE_DIR/pkvm-v6.18"
	KERNEL_NAME="pkvm-v6.18"
	;;
pKVM-IA|pkvm-ia)
	KERNEL_DIR="$BASE_DIR/pKVM-IA"
	KERNEL_NAME="pkvm-ia"
	;;
*)
	echo "错误: --kernel 仅支持: pvVMCS-POC-v6.12 / pkvm-v6.18 / pKVM-IA"
	exit 1
	;;
esac

if [ -z "$BUILD_DIR" ]; then
	BUILD_DIR="$BUILD_ROOT_DEFAULT/$KERNEL_NAME"
fi

if ! command -v apt-get &>/dev/null; then
	echo "错误: 仅支持 Debian/Ubuntu（需生成 .deb 包）"
	exit 1
fi

if [ ! -d "$KERNEL_DIR" ]; then
	echo "错误: 内核源码目录不存在: $KERNEL_DIR"
	exit 1
fi

mkdir -p "$PKG_OUT_DIR" "$BUILD_DIR"
PKG_OUT_DIR="$(realpath "$PKG_OUT_DIR")"
BUILD_DIR="$(realpath "$BUILD_DIR")"
BUILD_CONFIG="$BUILD_DIR/.config"
SOURCE_TREE_CONFIG="$KERNEL_DIR/.config"

seed_build_config() {
	if [[ -f "$BUILD_CONFIG" ]]; then
		echo ">>> 复用已有 Host 配置: $BUILD_CONFIG"
		return 0
	fi

	if [[ -f "$SOURCE_TREE_CONFIG" ]]; then
		echo ">>> 迁移旧的 source-tree Host 配置到 O= 输出目录: $SOURCE_TREE_CONFIG -> $BUILD_CONFIG"
		cp -a "$SOURCE_TREE_CONFIG" "$BUILD_CONFIG"
		return 0
	fi

	echo "错误: 未找到 Host .config。" >&2
	echo "请先准备 $BUILD_CONFIG（推荐：make -C $KERNEL_DIR O=$BUILD_DIR ARCH=$ARCH menuconfig）" >&2
	echo "或先把已有配置复制到该路径，再重新运行本脚本。" >&2
	exit 1
}

check_source_tree_clean() {
	if [[ -f "$KERNEL_DIR/.config" || -d "$KERNEL_DIR/include/config" || -d "$KERNEL_DIR/arch/$SRCARCH/include/generated" ]]; then
		echo "错误: 共享源码树的 O= 构建要求源码树保持 clean，但检测到 $KERNEL_DIR 中仍有 in-tree 构建残留。" >&2
		echo "内核源码会在 $KERNEL_DIR/Makefile 的 outputmakefile 阶段检查以下路径：" >&2
		echo "  - $KERNEL_DIR/.config" >&2
		echo "  - $KERNEL_DIR/include/config" >&2
		echo "  - $KERNEL_DIR/arch/$SRCARCH/include/generated" >&2
		echo "请先执行一次：" >&2
		echo "  make -C $KERNEL_DIR ARCH=$ARCH mrproper" >&2
		echo "本脚本使用的 Host 配置保存在：$BUILD_CONFIG" >&2
		exit 1
	fi
}

seed_build_config
check_source_tree_clean

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
echo ">>> Host build dir: $BUILD_DIR"
echo ">>> Host config: $BUILD_CONFIG"
echo ">>> 打包输出目录: $PKG_OUT_DIR"

echo ">>> make olddefconfig (用默认值处理新选项，不交互)"
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" olddefconfig

# 每次编译前：清理输出目录中的 deb/buildinfo/changes 文件
echo ">>> 清理输出目录中已有的 deb/buildinfo/changes（如有）: $PKG_OUT_DIR"
rm -f "$PKG_OUT_DIR"/*.deb "$PKG_OUT_DIR"/*.buildinfo "$PKG_OUT_DIR"/*.changes

echo ">>> make -j$(nproc) bindeb-pkg LOCALVERSION=-${KERNEL_NAME}"
BUILD_PARENT="$(cd "$BUILD_DIR/.." && pwd)"
START_TS="$(date +%s)"

# 给 buildinfo/changes 一个可区分的 source 名，避免两套源码互相覆盖/混淆
# Debian Source 字段通常要求小写；这里统一转成小写，避免 pvVMCS-POC-v6.12 触发打包失败
KERNEL_SOURCE_NAME="$(echo "$KERNEL_NAME" | tr '[:upper:]' '[:lower:]')"
export KDEB_SOURCENAME="linux-${KERNEL_SOURCE_NAME}"

make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" -j"$(nproc)" bindeb-pkg LOCALVERSION="-${KERNEL_NAME}"

# bindeb-pkg 在 O= 构建下会把产物输出到构建输出目录的上一级；这里把本次新生成的文件统一搬到 $PKG_OUT_DIR
echo ">>> 归集本次构建产物到输出目录: $PKG_OUT_DIR"
find "$BUILD_PARENT" -maxdepth 1 -type f \
	\( -name "*.deb" -o -name "*.buildinfo" -o -name "*.changes" \) \
	-newermt "@${START_TS}" \
	-exec mv -f -t "$PKG_OUT_DIR" {} +

echo ""
echo "完成. .deb 包已生成在: $PKG_OUT_DIR"
ls -la "$PKG_OUT_DIR"/*.deb 2>/dev/null || true
echo ""
echo "=== 安装说明（以下为绝对路径，任意当前目录下复制执行即可）==="
INSTALL_CMD="sudo dpkg -i ${PKG_OUT_DIR}/linux-image-*-${KERNEL_NAME}_*.deb ${PKG_OUT_DIR}/linux-headers-*-${KERNEL_NAME}_*.deb"
echo "${INSTALL_CMD}"
echo ""
echo "安装后重启并选择新内核: sudo reboot"
