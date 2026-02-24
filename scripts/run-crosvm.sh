#!/bin/sh -e

# 可直接执行: ./scripts/run-crosvm.sh
# 如需覆盖默认路径，可设置环境变量: CROSVM=... IMAGE=... KERNEL=... SETUP_NET=1 ...

# 脚本所在目录的上一级为仓库根目录，用于默认路径
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$REPO_ROOT:$PATH"
export CROSVM="${CROSVM:-$REPO_ROOT/crosvm/target/debug/crosvm}"
export IMAGE="${IMAGE:-$REPO_ROOT/images/guest/ubuntuguest.qcow2}"
export KERNEL="${KERNEL:-$REPO_ROOT/images/guest/bzImage}"
export RAM=4096
export CORECOUNT=2
export SETUP_NET="${SETUP_NET:-0}"           # set to 0 to skip tap/iptables/sysctl changes
export PROTECTED="${PROTECTED:-1}"           # set to 0 to run a normal (non-protected) VM
export TAP_NAME="${TAP_NAME:-crosvm_tap}"
export TAP_ADDR="${TAP_ADDR:-192.168.8.1/24}"
export VFIO_DEV="${VFIO_DEV:-}"              # e.g. 0000:01:00.0 ; empty means no vfio passthrough

[ ! -d /var/empty ] && mkdir /var/empty
[ "x$DEBUG" != "x" ] && DEBUG='--gdb 1234' && KERNEL=vmlinux && CORECOUNT=1

need_cmd() { command -v "$1" >/dev/null 2>&1; }
note() { echo "run-crosvm: $*" >&2; }
die() { note "ERROR: $*"; exit 1; }

NET_OPT="--net tap-name=${TAP_NAME}"
if [ "x$SETUP_NET" = "x0" ]; then
        note "SETUP_NET=0: skipping tap/iptables/sysctl network setup; guest will have no network device"
        NET_OPT=""
fi

VFIO_OPT=""
if [ -n "$VFIO_DEV" ]; then
        VFIO_PATH="/sys/bus/pci/devices/$VFIO_DEV"
        [ -e "$VFIO_PATH" ] || die "VFIO_DEV '$VFIO_DEV' not found at $VFIO_PATH"
        VFIO_OPT="--vfio ${VFIO_PATH}"
        note "enabling VFIO passthrough: $VFIO_DEV"
fi

if [ "x$SETUP_NET" != "x0" ] && [ ! -d "/sys/class/net/${TAP_NAME}" ]; then
        need_cmd ip || die "'ip' not found (install iproute2, or run with SETUP_NET=0)"
        need_cmd sysctl || die "'sysctl' not found (install procps, or run with SETUP_NET=0)"
        need_cmd iptables || die "'iptables' not found (install iptables, or run with SETUP_NET=0)"

        ip tuntap add mode tap user "${USER:-root}" vnet_hdr "${TAP_NAME}"
        ip addr add "${TAP_ADDR}" dev "${TAP_NAME}"
        ip link set "${TAP_NAME}" up

        sysctl net.ipv4.ip_forward=1
        # Network interface used to connect to the internet.
        HOST_DEV=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
        # Keep these rules idempotent to avoid stacking duplicates.
        iptables -t nat -C POSTROUTING -o "${HOST_DEV}" -j MASQUERADE 2>/dev/null || \
                iptables -t nat -A POSTROUTING -o "${HOST_DEV}" -j MASQUERADE
        iptables -C FORWARD -i "${HOST_DEV}" -o "${TAP_NAME}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
                iptables -A FORWARD -i "${HOST_DEV}" -o "${TAP_NAME}" -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -C FORWARD -i "${TAP_NAME}" -o "${HOST_DEV}" -j ACCEPT 2>/dev/null || \
                iptables -A FORWARD -i "${TAP_NAME}" -o "${HOST_DEV}" -j ACCEPT
fi

${CROSVM:-crosvm} --log-level=debug run $DEBUG $KERNEL --cpus num-cores=$CORECOUNT		\
	--mem size=$RAM --block path=$IMAGE $NET_OPT	\
	$VFIO_OPT \
	--serial type=stdout,hardware=virtio-console,console,stdin		\
	--core-scheduling false \
	-p "root=/dev/vda1 rw" \
	$( [ "x$PROTECTED" = "x0" ] && echo "" || echo "--protected-vm-without-firmware" )
