# pKVM-IA 内核 Kconfig 说明（x86）

本文档记录 pKVM-IA 源码中与 PKVM 相关的 Kconfig 选项及 Host/Guest 配置要求。结论来源于 `arch/x86/kvm/Kconfig` 与 `arch/x86/Kconfig` 中的 `depends` 与 help 文本。

---

## 宿主内核（跑 pKVM 的那台机器）

**必须开启：**

| Config | 说明 | 来源 |
|--------|------|------|
| `CONFIG_KVM_INTEL=y` | KVM Intel 支持（必须内置 `=y`，不能 `=m`） | `PKVM_INTEL` 的 `depends on KVM_INTEL=y` |
| `CONFIG_PKVM_INTEL=y` | pKVM for Intel：宿主以 VM 身份运行在 non-root VMX，pKVM 运行在 root VMX | `arch/x86/kvm/Kconfig` |

**PKVM_INTEL 的依赖（需同时满足）：**

- `CONFIG_KVM_INTEL=y`（见上）
- `CONFIG_X86_64`（通常已选）
- `CONFIG_KSM=n`（不能开 KSM）
- `CONFIG_INTEL_IOMMU=y`
- `CONFIG_BLK_DEV_FD` 未启用（`=n` 或 不设置）

**可选：**

| Config | 说明 |
|--------|------|
| `CONFIG_PKVM_INTEL_PVIOMMU=y` | 半虚拟化 IOMMU，pKVM 接管 IOMMU，宿主通过 hypercall 访问 |
| `CONFIG_PKVM_INTEL_DEBUG=y` | pKVM 调试支持 |

---

## 客户机内核（跑在 pKVM 里的 VM）

**必须开启：**

| Config | 说明 | 来源 |
|--------|------|------|
| `CONFIG_PKVM_GUEST=y` | 作为 Protected KVM 保护客户机运行；不开启则无法在 pKVM 下启动 | `arch/x86/Kconfig` 中 `HYPERVISOR_GUEST` 子菜单，help 明确写 “guest kernel” |

依赖：`X86_64`，会 `select X86_MEM_ENCRYPT` 等。

---

## 在 .config 中检查

```bash
# 宿主
grep -E '^CONFIG_(KVM|KVM_INTEL|PKVM_INTEL|KSM|BLK_DEV_FD|INTEL_IOMMU)=' \
  /home/mrgeek/pkvm-x86/build-host/pkvm-ia/.config

# 客户机
grep -E '^CONFIG_PKVM_GUEST=' /home/mrgeek/pkvm-x86/build-guest/.config
```

---

## Kconfig 源码位置

- 宿主 pKVM：`pKVM-IA/arch/x86/kvm/Kconfig`（`PKVM_INTEL`、`PKVM_INTEL_PVIOMMU`、`PKVM_INTEL_DEBUG`）
- 客户机：`pKVM-IA/arch/x86/Kconfig`（`PKVM_GUEST` 在 `if HYPERVISOR_GUEST` 块内）

---

## 编译宿主内核

同目录下的 `build-host-kernel.sh` 会：自动安装依赖 → 编译内核 → 打成 .deb 包（仅 Debian/Ubuntu）。不执行 `make install`，需自行用 dpkg 安装。

```bash
cd /home/mrgeek/pkvm-x86/DOCS/pKVM-IA-docs
./build-host-kernel.sh
```

默认行为：
- 使用 `pKVM-IA` 作为源码树
- 使用 `/home/mrgeek/pkvm-x86/build-host/pkvm-ia` 作为 Host 的 `O=` 输出目录
- 将 `.deb/.buildinfo/.changes` 归集到 `/home/mrgeek/pkvm-x86/output`

手动安装示例：

```bash
sudo dpkg -i /home/mrgeek/pkvm-x86/output/linux-image-*.deb /home/mrgeek/pkvm-x86/output/linux-headers-*.deb
```

依赖由脚本自动安装：`build-essential`、`flex`、`bison`、`libssl-dev`、`libelf-dev`、`bc`、`cpio`、`rsync`、`kmod`、`libncurses-dev`、`dpkg-dev`。

若你以前做过 in-tree 构建，源码树里可能还留着 `pKVM-IA/.config`、`pKVM-IA/include/config/`、`pKVM-IA/arch/x86/include/generated/`。共享同一份源码树给 Host/Guest 做 `O=` 构建时，这些残留必须先清掉。脚本会优先把旧的 `pKVM-IA/.config` 迁移到 `build-host/pkvm-ia/.config`，然后提示你执行：

```bash
make -C /home/mrgeek/pkvm-x86/pKVM-IA ARCH=x86_64 mrproper
```

---

## 编译 Protected VM 的客户机内核（Guest kernel）

Protected VM 的 guest kernel **必须**开启 `CONFIG_PKVM_GUEST=y`（它在 `HYPERVISOR_GUEST` 子菜单下），否则 crosvm 以 protected-vm 方式启动时会失败或行为异常。

推荐做法：**同一份内核源码 + 单独的 O= 输出目录**，避免你为 guest 再复制一份源码树。

仓库已提供脚本 `build-guest-kernel.sh`（同目录）用于快速构建：

```bash
cd /home/mrgeek/pkvm-x86/DOCS/pKVM-IA-docs
./build-guest-kernel.sh
```

默认行为：
- 复用宿主的 `/home/mrgeek/pkvm-x86/build-host/pkvm-ia/.config` 作为起点（更贴合 pKVM-IA 分支的依赖组合）
- 强制开启 `HYPERVISOR_GUEST=y`、`PKVM_GUEST=y`
- 将 guest 的 `.config` 独立保存在 `/home/mrgeek/pkvm-x86/build-guest/.config`
- 输出 guest bzImage 到：`/home/mrgeek/pkvm-x86/build-guest/arch/x86/boot/bzImage`

如果你更想从一个“更干净”的 guest 配置起步，可以用：

```bash
./build-guest-kernel.sh --defconfig
```

注意：defconfig 通常需要你额外启用 guest 启动所需驱动（常见：virtio 块/网卡、文件系统、串口等）。
