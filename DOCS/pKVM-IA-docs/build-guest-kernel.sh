#!/usr/bin/env bash
set -euo pipefail

# pKVM-IA Guest 内核：构建用于 Protected VM 的 guest bzImage/modules
#
# 设计目标：
# - Host/Guest 共用同一份 pKVM-IA 源码树，通过独立的 O= 输出目录隔离各自 .config/产物。
# - 默认复用 Host O= 输出目录中的 .config 作为起点，然后强制打开 guest 必需选项。
# - 不默认安装 modules（避免污染宿主机）；如需写入 rootfs，请用 --install-modules。
#
# 用法示例：
#   ./build-guest-kernel.sh
#   ./build-guest-kernel.sh --out /path/to/build-guest
#   ./build-guest-kernel.sh --host-out /path/to/build-host/pkvm-ia
#   ./build-guest-kernel.sh --defconfig
#   ./build-guest-kernel.sh --install-modules /path/to/rootfs
#
# 输出：
#   - bzImage: <out>/arch/x86/boot/bzImage
#   - modules: <out> 下生成（需要时可 --install-modules 安装到 rootfs）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
KERNEL_DIR="$BASE_DIR/pKVM-IA"
HOST_OUT_DIR="$BASE_DIR/build-host/pkvm-ia"
HOST_CONFIG=""

OUT_DIR="$BASE_DIR/build-guest"
CONFIG_MODE="from-host-config" # from-host-config | defconfig | keep-existing
INSTALL_MODULES_DIR=""
ARCH="${ARCH:-x86_64}"
SRCARCH="x86"
NEED_DEFCONFIG=0

usage() {
	cat <<'EOF'
build-guest-kernel.sh - build pKVM guest kernel (x86_64)

Options:
  --out <dir>              输出目录（O=...，默认: <repo>/build-guest）
  --host-out <dir>         Host O= 输出目录；默认从 <repo>/build-host/pkvm-ia/.config 取 guest 种子配置
  --host-config <file>     显式指定 guest 的种子配置文件
  --defconfig              从 defconfig 起步（不复用宿主 .config）
  --keep-existing-config   如果 <out>/.config 已存在则以它为起点（仍会强制启用 PKVM_GUEST/HYPERVISOR_GUEST）
  --install-modules <dir>  执行 modules_install 到指定目录（通常是 guest rootfs 挂载点）
  -h, --help               显示帮助

Notes:
  - Protected guest 必须开启 CONFIG_PKVM_GUEST=y（以及 HYPERVISOR_GUEST=y）。
  - 如果 guest 需要 virtio 磁盘/网卡，请确保相应驱动也在 .config 里启用。
  - 默认优先复用 <host-out>/.config；仅为兼容旧流程，找不到时才回退到源码树里的 pKVM-IA/.config。
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--out)
			OUT_DIR="${2:?missing dir after --out}"
			shift 2
			;;
		--host-out)
			HOST_OUT_DIR="${2:?missing dir after --host-out}"
			shift 2
			;;
		--host-config)
			HOST_CONFIG="${2:?missing path after --host-config}"
			shift 2
			;;
		--defconfig)
			CONFIG_MODE="defconfig"
			shift
			;;
		--keep-existing-config)
			CONFIG_MODE="keep-existing"
			shift
			;;
		--install-modules)
			INSTALL_MODULES_DIR="${2:?missing dir after --install-modules}"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "未知参数: $1" >&2
			usage >&2
			exit 2
			;;
		esac
done

if [[ ! -d "$KERNEL_DIR" ]]; then
	echo "错误: guest 内核源码目录不存在: $KERNEL_DIR" >&2
	exit 1
fi

if [[ ! -x "$KERNEL_DIR/scripts/config" ]]; then
	echo "错误: 未找到 $KERNEL_DIR/scripts/config（内核源码不完整？）" >&2
	exit 1
fi

mkdir -p "$OUT_DIR"
OUT_DIR="$(realpath "$OUT_DIR")"

resolve_seed_config() {
	if [[ -n "$HOST_CONFIG" ]]; then
		echo "$HOST_CONFIG"
		return 0
	fi

	if [[ -f "$HOST_OUT_DIR/.config" ]]; then
		echo "$HOST_OUT_DIR/.config"
		return 0
	fi

	# 兼容旧流程：如果用户还没把 Host 配置迁移出源码树，允许先拿它做一次种子复制。
	if [[ -f "$KERNEL_DIR/.config" ]]; then
		echo "$KERNEL_DIR/.config"
		return 0
	fi

	return 1
}

prepare_initial_config() {
	# 若当前已存在 .config，则不再从 Host 拷贝，直接在其基础上继续
	if [[ -f "$OUT_DIR/.config" ]]; then
		if [[ "$CONFIG_MODE" == "keep-existing" ]]; then
			echo ">>> 复用已有配置: $OUT_DIR/.config（--keep-existing-config）"
		else
			echo ">>> 已存在 $OUT_DIR/.config，不再从 Host 拷贝，在其基础上继续"
		fi
		return 0
	fi

	if [[ "$CONFIG_MODE" == "defconfig" ]]; then
		NEED_DEFCONFIG=1
		return 0
	fi

	# 默认：从宿主配置起步（更符合 pKVM-IA 分支的依赖组合）
	local seed_config
	if ! seed_config="$(resolve_seed_config)"; then
		echo "错误: 未找到宿主 .config。" >&2
		echo "默认会先查找: $HOST_OUT_DIR/.config" >&2
		echo "兼容旧流程时会回退到: $KERNEL_DIR/.config" >&2
		echo "请先准备 Host 配置（见 PKVM-Kconfig.md），或用 --defconfig。" >&2
		exit 1
	fi

	echo ">>> 复制宿主配置作为 guest 起点: $seed_config -> $OUT_DIR/.config"
	cp -a "$seed_config" "$OUT_DIR/.config"
}

check_source_tree_clean() {
	if [[ -f "$KERNEL_DIR/.config" || -d "$KERNEL_DIR/include/config" || -d "$KERNEL_DIR/arch/$SRCARCH/include/generated" ]]; then
		echo "错误: 当前为共享源码树的 out-of-tree 构建（O=$OUT_DIR），但源码树 $KERNEL_DIR 中存在 in-tree 构建残留。" >&2
		echo "内核源码会在 $KERNEL_DIR/Makefile 的 outputmakefile 阶段检查以下路径：" >&2
		echo "  - $KERNEL_DIR/.config" >&2
		echo "  - $KERNEL_DIR/include/config" >&2
		echo "  - $KERNEL_DIR/arch/$SRCARCH/include/generated" >&2
		echo "请先执行一次：" >&2
		echo "  make -C $KERNEL_DIR ARCH=$ARCH mrproper" >&2
		echo "Host 与 Guest 配置应分别保存在：" >&2
		echo "  - $HOST_OUT_DIR/.config" >&2
		echo "  - $OUT_DIR/.config" >&2
		exit 1
	fi
}

maybe_generate_defconfig() {
	if [[ "$NEED_DEFCONFIG" != "1" ]]; then
		return 0
	fi

	echo ">>> 生成 defconfig（ARCH=$ARCH）"
	make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" defconfig
}

force_enable_pkvm_guest() {
	# PKVM_GUEST 在 arch/x86/Kconfig 的 HYPERVISOR_GUEST 子菜单里；两者都打开更稳妥。
	echo ">>> 打开 guest 必需选项: HYPERVISOR_GUEST=y, PKVM_GUEST=y"
	"$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
		-e HYPERVISOR_GUEST \
		-e PKVM_GUEST

	# 避免把宿主侧 pKVM 逻辑“误带进” guest 配置（不是必须，但更清晰）。
	# 注意：如果符号不存在，scripts/config 会返回非 0；这里用 || true 放过。
	"$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d PKVM_INTEL >/dev/null 2>&1 || true
	"$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d PKVM_INTEL_PVIOMMU >/dev/null 2>&1 || true
}

cat <<EOF
=== build guest kernel ===
repo root : $BASE_DIR
kernel src : $KERNEL_DIR
host out  : $HOST_OUT_DIR
out dir   : $OUT_DIR
arch      : $ARCH
config    : $CONFIG_MODE
EOF

prepare_initial_config
check_source_tree_clean
maybe_generate_defconfig
force_enable_pkvm_guest

echo ">>> make olddefconfig（用默认值处理新选项，不交互）"
make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" olddefconfig

echo ">>> 构建 bzImage + modules"
make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" -j"$(nproc)" bzImage modules

VMLINUX="$OUT_DIR/vmlinux"
BZIMAGE="$OUT_DIR/arch/x86/boot/bzImage"

echo ""
echo "完成."
[[ -f "$BZIMAGE" ]] && echo "bzImage: $BZIMAGE" || echo "警告: 未找到 bzImage（请检查构建输出）"
[[ -f "$VMLINUX" ]] && echo "vmlinux: $VMLINUX" || true

if [[ -n "$INSTALL_MODULES_DIR" ]]; then
	echo ">>> 安装 modules 到: $INSTALL_MODULES_DIR"
	# 典型用法：rootfs 挂载在某目录（或用 fakeroot + 打包）。
	make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" modules_install INSTALL_MOD_PATH="$INSTALL_MODULES_DIR"
	echo "modules 已安装到: $INSTALL_MODULES_DIR/lib/modules/"
fi

cat <<'EOF'

下一步（Protected VM）:
  - 用 crosvm 启动时加: --protected-vm-without-firmware
  - 通常需要 direct-kernel boot：传入 --kernel <bzImage> 并设置 --params "<cmdline>"
  - 具体参数请以你的 crosvm 版本为准：运行 `crosvm run --help` 查看
EOF
