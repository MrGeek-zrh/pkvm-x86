#!/usr/bin/env bash
set -Eeuo pipefail

# 用途:
#   自动化执行 BOOT-004 场景的跨重启复现流程：
#   1. 在当前系统中记录本次复现参数，并安装一个临时的 systemd one-shot 服务。
#   2. 重启后自动重新定位 NVMe 设备、绑定到 vfio-pci、启动非机密 crosvm VFIO 透传。
#   3. 在启动 crosvm 前清空并持续抓取 dmesg，同时保存 crosvm 控制台日志与结果摘要。
#
# 用法:
#   1) 跨重启自动复现（推荐）
#      sudo DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-004/auto-repro-boot004.sh prepare --bdf 0000:01:00.0 --reboot-now
#      sudo DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-004/auto-repro-boot004.sh prepare --serial NVME0 --reboot-now
#
#   2) 不跨重启，直接在当前系统执行一次
#      sudo DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-004/auto-repro-boot004.sh once --bdf 0000:01:00.0
#      sudo DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-004/auto-repro-boot004.sh manual --bdf 0000:01:00.0
#
#   3) 清理临时 systemd 服务与状态文件
#      sudo ./auto-repro-boot004.sh cleanup
#
# 产物:
#   日志会保存在本脚本所在目录下的 logs/<时间戳>/ 中，至少包含：
#     - dmesg.before-clear.log
#     - dmesg.live.log
#     - crosvm.log
#     - summary.log
#     - result.txt
#
# 说明:
#   - 当前脚本固定复现 BOOT-004 的非机密 VFIO 场景，因此默认使用 PROTECTED=0、SETUP_NET=0。
#   - 为了保证时间先后关系，脚本会先清空 dmesg，再启动 dmesg 跟随抓取，然后才重新配置 VFIO 并启动 crosvm。
#   - `manual` 子命令尽量贴近手工复现路径：默认不额外等待，不对 crosvm 设置 timeout，可选跳过 VFIO rebind。

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
STATE_DIR="$SCRIPT_DIR/.auto-repro-state"
STATE_FILE="$STATE_DIR/state.env"
LOG_ROOT="$SCRIPT_DIR/logs"
SERVICE_NAME="boot004-auto-repro.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
DEFAULT_SERIAL="NVME0"
DEFAULT_SETTLE_SECS=8
DEFAULT_DEVICE_TIMEOUT=60
DEFAULT_CROSVM_TIMEOUT=120
DEFAULT_MANUAL_SETTLE_SECS=0
DEFAULT_MANUAL_CROSVM_TIMEOUT=0

DMESG_FOLLOW_PID=""
RUN_LOG_DIR=""
SCRIPT_ACTION_LOG=""
COMMAND_MODE=""

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
    printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
    printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
用途:
  自动化执行 BOOT-004 场景的跨重启复现流程：
  1. 在当前系统中记录本次复现参数，并安装一个临时的 systemd one-shot 服务。
  2. 重启后自动重新定位 NVMe 设备、绑定到 vfio-pci、启动非机密 crosvm VFIO 透传。
  3. 在启动 crosvm 前清空并持续抓取 dmesg，同时保存 crosvm 控制台日志与结果摘要。

用法:
  1) 跨重启自动复现（推荐）
     sudo ./auto-repro-boot004.sh prepare --bdf 0000:01:00.0 --reboot-now
     sudo ./auto-repro-boot004.sh prepare --serial NVME0 --reboot-now

  2) 不跨重启，直接在当前系统执行一次
     sudo ./auto-repro-boot004.sh once --bdf 0000:01:00.0
     sudo ./auto-repro-boot004.sh manual --bdf 0000:01:00.0

  3) 可选参数
     --skip-vfio-rebind   如果设备已绑定到 vfio-pci，则跳过再次绑定
     --no-crosvm-timeout  不对 crosvm 施加 timeout（manual 模式默认）

  4) 清理临时 systemd 服务与状态文件
     sudo ./auto-repro-boot004.sh cleanup
USAGE
}

ensure_root() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        return 0
    fi
    exec sudo -E bash "$SCRIPT_PATH" "$@"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

normalize_bdf() {
    local raw="$1"
    raw="${raw#0000:}"
    printf '0000:%s\n' "$raw"
}

trim_spaces() {
    tr -d '[:space:]'
}

serial_from_bdf() {
    local bdf="$1"
    local serial_file

    serial_file="/sys/bus/pci/devices/$bdf/nvme/nvme*/serial"
    # shellcheck disable=SC2086
    for file in $serial_file; do
        [[ -f "$file" ]] || continue
        <"$file" trim_spaces
        return 0
    done
    return 1
}

find_bdf_by_serial() {
    local serial="$1"
    local file current devpath

    for file in /sys/class/nvme/nvme*/serial; do
        [[ -f "$file" ]] || continue
        current="$(<"$file" trim_spaces)"
        if [[ "$current" == "$serial" ]]; then
            devpath="$(readlink -f "$(dirname "$file")/device")"
            [[ -n "$devpath" ]] || continue
            basename "$devpath"
            return 0
        fi
    done
    return 1
}

wait_for_bdf() {
    local bdf="$1"
    local timeout="$2"
    local start now

    start="$(date +%s)"
    while true; do
        if [[ -e "/sys/bus/pci/devices/$bdf" ]]; then
            return 0
        fi
        now="$(date +%s)"
        if (( now - start >= timeout )); then
            return 1
        fi
        sleep 1
    done
}

resolve_bdf() {
    local preferred_bdf="$1"
    local nvme_serial="$2"
    local bdf

    if [[ -n "$preferred_bdf" ]]; then
        bdf="$(normalize_bdf "$preferred_bdf")"
        if wait_for_bdf "$bdf" "$DEVICE_TIMEOUT"; then
            printf '%s\n' "$bdf"
            return 0
        fi
        warn "指定的 BDF $bdf 在超时时间内未出现，尝试通过 serial 重新定位"
    fi

    if [[ -n "$nvme_serial" ]]; then
        local start now candidate
        start="$(date +%s)"
        while true; do
            if candidate="$(find_bdf_by_serial "$nvme_serial" 2>/dev/null)"; then
                printf '%s\n' "$(normalize_bdf "$candidate")"
                return 0
            fi
            now="$(date +%s)"
            if (( now - start >= DEVICE_TIMEOUT )); then
                break
            fi
            sleep 1
        done
    fi

    return 1
}

setup_vfio_binding() {
    local bdf="$1"
    local devpath="/sys/bus/pci/devices/$bdf"
    local current_driver=""

    [[ -e "$devpath" ]] || die "设备不存在: $devpath"

    modprobe vfio-pci

    if [[ -L "$devpath/driver" ]]; then
        current_driver="$(basename "$(readlink -f "$devpath/driver")")"
    fi

    if [[ "$SKIP_VFIO_REBIND" == "1" && "$current_driver" == "vfio-pci" ]]; then
        log "设备 $bdf 已绑定 vfio-pci，按请求跳过 rebind"
        return 0
    fi

    printf 'vfio-pci\n' > "$devpath/driver_override"

    if [[ -n "$current_driver" && "$current_driver" != "vfio-pci" ]]; then
        printf '%s\n' "$bdf" > "$devpath/driver/unbind"
    fi

    if [[ ! -L "$devpath/driver" || "$(basename "$(readlink -f "$devpath/driver")")" != "vfio-pci" ]]; then
        printf '%s\n' "$bdf" > /sys/bus/pci/drivers/vfio-pci/bind
    fi
}

capture_manual_context() {
    local bdf="$1"
    local short_bdf="${bdf#0000:}"
    local serial=""
    local devpath=""

    lspci -nn | grep -E 'Non-Volatile|NVMe' > "$RUN_LOG_DIR/nvme.lspci.txt" 2>&1 || true
    serial="$(serial_from_bdf "$bdf" 2>/dev/null || true)"
    printf '%s\n' "$serial" > "$RUN_LOG_DIR/nvme.serial.txt"
    devpath="$(readlink -f "/sys/bus/pci/devices/$bdf" 2>/dev/null || true)"
    printf '%s\n' "$devpath" > "$RUN_LOG_DIR/nvme.device-path.txt"
    lspci -nnk -s "$short_bdf" > "$RUN_LOG_DIR/lspci.before-vfio.txt" 2>&1 || true
}

start_dmesg_capture() {
    local out="$1"
    stdbuf -oL -eL dmesg -wT > "$out" 2>&1 &
    DMESG_FOLLOW_PID=$!
    sleep 1
}

stop_dmesg_capture() {
    if [[ -n "$DMESG_FOLLOW_PID" ]] && kill -0 "$DMESG_FOLLOW_PID" 2>/dev/null; then
        kill "$DMESG_FOLLOW_PID" 2>/dev/null || true
        wait "$DMESG_FOLLOW_PID" 2>/dev/null || true
    fi
    DMESG_FOLLOW_PID=""
}

cleanup_runtime() {
    stop_dmesg_capture
    sync || true
}

cleanup_service() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "$SERVICE_FILE"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

write_state() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<STATE
REPO_ROOT=$(printf '%q' "$REPO_ROOT")
SCRIPT_PATH=$(printf '%q' "$SCRIPT_PATH")
PREFERRED_BDF=$(printf '%q' "$PREFERRED_BDF")
NVME_SERIAL=$(printf '%q' "$NVME_SERIAL")
SETTLE_SECS=$(printf '%q' "$SETTLE_SECS")
DEVICE_TIMEOUT=$(printf '%q' "$DEVICE_TIMEOUT")
CROSVM_TIMEOUT=$(printf '%q' "$CROSVM_TIMEOUT")
KERNEL_OVERRIDE=$(printf '%q' "$KERNEL_OVERRIDE")
IMAGE_OVERRIDE=$(printf '%q' "$IMAGE_OVERRIDE")
CROSVM_OVERRIDE=$(printf '%q' "$CROSVM_OVERRIDE")
RUN_ID=$(printf '%q' "$RUN_ID")
STATE
}

load_state() {
    [[ -f "$STATE_FILE" ]] || die "状态文件不存在: $STATE_FILE"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

install_service() {
    mkdir -p /etc/systemd/system
    cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=BOOT-004 auto repro after reboot
After=local-fs.target multi-user.target
Wants=multi-user.target
ConditionPathExists=$STATE_FILE

[Service]
Type=oneshot
WorkingDirectory=$REPO_ROOT
ExecStart=/bin/bash $SCRIPT_PATH postboot
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
}

parse_common_options() {
    PREFERRED_BDF=""
    NVME_SERIAL="$DEFAULT_SERIAL"
    if [[ "$COMMAND_MODE" == "manual" ]]; then
        SETTLE_SECS="$DEFAULT_MANUAL_SETTLE_SECS"
        CROSVM_TIMEOUT="$DEFAULT_MANUAL_CROSVM_TIMEOUT"
    else
        SETTLE_SECS="$DEFAULT_SETTLE_SECS"
        CROSVM_TIMEOUT="$DEFAULT_CROSVM_TIMEOUT"
    fi
    DEVICE_TIMEOUT="$DEFAULT_DEVICE_TIMEOUT"
    KERNEL_OVERRIDE=""
    IMAGE_OVERRIDE=""
    CROSVM_OVERRIDE=""
    SKIP_VFIO_REBIND=0
    REBOOT_NOW=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bdf)
                PREFERRED_BDF="$(normalize_bdf "${2:-}")"
                shift 2
                ;;
            --serial)
                NVME_SERIAL="${2:-}"
                shift 2
                ;;
            --settle-secs)
                SETTLE_SECS="${2:-}"
                shift 2
                ;;
            --device-timeout)
                DEVICE_TIMEOUT="${2:-}"
                shift 2
                ;;
            --crosvm-timeout)
                CROSVM_TIMEOUT="${2:-}"
                shift 2
                ;;
            --no-crosvm-timeout)
                CROSVM_TIMEOUT=0
                shift
                ;;
            --kernel)
                KERNEL_OVERRIDE="${2:-}"
                shift 2
                ;;
            --image)
                IMAGE_OVERRIDE="${2:-}"
                shift 2
                ;;
            --crosvm)
                CROSVM_OVERRIDE="${2:-}"
                shift 2
                ;;
            --skip-vfio-rebind)
                SKIP_VFIO_REBIND=1
                shift
                ;;
            --reboot-now)
                REBOOT_NOW=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数: $1"
                ;;
        esac
    done
}

prepare_log_dir() {
    mkdir -p "$LOG_ROOT"
    RUN_LOG_DIR="$LOG_ROOT/$RUN_ID"
    mkdir -p "$RUN_LOG_DIR"
    SCRIPT_ACTION_LOG="$RUN_LOG_DIR/script.log"
    exec > >(stdbuf -oL -eL tee -a "$SCRIPT_ACTION_LOG") 2>&1
}

collect_summary() {
    local summary_file="$RUN_LOG_DIR/summary.log"
    local result_file="$RUN_LOG_DIR/result.txt"
    local result="unknown"

    {
        echo '=== dmesg keywords ==='
        grep -nE 'pkvm-debug|host_initiate_donation|do_donate|exception 6|soft lockup|vfio|tube was disconnected|Broken pipe' "$RUN_LOG_DIR/dmesg.live.log" || true
        echo
        echo '=== crosvm keywords ==='
        grep -nE 'vfio|tube was disconnected|Broken pipe|child .* exited|failed to enable ACPI notifications' "$RUN_LOG_DIR/crosvm.log" || true
    } > "$summary_file"

    if grep -qE 'host_initiate_donation: page refcounted|exception 6|soft lockup' "$RUN_LOG_DIR/dmesg.live.log"; then
        result="pkvm_panic"
    elif grep -qE 'failed to enable ACPI notifications|tube was disconnected|child .* exited' "$RUN_LOG_DIR/crosvm.log"; then
        result="crosvm_vfio_early_fail"
    fi

    {
        echo "RESULT=$result"
        echo "LOG_DIR=$RUN_LOG_DIR"
    } > "$result_file"
}

run_repro_sequence() {
    local resolved_bdf short_bdf
    local crosvm_script="$REPO_ROOT/scripts/run-crosvm.sh"
    local crosvm_rc=0

    require_cmd dmesg
    require_cmd lspci
    require_cmd modprobe
    [[ -x "$crosvm_script" ]] || die "找不到可执行脚本: $crosvm_script"
    if [[ "$CROSVM_TIMEOUT" != "0" ]]; then
        require_cmd timeout
    fi

    mkdir -p "$RUN_LOG_DIR"
    trap cleanup_runtime EXIT INT TERM

    log "保存清空前的 dmesg 到 $RUN_LOG_DIR/dmesg.before-clear.log"
    dmesg -T > "$RUN_LOG_DIR/dmesg.before-clear.log" 2>&1 || true

    log "清空 dmesg 并启动实时抓取"
    dmesg -CT || true
    start_dmesg_capture "$RUN_LOG_DIR/dmesg.live.log"

    log "等待系统与设备稳定 ${SETTLE_SECS}s"
    udevadm settle >/dev/null 2>&1 || true
    sleep "$SETTLE_SECS"

    resolved_bdf="$(resolve_bdf "$PREFERRED_BDF" "$NVME_SERIAL")" || die "无法定位目标 NVMe 设备 (BDF='${PREFERRED_BDF:-}', serial='${NVME_SERIAL:-}')"
    short_bdf="${resolved_bdf#0000:}"
    log "本次使用的 BDF: $resolved_bdf"
    printf 'BDF=%s\nSERIAL=%s\n' "$resolved_bdf" "$NVME_SERIAL" > "$RUN_LOG_DIR/device.txt"

    capture_manual_context "$resolved_bdf"
    if [[ "$SKIP_VFIO_REBIND" == "1" ]]; then
        log "按请求尝试跳过 VFIO rebind"
    else
        log "重新绑定 $resolved_bdf 到 vfio-pci"
    fi
    setup_vfio_binding "$resolved_bdf"
    lspci -nnk -s "$short_bdf" > "$RUN_LOG_DIR/lspci.after-vfio.txt" 2>&1 || true

    log "启动 crosvm，并抓取控制台日志"
    (
        cd "$REPO_ROOT"
        if [[ -n "$KERNEL_OVERRIDE" ]]; then
            export KERNEL="$KERNEL_OVERRIDE"
        fi
        if [[ -n "$IMAGE_OVERRIDE" ]]; then
            export IMAGE="$IMAGE_OVERRIDE"
        fi
        if [[ -n "$CROSVM_OVERRIDE" ]]; then
            export CROSVM="$CROSVM_OVERRIDE"
        fi
        export PROTECTED=0
        export SETUP_NET=0
        export VFIO_DEV="$resolved_bdf"
        if [[ "$CROSVM_TIMEOUT" == "0" ]]; then
            stdbuf -oL -eL -i0 "$crosvm_script"
        else
            timeout --preserve-status "${CROSVM_TIMEOUT}s" stdbuf -oL -eL -i0 "$crosvm_script"
        fi
    ) > >(stdbuf -oL -eL tee -a "$RUN_LOG_DIR/crosvm.log") 2>&1 || crosvm_rc=$?
    log "crosvm 退出码: $crosvm_rc"

    sleep 3
    stop_dmesg_capture
    collect_summary
    log "日志目录: $RUN_LOG_DIR"
}

cmd_prepare() {
    COMMAND_MODE="prepare"
    ensure_root prepare "$@"
    parse_common_options "$@"

    require_cmd systemctl
    require_cmd readlink

    if [[ -n "$PREFERRED_BDF" && -z "$NVME_SERIAL" ]]; then
        NVME_SERIAL="$(serial_from_bdf "$PREFERRED_BDF" 2>/dev/null || true)"
    fi

    RUN_ID="$(date '+%Y%m%d-%H%M%S')"
    write_state
    install_service

    log "已写入状态文件: $STATE_FILE"
    log "已安装临时服务: $SERVICE_NAME"
    if [[ $REBOOT_NOW -eq 1 ]]; then
        log "现在执行重启，重启后将自动继续复现"
        systemctl reboot
    else
        log "请手动执行 reboot；重启后会自动继续复现"
    fi
}

cmd_postboot() {
    COMMAND_MODE="postboot"
    ensure_root postboot "$@"
    load_state
    RUN_LOG_DIR="$LOG_ROOT/$RUN_ID"
    prepare_log_dir
    log "开始执行 postboot 自动复现"
    cleanup_service
    run_repro_sequence
}

cmd_once() {
    COMMAND_MODE="once"
    ensure_root once "$@"
    parse_common_options "$@"
    RUN_ID="manual-$(date '+%Y%m%d-%H%M%S')"
    RUN_LOG_DIR="$LOG_ROOT/$RUN_ID"
    prepare_log_dir
    log "开始执行一次性复现（不跨重启）"
    run_repro_sequence
}

cmd_manual() {
    COMMAND_MODE="manual"
    ensure_root manual "$@"
    parse_common_options "$@"
    RUN_ID="manual-like-$(date '+%Y%m%d-%H%M%S')"
    RUN_LOG_DIR="$LOG_ROOT/$RUN_ID"
    prepare_log_dir
    log "开始执行手工等效复现（不跨重启）"
    run_repro_sequence
}

cmd_cleanup() {
    ensure_root cleanup "$@"
    cleanup_service
    rm -rf "$STATE_DIR"
    log "已清理临时服务与状态文件"
}

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        prepare)
            cmd_prepare "$@"
            ;;
        postboot)
            cmd_postboot "$@"
            ;;
        once)
            cmd_once "$@"
            ;;
        manual)
            cmd_manual "$@"
            ;;
        cleanup)
            cmd_cleanup "$@"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage
            die "未知子命令: $cmd"
            ;;
    esac
}

main "$@"
