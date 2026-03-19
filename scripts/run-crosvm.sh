#!/bin/sh -e

# 可直接执行: ./scripts/run-crosvm.sh
# 如需覆盖默认路径，可设置环境变量: CROSVM=... IMAGE=... KERNEL=... SETUP_NET=1 ...
#
# VFIO 设备透传:
#   VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
#   VFIO_DEV=0000:01:00.0 VFIO_IOMMU=viommu ./scripts/run-crosvm.sh   # 使用虚拟 IOMMU（动态按需映射）
#   VFIO_DEV=0000:01:00.0 VFIO_IOMMU=coiommu ./scripts/run-crosvm.sh  # 使用 CoIOMMU（仅可信设备）

# 脚本所在目录的上一级为仓库根目录，用于默认路径
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$REPO_ROOT:$PATH"
export CROSVM="${CROSVM:-$REPO_ROOT/crosvm/target/debug/crosvm}"
export IMAGE="${IMAGE:-$REPO_ROOT/images/guest/ubuntuguest.qcow2}"
export KERNEL="${KERNEL:-$REPO_ROOT/images/guest/bzImage}"
export RAM="${RAM:-4096}"
export CORECOUNT="${CORECOUNT:-2}"
export SETUP_NET="${SETUP_NET:-0}"           # set to 0 to skip tap/iptables/sysctl changes
export PROTECTED="${PROTECTED:-1}"           # set to 0 to run a normal (non-protected) VM
export TAP_NAME="${TAP_NAME:-crosvm_tap}"
export TAP_ADDR="${TAP_ADDR:-192.168.8.1/24}"
export GUEST_ADDR="${GUEST_ADDR:-192.168.8.3}"
export TAP_USER="${TAP_USER:-${SUDO_USER:-${USER:-root}}}"
export HOST_DEV="${HOST_DEV:-}"
export IPTABLES_BIN="${IPTABLES_BIN:-iptables}"
export VFIO_DEV="${VFIO_DEV:-}"              # e.g. 0000:01:00.0 ; empty means no vfio passthrough
export VFIO_IOMMU="${VFIO_IOMMU:-}"          # iommu type for vfio device: viommu, coiommu, or empty (no virtual iommu, maps all guest ram)

[ ! -d /var/empty ] && mkdir /var/empty
[ "x$DEBUG" != "x" ] && DEBUG='--gdb 1234' && KERNEL=vmlinux && CORECOUNT=1

need_cmd() { command -v "$1" >/dev/null 2>&1; }
note() { echo "run-crosvm: $*" >&2; }
die() { note "ERROR: $*"; exit 1; }
get_route_dev() {
        ip -4 route get "$1" 2>/dev/null | awk '
                {
                        for (i = 1; i <= NF; i++) {
                                if ($i == "dev") {
                                        print $(i + 1)
                                        exit
                                }
                        }
                }'
}
has_direct_route() {
        route_line=$(ip -4 route get "$1" 2>/dev/null | awk 'NR == 1 { print; exit }')
        [ -n "$route_line" ] || return 1
        case "$route_line" in
                *" via "*) return 1 ;;
        esac
        route_dev=$(get_route_dev "$1")
        [ -n "$route_dev" ] && [ "x$route_dev" != "x$TAP_NAME" ]
}
iptables_run() {
        "$IPTABLES_BIN" -w "$@"
}

NET_OPT="tap-name=${TAP_NAME}"
VFIO_PATH=""
NET_CREATED_TAP=0
NET_CONFIGURED=0
NET_NAT_CHAIN=""
NET_FWD_CHAIN=""
ORIG_IP_FORWARD=""
IP_FORWARD_CHANGED=0
cleanup_net() {
        if [ -n "$NET_FWD_CHAIN" ]; then
                iptables_run -D FORWARD -j "$NET_FWD_CHAIN" 2>/dev/null || true
                iptables_run -F "$NET_FWD_CHAIN" 2>/dev/null || true
                iptables_run -X "$NET_FWD_CHAIN" 2>/dev/null || true
        fi

        if [ -n "$NET_NAT_CHAIN" ]; then
                iptables_run -t nat -D POSTROUTING -j "$NET_NAT_CHAIN" 2>/dev/null || true
                iptables_run -t nat -F "$NET_NAT_CHAIN" 2>/dev/null || true
                iptables_run -t nat -X "$NET_NAT_CHAIN" 2>/dev/null || true
        fi

        if [ "x$IP_FORWARD_CHANGED" = "x1" ] && [ -n "$ORIG_IP_FORWARD" ]; then
                sysctl -q -w "net.ipv4.ip_forward=${ORIG_IP_FORWARD}" >/dev/null 2>&1 || true
        fi

        if [ "x$NET_CREATED_TAP" = "x1" ]; then
                ip link delete "$TAP_NAME" 2>/dev/null || true
        fi
}
trap 'cleanup_net' EXIT INT TERM

if [ "x$SETUP_NET" = "x0" ]; then
        note "SETUP_NET=0: skipping tap/iptables/sysctl network setup; guest will have no network device"
        NET_OPT=""
fi

if [ -n "$VFIO_DEV" ]; then
        VFIO_PATH="/sys/bus/pci/devices/$VFIO_DEV"
        [ -e "$VFIO_PATH" ] || die "VFIO_DEV '$VFIO_DEV' not found at $VFIO_PATH"
        if [ -n "$VFIO_IOMMU" ]; then
                case "$VFIO_IOMMU" in
                        viommu|coiommu) ;;
                        *) die "VFIO_IOMMU must be 'viommu' or 'coiommu' (got '$VFIO_IOMMU')";;
                esac
                VFIO_PATH="${VFIO_PATH},iommu=${VFIO_IOMMU}"
                note "enabling VFIO passthrough: $VFIO_DEV (iommu=$VFIO_IOMMU)"
        else
                note "enabling VFIO passthrough: $VFIO_DEV (no virtual iommu, mapping all guest ram)"
        fi
fi

if [ "x$SETUP_NET" != "x0" ]; then
        need_cmd ip || die "'ip' not found (install iproute2, or run with SETUP_NET=0)"
        need_cmd sysctl || die "'sysctl' not found (install procps, or run with SETUP_NET=0)"
        need_cmd "$IPTABLES_BIN" || die "'$IPTABLES_BIN' not found (install iptables, or run with SETUP_NET=0)"
        [ "$(id -u)" -eq 0 ] || die "SETUP_NET=1 requires root privileges (run with sudo)"

        TAP_IP="${TAP_ADDR%/*}"
        [ "x$TAP_IP" != "x$TAP_ADDR" ] || die "TAP_ADDR must be in CIDR form, for example 192.168.8.1/24"

        # Guest images created by scripts/create-guestimg.sh currently assume
        # 192.168.8.3/24 with gateway 192.168.8.1. Refuse to hijack a local subnet.
        if has_direct_route "$TAP_IP" || has_direct_route "$GUEST_ADDR"; then
                die "guest subnet conflicts with an existing directly-connected host route; current guest defaults come from scripts/create-guestimg.sh and require TAP_ADDR/GUEST_ADDR to match"
        fi

        [ -n "$HOST_DEV" ] || HOST_DEV=$(get_route_dev 8.8.8.8)
        [ -n "$HOST_DEV" ] || die "failed to determine the host uplink interface; set HOST_DEV=..."
        [ "x$HOST_DEV" != "x$TAP_NAME" ] || die "HOST_DEV resolves to TAP_NAME ($TAP_NAME), refusing to create a NAT loop"

        if [ ! -d "/sys/class/net/${TAP_NAME}" ]; then
                ip tuntap add mode tap user "${TAP_USER}" vnet_hdr "${TAP_NAME}"
                NET_CREATED_TAP=1
        fi
        ip addr replace "${TAP_ADDR}" dev "${TAP_NAME}"
        ip link set "${TAP_NAME}" up

        CHAIN_TAG=$(printf '%s' "$TAP_NAME" | tr -c '[:alnum:]' '_')
        NET_NAT_CHAIN="CROSVM_${CHAIN_TAG}_NAT"
        NET_FWD_CHAIN="CROSVM_${CHAIN_TAG}_FWD"

        ORIG_IP_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
        sysctl -q -w net.ipv4.ip_forward=1 >/dev/null
        IP_FORWARD_CHANGED=1

        iptables_run -t nat -N "$NET_NAT_CHAIN" 2>/dev/null || true
        iptables_run -t nat -F "$NET_NAT_CHAIN"
        iptables_run -t nat -A "$NET_NAT_CHAIN" -s "${GUEST_ADDR}/32" -o "${HOST_DEV}" -j MASQUERADE
        iptables_run -t nat -C POSTROUTING -j "$NET_NAT_CHAIN" 2>/dev/null || \
                iptables_run -t nat -A POSTROUTING -j "$NET_NAT_CHAIN"

        iptables_run -N "$NET_FWD_CHAIN" 2>/dev/null || true
        iptables_run -F "$NET_FWD_CHAIN"
        iptables_run -A "$NET_FWD_CHAIN" -i "${HOST_DEV}" -o "${TAP_NAME}" -d "${GUEST_ADDR}/32" -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables_run -A "$NET_FWD_CHAIN" -i "${TAP_NAME}" -o "${HOST_DEV}" -s "${GUEST_ADDR}/32" -j ACCEPT
        iptables_run -C FORWARD -j "$NET_FWD_CHAIN" 2>/dev/null || \
                iptables_run -A FORWARD -j "$NET_FWD_CHAIN"

        NET_CONFIGURED=1
        note "network enabled: tap=${TAP_NAME} host=${TAP_ADDR} guest=${GUEST_ADDR} uplink=${HOST_DEV}"
fi

set -- "${CROSVM:-crosvm}" --log-level=debug run
[ "x$DEBUG" = "x" ] || set -- "$@" --gdb 1234
set -- "$@" "$KERNEL" --cpus "num-cores=$CORECOUNT" --mem "size=$RAM" --block "path=$IMAGE"
[ -z "$NET_OPT" ] || set -- "$@" --net "$NET_OPT"
set -- "$@" --disable-sandbox
[ -z "$VFIO_PATH" ] || set -- "$@" --vfio "$VFIO_PATH"
set -- "$@" --serial "type=stdout,hardware=virtio-console,console,stdin"
set -- "$@" --core-scheduling false -p "root=/dev/vda1 rw"
[ "x$PROTECTED" = "x0" ] || set -- "$@" --protected-vm-without-firmware

"$@"
exit "$?"
