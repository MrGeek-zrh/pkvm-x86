#!/usr/bin/env bash
# 修复虚拟机grub菜单，启用启动菜单或修改默认启动项
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="ubuntu-24.04-custom.qcow2"
SSH_HOST="${SSH_HOST:-localhost}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-mrgeek}"
SSH_PASS="${SSH_PASS:-111}"

if [ ! -f "$IMAGE_NAME" ]; then
    echo "错误: 镜像文件 $IMAGE_NAME 不存在"
    exit 1
fi

ensure_grub_kv() {
    # Ensure /etc/default/grub has KEY=VALUE (replace if exists, append otherwise).
    local file="$1"
    local key="$2"
    local value="$3"
    if sudo grep -qE "^${key}=" "$file" 2>/dev/null; then
        sudo sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" | sudo tee -a "$file" >/dev/null
    fi
}

enable_serial_grub() {
    # With -nographic, GRUB menu is only usable if GRUB outputs to serial.
    local file="$1"
    ensure_grub_kv "$file" "GRUB_TERMINAL" "\"serial console\""
    ensure_grub_kv "$file" "GRUB_SERIAL_COMMAND" "\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\""

    # Ensure kernel messages also go to the same serial.
    if sudo grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' "$file" 2>/dev/null; then
        # If a previous buggy sed wrote a literal "\1" into the file, clean it up.
        # Example bad line: GRUB_CMDLINE_LINUX_DEFAULT="\1 console=ttyS0,115200n8"
        sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\\1[[:space:]]*/GRUB_CMDLINE_LINUX_DEFAULT="/' "$file" 2>/dev/null || true

        if ! sudo grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=.*console=ttyS0,115200n8' "$file" 2>/dev/null; then
            # Append console=... to the existing quoted value.
            # NOTE: keep "\1" (sed backref) unescaped, otherwise it becomes literal "\1" in the file.
            sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 console=ttyS0,115200n8"/' "$file" || true
        fi
    else
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8"' | sudo tee -a "$file" >/dev/null
    fi
}

patch_grub_cfg_file() {
    # Emergency patch for generated grub.cfg (works even if update-grub can't run).
    # This is intentionally minimal; it's OK to edit grub.cfg for recovery.
    local cfg="$1"
    local timeout_style="$2"
    local timeout="$3"
    local enable_serial="$4"

    if [ ! -f "$cfg" ]; then
        return 0
    fi

    # grub.cfg often contains conditional logic (eg recordfail) that can override earlier
    # "set timeout=...". To make this reliable, inject an unconditional override block
    # right before the first menuentry/submenu, and replace it on re-runs.
    if ! command -v python3 >/dev/null 2>&1; then
        echo "⚠️  未找到 python3，无法可靠修补 grub.cfg：$cfg"
        return 0
    fi

    sudo python3 - "$cfg" "$timeout_style" "$timeout" "$enable_serial" <<'PY'
import re
import sys

path, timeout_style, timeout, enable_serial = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
enable_serial = enable_serial == "1"

BEGIN = "### BEGIN PKVM GRUB FIX ###"
END = "### END PKVM GRUB FIX ###"

try:
    raw = open(path, "r", encoding="utf-8", errors="ignore").read().splitlines()
except Exception as e:
    print(f"error reading {path}: {e}")
    sys.exit(0)

# Drop previous injected block if present.
lines = []
i = 0
while i < len(raw):
    if raw[i].strip() == BEGIN:
        i += 1
        while i < len(raw) and raw[i].strip() != END:
            i += 1
        if i < len(raw) and raw[i].strip() == END:
            i += 1
        continue
    lines.append(raw[i])
    i += 1

block = [BEGIN]
if enable_serial:
    block += [
        "insmod serial",
        "insmod terminal",
        "serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1",
        "terminal_input serial console",
        "terminal_output serial console",
    ]
block += [
    f"set timeout_style={timeout_style}",
    f"set timeout={timeout}",
    END,
    "",
]

ins = len(lines)
for idx, line in enumerate(lines):
    if re.match(r"^\\s*(menuentry|submenu)\\b", line):
        ins = idx
        break

new_lines = lines[:ins] + block + lines[ins:]
try:
    open(path, "w", encoding="utf-8").write("\n".join(new_lines) + "\n")
except Exception as e:
    print(f"error writing {path}: {e}")
PY
}

run_update_grub_offline() {
    # Changes to /etc/default/grub won't take effect until grub.cfg is regenerated.
    # Many environments (e.g. inside restricted containers) cannot launch libguestfs.
    # Default behavior is "auto": try quietly; if it fails, fall back without spamming errors.
    OFFLINE_UPDATE_GRUB="${OFFLINE_UPDATE_GRUB:-auto}"  # auto|1|0

    case "$OFFLINE_UPDATE_GRUB" in
        0|false|no|NO|False|No)
            echo "跳过离线 update-grub（OFFLINE_UPDATE_GRUB=$OFFLINE_UPDATE_GRUB）"
            return 0
            ;;
    esac

    if ! command -v virt-customize >/dev/null 2>&1; then
        echo "⚠️  未找到 virt-customize，无法离线运行 update-grub。"
        echo "    你需要在虚拟机内执行: sudo update-grub"
        return 0
    fi

    echo "离线更新 grub.cfg（virt-customize --run-command update-grub）..."
    _tmp_log="$(mktemp -p /tmp virt-customize.XXXX.log)"
    if sudo virt-customize -a "$IMAGE_NAME" \
        --run-command 'set -e; (command -v update-grub >/dev/null 2>&1 && update-grub) || (command -v grub-mkconfig >/dev/null 2>&1 && grub-mkconfig -o /boot/grub/grub.cfg) || (command -v grub2-mkconfig >/dev/null 2>&1 && grub2-mkconfig -o /boot/grub2/grub.cfg) || true' \
        >/dev/null 2>"$_tmp_log"; then
        echo "✓ grub.cfg 已更新"
        rm -f "$_tmp_log" 2>/dev/null || true
        return 0
    fi

    if [ "$OFFLINE_UPDATE_GRUB" = "1" ] || [ "$OFFLINE_UPDATE_GRUB" = "true" ] || [ "$OFFLINE_UPDATE_GRUB" = "yes" ]; then
        echo "⚠️  virt-customize 失败（OFFLINE_UPDATE_GRUB=$OFFLINE_UPDATE_GRUB），输出如下（截断）："
        tail -n 40 "$_tmp_log" 2>/dev/null || true
    else
        echo "⚠️  virt-customize / libguestfs 无法启动，已自动跳过离线 update-grub（不影响本次救援）。"
        echo "    如需彻底生效：请在虚拟机内执行 sudo update-grub，或在非受限环境运行此脚本。"
    fi
    rm -f "$_tmp_log" 2>/dev/null || true
    return 1
}

format_grub_default_value() {
    # Accept:
    # - numeric index: 0
    # - submenu path: 1>2
    # - saved / exact menuentry string
    local v="$1"
    if [[ "$v" =~ ^[0-9]+(>[0-9]+)*$ ]]; then
        echo "$v"
        return 0
    fi
    if [[ "$v" =~ ^\".*\"$ ]] || [[ "$v" =~ ^\'.*\'$ ]]; then
        echo "$v"
        return 0
    fi
    printf '"%s"' "$v"
}

list_grub_menu_paths() {
    local grub_cfg="$1"
    if ! command -v python3 >/dev/null 2>&1; then
        echo "⚠️  未找到 python3，无法解析 grub.cfg 的层级菜单。"
        echo "    你可以手动查看: $grub_cfg"
        sudo grep -E "^menuentry|^submenu" "$grub_cfg" | head -50 || true
        return 0
    fi

    # Print entries as "path  title" where path is like 0 / 1>2 for submenus.
    sudo python3 - "$grub_cfg" <<'PY'
import re, sys
path = sys.argv[1]
try:
    data = open(path, "r", encoding="utf-8", errors="ignore").read().splitlines()
except Exception as e:
    print(f"error reading {path}: {e}")
    sys.exit(0)

depth = 0
idx = [0]               # per-level index
submenu_end = []        # stack of brace-depth to return to when submenu closes

def cur_path():
    return ">".join(str(i) for i in idx[:-1] + [idx[-1]])

for line in data:
    opens = line.count("{")
    closes = line.count("}")

    m = re.match(r"^submenu\\s+['\\\"]([^'\\\"]+)['\\\"].*\\{", line)
    if m:
        title = m.group(1)
        p = cur_path()
        print(f"{p}\t{title} (submenu)")
        idx[-1] += 1
        end_depth = depth
        depth += opens - closes
        submenu_end.append(end_depth)
        idx.append(0)
        continue

    m = re.match(r"^menuentry\\s+['\\\"]([^'\\\"]+)['\\\"].*\\{", line)
    if m:
        title = m.group(1)
        p = cur_path()
        print(f"{p}\t{title}")
        idx[-1] += 1
        depth += opens - closes
    else:
        depth += opens - closes

    while submenu_end and depth == submenu_end[-1]:
        submenu_end.pop()
        if len(idx) > 1:
            idx.pop()
PY
}

# 检查镜像是否被锁定（虚拟机可能正在运行）
echo "检查镜像状态..."
if qemu-img info "$IMAGE_NAME" 2>&1 | grep -q "Failed to get.*lock"; then
    echo ""
    echo "⚠️  警告: 镜像文件被锁定，虚拟机可能正在运行"
    echo ""
    echo "有两个选择:"
    echo "1. 关闭虚拟机后重新运行此脚本（推荐，可以修改镜像）"
    echo "2. 通过SSH在虚拟机内直接修改grub配置"
    echo ""
    read -p "是否通过SSH在虚拟机内修改? (Y/n): " use_ssh
    if [[ ! "$use_ssh" =~ ^[Nn]$ ]]; then
        echo ""
        echo "通过SSH修改grub配置..."
        
        # 检查sshpass
        if ! command -v sshpass >/dev/null 2>&1; then
            echo "需要安装 sshpass"
            echo "运行: sudo apt-get install sshpass"
            exit 1
        fi
        
        # 等待SSH就绪
        echo "等待SSH连接..."
        for i in $(seq 1 30); do
            if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "true" >/dev/null 2>&1; then
                break
            fi
            sleep 2
        done
        
        # 检查SSH连接
        if ! sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "true" >/dev/null 2>&1; then
            echo "错误: 无法连接到虚拟机SSH"
            echo "请确保虚拟机正在运行且SSH服务正常"
            exit 1
        fi
        
        echo "✓ SSH连接成功"
        echo ""
        echo "当前grub配置:"
        sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "sudo cat /etc/default/grub | grep -E '^GRUB_|^#GRUB_' | head -10" || true

        echo ""
        read -p "是否启用串口GRUB菜单（推荐，适配 start-vm.sh 的 -nographic）? (Y/n): " ssh_enable_serial
        if [[ "$ssh_enable_serial" =~ ^[Nn]$ ]]; then
            SSH_ENABLE_SERIAL=0
        else
            SSH_ENABLE_SERIAL=1
        fi
        
        echo ""
        echo "选择操作:"
        echo "1. 启用grub菜单（GRUB_TIMEOUT=5，显示菜单5秒）"
        echo "2. 启用grub菜单并永久显示（GRUB_TIMEOUT=-1）"
        echo "3. 修改默认启动项（选择旧内核）"
        echo "4. 查看当前可用的内核"
        read -p "请选择 (1-4): " ssh_choice
        
        case "$ssh_choice" in
            1)
                echo "修改 GRUB_TIMEOUT=5..."
                sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "
                    sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
                    sudo sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub || true
                    if ! grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
                        echo 'GRUB_TIMEOUT=5' | sudo tee -a /etc/default/grub > /dev/null
                    fi
                    if ! grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub; then
                        echo 'GRUB_TIMEOUT_STYLE=menu' | sudo tee -a /etc/default/grub > /dev/null
                    fi
                    if [ $SSH_ENABLE_SERIAL -eq 1 ]; then
                        sudo sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL=\"serial console\"/' /etc/default/grub || true
                        sudo sed -i 's/^GRUB_SERIAL_COMMAND=.*/GRUB_SERIAL_COMMAND=\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\"/' /etc/default/grub || true
                        if ! grep -q '^GRUB_TERMINAL=' /etc/default/grub; then
                            echo 'GRUB_TERMINAL=\"serial console\"' | sudo tee -a /etc/default/grub > /dev/null
                        fi
                        if ! grep -q '^GRUB_SERIAL_COMMAND=' /etc/default/grub; then
                            echo 'GRUB_SERIAL_COMMAND=\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\"' | sudo tee -a /etc/default/grub > /dev/null
                        fi
                        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub && ! grep -q 'console=ttyS0,115200n8' /etc/default/grub; then
                            sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 console=ttyS0,115200n8\"/' /etc/default/grub || true
                        fi
                    fi
                    sudo update-grub
                    echo '✓ 配置已更新，grub菜单将在下次启动时显示5秒'
                "
                ;;
            2)
                echo "修改 GRUB_TIMEOUT=-1..."
                sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "
                    sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=-1/' /etc/default/grub
                    sudo sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub || true
                    if ! grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
                        echo 'GRUB_TIMEOUT=-1' | sudo tee -a /etc/default/grub > /dev/null
                    fi
                    if ! grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub; then
                        echo 'GRUB_TIMEOUT_STYLE=menu' | sudo tee -a /etc/default/grub > /dev/null
                    fi
                    if [ $SSH_ENABLE_SERIAL -eq 1 ]; then
                        sudo sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL=\"serial console\"/' /etc/default/grub || true
                        sudo sed -i 's/^GRUB_SERIAL_COMMAND=.*/GRUB_SERIAL_COMMAND=\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\"/' /etc/default/grub || true
                        if ! grep -q '^GRUB_TERMINAL=' /etc/default/grub; then
                            echo 'GRUB_TERMINAL=\"serial console\"' | sudo tee -a /etc/default/grub > /dev/null
                        fi
                        if ! grep -q '^GRUB_SERIAL_COMMAND=' /etc/default/grub; then
                            echo 'GRUB_SERIAL_COMMAND=\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\"' | sudo tee -a /etc/default/grub > /dev/null
                        fi
                        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub && ! grep -q 'console=ttyS0,115200n8' /etc/default/grub; then
                            sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 console=ttyS0,115200n8\"/' /etc/default/grub || true
                        fi
                    fi
                    sudo update-grub
                    echo '✓ 配置已更新，grub菜单将永久显示'
                "
                ;;
            3)
                echo "查找可用的内核..."
                sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "
                    echo '可用的内核:'
                    ls -lh /boot/vmlinuz-* 2>/dev/null | tail -5 || true
                    echo ''
                    echo 'grub菜单项:'
                    sudo grep -E '^menuentry|^submenu' /boot/grub/grub.cfg | head -10 || true
                "
                echo ""
                echo "提示: 旧内核通常在 \"Advanced options for Ubuntu\" 子菜单里，可用 1>2 这种路径。"
                read -p "请输入要设置为默认的菜单路径（例如 1>2），或菜单项名称: " menu_num
                sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "
                    sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"$menu_num\"/' /etc/default/grub
                    if ! grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
                        echo 'GRUB_DEFAULT=\"$menu_num\"' | sudo tee -a /etc/default/grub > /dev/null
                    fi
                    if [ $SSH_ENABLE_SERIAL -eq 1 ]; then
                        sudo sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL=\"serial console\"/' /etc/default/grub || true
                        sudo sed -i 's/^GRUB_SERIAL_COMMAND=.*/GRUB_SERIAL_COMMAND=\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\"/' /etc/default/grub || true
                        if ! grep -q '^GRUB_TERMINAL=' /etc/default/grub; then
                            echo 'GRUB_TERMINAL=\"serial console\"' | sudo tee -a /etc/default/grub > /dev/null
                        fi
                        if ! grep -q '^GRUB_SERIAL_COMMAND=' /etc/default/grub; then
                            echo 'GRUB_SERIAL_COMMAND=\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\"' | sudo tee -a /etc/default/grub > /dev/null
                        fi
                        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub && ! grep -q 'console=ttyS0,115200n8' /etc/default/grub; then
                            sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 console=ttyS0,115200n8\"/' /etc/default/grub || true
                        fi
                    fi
                    sudo update-grub
                    echo '✓ 已设置默认启动项为: $menu_num'
                "
                ;;
            4)
                sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "
                    echo '可用的内核:'
                    ls -lh /boot/vmlinuz-* 2>/dev/null || true
                    echo ''
                    echo 'grub菜单项:'
                    sudo grep -E '^menuentry|^submenu' /boot/grub/grub.cfg | head -20 || true
                "
                ;;
            *)
                echo "无效选择"
                exit 1
                ;;
        esac
        
        echo ""
        echo "✓ 完成！修改将在下次重启时生效。"
        exit 0
    else
        echo ""
        echo "请先关闭虚拟机，然后重新运行此脚本。"
        echo "关闭虚拟机的方法:"
        echo "  - 在QEMU中按 Ctrl+A 然后按 X"
        echo "  - 或者通过SSH: sudo shutdown -h now"
        exit 1
    fi
fi

# 检查必要的工具
command -v guestmount >/dev/null 2>&1 || {
    echo "需要安装 libguestfs-tools"
    echo "运行: sudo apt-get install libguestfs-tools"
    exit 1
}

MNT_DIR=$(mktemp -d)
echo "挂载点: $MNT_DIR"

cleanup() {
    echo "清理挂载点..."
    sudo guestunmount "$MNT_DIR" 2>/dev/null || true
    rmdir "$MNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "正在挂载虚拟机镜像..."
# Prefer auto-inspection mount: mounts /, /boot, /boot/efi correctly when they are separate partitions.
if sudo guestmount -a "$IMAGE_NAME" -i "$MNT_DIR" 2>&1; then
    echo "✓ 成功自动挂载（guestmount -i）"
else
    echo "guestmount -i 失败，尝试手动挂载根分区..."
    # 根据经验先试 /dev/sda1
    if sudo guestmount -a "$IMAGE_NAME" -m /dev/sda1 "$MNT_DIR" 2>&1; then
        echo "✓ 成功挂载根分区: /dev/sda1"
    else
        echo "尝试其他分区..."
        # 尝试其他分区
        for part in /dev/sda16 /dev/sda2 /dev/sda3; do
            if sudo guestmount -a "$IMAGE_NAME" -m "$part" "$MNT_DIR" 2>&1; then
                if [ -d "$MNT_DIR/etc" ]; then
                    echo "✓ 成功挂载根分区: $part"
                    break
                else
                    sudo guestunmount "$MNT_DIR" 2>/dev/null || true
                fi
            fi
        done
    fi
fi

if [ ! -d "$MNT_DIR/etc" ]; then
    echo "错误: 无法挂载镜像的根分区"
    exit 1
fi

GRUB_CFG="$MNT_DIR/etc/default/grub"

echo ""
echo "当前grub配置:"
if [ -f "$GRUB_CFG" ]; then
    grep -E "^GRUB_|^#GRUB_" "$GRUB_CFG" | head -10 || true
fi

echo ""
echo "选择操作:"
echo "1. 启用grub菜单（GRUB_TIMEOUT=5，显示菜单5秒）"
echo "2. 启用grub菜单并永久显示（GRUB_TIMEOUT=-1）"
echo "3. 修改默认启动项（选择旧内核）"
echo "4. 查看当前可用的内核"
echo "5. 仅修改GRUB_TIMEOUT（不修改其他设置）"
read -p "请选择 (1-5): " choice

echo ""
read -p "是否启用串口GRUB菜单（推荐，适配 start-vm.sh 的 -nographic）? (Y/n): " enable_serial
if [[ "$enable_serial" =~ ^[Nn]$ ]]; then
    ENABLE_SERIAL=0
else
    ENABLE_SERIAL=1
fi

case "$choice" in
    1)
        echo "启用grub菜单（5秒超时）..."
        if [ -f "$GRUB_CFG" ]; then
            sudo cp "$GRUB_CFG" "${GRUB_CFG}.bak"
            ensure_grub_kv "$GRUB_CFG" "GRUB_TIMEOUT_STYLE" "menu"
            ensure_grub_kv "$GRUB_CFG" "GRUB_TIMEOUT" "5"
            sudo sed -i 's/^GRUB_HIDDEN_TIMEOUT=.*/GRUB_HIDDEN_TIMEOUT=0/' "$GRUB_CFG" 2>/dev/null || true
            sudo sed -i 's/^GRUB_HIDDEN_TIMEOUT_QUIET=.*/GRUB_HIDDEN_TIMEOUT_QUIET=false/' "$GRUB_CFG" 2>/dev/null || true
            if [ "$ENABLE_SERIAL" -eq 1 ]; then
                enable_serial_grub "$GRUB_CFG"
            fi
        fi
        ;;
    2)
        echo "启用grub菜单（永久显示）..."
        if [ -f "$GRUB_CFG" ]; then
            sudo cp "$GRUB_CFG" "${GRUB_CFG}.bak"
            ensure_grub_kv "$GRUB_CFG" "GRUB_TIMEOUT_STYLE" "menu"
            ensure_grub_kv "$GRUB_CFG" "GRUB_TIMEOUT" "-1"
            sudo sed -i 's/^GRUB_HIDDEN_TIMEOUT=.*/GRUB_HIDDEN_TIMEOUT=0/' "$GRUB_CFG" 2>/dev/null || true
            sudo sed -i 's/^GRUB_HIDDEN_TIMEOUT_QUIET=.*/GRUB_HIDDEN_TIMEOUT_QUIET=false/' "$GRUB_CFG" 2>/dev/null || true
            if [ "$ENABLE_SERIAL" -eq 1 ]; then
                enable_serial_grub "$GRUB_CFG"
            fi
        fi
        ;;
    3)
        echo "查找可用的内核..."
        
        # 查找内核文件
        KERNELS=""
        if [ -d "$MNT_DIR/boot" ]; then
            KERNELS=$(ls -1 "$MNT_DIR/boot" 2>/dev/null | grep -E "^vmlinuz" | sort -V || true)
        fi
        
        # 如果/boot目录没有内核，尝试查找其他位置
        if [ -z "$KERNELS" ]; then
            echo "在 /boot 目录未找到内核，尝试其他位置..."
            KERNELS=$(find "$MNT_DIR" -name "vmlinuz-*" -type f 2>/dev/null | xargs -n1 basename | sort -V || true)
        fi
        
        # 显示内核列表
        if [ -n "$KERNELS" ]; then
            echo "可用的内核:"
            echo "$KERNELS" | nl -v 0 -w 2 -s '. '
            echo ""
        else
            echo "警告: 未找到内核文件"
        fi
        
        # 查找grub.cfg文件
        GRUB_CFG_FILE=""
        for cfg in "$MNT_DIR/boot/grub/grub.cfg" "$MNT_DIR/boot/grub2/grub.cfg" "$MNT_DIR/boot/efi/EFI/ubuntu/grub.cfg"; do
            if [ -f "$cfg" ]; then
                GRUB_CFG_FILE="$cfg"
                break
            fi
        done
        
        # 显示grub菜单项（支持 submenu 路径，例如 1>2）
        if [ -n "$GRUB_CFG_FILE" ]; then
            echo "可用的grub菜单项（路径格式：0 或 1>2，对应子菜单）："
            list_grub_menu_paths "$GRUB_CFG_FILE" | head -80 || true
        else
            echo "警告: 未找到 grub.cfg 文件"
            echo "尝试查找的位置:"
            echo "  - $MNT_DIR/boot/grub/grub.cfg"
            echo "  - $MNT_DIR/boot/grub2/grub.cfg"
            echo "  - $MNT_DIR/boot/efi/EFI/ubuntu/grub.cfg"
        fi
        
        echo ""
        if [ -z "$KERNELS" ] && [ -z "$MENU_ENTRIES" ]; then
            echo "错误: 无法找到内核或grub菜单项"
            echo "建议: 先选择选项4查看详细信息"
            exit 1
        fi
        
        echo ""
        echo "提示: 旧内核通常在 \"Advanced options for Ubuntu\" 子菜单里，默认项 0 往往还是最新内核。"
        read -p "请输入要设置为默认的菜单路径（例如 1>2），或直接输入菜单项名称: " menu_num
        menu_num_fmt=$(format_grub_default_value "$menu_num")
        if [ -f "$GRUB_CFG" ]; then
            sudo cp "$GRUB_CFG" "${GRUB_CFG}.bak"
            ensure_grub_kv "$GRUB_CFG" "GRUB_DEFAULT" "$menu_num_fmt"
            if [ "$ENABLE_SERIAL" -eq 1 ]; then
                enable_serial_grub "$GRUB_CFG"
            fi
            echo "已设置默认启动项为: $menu_num_fmt"
        fi
        ;;
    4)
        echo "可用的内核:"
        if [ -d "$MNT_DIR/boot" ]; then
            ls -lh "$MNT_DIR/boot" | grep -E "vmlinuz|initrd" || true
        fi
        
        # 如果/boot没有，尝试查找其他位置
        if [ ! -d "$MNT_DIR/boot" ] || [ -z "$(ls -A "$MNT_DIR/boot" 2>/dev/null | grep -E "vmlinuz|initrd")" ]; then
            echo "在 /boot 目录未找到，搜索整个文件系统..."
            find "$MNT_DIR" -name "vmlinuz-*" -o -name "initrd*" 2>/dev/null | head -10 || true
        fi
        
        echo ""
        echo "grub配置文件位置:"
        for cfg in "$MNT_DIR/boot/grub/grub.cfg" "$MNT_DIR/boot/grub2/grub.cfg" "$MNT_DIR/boot/efi/EFI/ubuntu/grub.cfg"; do
            if [ -f "$cfg" ]; then
                echo "找到: $cfg"
                echo "菜单项:"
                grep -E "^menuentry|^submenu" "$cfg" | head -20 || true
                break
            fi
        done
        
        # 如果都没找到，列出所有可能的grub.cfg
        if [ -z "$(find "$MNT_DIR" -name "grub.cfg" 2>/dev/null | head -1)" ]; then
            echo "未找到 grub.cfg 文件"
            echo "搜索所有可能的grub配置文件:"
            find "$MNT_DIR" -name "*grub*" -type f 2>/dev/null | head -10 || true
        fi
        exit 0
        ;;
    5)
        read -p "请输入超时时间（秒，-1表示永久显示，0表示隐藏）: " timeout
        if [ -f "$GRUB_CFG" ]; then
            sudo cp "$GRUB_CFG" "${GRUB_CFG}.bak"
            # If user sets timeout > 0, force menu style so it shows.
            if [ "$timeout" != "0" ]; then
                ensure_grub_kv "$GRUB_CFG" "GRUB_TIMEOUT_STYLE" "menu"
            fi
            ensure_grub_kv "$GRUB_CFG" "GRUB_TIMEOUT" "$timeout"
            if [ "$ENABLE_SERIAL" -eq 1 ]; then
                enable_serial_grub "$GRUB_CFG"
            fi
            echo "已设置GRUB_TIMEOUT=$timeout"
        fi
        ;;
    *)
        echo "无效选择"
        exit 1
        ;;
esac

echo ""
echo "修改后的grub配置:"
if [ -f "$GRUB_CFG" ]; then
    grep -E "^GRUB_|^#GRUB_" "$GRUB_CFG" | head -10 || true
fi

echo ""
# 先直接修补已生成的 grub.cfg（不依赖 update-grub / libguestfs），确保救援可用。
GRUB_TIMEOUT_STYLE_VAL="menu"
GRUB_TIMEOUT_VAL="5"
if [ "$choice" = "2" ]; then
    GRUB_TIMEOUT_VAL="-1"
elif [ "$choice" = "5" ]; then
    GRUB_TIMEOUT_VAL="$timeout"
fi

echo "正在查找 grub.cfg（优先查找 /boot 与 EFI 目录，避免全盘扫描很慢）..."
CFG_COUNT=0

# Fast path: typical locations for Ubuntu.
for cfg in \
    "$MNT_DIR/boot/grub/grub.cfg" \
    "$MNT_DIR/boot/grub2/grub.cfg" \
    "$MNT_DIR/boot/efi/EFI/ubuntu/grub.cfg" \
    "$MNT_DIR/boot/efi/EFI/debian/grub.cfg" \
    "$MNT_DIR/boot/efi/EFI/*/grub.cfg"; do
    # Globs may not expand if no match; guard with -f.
    if [ -f "$cfg" ]; then
        CFG_COUNT=$((CFG_COUNT + 1))
        echo "修补 grub.cfg: $cfg"
        patch_grub_cfg_file "$cfg" "$GRUB_TIMEOUT_STYLE_VAL" "$GRUB_TIMEOUT_VAL" "$ENABLE_SERIAL"
    fi
done

# Slow path: limited find under /boot only (guestmount FUSE can be very slow for full filesystem scans).
if [ "$CFG_COUNT" -eq 0 ]; then
    for root in "$MNT_DIR/boot" "$MNT_DIR/boot/efi"; do
        if [ -d "$root" ]; then
            while IFS= read -r -d '' cfg; do
                CFG_COUNT=$((CFG_COUNT + 1))
                echo "修补 grub.cfg: $cfg"
                patch_grub_cfg_file "$cfg" "$GRUB_TIMEOUT_STYLE_VAL" "$GRUB_TIMEOUT_VAL" "$ENABLE_SERIAL"
            done < <(sudo find "$root" -maxdepth 6 -type f -name grub.cfg -print0 2>/dev/null || true)
        fi
    done
fi

if [ "$CFG_COUNT" -eq 0 ]; then
    echo "⚠️  未在镜像中找到 grub.cfg（可能 /boot 未挂载、EFI 路径不同、或不是 GRUB 引导）。"
    echo "    建议：选择选项4查看 /boot 与 EFI 目录实际内容。"
fi

# 尝试离线 update-grub（如果环境支持的话）；失败也不致命。
run_update_grub_offline || true
echo ""
echo "修复完成！现在可以重新启动虚拟机，grub菜单应该会显示。"
echo "启动时按住 Shift 键或任意键可以进入grub菜单（如果已启用串口GRUB，会直接在当前终端显示菜单）。"
