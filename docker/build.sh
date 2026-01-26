#!/bin/bash
#
# pKVM-x86 Docker 编译助手脚本
# 
# 用法:
#   ./build.sh build-image     # 构建 Docker 镜像
#   ./build.sh shell           # 进入交互式编译环境
#   ./build.sh make [target]   # 在容器中执行 make 命令
#   ./build.sh compile [comp]  # 编译指定组件
#   ./build.sh clean           # 清理编译产物
#
# 组件列表: kernel, guest-kernel, qemu, shim, openfw, coreboot, all
#
# 注意: Docker 相关文件位于 pkvm-x86/docker/ 目录下
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 确保宿主机 nbd 设备存在（guestimage/hostimage 需要）
ensure_nbd() {
    if [ "${SKIP_NBD:-0}" = "1" ]; then
        log_warn "SKIP_NBD=1，跳过 nbd 检查/加载"
        return 0
    fi

    if [ -e /dev/nbd0 ]; then
        return 0
    fi

    log_warn "未发现 /dev/nbd0，尝试在宿主机加载 nbd 模块（需要 sudo）..."
    if sudo modprobe nbd max_part=8; then
        if [ -e /dev/nbd0 ]; then
            log_success "nbd 模块已加载: /dev/nbd0 已就绪"
            return 0
        fi
    fi

    log_warn "nbd 模块加载失败或 /dev/nbd0 仍不存在，guestimage/hostimage 可能会失败"
}

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
    else
        log_error "无法检测操作系统类型"
        exit 1
    fi
}

# 安装 Docker（根据操作系统类型）
install_docker() {
    log_info "检测到 Docker 未安装，开始自动安装..."
    detect_os
    
    case "$OS" in
        ubuntu|debian)
            log_info "检测到 Ubuntu/Debian 系统，手动添加 Docker 源并安装..."
            
            # 安装必要的依赖
            log_info "安装必要的依赖包..."
            DEBIAN_FRONTEND=noninteractive sudo apt-get update
            DEBIAN_FRONTEND=noninteractive sudo apt-get install -y \
                ca-certificates \
                curl \
                gnupg \
                lsb-release
            
            # 检测系统版本（用于确定 Docker 源）
            DISTRO_CODENAME=""
            DOCKER_DISTRO=""
            
            if [ "$OS" = "ubuntu" ]; then
                DOCKER_DISTRO="ubuntu"
                # 检测 Ubuntu codename
                if [ -f /etc/os-release ]; then
                    . /etc/os-release
                    DISTRO_CODENAME=${UBUNTU_CODENAME:-$VERSION_CODENAME}
                    if [ -z "$DISTRO_CODENAME" ] && [ -n "$OS_VERSION" ]; then
                        # 从版本号推导 codename
                        case "$OS_VERSION" in
                            20.04) DISTRO_CODENAME="focal" ;;
                            22.04) DISTRO_CODENAME="jammy" ;;
                            24.04) DISTRO_CODENAME="noble" ;;
                            *) DISTRO_CODENAME="focal" ;; # 默认使用 focal
                        esac
                    fi
                fi
            elif [ "$OS" = "debian" ]; then
                DOCKER_DISTRO="debian"
                # 检测 Debian codename
                if [ -f /etc/os-release ]; then
                    . /etc/os-release
                    DISTRO_CODENAME=${VERSION_CODENAME}
                fi
            fi
            
            # 如果没有检测到 codename，尝试从 lsb_release 获取
            if [ -z "$DISTRO_CODENAME" ] && command -v lsb_release &> /dev/null; then
                DISTRO_CODENAME=$(lsb_release -cs)
            fi
            
            # 如果还是无法确定，使用默认值
            if [ "$OS" = "ubuntu" ]; then
                DISTRO_CODENAME=${DISTRO_CODENAME:-focal}
            elif [ "$OS" = "debian" ]; then
                DISTRO_CODENAME=${DISTRO_CODENAME:-bullseye}
            fi
            
            log_info "检测到 $OS codename: $DISTRO_CODENAME"
            
            # 添加 Docker 的 GPG 密钥
            log_info "添加 Docker GPG 密钥..."
            sudo install -m 0755 -d /etc/apt/keyrings
            if curl -fsSL https://download.docker.com/linux/$DOCKER_DISTRO/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null; then
                sudo chmod a+r /etc/apt/keyrings/docker.gpg
            else
                log_error "添加 Docker GPG 密钥失败"
                exit 1
            fi
            
            # 添加 Docker apt 源
            log_info "添加 Docker apt 源..."
            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DOCKER_DISTRO \
                $DISTRO_CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # 更新 apt 缓存
            log_info "更新 apt 缓存..."
            DEBIAN_FRONTEND=noninteractive sudo apt-get update
            
            # 安装 Docker 相关包（只安装核心包，避免不存在的包）
            log_info "安装 Docker 核心组件..."
            DEBIAN_FRONTEND=noninteractive sudo apt-get install -y \
                docker-ce \
                docker-ce-cli \
                containerd.io \
                docker-buildx-plugin \
                docker-compose-plugin || {
                log_error "Docker 安装失败"
                exit 1
            }
            
            log_success "Docker 核心组件安装完成"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            log_info "检测到 CentOS/RHEL/Fedora 系统，使用 yum/dnf 安装 Docker..."
            if command -v dnf &> /dev/null; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            sudo $PKG_MGR install -y yum-utils
            sudo $PKG_MGR-config-manager --add-repo https://download.docker.com/linux/$OS/docker-ce.repo
            sudo $PKG_MGR install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        *)
            log_warn "未识别的操作系统: $OS"
            log_info "尝试使用通用安装脚本..."
            if ! command -v curl &> /dev/null; then
                log_error "需要 curl 但未安装，请手动安装 Docker"
                exit 1
            fi
            if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
                log_warn "如果系统已 EOL，安装脚本会显示警告并等待 10 秒后自动继续..."
                log_info "正在安装 Docker（这可能需要几分钟）..."
                if DEBIAN_FRONTEND=noninteractive timeout 300 bash -c 'yes "" | sudo sh /tmp/get-docker.sh' 2>&1; then
                    log_success "Docker 安装脚本执行完成"
                else
                    EXIT_CODE=$?
                    if [ $EXIT_CODE -eq 124 ]; then
                        log_warn "安装脚本执行超时，检查 Docker 是否已安装..."
                    elif command -v docker &> /dev/null; then
                        log_success "Docker 已安装（可能在等待过程中完成）"
                    else
                        log_error "Docker 安装可能失败，退出码: $EXIT_CODE"
                        log_info "提示: 可以手动运行 'sudo sh /tmp/get-docker.sh' 查看详细错误"
                        rm -f /tmp/get-docker.sh
                        exit 1
                    fi
                fi
                rm -f /tmp/get-docker.sh
            else
                log_error "下载 Docker 安装脚本失败，请手动安装 Docker"
                exit 1
            fi
            ;;
    esac
    
    # 启动 Docker 服务
    log_info "启动 Docker 服务..."
    if command -v systemctl &> /dev/null; then
        sudo systemctl enable docker
        sudo systemctl start docker
    elif command -v service &> /dev/null; then
        sudo service docker start
    fi
    
    # 将当前用户添加到 docker 组（避免每次都需要 sudo）
    if [ -n "$USER" ] && ! groups "$USER" | grep -q docker; then
        log_info "将用户 $USER 添加到 docker 组（需要重新登录或执行 'newgrp docker' 才能生效）..."
        sudo usermod -aG docker "$USER"
        log_warn "已将用户添加到 docker 组，但需要重新登录或执行 'newgrp docker' 才能无需 sudo 使用 Docker"
        log_warn "当前会话中可能仍需要 sudo 来运行 Docker 命令"
    fi
    
    # 验证安装
    sleep 2
    if command -v docker &> /dev/null; then
        log_success "Docker 安装完成"
    else
        log_error "Docker 安装失败，请手动安装"
        exit 1
    fi
}

# 检查 Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_warn "Docker 未安装"
        read -p "是否自动安装 Docker? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            install_docker
        else
            log_error "Docker 未安装，请先安装 Docker"
            exit 1
        fi
    fi
    
    # 检查 Docker 服务是否运行
    if ! docker info &> /dev/null; then
        log_warn "Docker 服务未运行或当前用户无权限，尝试启动服务..."
        if command -v systemctl &> /dev/null; then
            sudo systemctl start docker 2>/dev/null || true
        elif command -v service &> /dev/null; then
            sudo service docker start 2>/dev/null || true
        fi
        
        # 再次检查
        sleep 1
        if ! docker info &> /dev/null; then
            log_error "Docker 服务未运行或当前用户无权限"
            log_info "提示: 如果已添加用户到 docker 组，请执行 'newgrp docker' 或重新登录"
            exit 1
        fi
    fi
    
    log_success "Docker 检查通过"
}

# 检查 docker-compose
check_compose() {
    if command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
    elif docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
    else
        log_error "docker-compose 未安装"
        exit 1
    fi
}

# 构建镜像
build_image() {
    log_info "构建 Docker 镜像..."
    $COMPOSE_CMD build
    log_success "镜像构建完成"
}

# 进入交互式 shell
enter_shell() {
    log_info "进入交互式编译环境..."
    log_info "提示: 使用 'pkvm-build [target]' 进行编译"
    log_info "      使用 'exit' 退出容器"
    log_info "提示: 若要生成镜像，需宿主机 /dev/nbd0（可先执行: sudo modprobe nbd max_part=8）"
    $COMPOSE_CMD run --rm --entrypoint bash build
}

# 在容器中执行 make
run_make() {
    local target="${1:-all}"
    log_info "在容器中执行: make $target"
    $COMPOSE_CMD run --rm --entrypoint bash build -c "source /usr/local/bin/pkvm-env.sh && make $target"
}

# 编译指定组件
compile_component() {
    local component="${1:-all}"
    log_info "编译组件: $component"
    $COMPOSE_CMD run --rm build pkvm-build "$component"
}

# 清理编译
clean_build() {
    log_info "清理编译产物..."
    $COMPOSE_CMD run --rm build make clean
    log_success "清理完成"
}

# 初始化子模块
init_submodules() {
    log_info "初始化 git 子模块..."
    $COMPOSE_CMD run --rm build /usr/local/bin/pkvm-scripts/init-submodules.sh /workspace/pkvm-x86
    log_success "子模块初始化完成"
}

# 应用补丁
apply_patches() {
    local component="${1:-all}"
    log_info "应用补丁: $component"
    $COMPOSE_CMD run --rm build /usr/local/bin/pkvm-scripts/apply-patches.sh "$component"
}

# 显示帮助
show_help() {
    cat << EOF
pKVM-x86 Docker 编译助手

用法: $0 <命令> [参数]

命令:
  build-image          构建 Docker 编译镜像
  shell                进入交互式编译环境
  make [target]        在容器中执行 make 命令 (默认: all)
  compile [component]  编译指定组件
  init-submodules      初始化 git 子模块
  apply-patches [comp] 应用补丁 (linux-host/qemu/coreboot/edk2/firmware-open/all/check)
  clean                清理编译产物
  help                 显示此帮助信息

组件列表:
  kernel        编译主机内核
  guest-kernel  编译客户机内核
  qemu          编译 QEMU
  shim          编译 shim
  openfw        编译 firmware-open
  coreboot      编译 coreboot
  all           完整编译 (默认)

示例:
  $0 build-image           # 首次使用，构建镜像
  $0 shell                 # 进入编译环境
  $0 apply-patches all        # 应用通用补丁（不含 linux-host）
  $0 apply-patches linux-host # 仅应用 Host 内核补丁（编译 Guest 后再执行）
  $0 apply-patches qemu    # 仅应用 QEMU + qboot 补丁
  $0 compile kernel        # 编译内核
  $0 compile all           # 完整编译
  $0 make menuconfig       # 执行 make menuconfig

环境变量:
  NJOBS                    并行编译任务数 (默认: nproc)
  AUTO_INSTALL_DOCKER      自动安装 Docker (设置为 1 时，如果 Docker 未安装则自动安装)
  SKIP_NBD                 跳过 nbd 检查/加载 (设置为 1 时跳过)

已解决的编译坑:
  ✓ GCC < 12.3.1 (bug 103979)  - Ubuntu 24.04 自带 GCC 13.3
  ✓ 内核配置交互提示           - 容器内使用 kconfig-auto.sh
  ✓ Rust 版本过低              - 预装最新 Rust stable
  ✓ Git 子模块缺失             - 自动检查并初始化
  ✓ 各种依赖缺失               - Dockerfile 预装所有依赖

EOF
}

# 主函数
main() {
    check_docker
    check_compose
    
    # 在进入 Docker 容器之前，确保宿主机 nbd 设备存在
    ensure_nbd
    
    case "${1:-help}" in
        build-image|build)
            build_image
            ;;
        shell|sh)
            enter_shell
            ;;
        make)
            shift
            run_make "$@"
            ;;
        compile|c)
            shift
            compile_component "$@"
            ;;
        init-submodules|submodules)
            init_submodules
            ;;
        apply-patches|patches)
            shift
            apply_patches "$@"
            ;;
        clean)
            clean_build
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            log_error "未知命令: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
