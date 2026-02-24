# 验证: 普通 VM 场景下 Host 可读取 Guest 明文内存

## 验证结论

在普通 VM (`PROTECTED=0`) 场景下, Host 可通过 attach 到 `crosvm` 进程, 在其 `/memfd:crosvm_guest` 映射中直接读取 Guest 内存明文. 本次测试成功在 crosvm 进程内存中搜索并读出 Guest 写入的 `SECRET`, 证明 Host/VMM 能直接访问 guest RAM 明文.

---

## 1. 启动普通 VM

```bash
sudo PROTECTED=0 bash ./scripts/run-crosvm.sh
```

> 注：`PROTECTED=0` 表示未启用 protected VM 特性。

---

## 2. Guest 侧: 写入测试数据

### 2.1 生成并写入 SECRET

本次测试使用 NONCE: `2026-02-06-01`

在 Guest 终端执行以下命令, 向内存写入 256MB 重复的 SECRET 模式:

```bash
NONCE="2026-02-06-01" python3 - <<'PY'
import hashlib, os, sys, time

nonce = os.environ["NONCE"].encode()
secret = hashlib.sha256(b"PKVMTEST:" + nonce).hexdigest().encode()
print("GUEST_SECRET=" + secret.decode(), file=sys.stderr, flush=True)

sz = 256 * 1024 * 1024  # 256MB
buf = bytearray(sz)
pat = secret + b"|"
for i in range(0, len(buf), len(pat)):
    buf[i:i+len(pat)] = pat[:min(len(pat), len(buf)-i)]

print("READY. Now run host-side gdb find, then press Enter here.", file=sys.stderr, flush=True)
open("/dev/tty","r").readline()
print("DONE", flush=True)
time.sleep(1)
PY
```

> **重要**: 看到 `READY` 提示后, 保持 Guest 进程运行, 不要按回车, 等待 Host 侧完成搜索.

### 2.2 计算 SECRET 值

SECRET 生成公式: `sha256("PKVMTEST:" + NONCE)`

本次测试的 SECRET 值为:

```text
cb0a71204de8ad7488726bd2f87aceec0165408267b2143bd93b761d0746205b
```

Host 侧可用以下命令独立计算 (用于后续 gdb 搜索):

```bash
NONCE="2026-02-06-01"
SECRET="$(NONCE="$NONCE" python3 - <<'PY'
import hashlib, os
nonce = os.environ["NONCE"].encode()
print(hashlib.sha256(b"PKVMTEST:" + nonce).hexdigest())
PY
)"
echo "$SECRET"
```

---

## 3. Host 侧: 定位 crosvm 进程

### 3.1 查找 crosvm 进程 PID

```bash
ps -ef | rg -n "crosvm.*run" | head
```

输出示例:

```text
406:root       56610   56606 ... /home/mrgeek/pkvm-x86/crosvm/target/debug/crosvm --log-level=debug run ...
409:root       56614   56610 ... /home/mrgeek/pkvm-x86/crosvm/target/debug/crosvm --log-level=debug run ...
```

一般是最终的parent是所需要的。本次测试使用 PID: `56610`

### 3.2 查看 guest RAM 映射

```bash
PID=56610
sudo rg -n "memfd:crosvm_guest" /proc/"$PID"/maps
```

输出示例:

```text
47:7695acc60000-7695dcc60000 rw-s d0000000 ... /memfd:crosvm_guest (deleted)
48:7695dcc60000-7696acb60000 rw-s 00100000 ... /memfd:crosvm_guest (deleted)
49:7696acb60000-7696acc00000 rw-s 00000000 ... /memfd:crosvm_guest (deleted)
69:7696ace23000-7696ace83000 rw-s 000a0000 ... /memfd:crosvm_guest (deleted)
```

> 注: `/memfd:crosvm_guest` 是 crosvm 用于承载 guest RAM 的 memfd 映射, 可能分成多段.

---

## 4. Host 侧: 搜索并读取 SECRET

### 4.1 在内存中搜索 SECRET

在第一个映射区间 `0x7695acc60000-0x7695dcc60000` 内搜索:

```bash
sudo gdb -q -p "$PID" \
  -ex 'set pagination off' \
  -ex 'find 0x7695acc60000, 0x7695dcc60000, "cb0a71204de8ad7488726bd2f87aceec0165408267b2143bd93b761d0746205b"' \
  -ex 'detach' -ex 'quit'
```

输出:

```text
0x7695b66ce1d0
1 pattern found.
```

### 4.2 读取找到的地址内容

```bash
sudo gdb -q -p 56610 \
  -ex 'set pagination off' \
  -ex 'x/s 0x7695b66ce1d0' \
  -ex 'detach' -ex 'quit'
```

输出:

```text
0x7695b66ce1d0: "cb0a71204de8ad7488726bd2f87aceec0165408267b2143bd93b761d0746205b"
```

**验证成功**: 在 crosvm 进程虚拟地址空间的 `0x7695b66ce1d0` 处成功读取到 Guest 写入的明文 SECRET.

---

## 5. 结论与对比


| 场景                           | 预期结果                                | 本次验证   |
| ---------------------------- | ----------------------------------- | ------ |
| 普通 VM (`PROTECTED=0`)        | Host 可在 `/memfd:crosvm_guest` 中读取明文 | ✅ 符合预期 |
| Protected VM (`PROTECTED=1`) | Host 无法读取明文 (需单独验证)                 | 待测试    |

### 5.1 pVM 场景下的 Host dmesg 证据（gdb 扫描触发 EPT violation/GPF）

在开启 `PROTECTED=1`（pVM）后，Host 侧对 crosvm 进程内存执行 gdb 扫描/读取（例如 `find`）期间，Host `dmesg` 观测到如下日志（完整记录）：

```text
[    6.400189] bridge: filtering via arp/ip/ip6tables is no longer available by default. Update your scripts to load br_netfilter if you need this.
[   17.950829] systemd-journald[596]: /var/log/journal/9dce3dfe526f4a8cb553b21502da7d2a/user-1000.journal: Journal file uses a different sequence number ID, rotating.
[ 7944.112324] handle_host_ept_violation: not handle for memory address 0x44b888000
[ 7944.113104] pkvm: handle host ept violation failed
[ 7944.113581] Oops: general protection fault, maybe for address 0xff4944110b888000: 0000 [#1] PREEMPT SMP NOPTI
[ 7944.114597] CPU: 3 UID: 0 PID: 68586 Comm: gdb Tainted: G S                 6.12.0-pkvm-ia #31
[ 7944.115368] Tainted: [S]=CPU_OUT_OF_SPEC
[ 7944.115758] Hardware name: QEMU Standard PC (Q35 + ICH9, 2009), BIOS 1.16.3-debian-1.16.3-2 04/01/2014
[ 7944.116574] RIP: 0010:__access_remote_vm+0x2b6/0x400
[ 7944.117047] Code: 01 c5 45 85 e4 0f 85 12 fe ff ff 8b 45 c0 45 89 fc 41 29 c4 0f 1f 44 00 00 48 8b 7d a8 e8 42 bd d6 ff 44 89 e0 e9 ee fe ff ff <48> 8b 06 49 8d 7f 08 48 83 e7 f8 49 89 07 44 89 c0 48 8b 4c 06 f8
[ 7944.119196] RSP: 0018:ff60879d65cdb978 EFLAGS: 00010212
[ 7944.119657] RAX: 0000000000000000 RBX: ff49440dc811bc80 RCX: 0000000000001000
[ 7944.120447] RDX: ffc87cc8d12e2200 RSI: ff4944110b888000 RDI: 0000000000000000
[ 7944.121071] RBP: ff60879d65cdb9e0 R08: 0000000000001000 R09: 0000000000000000
[ 7944.121658] R10: 0000000000000000 R11: 0000000000000000 R12: 0000000000000000
[ 7944.122239] R13: 0000757af7177000 R14: 0000000000000008 R15: ff49440dd7e86000
[ 7944.122826] FS:  000071649e7071c0(0000) GS:ff4944121a580000(0000) knlGS:0000000000000000
[ 7944.123487] CS:  0010 DS: 0000 ES: 0000 CR0: 0000000080050033
[ 7944.123965] CR2: 000071649fee4da8 CR3: 000000033b69e006 CR4: 0000000000771ef0
[ 7944.124546] DR0: 0000000000000000 DR1: 0000000000000000 DR2: 0000000000000000
[ 7944.125133] DR3: 0000000000000000 DR6: 00000000fffe07f0 DR7: 0000000000000400
[ 7944.125724] PKRU: 55555554
[ 7944.125958] Call Trace:
[ 7944.126177]  <TASK>
[ 7944.126374]  ? show_regs+0x6c/0x80
[ 7944.126671]  ? die_addr+0x37/0xa0
[ 7944.126954]  ? exc_general_protection+0x1d2/0x400
[ 7944.127339]  ? asm_exc_general_protection+0x27/0x30
[ 7944.127756]  ? __access_remote_vm+0x2b6/0x400
[ 7944.128123]  ? __access_remote_vm+0xe9/0x400
[ 7944.128487]  access_remote_vm+0xe/0x20
[ 7944.128794]  mem_rw+0x139/0x2e0
[ 7944.129070]  mem_read+0x11/0x30
[ 7944.129333]  vfs_read+0xf9/0x380
[ 7944.129610]  ? fput+0xf0/0x150
[ 7944.129881]  __x64_sys_pread64+0xa6/0xd0
[ 7944.130245]  x64_sys_call+0x1ee1/0x25f0
[ 7944.130624]  do_syscall_64+0x7e/0x170
[ 7944.130993]  ? __mod_memcg_lruvec_state+0xec/0x210
[ 7944.131460]  ? xas_find+0x74/0x1e0
[ 7944.131809]  ? next_uptodate_folio+0xaa/0x370
[ 7944.132225]  ? filemap_map_pages+0x574/0x6e0
[ 7944.132631]  ? do_syscall_64+0x8a/0x170
[ 7944.133005]  ? do_fault+0x2aa/0x500
[ 7944.133351]  ? __handle_mm_fault+0x824/0x10a0
[ 7944.133772]  ? __count_memcg_events+0x85/0x160
[ 7944.134186]  ? count_memcg_events.constprop.0+0x2a/0x50
[ 7944.134661]  ? handle_mm_fault+0xaf/0x2e0
[ 7944.135383]  ? do_user_addr_fault+0x5d5/0x870
[ 7944.136000]  ? irqentry_exit_to_user_mode+0x43/0x250
[ 7944.136660]  ? irqentry_exit+0x43/0x50
[ 7944.137246]  ? clear_bhb_loop+0x30/0x80
[ 7944.137792]  ? clear_bhb_loop+0x30/0x80
[ 7944.138332]  ? clear_bhb_loop+0x30/0x80
[ 7944.138856]  entry_SYSCALL_64_after_hwframe+0x76/0x7e
[ 7944.139476] RIP: 0033:0x71649f6fa4b5
[ 7944.139976] Code: e8 48 89 75 f0 89 7d f8 48 89 4d e0 e8 b4 e0 f9 ff 4c 8b 55 e0 48 8b 55 e8 41 89 c0 48 8b 75 f0 8b 7d f8 b8 11 00 00 00 0f 05 <48> 3d 00 f0 ff ff 77 2b 44 89 c7 48 89 45 f8 e8 07 e1 f9 ff 48 8b
[ 7944.141893] RSP: 002b:00007ffe24d77300 EFLAGS: 00000293 ORIG_RAX: 0000000000000011
[ 7944.142709] RAX: ffffffffffffffda RBX: 000000000000000b RCX: 000071649f6fa4b5
[ 7944.143493] RDX: 0000000000003ec0 RSI: 000063d92b7c5450 RDI: 000000000000000b
[ 7944.144285] RBP: 00007ffe24d77320 R08: 0000000000000000 R09: 0000000000003ec0
[ 7944.145064] R10: 0000757af7177000 R11: 0000000000000293 R12: 000063d92b7c5450
[ 7944.145850] R13: 0000000000003ec0 R14: 0000000000000000 R15: 000063d9022693c0
[ 7944.146648]  </TASK>
[ 7944.147043] Modules linked in: tcp_diag udp_diag inet_diag tls xt_conntrack xt_MASQUERADE bridge stp llc xfrm_user xfrm_algo xt_set ip_set nft_chain_nat nf_nat nf_conntrack nf_defrag_ipv6 nf_defrag_ipv4 xt_addrtype nft_compat nf_tables qrtr overlay intel_rapl_msr intel_rapl_common cfg80211 intel_uncore_frequency_common binfmt_misc nls_iso8859_1 ppdev skx_edac_common nfit rapl parport_pc i2c_i801 i2c_mux parport i2c_smbus lpc_ich joydev input_leds mac_hid serio_raw sch_fq_codel dm_multipath msr efi_pstore nfnetlink dmi_sysfs qemu_fw_cfg ip_tables x_tables autofs4 btrfs blake2b_generic raid10 raid456 async_raid6_recov async_memcpy async_pq async_xor async_tx xor raid6_pq libcrc32c raid1 raid0 crct10dif_pclmul crc32_pclmul polyval_clmulni polyval_generic ghash_clmulni_intel bochs drm_vram_helper sha256_ssse3 drm_ttm_helper sha1_ssse3 ahci psmouse virtio_rng e1000 libahci ttm aesni_intel crypto_simd cryptd
[ 7944.155044] ---[ end trace 0000000000000000 ]---
[ 7944.155630] RIP: 0010:__access_remote_vm+0x2b6/0x400
[ 7944.156257] Code: 01 c5 45 85 e4 0f 85 12 fe ff ff 8b 45 c0 45 89 fc 41 29 c4 0f 1f 44 00 00 48 8b 7d a8 e8 42 bd d6 ff 44 89 e0 e9 ee fe ff ff <48> 8b 06 49 8d 7f 08 48 83 e7 f8 49 89 07 44 89 c0 48 8b 4c 06 f8
[ 7944.158482] RSP: 0018:ff60879d65cdb978 EFLAGS: 00010212
[ 7944.159180] RAX: 0000000000000000 RBX: ff49440dc811bc80 RCX: 0000000000001000
[ 7944.159972] RDX: ffc87cc8d12e2200 RSI: ff4944110b888000 RDI: 0000000000000000
[ 7944.160805] RBP: ff60879d65cdb9e0 R08: 0000000000001000 R09: 0000000000000000
[ 7944.161650] R10: 0000000000000000 R11: 0000000000000000 R12: 0000000000000000
[ 7944.162649] R13: 0000757af7177000 R14: 0000000000000008 R15: ff49440dd7e86000
[ 7944.163470] FS:  000071649e7071c0(0000) GS:ff4944121a580000(0000) knlGS:0000000000000000
[ 7944.164372] CS:  0010 DS: 0000 ES: 0000 CR0: 0000000080050033
[ 7944.165198] CR2: 000071649fee4da8 CR3: 000000033b69e006 CR4: 0000000000771ef0
[ 7944.166047] DR0: 0000000000000000 DR1: 0000000000000000 DR2: 0000000000000000
[ 7944.166857] DR3: 0000000000000000 DR6: 00000000fffe07f0 DR7: 0000000000000400
[ 7944.167683] PKRU: 55555554
```

备注：
- `handle_host_ept_violation: not handle for memory address ...` / `pkvm: handle host ept violation failed` 对应 pKVM 的 Host EPT violation 处理路径（详见 `DOCS/分析文档/pkvm-x86-pVM内存保护关键调用链-donate与Host-EPT-violation.md`）。
- 该日志可作为“pVM 场景下 Host 侧尝试直接读取/线性扫描 guest RAM 明文会失败（甚至触发 GPF/Oops）”的佐证。

本次验证证明: 在普通 VM 场景下, Host/VMM 能够直接访问 guest RAM 明文内容. 后续需对 protected VM 场景进行对照测试, 验证其内存隔离保护是否生效.
