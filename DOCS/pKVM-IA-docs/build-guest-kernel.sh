#!/usr/bin/env bash
set -euo pipefail

# pKVM-IA Guest 内核：构建用于 Protected VM 的 guest bzImage/modules
#
# 设计目标：
# - 使用 pkvm-ia-guest 作为 guest 内核源码目录（与宿主 pKVM-IA 分离，避免 in-tree 冲突）。
# - 默认复用宿主 .config（pKVM-IA/.config）作为起点，然后强制打开 guest 必需选项。
# - 不默认安装 modules（避免污染宿主机）；如需写入 rootfs，请用 --install-modules。
#
# 用法示例：
#   ./build-guest-kernel.sh
#   ./build-guest-kernel.sh --out /path/to/build-guest
#   ./build-guest-kernel.sh --defconfig
#   ./build-guest-kernel.sh --install-modules /path/to/rootfs
#
# 输出：
#   - bzImage: <out>/arch/x86/boot/bzImage
#   - modules: <out> 下生成（需要时可 --install-modules 安装到 rootfs）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUEST_KERNEL_DIR="$BASE_DIR/pkvm-ia-guest"
HOST_CONFIG="$BASE_DIR/pKVM-IA/.config"

OUT_DIR="$BASE_DIR/build-guest"
CONFIG_MODE="from-host-config" # from-host-config | defconfig | keep-existing
INSTALL_MODULES_DIR=""
ARCH="${ARCH:-x86_64}"

usage() {
	cat <<'EOF'
build-guest-kernel.sh - build pKVM guest kernel (x86_64)

Options:
  --out <dir>              输出目录（O=...，默认: <repo>/build-guest）
  --defconfig              从 defconfig 起步（不复用宿主 .config）
  --keep-existing-config   如果 <out>/.config 已存在则以它为起点（仍会强制启用 PKVM_GUEST/HYPERVISOR_GUEST）
  --install-modules <dir>  执行 modules_install 到指定目录（通常是 guest rootfs 挂载点）
  -h, --help               显示帮助

Notes:
  - Protected guest 必须开启 CONFIG_PKVM_GUEST=y（以及 HYPERVISOR_GUEST=y）。
  - 如果 guest 需要 virtio 磁盘/网卡，请确保相应驱动也在 .config 里启用。
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--out)
			OUT_DIR="${2:?missing dir after --out}"
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

if [[ ! -d "$GUEST_KERNEL_DIR" ]]; then
	echo "错误: guest 内核源码目录不存在: $GUEST_KERNEL_DIR" >&2
	exit 1
fi

if [[ ! -x "$GUEST_KERNEL_DIR/scripts/config" ]]; then
	echo "错误: 未找到 $GUEST_KERNEL_DIR/scripts/config（内核源码不完整？）" >&2
	exit 1
fi

mkdir -p "$OUT_DIR"

maybe_seed_config() {
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
		echo ">>> 生成 defconfig（ARCH=$ARCH）"
		make -C "$GUEST_KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" defconfig
		return 0
	fi

	# 默认：从宿主 .config 起步（更符合 pKVM-IA 分支的依赖组合）
	if [[ ! -f "$HOST_CONFIG" ]]; then
		echo "错误: 未找到宿主 .config: $HOST_CONFIG；请先准备宿主 .config（见 PKVM-Kconfig.md），或用 --defconfig。" >&2
		exit 1
	fi
	echo ">>> 复制宿主配置作为 guest 起点: $HOST_CONFIG -> $OUT_DIR/.config"
	cp -a "$HOST_CONFIG" "$OUT_DIR/.config"
}

force_enable_pkvm_guest() {
	# PKVM_GUEST 在 arch/x86/Kconfig 的 HYPERVISOR_GUEST 子菜单里；两者都打开更稳妥。
	echo ">>> 打开 guest 必需选项: HYPERVISOR_GUEST=y, PKVM_GUEST=y"
	"$GUEST_KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
		-e HYPERVISOR_GUEST \
		-e PKVM_GUEST

	# 避免把宿主侧 pKVM 逻辑“误带进” guest 配置（不是必须，但更清晰）。
	# 注意：如果符号不存在，scripts/config 会返回非 0；这里用 || true 放过。
	"$GUEST_KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d PKVM_INTEL >/dev/null 2>&1 || true
	"$GUEST_KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d PKVM_INTEL_PVIOMMU >/dev/null 2>&1 || true
}

cat <<EOF
=== build guest kernel ===
repo root : $BASE_DIR
guest src : $GUEST_KERNEL_DIR
out dir   : $OUT_DIR
arch      : $ARCH
config    : $CONFIG_MODE
EOF

maybe_seed_config
force_enable_pkvm_guest

# out-of-tree 构建时内核要求 guest 源码树无 in-tree 残留（.config / include/config / arch/.../include/generated）
if [[ -f "$GUEST_KERNEL_DIR/.config" || -d "$GUEST_KERNEL_DIR/include/config" || -d "$GUEST_KERNEL_DIR/arch/$ARCH/include/generated" ]]; then
	echo "错误: 当前为 out-of-tree 构建（O=$OUT_DIR），但 guest 源码树 $GUEST_KERNEL_DIR 中存在 in-tree 构建残留。" >&2
	echo "解决: 在 guest 源码树中执行 mrproper 后再编 guest：" >&2
	echo "  cd $GUEST_KERNEL_DIR && make ARCH=$ARCH mrproper" >&2
	echo "然后重新运行本脚本；配置会从 $HOST_CONFIG 复制或使用已有 $OUT_DIR/.config。" >&2
	exit 1
fi

echo ">>> make olddefconfig（用默认值处理新选项，不交互）"
make -C "$GUEST_KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" olddefconfig

echo ">>> 构建 bzImage + modules"
make -C "$GUEST_KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" -j"$(nproc)" bzImage modules

VMLINUX="$OUT_DIR/vmlinux"
BZIMAGE="$OUT_DIR/arch/x86/boot/bzImage"

echo ""
echo "完成."
[[ -f "$BZIMAGE" ]] && echo "bzImage: $BZIMAGE" || echo "警告: 未找到 bzImage（请检查构建输出）"
[[ -f "$VMLINUX" ]] && echo "vmlinux: $VMLINUX" || true

if [[ -n "$INSTALL_MODULES_DIR" ]]; then
	echo ">>> 安装 modules 到: $INSTALL_MODULES_DIR"
	# 典型用法：rootfs 挂载在某目录（或用 fakeroot + 打包）。
	make -C "$GUEST_KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" modules_install INSTALL_MOD_PATH="$INSTALL_MODULES_DIR"
	echo "modules 已安装到: $INSTALL_MODULES_DIR/lib/modules/"
fi

cat <<'EOF'

下一步（Protected VM）:
  - 用 crosvm 启动时加: --protected-vm-without-firmware
  - 通常需要 direct-kernel boot：传入 --kernel <bzImage> 并设置 --params "<cmdline>"
  - 具体参数请以你的 crosvm 版本为准：运行 `crosvm run --help` 查看
EOF
