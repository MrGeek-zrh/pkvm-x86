#!/usr/bin/env -S bash -e

[ ! -d "$BASE_DIR" ] && sysroot_exit_error 1 "BASE_DIR does not exist"

copy_kernel()
{
	[ ! -d "$BASE_DIR/build/linux" ] && mkdir -p "$BASE_DIR/build/linux"
	rsync -aWt --filter=":- .gitignore" --no-compress "$BASE_DIR/linux" "$BASE_DIR/build/"
}

install_defconfigs()
{
	# Guest kernel build happens from $BASE_DIR/build/linux, so we must
	# provide the defconfig targets under arch/x86/configs/.
	#
	# The project keeps these defconfigs in $BASE_DIR/scripts/.
	mkdir -p "$BASE_DIR/build/linux/arch/x86/configs"
	cp -f "$BASE_DIR/scripts/nixos_"*defconfig "$BASE_DIR/build/linux/arch/x86/configs/"
}

copy_kernel
install_defconfigs

cd "$BASE_DIR/build/linux"
make CC="$CC" -j$(nproc) nixos_guest_defconfig bzImage modules
