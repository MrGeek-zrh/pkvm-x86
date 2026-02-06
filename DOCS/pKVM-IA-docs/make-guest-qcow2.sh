#!/usr/bin/env bash
set -euo pipefail

# 用途:
#   一键生成用于 crosvm 启动的 guest qcow2（Ubuntu base rootfs + 必要软件包 + guest 内核模块）。
#   本脚本本质上是对仓库内 `scripts/create-guestimg.sh` 的封装。
#
# 关键路径概念（容易混）:
#   - kernel src (KERNEL_SRC): guest 内核源码树（用于 `make ... modules_install` 把模块装进镜像）
#       默认:  <repo-root>/pkvm-ia-guest
#       自动探测: 如果 <kernel-out>/Makefile 里有 `include /abs/path/to/linux/Makefile`，则用该路径反推 src。
#       覆盖方式: --kernel-src <dir>
#
#   - kernel out (KERNEL_OUT): guest 内核的 out-of-tree 构建输出目录（也就是 `make O=<dir>` 的那个目录）
#       默认:  <repo-root>/build-guest
#       本脚本会从这里找:
#         - <kernel-out>/.config
#         - <kernel-out>/arch/x86/boot/bzImage 或 <kernel-out>/arch/x86_64/boot/bzImage
#       覆盖方式: --kernel-out <dir>
#
#   - out dir (OUTDIR): 生成的 qcow2 + bzImage 的输出目录
#       默认:  <repo-root>/images/guest
#       覆盖方式: --outdir <dir>
#
# 前置条件（需要你提前准备好）:
#   - guest 内核已经编译完成（至少有 bzImage + modules）：
#       make -C <kernel-src> O=<kernel-out> bzImage modules
#   - 运行环境需要 sudo；并且宿主机能正常加载 nbd（`modprobe nbd`），否则 qemu-nbd 无法挂载镜像。
#   - 该流程会下载 ubuntu-base，并在 chroot 内 apt 安装软件包：需要网络可用。
#
# 用法:
#   ./DOCS/pKVM-IA-docs/make-guest-qcow2.sh [--kernel-src <dir>] --kernel-out <dir> [--outdir <dir>] [--size 10G] [--efi] [--no-cache]
#
# 默认行为总结:
#   - 在 <repo-root>/build-guest/ 下找 bzImage/.config（可用 --kernel-out 改）
#   - 将 qcow2 输出到 <repo-root>/images/guest/（可用 --outdir 改）
#
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# This script lives under DOCS/pKVM-IA-docs/, so the repo root is two levels up.
BASE_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

usage() {
	cat <<EOF
make-guest-qcow2.sh - build guest qcow2 for crosvm from pkvm-ia-guest kernel

Defaults:
  kernel src : ${BASE_DIR}/pkvm-ia-guest  (will auto-detect from build-guest/Makefile if present)
  kernel out : ${BASE_DIR}/build-guest   (out-of-tree build directory, i.e. make O=...)
  out dir    : ${BASE_DIR}/images/guest
  size       : 10G

Environment (can override):
  UBUNTU_BASE    - ubuntu-base tarball URL
  UBUNTU_PKGLIST - package list file path
  USE_CACHE=0    - force rebuild sysroot cache
  EFI=1          - build EFI-flavored image name

Options:
  --kernel-src <dir>   kernel source tree (used for modules_install)
  --kernel-out <dir>   kernel out dir (O=...), required for your build-guest layout
  --outdir <dir>       output directory (qcow2 + bzImage copy)
  --size <10G>         image size (passed to create-guestimg.sh)
  --no-cache           set USE_CACHE=0
  --efi                set EFI=1
  --user <name>        owner user for resulting qcow2 (default: current user)
  --group <name>       owner group for resulting qcow2 (default: current group)
  -h, --help           show this help

Example:
  ./DOCS/pKVM-IA-docs/make-guest-qcow2.sh
  ./DOCS/pKVM-IA-docs/make-guest-qcow2.sh --kernel-out ./build-guest --outdir ./images/guest --size 12G
EOF
}

KERNEL_SRC="${BASE_DIR}/pkvm-ia-guest"
KERNEL_OUT="${BASE_DIR}/build-guest"
OUTDIR="${BASE_DIR}/images/guest"
SIZE="10G"
USER_NAME="$(id -un)"
GROUP_NAME="$(id -gn)"
KERNEL_SRC_SET=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--kernel-src) KERNEL_SRC="${2:?missing value}"; KERNEL_SRC_SET=1; shift 2 ;;
		--kernel-out) KERNEL_OUT="${2:?missing value}"; shift 2 ;;
		--outdir) OUTDIR="${2:?missing value}"; shift 2 ;;
		--size) SIZE="${2:?missing value}"; shift 2 ;;
		--user) USER_NAME="${2:?missing value}"; shift 2 ;;
		--group) GROUP_NAME="${2:?missing value}"; shift 2 ;;
		--no-cache) export USE_CACHE=0; shift 1 ;;
		--efi) export EFI=1; shift 1 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown arg: $1" >&2; usage; exit 2 ;;
	esac
done

# Autodetect the kernel source tree from the output dir's generated Makefile,
# unless the user explicitly set --kernel-src.
if [[ "${KERNEL_SRC_SET}" = "0" && -f "${KERNEL_OUT}/Makefile" ]]; then
	# Example line:
	#   include /abs/path/to/linux/Makefile
	INCLUDED_MAKEFILE="$(awk '/^[[:space:]]*include[[:space:]]+\\//{print $2; exit}' "${KERNEL_OUT}/Makefile" || true)"
	if [[ -n "${INCLUDED_MAKEFILE}" && -f "${INCLUDED_MAKEFILE}" ]]; then
		KERNEL_SRC="$(dirname -- "${INCLUDED_MAKEFILE}")"
	fi
fi

if [[ ! -d "${KERNEL_SRC}" ]]; then
	echo "error: kernel src dir not found: ${KERNEL_SRC}" >&2
	exit 1
fi
if [[ ! -x "${BASE_DIR}/scripts/create-guestimg.sh" ]]; then
	echo "error: expected repo root at ${BASE_DIR} (missing scripts/create-guestimg.sh)" >&2
	exit 1
fi
if [[ ! -d "${KERNEL_OUT}" ]]; then
	echo "error: kernel out dir not found: ${KERNEL_OUT}" >&2
	exit 1
fi
if [[ ! -f "${KERNEL_OUT}/.config" ]]; then
	echo "error: ${KERNEL_OUT} doesn't look like a kernel O= output dir (missing .config)" >&2
	exit 1
fi
if [[ ! -f "${KERNEL_OUT}/arch/x86/boot/bzImage" && ! -f "${KERNEL_OUT}/arch/x86_64/boot/bzImage" ]]; then
	echo "error: bzImage not found under ${KERNEL_OUT}/arch/*/boot/" >&2
	echo "hint: build it first: make -C <kernel-src> O=<kernel-out> bzImage modules" >&2
	exit 1
fi

mkdir -p "${BASE_DIR}/build"

: "${UBUNTU_BASE:=http://cdimage.debian.org/mirror/cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz}"
: "${UBUNTU_PKGLIST:=${BASE_DIR}/scripts/package.list.24}"
export BASE_DIR UBUNTU_BASE UBUNTU_PKGLIST

echo "=== make guest qcow2 ==="
echo "kernel src : ${KERNEL_SRC}"
echo "kernel out : ${KERNEL_OUT}"
echo "out dir    : ${OUTDIR}"
echo "size       : ${SIZE}"
echo "ubuntu base: ${UBUNTU_BASE}"
echo "pkglist    : ${UBUNTU_PKGLIST}"
echo ""

# This invokes sudo + network (downloading ubuntu-base, apt in chroot) and will
# touch host networking/sysctl/iptables in the companion run-crosvm script later,
# but here we only create the qcow2 and install kernel modules into it.
sudo -E KERNEL_OUT="${KERNEL_OUT}" \
	"${BASE_DIR}/scripts/create-guestimg.sh" \
	"${USER_NAME}" "${GROUP_NAME}" \
	-k "${KERNEL_SRC}" \
	-o "${OUTDIR}" \
	-s "${SIZE}"

# NOTE: create-guestimg.sh expects USER/GROUP as the first two positional args.
