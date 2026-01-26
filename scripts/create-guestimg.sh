#!/usr/bin/env -S bash -e

SCRIPT_NAME=$(realpath "$0")
SCRIPT_DIR=$(dirname "${SCRIPT_NAME}")

# shellcheck disable=SC1090
. "${SCRIPT_DIR}/${SYSROOT_JAIL:-chroot}-utils.sh"

# Check required env variables
[ ! -d "$BASE_DIR" ] && sysroot_exit_error 1 "BASE_DIR does not exist"
[ -z "$UBUNTU_BASE" ] && sysroot_exit_error 1 "UBUNTU_BASE is not set"
[ -z "$UBUNTU_PKGLIST" ] && sysroot_exit_error 1 "UBUNTU_PKGLIST is not set"

PKGLIST=$(grep -v "\-dev" < "$UBUNTU_PKGLIST" |tr '\n' ' ' )
EXTRA_PKGLIST=
HOSTBUILD=0

USERNAME=$1
GROUPNAME=$2
if [ "x$EFI" = "x1" ]; then
OUTFILE=ubuntuguest-efi.qcow2
else
OUTFILE=ubuntuguest.qcow2
fi
OUTDIR=$BASE_DIR/images/guest
SIZE=10G

# 缓存目录 - 避免每次都重新下载和安装软件包
SYSROOT_CACHE_DIR="$BASE_DIR/build/sysroot-cache-guest"
SYSROOT_CACHE_MARKER="$SYSROOT_CACHE_DIR/.cache-ready"
# 设置 USE_CACHE=0 可以强制重建缓存
USE_CACHE=${USE_CACHE:-1}

do_cleanup()
{
	echo "${FUNCNAME[0]}: enter"

	sysroot_unmount_all "$TEMP_SYSROOT_DIR"

	if [ -f "$OUTDIR/$OUTFILE" ]; then
		sudo chown "$USERNAME:$GROUPNAME" "$OUTDIR/$OUTFILE"
	fi

	sudo rm -rf "$TEMP_SYSROOT_DIR"
}

usage() {
	echo "$0 -k <guest_kernel> -o <output directory> -s <image size> -u <ubuntu_base> -p <pkglist>"
	echo ""
	echo "环境变量:"
	echo "  USE_CACHE=0  强制重建 sysroot 缓存"
}

while getopts "h?u:o:s:k:" opt; do
	case "$opt" in
	h|\?)	usage
		exit 0
		;;
	u)	UBUNTU_BASE=$UBUNTU_UNSTABLE
		;;
	o)	OUTDIR=$OPTARG
		;;
	s)	SIZE=$OPTARG
		;;
	k)	GUEST_KERNEL=$OPTARG
		;;
  esac
done

[ ! -d "$GUEST_KERNEL" ] && sysroot_exit_error 1 "GUEST_KERNEL directory does not exist"

# Create sysroot dir
TEMP_SYSROOT_DIR=$(mktemp -d --tmpdir="$(pwd)/build")
export TEMP_SYSROOT_DIR
[ ! -d "$TEMP_SYSROOT_DIR" ] && sysroot_exit_error 1 "Tempdir $TEMP_SYSROOT_DIR creation failed"

trap do_cleanup SIGHUP SIGINT SIGTERM EXIT

PACKAGES="$PKGLIST $EXTRA_PKGLIST"

# 检查是否可以使用缓存
if [ "$USE_CACHE" = "1" ] && [ -f "$SYSROOT_CACHE_MARKER" ]; then
	echo "=========================================="
	echo "使用缓存的 sysroot: $SYSROOT_CACHE_DIR"
	echo "（设置 USE_CACHE=0 可强制重建）"
	echo "=========================================="
	echo "Copying cached sysroot..."
	sudo rsync -aWPHq --numeric-ids "$SYSROOT_CACHE_DIR/" "$TEMP_SYSROOT_DIR/"
else
	echo "=========================================="
	echo "Creating sysroot (首次构建或缓存不存在)"
	echo "=========================================="
	sysroot_create "$BASE_DIR" "$TEMP_SYSROOT_DIR" "$UBUNTU_BASE" "$PACKAGES"

	echo "Configuring sysroot"
	sysroot_run_commands "$TEMP_SYSROOT_DIR" "
		set -ex
		update-alternatives --set iptables /usr/sbin/iptables-legacy
		adduser --disabled-password --gecos \"\" ubuntu
		passwd -d ubuntu
		usermod -aG sudo ubuntu

		mkdir -p /etc/systemd/network
		cat << EOF >> /etc/systemd/network/99-wildcard.network
[Match]
Name=enp0*

[Network]
DHCP=no
Gateway=192.168.8.1
Address=192.168.8.3/24
EOF
		systemctl enable systemd-networkd
		sed 's/#DNS=/DNS=8.8.8.8/' -i /etc/systemd/resolved.conf
		sed 's/#PermitEmptyPasswords no/PermitEmptyPasswords yes/' -i /etc/ssh/sshd_config
		"

	# 保存到缓存（不包含内核模块，因为内核可能会变）
	echo "=========================================="
	echo "保存 sysroot 缓存到: $SYSROOT_CACHE_DIR"
	echo "=========================================="
	sysroot_unmount_all "$TEMP_SYSROOT_DIR"
	sudo rm -rf "$SYSROOT_CACHE_DIR"
	sudo mkdir -p "$SYSROOT_CACHE_DIR"
	sudo rsync -aWPHq --numeric-ids "$TEMP_SYSROOT_DIR/" "$SYSROOT_CACHE_DIR/"
	sudo touch "$SYSROOT_CACHE_MARKER"

	echo "Sysroot 缓存已创建，下次运行将直接使用缓存"
fi

# 挂载必要的目录用于安装内核模块
sysroot_mount_all "$BASE_DIR" "$TEMP_SYSROOT_DIR"

echo "Installing kernel modules"
sudo make -C"$GUEST_KERNEL" INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$TEMP_SYSROOT_DIR" -j"$(nproc)" modules_install

sysroot_unmount_all "$TEMP_SYSROOT_DIR"
sync

echo "Create image file"
sysroot_create_image_file "$TEMP_SYSROOT_DIR" "$OUTFILE" "$SIZE"

if [ ! -d "$OUTDIR" ]; then
	mkdir -p "$OUTDIR"
fi

# 复制 guest 内核镜像（与 modules_install 的内核目录保持一致）
cp -f "$GUEST_KERNEL/arch/x86_64/boot/bzImage" "$OUTDIR"
mv "$OUTFILE" "$OUTDIR"
echo "Output saved at $OUTDIR"
