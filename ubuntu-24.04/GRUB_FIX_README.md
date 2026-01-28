# Grub菜单修复指南

当虚拟机修改内核后启动失败，需要访问grub菜单选择旧内核时，可以使用以下方法：

## 方法1: 修复grub配置（推荐）

运行修复脚本，启用grub菜单：

```bash
cd pkvm-x86/ubuntu-24.04
bash fix-grub-menu.sh
```

脚本会提供以下选项：
1. **启用grub菜单（5秒超时）** - 显示菜单5秒后自动启动
2. **启用grub菜单并永久显示** - 菜单一直显示，需要手动选择
3. **修改默认启动项** - 直接设置默认启动旧内核
4. **查看当前可用的内核** - 列出所有可用内核
5. **仅修改GRUB_TIMEOUT** - 自定义超时时间

选择选项1或2后，重新启动虚拟机，grub菜单就会显示。

补充说明（很关键）：
- 仅仅修改 `/etc/default/grub` 并不会立刻生效，必须重新生成 `/boot/grub/grub.cfg`（也就是执行 `update-grub` / `grub-mkconfig`）。
- 本项目的 `start-vm.sh` 默认使用 `-nographic`，如果不启用串口 GRUB，你可能“其实已经打开了菜单”但看不到；`fix-grub-menu.sh` 现在会提示是否启用串口 GRUB（推荐选 Y）。

## 方法2: 启动时按住Shift键

即使grub菜单被隐藏，在虚拟机启动时（看到BIOS/UEFI启动信息后），**立即按住Shift键或任意键**，可以强制显示grub菜单。

使用 `start-vm-with-grub.sh` 启动虚拟机：

```bash
bash start-vm-with-grub.sh
```

在启动过程中，看到grub提示时立即按Shift键。

如果你用的是 `start-vm.sh` 的 `-nographic`，但还是看不到 grub 菜单，建议用 `start-vm-with-grub.sh` 的默认 curses 模式（VGA 输出渲染到终端），它不依赖串口 GRUB：

```bash
bash start-vm-with-grub.sh
```

若你确实需要纯串口模式：

```bash
GRUB_UI=serial bash start-vm-with-grub.sh
```

## 方法3: 使用QEMU monitor修改启动参数

如果虚拟机可以启动但内核有问题，可以通过QEMU monitor操作：

1. 虚拟机启动时，按 `Ctrl+A` 然后按 `C` 进入QEMU monitor
2. 或者连接到monitor socket：
   ```bash
   socat - UNIX-CONNECT:/tmp/qemu-monitor-ubuntu-24.04.sock
   ```

在monitor中可以：
- `info registers` - 查看寄存器
- `system_reset` - 重启虚拟机
- `sendkey shift` - 发送Shift键（尝试触发grub菜单）

## 方法4: 直接修改grub默认启动项

如果知道旧内核的菜单项序号，可以直接修改：

```bash
bash fix-grub-menu.sh
# 选择选项3，输入旧内核的菜单项序号（通常是0或1）
```

## 常见问题

### Q: 修复脚本提示无法挂载镜像？
A: 确保虚拟机已关闭，并且有root权限。可以尝试：
```bash
sudo bash fix-grub-menu.sh
```

### Q: 修改后grub菜单还是不显示？
A: 可能需要更新grub配置。在虚拟机内运行：
```bash
sudo update-grub
```

或者使用修复脚本时，确保选择了正确的选项（选项1或2）。

### Q: 如何查看可用的内核版本？
A: 运行修复脚本，选择选项4，或者：
```bash
# 在虚拟机内
ls -lh /boot/vmlinuz-*
```

### Q: 启动时按Shift键没反应？
A: 
1. 确保在正确的时机按键（看到BIOS/UEFI信息后，grub启动前）
2. 尝试使用 `start-vm-with-grub.sh` 启动
3. 先运行 `fix-grub-menu.sh` 启用菜单

## 快速修复步骤

1. **停止当前虚拟机**（如果正在运行）

2. **运行修复脚本**：
   ```bash
   cd pkvm-x86/ubuntu-24.04
   bash fix-grub-menu.sh
   ```
   选择选项1（启用5秒菜单）或选项2（永久显示）

3. **重新启动虚拟机**：
   ```bash
   bash start-vm.sh
   ```
   或
   ```bash
   bash start-vm-with-grub.sh
   ```

4. **在grub菜单出现时**，选择旧内核（通常是第一个或第二个选项）

5. **启动成功后**，在虚拟机内修复新内核问题或卸载有问题的内核
