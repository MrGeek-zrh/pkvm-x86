#!/usr/bin/env bash
set -euo pipefail

# 按照 https://crosvm.dev/book/building_crosvm/linux.html 整理的 crosvm（CrossVM）在 Linux 上的构建步骤。
# 目标：在本仓库里一键拉取/初始化/安装依赖/编译生成 crosvm 二进制。
#
# 默认行为（不带参数）：在宿主机上构建 debug 版本（cargo build），产物为:
#   <crosvm_dir>/target/debug/crosvm
#
# 用法示例:
#   ./build-crosvm.sh
#   ./build-crosvm.sh --dir /path/to/crosvm
#   ./build-crosvm.sh --use-dev-container
#   ./build-crosvm.sh --features gdb
#   ./build-crosvm.sh --target aarch64-unknown-linux-gnu --use-dev-container
#
# 注意:
# - Debian/Ubuntu 推荐使用 crosvm 自带的 ./tools/setup 安装依赖（会用到 sudo/apt）。
# - 非 Debian 系发行版建议使用 ./tools/dev_container（需要 podman 或 docker）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_CROSVM_DIR="$BASE_DIR/third_party/crosvm"
CROSVM_DIR="$DEFAULT_CROSVM_DIR"

USE_DEV_CONTAINER=0
RUN_SETUP=1
FEATURES=""
TARGET_TRIPLE=""

usage() {
	cat <<'EOF'
build-crosvm.sh - build crosvm on Linux (per crosvm.dev book)

Options:
  --dir <path>            crosvm 源码目录（默认: <repo>/third_party/crosvm）
  --no-setup              不运行 ./tools/setup（只做 clone/submodule/config/build）
  --use-dev-container     使用 ./tools/dev_container 进行构建（推荐非 Debian 系，或需要交叉编译）
  --features <list>       传给 cargo 的 features（例如: "gdb" 或 "gdb,seccomp"）
  --target <triple>       交叉编译目标三元组（例如: aarch64-unknown-linux-gnu）
  -h, --help              显示帮助

Outputs:
  - 宿主机构建:   <crosvm_dir>/target/debug/crosvm
  - Dev container: /scratch/cargo_target/debug/crosvm (容器内路径，交叉编译则含 <target>)

Notes (dev container):
  - 需要 Podman 或 Docker。
  - 如果用 Podman（Debian/Ubuntu）：通常需要 sudo apt install passt crun
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dir)
			CROSVM_DIR="${2:?missing path after --dir}"
			shift 2
			;;
		--no-setup)
			RUN_SETUP=0
			shift
			;;
		--use-dev-container)
			USE_DEV_CONTAINER=1
			shift
			;;
		--features)
			FEATURES="${2:?missing features after --features}"
			shift 2
			;;
		--target)
			TARGET_TRIPLE="${2:?missing target triple after --target}"
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

ensure_crosvm_checkout() {
	if [[ -d "$CROSVM_DIR/.git" ]]; then
		return 0
	fi

	echo ">>> 未找到 crosvm 源码，准备 clone 到: $CROSVM_DIR"
	mkdir -p "$(dirname "$CROSVM_DIR")"
	# 官方文档给出的 checkout 地址（googlesource）。
	git clone https://chromium.googlesource.com/crosvm/crosvm "$CROSVM_DIR"
}

init_submodules_and_git_config() {
	echo ">>> 初始化 submodule（git submodule update --init）"
	( cd "$CROSVM_DIR" && git submodule update --init )

	# 官方文档建议：自动递归更新 submodule，但不要 push submodule。
	echo ">>> 配置 git submodule 递归行为（推荐）"
	( cd "$CROSVM_DIR" && git config submodule.recurse true )
	( cd "$CROSVM_DIR" && git config push.recurseSubmodules no )
}

run_setup_if_requested() {
	if [[ "$RUN_SETUP" -eq 0 ]]; then
		echo ">>> 跳过 ./tools/setup（--no-setup）"
		return 0
	fi

	if [[ "$USE_DEV_CONTAINER" -eq 1 ]]; then
		# 在容器内执行 setup，避免宿主机装包（也更适合非 Debian 系）。
		echo ">>> 使用 dev container 执行 ./tools/setup"
		( cd "$CROSVM_DIR" && ./tools/dev_container ./tools/setup )
		return 0
	fi

	# 宿主机环境：官方推荐 Debian/Ubuntu 直接跑 ./tools/setup。
	if command -v apt-get >/dev/null 2>&1; then
		echo ">>> 在宿主机执行 ./tools/setup（Debian/Ubuntu 推荐；会用到 sudo/apt）"
		( cd "$CROSVM_DIR" && ./tools/setup )
	else
		cat >&2 <<'EOF'
错误: 当前系统未检测到 apt-get。
根据官方文档，非 Debian 系发行版建议使用开发容器:
  ./build-crosvm.sh --use-dev-container
或你也可以自行安装依赖后再加 --no-setup 继续构建。
EOF
		exit 1
	fi
}

cargo_build() {
	if [[ -n "$TARGET_TRIPLE" && "$USE_DEV_CONTAINER" -eq 0 ]]; then
		cat >&2 <<'EOF'
提示: 你正在进行交叉编译（--target），官方文档推荐优先使用 dev container（能自动配齐工具链/依赖）:
  ./build-crosvm.sh --use-dev-container --target <triple>

如果坚持在宿主机交叉编译，通常还需要：
  - 启用外来架构（Debian）：sudo dpkg --add-architecture arm64/riscv64 && sudo apt update
  - 安装对应依赖：./tools/setup-aarch64 或 ./tools/setup-riscv64
  - 配置 cargo：cat .cargo/config.debian.toml >> ${CARGO_HOME:-~/.cargo}/config.toml
EOF
	fi

	local cargo_cmd=(cargo build)
	if [[ -n "$FEATURES" ]]; then
		cargo_cmd+=(--features="$FEATURES")
	fi
	if [[ -n "$TARGET_TRIPLE" ]]; then
		cargo_cmd+=(--target "$TARGET_TRIPLE")
	fi

	if [[ "$USE_DEV_CONTAINER" -eq 1 ]]; then
		echo ">>> 在 dev container 内构建: ${cargo_cmd[*]}"
		( cd "$CROSVM_DIR" && ./tools/dev_container "${cargo_cmd[@]}" )
		echo ">>> 构建完成（容器内产物路径示例: /scratch/cargo_target/.../debug/crosvm）"
		return 0
	fi

	echo ">>> 在宿主机构建: ${cargo_cmd[*]}"
	( cd "$CROSVM_DIR" && "${cargo_cmd[@]}" )

	if [[ -n "$TARGET_TRIPLE" ]]; then
		echo ">>> 构建完成: $CROSVM_DIR/target/debug/$TARGET_TRIPLE/crosvm"
	else
		echo ">>> 构建完成: $CROSVM_DIR/target/debug/crosvm"
	fi
}

cat <<EOF
=== crosvm build (Linux) ===
repo root : $BASE_DIR
crosvm dir: $CROSVM_DIR
setup     : $([[ "$RUN_SETUP" -eq 1 ]] && echo enabled || echo disabled)
container : $([[ "$USE_DEV_CONTAINER" -eq 1 ]] && echo yes || echo no)
features  : ${FEATURES:-<none>}
target    : ${TARGET_TRIPLE:-<native>}
EOF

if [[ "$USE_DEV_CONTAINER" -eq 1 ]]; then
	cat <<'EOF'
提示（dev container）:
  - 需要 Podman 或 Docker。
  - 若使用 Podman 且需要在容器内访问 /dev/kvm，通常还需要 crun 以保留用户补充组。
  - Debian/Ubuntu 可参考：sudo apt install passt crun
EOF
fi

ensure_crosvm_checkout
init_submodules_and_git_config
run_setup_if_requested
cargo_build

cat <<'EOF'

官方文档补充（常见坑）:
  - 如果 /var/empty 不存在，某些 jail 相关功能会失败：sudo mkdir -p /var/empty
  - 运行测试/实例需要 /dev/kvm 权限：通常把用户加入 kvm 组后重新登录
  - 部分网络相关能力需要 CAP_NET_ADMIN（通常需要 root）
EOF
