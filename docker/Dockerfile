# pKVM-x86 编译环境 Docker镜像
# 解决的问题:
#   - GCC < 12.3.1 (bug 103979) - Ubuntu 24.04 自带 GCC 13.3
#   - Rust 版本 - 安装最新 stable
#   - 各种编译依赖 - 预装所有必要包
#   - 内核配置交互 - 提供 kconfig 辅助脚本

FROM ubuntu:24.04

LABEL maintainer="pkvm-x86-builder"
LABEL description="pKVM-x86 build environment with all dependencies"

# 避免交互式安装
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# 设置语言环境
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# 更新源并安装所有依赖（合并为单次 apt-get update）
RUN apt-get update && apt-get install -y \
    # ========== 基础编译工具 ==========
    build-essential \
    gcc \
    g++ \
    make \
    cmake \
    ninja-build \
    meson \
    automake \
    autoconf \
    libtool \
    pkg-config \
    bison \
    flex \
    gawk \
    bc \
    # ========== 版本控制 ==========
    git \
    git-lfs \
    # ========== 内核编译依赖 ==========
    libncurses-dev \
    libssl-dev \
    libelf-dev \
    liblz4-tool \
    zstd \
    zlib1g-dev \
    # ========== QEMU 编译依赖 ==========
    libglib2.0-dev \
    libpixman-1-dev \
    libspice-server-dev \
    libspice-protocol-dev \
    libusb-1.0-0-dev \
    libusbredirparser-dev \
    libvirglrenderer-dev \
    libepoxy-dev \
    libdrm-dev \
    libgbm-dev \
    libsdl2-dev \
    libgtk-3-dev \
    libvte-2.91-dev \
    libslirp-dev \
    # ========== EDK2/UEFI 编译依赖 ==========
    nasm \
    acpica-tools \
    uuid-dev \
    uuid-runtime \
    efitools \
    python3 \
    python3-pip \
    python3-venv \
    python-is-python3 \
    # ========== Coreboot 编译依赖 ==========
    gnat \
    libgmp-dev \
    libmpfr-dev \
    libmpc-dev \
    # ========== Shim 编译依赖 ==========
    gnu-efi \
    libpopt-dev \
    libefivar-dev \
    sbsigntool \
    # ========== 镜像创建工具 ==========
    dosfstools \
    mtools \
    parted \
    e2fsprogs \
    gdisk \
    squashfs-tools \
    debootstrap \
    # ========== 网络/下载工具 ==========
    curl \
    wget \
    ca-certificates \
    rsync \
    # ========== 其他实用工具 ==========
    xz-utils \
    cpio \
    device-tree-compiler \
    openssh-client \
    openssl \
    xxd \
    vim \
    less \
    sudo \
    kmod \
    qemu-utils \
    udev \
    # ========== 额外开发库 (package.list.24) ==========
    libaio-dev \
    libcap-ng-dev \
    libattr1-dev \
    libcacard-dev \
    libbrlapi-dev \
    libnuma-dev \
    libfdt-dev \
    libseccomp-dev \
    libiscsi-dev \
    libnfs-dev \
    liburing-dev \
    libssh-dev \
    libcurl4-gnutls-dev \
    libpulse-dev \
    libjack-dev \
    libibverbs-dev \
    librdmacm-dev \
    libibumad-dev \
    libpmem-dev \
    libbpf-dev \
    # ========== crosvm 编译依赖 ==========
    libcap-dev \
    libdbus-1-dev \
    libwayland-dev \
    wayland-protocols \
    libxext-dev \
    libavcodec-dev \
    libavutil-dev \
    libswscale-dev \
    libva-dev \
    libclang-dev \
    clang \
    lld \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# 安装 Python 依赖
RUN pip3 install --break-system-packages cryptography

# 安装 Rust (stable + crosvm 要求的 1.77.2)
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable \
    && rustup target add x86_64-unknown-uefi \
    && rustup component add rust-src \
    && rustup install 1.77.2

# 验证 GCC 版本 (必须 >= 12.3.1)
RUN gcc --version | head -1 && \
    GCC_VERSION=$(gcc -dumpfullversion) && \
    echo "GCC Full Version: $GCC_VERSION" && \
    if [ "$(printf '%s\n' "12.3.1" "$GCC_VERSION" | sort -V | head -n1)" != "12.3.1" ]; then \
        echo "ERROR: GCC version must be >= 12.3.1 (bug 103979)"; \
        exit 1; \
    fi

# 创建 GCC 包装器，修复 pkvm Makefile 的版本检测问题
# Ubuntu 的 gcc --version 输出格式不兼容 pkvm 的版本解析
RUN cat > /usr/local/bin/gcc <<'EOFWRAPPER'
#!/bin/bash
REAL_GCC=/usr/bin/gcc
if [ "$1" = "--version" ]; then
    # 输出 pkvm Makefile 能正确解析的格式: "gcc (GCC) X.Y.Z"
    VERSION=$($REAL_GCC -dumpfullversion)
    echo "gcc (GCC) $VERSION"
    echo "Copyright (C) 2023 Free Software Foundation, Inc."
else
    exec $REAL_GCC "$@"
fi
EOFWRAPPER
RUN chmod +x /usr/local/bin/gcc

# 验证 GCC 包装器
RUN echo "=== GCC 包装器测试 ===" && \
    gcc --version && \
    echo "版本提取测试:" && \
    gcc --version | grep gcc | awk '{print $3}'

# 验证 Rust 版本
RUN rustc --version && cargo --version

# 配置 Git (用于子模块操作)
RUN git config --global user.email "builder@pkvm.local" && \
    git config --global user.name "PKVM Builder" && \
    git config --global --add safe.directory '*'

# 创建编译辅助脚本目录
RUN mkdir -p /usr/local/bin/pkvm-scripts

# 创建内核配置辅助脚本 (解决交互式配置问题)
RUN cat > /usr/local/bin/pkvm-scripts/kconfig-auto.sh <<'EOFSCRIPT' \
&& chmod +x /usr/local/bin/pkvm-scripts/kconfig-auto.sh
#!/bin/bash
# 自动接受内核配置默认值，解决交互式提示问题
# 用法: kconfig-auto.sh <make_target> [额外参数...]
# 例如: kconfig-auto.sh oldconfig
#       kconfig-auto.sh defconfig
set -e
TARGET=${1:-oldconfig}
shift 2>/dev/null || true
yes "" | make "$TARGET" "$@"
EOFSCRIPT

# 创建子模块初始化脚本
RUN cat > /usr/local/bin/pkvm-scripts/init-submodules.sh <<'EOFSCRIPT' \
&& chmod +x /usr/local/bin/pkvm-scripts/init-submodules.sh
#!/bin/bash
# 安全初始化 git 子模块
set -e
cd "${1:-.}"

if [ ! -d ".git" ]; then
    echo "警告: 当前目录不是 git 仓库，跳过子模块初始化"
    exit 0
fi

echo "初始化 git 子模块..."
git submodule update --init --recursive
echo "子模块初始化完成"
EOFSCRIPT

# 创建补丁应用脚本
RUN cat > /usr/local/bin/pkvm-scripts/apply-patches.sh <<'EOFSCRIPT'
#!/bin/bash
# 应用 pKVM 相关补丁
set -e

PKVM_DIR="${PKVM_DIR:-/workspace/pkvm-x86}"
PATCH_DIR="$PKVM_DIR/patches"

apply_patches_to_repo() {
    local repo_path="$1"
    local patch_subdir="$2"
    local repo_name="$3"

    cleanup_repo_state() {
        # Ensure we don't have leftover "git am" state from previous runs (submodules use gitdir in .git/modules/*)
        git am --abort >/dev/null 2>&1 || true
        rm -rf "$(git rev-parse --git-path rebase-apply 2>/dev/null)" "$(git rev-parse --git-path rebase-merge 2>/dev/null)" 2>/dev/null || true
    }

    # 从补丁文件提取 Subject（commit message 第一行）
    get_patch_subject() {
        grep -m1 "^Subject:" "$1" | sed 's/^Subject: \(\[PATCH[^]]*\] \)\?//'
    }

    # 检查 commit message 是否已在 git log 中
    is_commit_in_history() {
        local subject="$1"
        # 取 subject 的前 40 个字符作为关键词搜索（避免完全匹配失败）
        local keyword=$(echo "$subject" | cut -c1-40)
        git log --oneline -200 | grep -qF "$keyword"
    }
    
    if [ ! -d "$PATCH_DIR/$patch_subdir" ]; then
        echo "  [跳过] 补丁目录不存在: $patch_subdir"
        return 0
    fi
    
    local patches=$(find "$PATCH_DIR/$patch_subdir" -maxdepth 1 -name "*.patch" 2>/dev/null | sort)
    if [ -z "$patches" ]; then
        echo "  [跳过] 没有找到补丁: $patch_subdir"
        return 0
    fi
    
    echo "  [应用] $repo_name 补丁..."
    cd "$repo_path"
    cleanup_repo_state
    
    for patch in $patches; do
        local patch_name=$(basename "$patch")
        local subject=$(get_patch_subject "$patch")
        
        # 方法1: 通过 commit message 检查是否已在历史中
        if is_commit_in_history "$subject"; then
            echo "    [已应用] $patch_name (commit 已在历史中)"
            continue
        fi
        
        # 方法2: 通过 reverse-check 检查是否已应用
        if git apply --reverse --check "$patch" 2>/dev/null; then
            echo "    [已应用] $patch_name"
            continue
        fi
        
        # 方法3: 尝试正向应用
        if git apply --check "$patch" 2>/dev/null; then
            echo "    [应用中] $patch_name"
            git apply --3way "$patch"
        else
            echo "    [失败] $patch_name 无法应用。"
            echo "           建议: 在该 repo 内执行 'git reset --hard && git clean -xfd' 后重试，或手工处理补丁。"
            return 1
        fi
    done
}

apply_single_patch() {
    local repo_path="$1"
    local patch_file="$2"
    local repo_name="$3"
    
    if [ ! -f "$patch_file" ]; then
        echo "  [跳过] 补丁文件不存在: $(basename $patch_file)"
        return 0
    fi
    
    if [ ! -d "$repo_path" ]; then
        echo "  [跳过] 目标目录不存在: $repo_path"
        return 0
    fi
    
    local patch_name=$(basename "$patch_file")
    echo "  [应用] $repo_name: $patch_name"
    cd "$repo_path"

    # 清理可能残留的 am 状态
    git am --abort >/dev/null 2>&1 || true
    rm -rf "$(git rev-parse --git-path rebase-apply 2>/dev/null)" "$(git rev-parse --git-path rebase-merge 2>/dev/null)" 2>/dev/null || true

    # 从补丁文件提取 Subject
    local subject=$(grep -m1 "^Subject:" "$patch_file" | sed 's/^Subject: \(\[PATCH[^]]*\] \)\?//')
    local keyword=$(echo "$subject" | cut -c1-40)
    
    # 方法1: 通过 commit message 检查是否已在历史中
    if git log --oneline -200 | grep -qF "$keyword"; then
        echo "    [已应用] $patch_name (commit 已在历史中)"
        return 0
    fi
    
    # 方法2: 通过 reverse-check 检查
    if git apply --reverse --check "$patch_file" 2>/dev/null; then
        echo "    [已应用] $patch_name"
        return 0
    fi
    
    # 方法3: 尝试正向应用
    if git apply --check "$patch_file" 2>/dev/null; then
        echo "    [应用中] $patch_name"
        git apply --3way "$patch_file"
    else
        echo "    [失败] $patch_name 无法应用。"
        echo "           建议: 清理目标 repo 后重试或手工处理。"
        return 1
    fi
}

echo "=========================================="
echo "pKVM 补丁应用工具"
echo "=========================================="

case "${1:-all}" in
    qemu)
        apply_patches_to_repo "$PKVM_DIR/qemu" "qemu" "QEMU"
        apply_single_patch "$PKVM_DIR/qemu/roms/qboot" "$PATCH_DIR/0001-qboot-Add-support-for-booting-pKVM-protected-VMs.patch" "qboot"
        ;;
    coreboot)
        # 这个仓库版本（system76/coreboot）通常已经包含这些补丁；重复应用会因为上下文差异而冲突
        if grep -q "select DEBUG_SMI" "$PKVM_DIR/coreboot/src/mainboard/emulation/qemu-q35/Kconfig" 2>/dev/null \
           && grep -q 'USE_FMAP_FILE' "$PKVM_DIR/coreboot/src/mainboard/emulation/qemu-q35/Kconfig" 2>/dev/null \
           && grep -q 'fmap.fmd' "$PKVM_DIR/coreboot/src/mainboard/emulation/qemu-q35/Kconfig" 2>/dev/null \
           && git -C "$PKVM_DIR/coreboot" log -200 --oneline | grep -q "base: introduce protected vm guest support"; then
            echo "  [跳过] Coreboot 看起来已包含 pKVM 相关改动（避免重复打补丁导致冲突）"
        else
            apply_patches_to_repo "$PKVM_DIR/coreboot" "coreboot" "Coreboot"
            apply_single_patch "$PKVM_DIR/coreboot" "$PATCH_DIR/0001-base-introduce-protected-vm-guest-support.patch" "Coreboot (base)"
        fi
        ;;
    edk2)
        if [ -d "$PKVM_DIR/uefi/firmware-open/edk2" ]; then
            apply_patches_to_repo "$PKVM_DIR/uefi/firmware-open/edk2" "edk2" "EDK2"
        else
            echo "  [跳过] EDK2 目录不存在，请先初始化 firmware-open 子模块"
        fi
        ;;
    firmware-open)
        apply_single_patch "$PKVM_DIR/uefi/firmware-open" "$PATCH_DIR/0001-firmware-open-qemu-edk2.config-remove-shell_type.patch" "firmware-open"
        ;;
    linux-host)
        echo "⚠️  注意: 此补丁只应用于 Host 内核，请先编译 Guest 内核再执行此命令！"
        echo ""
        # 自动创建备份 tag
        BACKUP_TAG="backup-before-devhost-$(date +%Y%m%d-%H%M%S)"
        cd "$PKVM_DIR/linux"
        git tag "$BACKUP_TAG" 2>/dev/null && echo "✅ 已创建备份 tag: $BACKUP_TAG" || echo "⚠️ 备份 tag 创建失败（可能已存在）"
        echo "   如需恢复: cd linux && git reset --hard $BACKUP_TAG"
        echo ""
        apply_patches_to_repo "$PKVM_DIR/linux" "dev-host" "Linux (dev-host)"
        ;;
    all)
        echo ""
        echo "⚠️  dev-host 补丁不包含在 all 中，请在编译 Guest 内核后单独执行:"
        echo "    apply-patches linux-host"
        echo ""
        echo "[QEMU]"
        apply_patches_to_repo "$PKVM_DIR/qemu" "qemu" "QEMU"
        echo ""
        echo "[qboot]"
        apply_single_patch "$PKVM_DIR/qemu/roms/qboot" "$PATCH_DIR/0001-qboot-Add-support-for-booting-pKVM-protected-VMs.patch" "qboot"
        echo ""
        echo "[Coreboot]"
        if grep -q "select DEBUG_SMI" "$PKVM_DIR/coreboot/src/mainboard/emulation/qemu-q35/Kconfig" 2>/dev/null \
           && grep -q 'USE_FMAP_FILE' "$PKVM_DIR/coreboot/src/mainboard/emulation/qemu-q35/Kconfig" 2>/dev/null \
           && grep -q 'fmap.fmd' "$PKVM_DIR/coreboot/src/mainboard/emulation/qemu-q35/Kconfig" 2>/dev/null \
           && git -C "$PKVM_DIR/coreboot" log -200 --oneline | grep -q "base: introduce protected vm guest support"; then
            echo "  [跳过] Coreboot 看起来已包含 pKVM 相关改动（避免重复打补丁导致冲突）"
        else
            apply_patches_to_repo "$PKVM_DIR/coreboot" "coreboot" "Coreboot"
            apply_single_patch "$PKVM_DIR/coreboot" "$PATCH_DIR/0001-base-introduce-protected-vm-guest-support.patch" "Coreboot (base)"
        fi
        echo ""
        echo "[firmware-open]"
        apply_single_patch "$PKVM_DIR/uefi/firmware-open" "$PATCH_DIR/0001-firmware-open-qemu-edk2.config-remove-shell_type.patch" "firmware-open"
        echo ""
        echo "[EDK2]"
        if [ -d "$PKVM_DIR/uefi/firmware-open/edk2" ]; then
            apply_patches_to_repo "$PKVM_DIR/uefi/firmware-open/edk2" "edk2" "EDK2"
        else
            echo "  [跳过] EDK2 目录不存在"
        fi
        ;;
    check)
        echo "检查补丁状态..."
        echo ""
        echo "=== 根目录补丁 ==="
        find "$PATCH_DIR" -maxdepth 1 -name "*.patch" -exec ls -lh {} \; 2>/dev/null || echo "  (无补丁)"
        echo ""
        echo "=== patches/dev-host/ (Linux宿主机内核) ==="
        find "$PATCH_DIR/dev-host" -maxdepth 1 -name "*.patch" -exec ls -lh {} \; 2>/dev/null || echo "  (无补丁)"
        echo ""
        echo "=== patches/qemu/ ==="
        find "$PATCH_DIR/qemu" -maxdepth 1 -name "*.patch" -exec ls -lh {} \; 2>/dev/null || echo "  (无补丁)"
        echo ""
        echo "=== patches/coreboot/ ==="
        find "$PATCH_DIR/coreboot" -maxdepth 1 -name "*.patch" -exec ls -lh {} \; 2>/dev/null || echo "  (无补丁)"
        echo ""
        echo "=== patches/edk2/ ==="
        find "$PATCH_DIR/edk2" -maxdepth 1 -name "*.patch" -exec ls -lh {} \; 2>/dev/null || echo "  (无补丁)"
        echo ""
        echo "总计:"
        echo "  根目录:      $(find "$PATCH_DIR" -maxdepth 1 -name "*.patch" 2>/dev/null | wc -l) 个补丁"
        echo "  dev-host:    $(find "$PATCH_DIR/dev-host" -maxdepth 1 -name "*.patch" 2>/dev/null | wc -l) 个补丁"
        echo "  qemu:        $(find "$PATCH_DIR/qemu" -maxdepth 1 -name "*.patch" 2>/dev/null | wc -l) 个补丁"
        echo "  coreboot:    $(find "$PATCH_DIR/coreboot" -maxdepth 1 -name "*.patch" 2>/dev/null | wc -l) 个补丁"
        echo "  edk2:        $(find "$PATCH_DIR/edk2" -maxdepth 1 -name "*.patch" 2>/dev/null | wc -l) 个补丁"
        ;;
    *)
        echo "用法: apply-patches.sh [linux-host|qemu|coreboot|edk2|firmware-open|all|check]"
        echo ""
        echo "  all           - 应用 QEMU/Coreboot/firmware-open/EDK2 补丁 (不含 linux-host)"
        echo "  linux-host    - 应用 Linux 宿主机内核补丁 (dev-host)"
        echo "  qemu          - 应用 QEMU + qboot 补丁"
        echo "  coreboot      - 应用 Coreboot 补丁"
        echo "  edk2          - 应用 EDK2 补丁"
        echo "  firmware-open - 应用 firmware-open 补丁"
        echo "  check         - 检查可用补丁"
        echo ""
        echo "⚠️  正确的编译顺序:"
        echo "  1. apply-patches all        # 应用通用补丁"
        echo "  2. make guest-kernel        # 先编译 Guest 内核"
        echo "  3. apply-patches linux-host # 再应用 Host 内核补丁"
        echo "  4. make kernel              # 最后编译 Host 内核"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "补丁处理完成"
echo "=========================================="
EOFSCRIPT
RUN chmod +x /usr/local/bin/pkvm-scripts/apply-patches.sh

# 创建完整编译脚本
RUN cat > /usr/local/bin/pkvm-scripts/build-all.sh <<'EOFSCRIPT'
#!/bin/bash
# pKVM-x86 完整编译脚本
set -e

PKVM_DIR="${PKVM_DIR:-/workspace/pkvm-x86}"
NJOBS="${NJOBS:-$(nproc)}"

cd "$PKVM_DIR"

echo "=========================================="
echo "pKVM-x86 编译环境"
echo "GCC: $(gcc --version | head -1)"
echo "Rust: $(rustc --version)"
echo "工作目录: $PKVM_DIR"
echo "并行任务: $NJOBS"
echo "=========================================="

# 检查并初始化子模块
/usr/local/bin/pkvm-scripts/init-submodules.sh "$PKVM_DIR"

case "${1:-all}" in
    submodules)
        echo "仅初始化子模块"
        ;;
    kernel)
        echo "编译内核..."
        make kernel -j$NJOBS
        ;;
    guest-kernel)
        echo "编译 guest 内核..."
        make guest-kernel -j$NJOBS
        ;;
    qemu)
        echo "编译 QEMU..."
        make qemu -j$NJOBS
        ;;
    shim)
        echo "编译 shim..."
        make shim
        ;;
    openfw)
        echo "编译 firmware-open..."
        make openfw
        ;;
    coreboot)
        echo "编译 coreboot..."
        make coreboot
        ;;
    all)
        echo "完整编译..."
        make all -j$NJOBS
        ;;
    clean)
        echo "清理编译..."
        make clean
        ;;
    *)
        echo "用法: build-all.sh [submodules|kernel|guest-kernel|qemu|shim|openfw|coreboot|all|clean]"
        exit 1
        ;;
esac

echo "=========================================="
echo "编译完成!"
echo "=========================================="
EOFSCRIPT
RUN chmod +x /usr/local/bin/pkvm-scripts/build-all.sh

# 创建环境设置脚本
RUN cat > /usr/local/bin/pkvm-env.sh <<'EOFSCRIPT'
#!/bin/bash
# pKVM-x86 编译环境设置
export PKVM_DIR="${PKVM_DIR:-/workspace/pkvm-x86}"
export PATH="/usr/local/bin/pkvm-scripts:$PATH"
export NJOBS="${NJOBS:-$(nproc)}"

# Rust 环境
source /usr/local/cargo/env 2>/dev/null || true

# 便捷别名
alias pkvm-build='/usr/local/bin/pkvm-scripts/build-all.sh'
alias kconfig-auto='/usr/local/bin/pkvm-scripts/kconfig-auto.sh'
alias apply-patches='/usr/local/bin/pkvm-scripts/apply-patches.sh'

echo "pKVM-x86 编译环境已加载"
echo "  - pkvm-build [target]  : 编译指定目标"
echo "  - apply-patches [comp] : 应用补丁 (qemu/coreboot/edk2/all)"
echo "  - kconfig-auto <target>: 自动接受内核配置默认值"
echo "  - PKVM_DIR=$PKVM_DIR"
EOFSCRIPT
RUN chmod +x /usr/local/bin/pkvm-env.sh

# 将环境设置加入 bashrc
RUN echo 'source /usr/local/bin/pkvm-env.sh' >> /etc/bash.bashrc

# 创建工作目录
WORKDIR /workspace

# 设置入口点
ENTRYPOINT ["/bin/bash"]
