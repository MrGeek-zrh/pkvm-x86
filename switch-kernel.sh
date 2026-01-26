#!/bin/bash

# Check if the script is run as root
if [ "$(id -u)" -ne "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Define the directory where the kernel images are stored
KERNEL_DIR="/boot"

# Check if we're in a linux source directory and find compiled kernels
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR=""
COMPILED_KERNELS=()

# Try to find linux directory (current dir or parent)
if [ -d "arch/x86_64/boot" ] || [ -d "arch/x86/boot" ]; then
    LINUX_DIR="$(pwd)"
elif [ -d "$SCRIPT_DIR/linux/arch/x86_64/boot" ] || [ -d "$SCRIPT_DIR/linux/arch/x86/boot" ]; then
    LINUX_DIR="$SCRIPT_DIR/linux"
fi

# Find compiled bzImage files and get kernel version
if [ -n "$LINUX_DIR" ] && [ -f "$LINUX_DIR/Makefile" ]; then
    # Check for compiled bzImage
    BZIMAGE=""
    if [ -f "$LINUX_DIR/arch/x86_64/boot/bzImage" ]; then
        BZIMAGE="$LINUX_DIR/arch/x86_64/boot/bzImage"
    elif [ -f "$LINUX_DIR/arch/x86/boot/bzImage" ]; then
        BZIMAGE="$LINUX_DIR/arch/x86/boot/bzImage"
    fi
    
    if [ -n "$BZIMAGE" ]; then
        # Get kernel version from Makefile
        VERSION=$(grep "^VERSION\s*=" "$LINUX_DIR/Makefile" 2>/dev/null | head -1 | awk '{print $NF}')
        PATCHLEVEL=$(grep "^PATCHLEVEL\s*=" "$LINUX_DIR/Makefile" 2>/dev/null | head -1 | awk '{print $NF}')
        SUBLEVEL=$(grep "^SUBLEVEL\s*=" "$LINUX_DIR/Makefile" 2>/dev/null | head -1 | awk '{print $NF}')
        EXTRAVERSION=$(grep "^EXTRAVERSION\s*=" "$LINUX_DIR/Makefile" 2>/dev/null | head -1 | awk '{print $NF}' | sed 's/^-//')
        
        if [ -n "$VERSION" ] && [ -n "$PATCHLEVEL" ] && [ -n "$SUBLEVEL" ]; then
            KVER_STR="${VERSION}.${PATCHLEVEL}.${SUBLEVEL}"
            if [ -n "$EXTRAVERSION" ]; then
                KVER_STR="${KVER_STR}${EXTRAVERSION}"
            fi
            
            # Get LOCALVERSION from .config if exists
            if [ -f "$LINUX_DIR/.config" ]; then
                LOCALVER=$(grep "^CONFIG_LOCALVERSION=" "$LINUX_DIR/.config" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
                if [ -n "$LOCALVER" ]; then
                    KVER_STR="${KVER_STR}${LOCALVER}"
                fi
            fi
            
            COMPILED_KERNELS+=("$KVER_STR")
        fi
    fi
fi

# List available kernel versions from /boot
echo "已安装的内核版本（在 /boot 目录）:"
INSTALLED_KERNELS=()
if ls $KERNEL_DIR/vmlinuz-* 1> /dev/null 2>&1; then
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            INSTALLED_KERNELS+=("$line")
            echo "  - $line"
        fi
    done < <(ls $KERNEL_DIR/vmlinuz-* 2>/dev/null | awk -F/ '{print $NF}' | sed 's/vmlinuz-//' | sort -V)
else
    echo "  (未找到已安装的内核)"
fi

# Show compiled but not installed kernels
if [ ${#COMPILED_KERNELS[@]} -gt 0 ]; then
    echo ""
    echo "已编译但未安装的内核（需要先执行 make install）:"
    for kver in "${COMPILED_KERNELS[@]}"; do
        if [[ ! " ${INSTALLED_KERNELS[@]} " =~ " ${kver} " ]]; then
            echo "  - $kver (在 $LINUX_DIR)"
        fi
    done
fi

echo ""

# Prompt the user to select a kernel version
read -p "Enter the kernel version you want to switch to: " kernel_version

# Check if the selected kernel version exists
if [ ! -e "$KERNEL_DIR/vmlinuz-$kernel_version" ]; then
    echo "Kernel version $kernel_version does not exist"
    exit 1
fi

MID=$(grep -F "submenu 'Advanced options for Ubuntu'" /boot/grub/grub.cfg | head -1 | awk '{print $(NF-1)}' | tr -d "'")
if [ -z "$MID" ]; then
    echo "无法找到 GRUB 高级菜单 ID" 1>&2
    exit 1
fi

KID=$(grep -F "menuentry 'Ubuntu, with Linux $kernel_version' " /boot/grub/grub.cfg | grep -v recovery | head -1 | awk '{print $(NF-1)}' | tr -d "'")
if [ -z "$KID" ]; then
    echo "无法找到与 $kernel_version 对应的 GRUB 菜单 ID" 1>&2
    exit 1
fi

# update-grub

sed -i -E "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$MID>$KID\"|" /etc/default/grub


if [ $kernel_version = "5.15.19-htmm" ];then
    sed -i '/^[^#].*memmap/ s/^/#/' /etc/default/grub   
else
    sed -i '/^#.*memmap/ s/^#//' /etc/default/grub
fi


update-grub

# Update saved_entry in grubenv to match GRUB_DEFAULT
# This ensures the saved entry matches the kernel we want to boot
saved_entry_text=$(grep -F "menuentry 'Ubuntu, with Linux $kernel_version' " /boot/grub/grub.cfg | grep -v recovery | head -1 | sed -E "s/.*menuentry '([^']*)'.*/\1/")
if [ -n "$saved_entry_text" ]; then
    grub-editenv - set "saved_entry=$saved_entry_text"
    echo "Updated saved_entry to: $saved_entry_text"
else
    echo "Warning: Could not find saved_entry for kernel $kernel_version"
fi

echo -e "\e[31mPlease reboot machine\e[0m"
