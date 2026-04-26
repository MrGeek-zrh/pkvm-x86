# T12-A1 pci=nomsi 临时验证记录

## 基本信息

- 时间：2026-04-26 07:57:34 UTC
- 仓库：/home/mrgeek/pkvm-x86
- 设备：0000:01:00.0
- 运行目录：DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1
- 绑定记录：DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t12-a1-nomsi-bind-0100-20260426-075220.log

## 临时脚本差异

scripts/run-crosvm.sh 已支持 GUEST_KERNEL_EXTRA。默认未设置时，来宾启动参数仍为 root=/dev/vda1 rw。

## 执行命令

```text
sudo -n timeout -k 10s 180s env PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 GUEST_KERNEL_EXTRA=pci=nomsi ./scripts/run-crosvm.sh
```

- 结束状态：FAILED
- 返回值：-9
- 结束时间：2026-04-26T07:55:52Z

## 命令行证据

```text
未在 stderr 摘要中匹配到完整 crosvm 命令；result.json 已记录 GUEST_KERNEL_EXTRA=pci=nomsi。
```

## 关键证据

- action-stdout.log 出现 localhost login:。
- 本轮日志未出现 deny host BAR remap。
- 本轮日志未出现 raw_readl。
- 本轮日志未出现 general protection fault。
- host-dmesg 中出现 BUG: scheduling while atomic。调用栈位于 KVM 运行线程，不是上一轮 MSI-X table 读取触发的 raw_readl 崩溃。

## 模式匹配

```text
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:617:[Sat Apr 25 02:39:14 2026] nvme nvme0: pci function 0000:01:00.0
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:618:[Sat Apr 25 02:39:14 2026] nvme nvme1: pci function 0000:02:00.0
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:626:[Sat Apr 25 02:39:15 2026] nvme nvme1: 32/0/0 default/read/poll queues
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:627:[Sat Apr 25 02:39:15 2026] nvme nvme0: 32/0/0 default/read/poll queues
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:628:[Sat Apr 25 02:39:15 2026] nvme nvme1: Ignoring bogus Namespace Identifiers
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:629:[Sat Apr 25 02:39:15 2026] nvme nvme0: Ignoring bogus Namespace Identifiers
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:752:[Sun Apr 26 07:52:22 2026] VFIO - User Level meta-driver version: 0.3
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:755:[Sun Apr 26 07:53:18 2026] BUG: scheduling while atomic: crosvm_vcpu0/99825/0x00000002
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:756:[Sun Apr 26 07:53:18 2026] Modules linked in: vfio_pci vfio_pci_core vfio_iommu_type1 vfio iommufd tls udp_diag tcp_diag inet_diag nft_nat nft_redir xt_conntrack xt_MASQUERADE bridge stp llc xfrm_user xfrm_algo xt_set ip_set nft_chain_nat nf_nat nf_conntrack nf_defrag_ipv6 nf_defrag_ipv4 xt_addrtype nft_compat nf_tables qrtr overlay intel_rapl_msr intel_rapl_common cfg80211 intel_uncore_frequency_common binfmt_misc ppdev nls_iso8859_1 skx_edac_common nfit rapl i2c_i801 i2c_mux parport_pc i2c_smbus parport lpc_ich joydev input_leds mac_hid serio_raw sch_fq_codel dm_multipath msr efi_pstore nfnetlink dmi_sysfs qemu_fw_cfg ip_tables x_tables autofs4 btrfs blake2b_generic raid10 raid456 async_raid6_recov async_memcpy async_pq async_xor async_tx xor raid6_pq libcrc32c raid1 raid0 crct10dif_pclmul crc32_pclmul polyval_clmulni nvme polyval_generic bochs ghash_clmulni_intel drm_vram_helper sha256_ssse3 drm_ttm_helper ahci nvme_core sha1_ssse3 psmouse e1000 libahci ttm virtio_rng nvme_auth aesni_intel crypto_simd cryptd
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:828:[Sun Apr 26 07:53:18 2026] BUG: scheduling while atomic: crosvm_vcpu0/99825/0x00000000
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-final.log:829:[Sun Apr 26 07:53:18 2026] Modules linked in: vfio_pci vfio_pci_core vfio_iommu_type1 vfio iommufd tls udp_diag tcp_diag inet_diag nft_nat nft_redir xt_conntrack xt_MASQUERADE bridge stp llc xfrm_user xfrm_algo xt_set ip_set nft_chain_nat nf_nat nf_conntrack nf_defrag_ipv6 nf_defrag_ipv4 xt_addrtype nft_compat nf_tables qrtr overlay intel_rapl_msr intel_rapl_common cfg80211 intel_uncore_frequency_common binfmt_misc ppdev nls_iso8859_1 skx_edac_common nfit rapl i2c_i801 i2c_mux parport_pc i2c_smbus parport lpc_ich joydev input_leds mac_hid serio_raw sch_fq_codel dm_multipath msr efi_pstore nfnetlink dmi_sysfs qemu_fw_cfg ip_tables x_tables autofs4 btrfs blake2b_generic raid10 raid456 async_raid6_recov async_memcpy async_pq async_xor async_tx xor raid6_pq libcrc32c raid1 raid0 crct10dif_pclmul crc32_pclmul polyval_clmulni nvme polyval_generic bochs ghash_clmulni_intel drm_vram_helper sha256_ssse3 drm_ttm_helper ahci nvme_core sha1_ssse3 psmouse e1000 libahci ttm virtio_rng nvme_auth aesni_intel crypto_simd cryptd
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/action-stdout.log:286:localhost login: 
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:617:[Sat Apr 25 02:39:14 2026] nvme nvme0: pci function 0000:01:00.0
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:618:[Sat Apr 25 02:39:14 2026] nvme nvme1: pci function 0000:02:00.0
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:626:[Sat Apr 25 02:39:15 2026] nvme nvme1: 32/0/0 default/read/poll queues
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:627:[Sat Apr 25 02:39:15 2026] nvme nvme0: 32/0/0 default/read/poll queues
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:628:[Sat Apr 25 02:39:15 2026] nvme nvme1: Ignoring bogus Namespace Identifiers
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:629:[Sat Apr 25 02:39:15 2026] nvme nvme0: Ignoring bogus Namespace Identifiers
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:752:[Sun Apr 26 07:52:22 2026] VFIO - User Level meta-driver version: 0.3
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:755:[Sun Apr 26 07:53:18 2026] BUG: scheduling while atomic: crosvm_vcpu0/99825/0x00000002
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:756:[Sun Apr 26 07:53:18 2026] Modules linked in: vfio_pci vfio_pci_core vfio_iommu_type1 vfio iommufd tls udp_diag tcp_diag inet_diag nft_nat nft_redir xt_conntrack xt_MASQUERADE bridge stp llc xfrm_user xfrm_algo xt_set ip_set nft_chain_nat nf_nat nf_conntrack nf_defrag_ipv6 nf_defrag_ipv4 xt_addrtype nft_compat nf_tables qrtr overlay intel_rapl_msr intel_rapl_common cfg80211 intel_uncore_frequency_common binfmt_misc ppdev nls_iso8859_1 skx_edac_common nfit rapl i2c_i801 i2c_mux parport_pc i2c_smbus parport lpc_ich joydev input_leds mac_hid serio_raw sch_fq_codel dm_multipath msr efi_pstore nfnetlink dmi_sysfs qemu_fw_cfg ip_tables x_tables autofs4 btrfs blake2b_generic raid10 raid456 async_raid6_recov async_memcpy async_pq async_xor async_tx xor raid6_pq libcrc32c raid1 raid0 crct10dif_pclmul crc32_pclmul polyval_clmulni nvme polyval_generic bochs ghash_clmulni_intel drm_vram_helper sha256_ssse3 drm_ttm_helper ahci nvme_core sha1_ssse3 psmouse e1000 libahci ttm virtio_rng nvme_auth aesni_intel crypto_simd cryptd
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:828:[Sun Apr 26 07:53:18 2026] BUG: scheduling while atomic: crosvm_vcpu0/99825/0x00000000
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/host-dmesg-live.log:829:[Sun Apr 26 07:53:18 2026] Modules linked in: vfio_pci vfio_pci_core vfio_iommu_type1 vfio iommufd tls udp_diag tcp_diag inet_diag nft_nat nft_redir xt_conntrack xt_MASQUERADE bridge stp llc xfrm_user xfrm_algo xt_set ip_set nft_chain_nat nf_nat nf_conntrack nf_defrag_ipv6 nf_defrag_ipv4 xt_addrtype nft_compat nf_tables qrtr overlay intel_rapl_msr intel_rapl_common cfg80211 intel_uncore_frequency_common binfmt_misc ppdev nls_iso8859_1 skx_edac_common nfit rapl i2c_i801 i2c_mux parport_pc i2c_smbus parport lpc_ich joydev input_leds mac_hid serio_raw sch_fq_codel dm_multipath msr efi_pstore nfnetlink dmi_sysfs qemu_fw_cfg ip_tables x_tables autofs4 btrfs blake2b_generic raid10 raid456 async_raid6_recov async_memcpy async_pq async_xor async_tx xor raid6_pq libcrc32c raid1 raid0 crct10dif_pclmul crc32_pclmul polyval_clmulni nvme polyval_generic bochs ghash_clmulni_intel drm_vram_helper sha256_ssse3 drm_ttm_helper ahci nvme_core sha1_ssse3 psmouse e1000 libahci ttm virtio_rng nvme_auth aesni_intel crypto_simd cryptd
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260426-075239-T12-A1/logs/action-stderr.log:2:run-crosvm: enabling VFIO passthrough: 0000:01:00.0 (no virtual iommu, mapping all guest ram)
```

## 判断

本轮结果支持临时假设：禁用来宾侧 MSI 后，上一轮 protected VM + VFIO 中的 deny host BAR remap 加 raw_readl 加 general protection fault 没有再次出现，并且来宾进入登录提示。T12-A1 仍不能标为通过，因为 host 日志出现 BUG: scheduling while atomic，且 crosvm 被 timeout 杀掉后返回 -9。
