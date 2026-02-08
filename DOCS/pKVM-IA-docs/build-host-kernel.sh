#!/usr/bin/env bash
set -e

# pKVM Host 内核：自动安装依赖、编译、打包成 .deb（仅 Debian/Ubuntu）
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
#
# 注意:
# - 每次编译前会清理输出目录中的 *.deb/*.buildinfo/*.changes
# - bindeb-pkg 的产物默认输出到“源码目录的上一级”，脚本会将本次新生成的
#   *.deb/*.buildinfo/*.changes 归集移动到输出目录中。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 仓库根目录（pKVM-IA 在 DOCS 的上一级），使用绝对路径以便任意目录下执行
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

KERNEL_CHOICE="pKVM-IA"
OUT_DIR_DEFAULT="$BASE_DIR/output"
OUT_DIR="$OUT_DIR_DEFAULT"

usage() {
	cat <<-EOF
	Usage: $0 [--kernel pvVMCS-POC-v6.12|pkvm-v6.18|pKVM-IA] [--out /abs/path]

	  --kernel   Select kernel source tree. Default: pKVM-IA
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

cd "$KERNEL_DIR"

echo ">>> make olddefconfig (用默认值处理新选项，不交互)"
make olddefconfig

# 每次编译前：清理输出目录中的 deb/buildinfo/changes 文件
echo ">>> 清理输出目录中已有的 deb/buildinfo/changes（如有）: $DEB_OUTPUT_DIR"
rm -f "$DEB_OUTPUT_DIR"/*.deb "$DEB_OUTPUT_DIR"/*.buildinfo "$DEB_OUTPUT_DIR"/*.changes

echo ">>> make -j$(nproc) bindeb-pkg LOCALVERSION=-${KERNEL_NAME}"
BUILD_PARENT="$(cd "$KERNEL_DIR/.." && pwd)"
START_TS="$(date +%s)"

# 给 buildinfo/changes 一个可区分的 source 名，避免两套源码互相覆盖/混淆
# Debian Source 字段通常要求小写；这里统一转成小写，避免 pvVMCS-POC-v6.12 触发打包失败
KERNEL_SOURCE_NAME="$(echo "$KERNEL_NAME" | tr '[:upper:]' '[:lower:]')"
export KDEB_SOURCENAME="linux-${KERNEL_SOURCE_NAME}"

make -j"$(nproc)" bindeb-pkg LOCALVERSION="-${KERNEL_NAME}"

# bindeb-pkg 默认将产物输出到源码目录的上一级；这里把本次新生成的文件统一搬到 $DEB_OUTPUT_DIR
echo ">>> 归集本次构建产物到输出目录: $DEB_OUTPUT_DIR"
find "$BUILD_PARENT" -maxdepth 1 -type f \
	\( -name "*.deb" -o -name "*.buildinfo" -o -name "*.changes" \) \
	-newermt "@${START_TS}" \
	-exec mv -f -t "$DEB_OUTPUT_DIR" {} +

echo ""
echo "完成. .deb 包已生成在: $DEB_OUTPUT_DIR"
ls -la "$DEB_OUTPUT_DIR"/*.deb 2>/dev/null || true
echo ""
echo "=== 安装说明（以下为绝对路径，任意当前目录下复制执行即可）==="
INSTALL_CMD="sudo dpkg -i ${DEB_OUTPUT_DIR}/linux-image-*-${KERNEL_NAME}_*.deb ${DEB_OUTPUT_DIR}/linux-headers-*-${KERNEL_NAME}_*.deb"
echo "${INSTALL_CMD}"
echo ""
echo "安装后重启并选择新内核: sudo reboot"
