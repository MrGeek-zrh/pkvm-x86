# T12 第一阶段测试记录

## 基本信息

- 时间：2026-04-24 16:04:30 UTC
- 仓库：/home/mrgeek/pkvm-x86
- pKVM-IA commit：9f9531b5e36a
- 测试设备：0000:01:00.0
- 自动串口脚本：/tmp/pkvm_guest_run.py

## 执行记录

| Case | 运行目录 | 状态 | 关键现象 |
|---|---|---|---|
| T12-G2 | DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260424-154939-T12-G2 | COMPLETE | protected pVM 无 VFIO 到达 login，并正常 poweroff。|
| T12-G1 | DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260424-155701-T12-G1 | COMPLETE | normal VM + VFIO 到达 login，guest 内 /dev/nvme0n1 只读 direct I/O 返回 DD_RC=0，并正常 poweroff。|
| T12-A1 | DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts/t12-20260424-155744-T12-A1 | FAILED | protected VM + VFIO 未到达 login。host 日志出现 deny host BAR remap，随后出现 general protection fault。|

## T12-G2 证据摘要

stdout 中出现 login、LOGIN_OK 和 CROSVM_RC=0。该轮 host-dmesg-live.log 因 dmesg -wT 会带出既有 ring buffer，包含早于该轮的旧异常日志。因此该文件不能单独作为该轮新增 forbidden signature 判定来源。

## T12-G1 证据摘要

运行前把 0000:01:00.0 从 nvme 绑定到 vfio-pci。stdout 中出现 login、LOGIN_OK、DD_RC=0 和 CROSVM_RC=0。普通 VM + VFIO 基本路径通过。

## T12-A1 证据摘要

stdout 只出现 crosvm 启动和 ACPI notification 相关错误，未出现 login。host-dmesg-live.log 记录到 pkvm: deny host BAR remap gpa=0xfe80200c owner_id=1048575 raw_pte=0xfffff000，随后记录 Oops: general protection fault。该现象满足失败条件中的 guest 早期失败和 forbidden signature。

## 后续状态

T12-A1 触发 host Oops 后，测试机建议重启后再继续后续用例。当前记录保留 run-shell 生成的 stdout、stderr、host dmesg live、host journal live 和 final snapshot。
