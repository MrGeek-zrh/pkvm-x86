# pKVM T12 Regression Harness

本目录是 `T12 / B5-3` 第一阶段测试工具的最小实现，目标是先把测试用例、判据、日志扫描和执行计划固化下来，再逐步扩展到串口驱动的端到端运行。

## 当前能力

- 列出 T12 第一阶段 case registry。
- 为 case 生成命令计划，区分 `scripted`、`agent-runbook`、`fault-injection-required`。
- 对 host / guest 日志扫描 forbidden signature。
- 生成 Markdown 验证记录骨架。
- 对 `T12-A2b` 这类 host BAR touch injection 默认加 guard，必须显式传 `--allow-host-bar-touch` 才会输出触发计划。
- `run-shell` 会创建 run artifact、启动 live collectors、执行 action，并把 stdout/stderr 落到本轮 `logs/`。

## 用法

列出第一轮建议执行的 case：

```bash
python3 tests/pkvm-regress/pkvm-regress.py list --first-wave
```

查看 case 详情：

```bash
python3 tests/pkvm-regress/pkvm-regress.py describe T12-A2b
```

生成某个 case 的命令计划：

```bash
python3 tests/pkvm-regress/pkvm-regress.py plan T12-A1 --vfio-dev 0000:01:00.0
```

生成 host BAR touch injection 的命令计划：

```bash
python3 tests/pkvm-regress/pkvm-regress.py plan T12-A2b --vfio-dev 0000:01:00.0 --allow-host-bar-touch
```


通过 runner 执行一个命令，并自动保全 Host live logs：

```bash
python3 tests/pkvm-regress/pkvm-regress.py run-shell T12-A1 \
  --vfio-dev 0000:01:00.0 \
  --artifacts-root DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts \
  -- sudo -n env PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

仅在单元测试或明确不需要 Host live collectors 的低风险命令中使用：

```bash
python3 tests/pkvm-regress/pkvm-regress.py run-shell T12-A1 --no-host-collectors -- echo smoke
```

扫描日志：

```bash
python3 tests/pkvm-regress/pkvm-regress.py scan-log /path/to/host-dmesg.log --require 'ptdev BAR revoked'
```

生成验证记录骨架：

```bash
python3 tests/pkvm-regress/pkvm-regress.py report T12-A1 T12-B1 T12-R1 \
  --vfio-dev 0000:01:00.0 \
  --pkvm-ia-commit 9f9531b5e36a \
  --out DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t12-phase1-testcases-$(date -u +%Y%m%d-%H%M%S).md
```

## 单元测试

```bash
python3 -m unittest discover -s tests/pkvm-regress/tests -v
```

## 后续扩展

- 增加串口 runner：启动 `scripts/run-crosvm.sh`、等待 `login:`、发送 guest 命令、保存 crosvm log。
- 增加 host trace helper wrapper：自动启动/停止 T11 host trace 并归档 summary。
- 增加 case result evaluator：把命令计划、日志扫描和人工/agent 分析合并成 `PASS / FAIL / INCONCLUSIVE`。

## 崩溃前日志保全

Host 内核可能在风险 case 中直接 panic，因此日志收集必须先于风险动作启动。

准备 run 目录并输出 live collector 命令：

```bash
python3 tests/pkvm-regress/pkvm-regress.py prepare-run T12-A2b \
  --vfio-dev 0000:01:00.0 \
  --artifacts-root DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts
```

该命令会先创建：

```text
artifacts/<run-id>/
  metadata.json
  status.json                  # 初始 RUNNING
  logs/host-dmesg-live.log
  logs/host-journal-live.log
  trace/trace-final.txt
  report.md                    # recovery 时生成
```

执行风险动作前，应先启动输出中的 `host-dmesg-live` 和 `host-journal-live` collector，并执行 `sync`。如果 Host panic 后无法正常收尾，下一次启动后先运行：

```bash
python3 tests/pkvm-regress/pkvm-regress.py recover-runs \
  --artifacts-root DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts
```

它会把仍处于 `RUNNING` 的 run 标记为 `CRASHED_OR_INTERRUPTED`，并保留已落盘的 live logs 作为后续 Bug issue / 问题记录证据入口。
