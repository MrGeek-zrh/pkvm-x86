# pKVM-IA 文档

本目录存放 **pKVM-IA（Protected KVM for Intel Architecture）** 相关的说明与工具，用于在 x86 上配置和构建支持 pKVM 的宿主/客户机内核。

| 文件 | 说明 |
|------|------|
| **PKVM-Kconfig.md** | 宿主与客户机内核的 Kconfig 要求（如 `CONFIG_PKVM_INTEL`、`CONFIG_PKVM_GUEST` 等）及依赖说明 |
| **build-host-kernel.sh** | 宿主内核一键编译脚本：安装依赖 → 用 `O=<repo>/build-host/<kernel>` 构建 → 打成 .deb 包（Debian/Ubuntu）；支持 `--kernel pvVMCS-POC-v6.12|pkvm-v6.18|pKVM-IA`（默认 `pKVM-IA`），包产物默认输出到 `/home/mrgeek/pkvm-x86/output` |
| **build-guest-kernel.sh** | 客户机（Protected VM）内核编译脚本：复用 Host `O=` 输出目录里的 .config 或生成新的 guest .config → 强制开启 `CONFIG_PKVM_GUEST=y` → 编译 bzImage/modules |
| **build-crosvm.sh** | crosvm（CrossVM）在 Linux 上的构建脚本：按官方文档 clone/submodule/setup/cargo build（可选 dev container） |

使用前请先阅读 `PKVM-Kconfig.md`，按 Host/Guest 各自的 `O=` 输出目录准备 `.config`。推荐约定：

- Host: `/home/mrgeek/pkvm-x86/build-host/pkvm-ia/.config`
- Guest: `/home/mrgeek/pkvm-x86/build-guest/.config`

如果源码树里还残留旧的 `pKVM-IA/.config`，`build-host-kernel.sh` 会先把它迁移到 `build-host/pkvm-ia/.config`，然后提示你对源码树执行一次 `mrproper`。

## Protected VM（客户机）内核快速构建

推荐方式：同一份 `pKVM-IA` 源码，用独立的 `O=` 输出目录分别构建 Host 和 Guest。Guest 直接复用 Host 的配置作为起点：

```bash
cd /home/mrgeek/pkvm-x86/DOCS/pKVM-IA-docs
./build-guest-kernel.sh
```

脚本默认复用 `build-host/pkvm-ia/.config` 作为起点，然后强制开启 `CONFIG_PKVM_GUEST=y`（以及 `HYPERVISOR_GUEST=y`），输出为：

- `build-guest/arch/x86/boot/bzImage`
- `build-guest/.config`

## 常见问题

### 内核打包 .deb 报错：缺少 debian/canonical-certs.pem

现象（示例）：

```
make[6]: *** No rule to make target 'debian/canonical-certs.pem', needed by 'certs/x509_certificate_list'.  Stop.
```

原因：

`.config` 中启用了发行版打包用的证书路径（例如 Debian/Ubuntu 的 `debian/canonical-certs.pem` / `debian/canonical-revoked-certs.pem`），但当前源码树的 `debian/` 目录没有提供这些文件，导致构建证书列表阶段失败。

解决方法 A（推荐：置空这两个配置，不从 `debian/` 读取证书）：

在内核源码目录（例如本仓库的 `pKVM-IA/`）执行：

```bash
./scripts/config --file .config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
make ARCH=x86 olddefconfig
```

然后重新执行打包（`make -f debian/rules binary` 或 `make bindeb-pkg`）。
