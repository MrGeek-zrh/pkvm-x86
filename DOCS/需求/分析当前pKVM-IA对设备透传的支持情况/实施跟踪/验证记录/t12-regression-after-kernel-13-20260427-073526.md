# T12 回归测试记录

## 基本信息

| 字段 | 内容 |
|---|---|
| 时间 | 2026-04-27 07:35:26 UTC 到 2026-04-27 07:40:50 UTC |
| Host 内核 | Linux ubuntu-vm 6.12.0-pkvm-ia #13 SMP PREEMPT_DYNAMIC Mon Apr 27 07:12:51 UTC 2026 x86_64 |
| 仓库提交 | 40de78f |
| pKVM-IA 提交 | a1b02bd8c012 |
| 测试设备 | 0000:01:00.0 |
| 运行工具 | tests/pkvm-regress/pkvm-regress.py run-shell |

## 用例结果

| 用例 | 运行目录 | 状态 | 观察 |
|---|---|---|---|
| T12-G2 | artifacts/t12-20260427-073526-T12-G2 | COMPLETE | protected pVM 无 VFIO 到达 login，并正常关机。 |
| T12-G1 | artifacts/t12-20260427-073556-T12-G1 | COMPLETE | normal VM + VFIO 到达 login，guest 内 /dev/nvme0n1 只读 direct I/O 返回 DD_RC=0。 |
| T12-A1 | artifacts/t12-20260427-073626-T12-A1 | COMPLETE | protected VM + VFIO 到达 login，guest 内 /dev/nvme0n1 只读 direct I/O 返回 DD_RC=0。 |
| T12-G3 round 1 | artifacts/t12-20260427-073726-T12-G3 | COMPLETE | protected VM + VFIO 重复启动第 1 轮完成 login、I/O 和关机。 |
| T12-G3 round 2 | artifacts/t12-20260427-073832-T12-G3 | COMPLETE | protected VM + VFIO 重复启动第 2 轮完成 login、I/O 和关机。 |
| T12-G3 round 3 | artifacts/t12-20260427-073941-T12-G3 | COMPLETE | protected VM + VFIO 重复启动第 3 轮完成 login、I/O 和关机。 |

## 日志检查

| 检查项 | 结果 |
|---|---|
| guest 登录 | 六个运行目录均出现 LOGIN_OK。 |
| guest I/O | G1、A1、G3 三轮均出现 DD_RC=0。G2 无 VFIO，因此未执行 NVMe I/O。 |
| crosvm 退出 | 六个运行目录均出现 CROSVM_RC=0。 |
| 旧故障签名 | 六个运行目录均未出现 pkvm: deny host BAR remap、general protection fault、kernel panic、RCU stall、soft lockup、DMA Read NO_PASID、PTE Read access is not set、do_donate failed。 |
| ptdev BAR revoked 日志 | 本轮仍未出现该字符串。当前 pKVM-IA 源码也没有该精确字符串。 |

## 单元测试

`python3 -m unittest discover -s tests/pkvm-regress/tests -v` 运行 23 个测试，结果为 OK。

## 覆盖说明

本轮执行了非破坏性回归。T12-A2b 需要主动触碰 host BAR，所以本轮没有执行。T12-B1、T12-C1、T12-R2 的完整判据需要额外 trace 或状态探针。本轮只用 guest 登录、只读 I/O、正常关机和三轮重复启动给出有限证据。

## 收尾状态

测试结束后，0000:01:00.0 已恢复到 nvme 驱动。远端没有遗留 crosvm 进程。
