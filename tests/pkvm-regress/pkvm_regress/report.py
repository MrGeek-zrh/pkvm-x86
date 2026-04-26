from __future__ import annotations

from datetime import datetime, timezone
from typing import Iterable

from .registry import TestCase


def render_report_skeleton(
    *,
    cases: Iterable[TestCase],
    vfio_dev: str,
    pkvm_ia_commit: str = "",
    timestamp: datetime | None = None,
) -> str:
    timestamp = timestamp or datetime.now(timezone.utc)
    case_list = list(cases)
    lines: list[str] = [
        f"# T12 第一阶段测试记录 - {timestamp:%Y-%m-%d %H:%M:%S UTC}",
        "",
        "## 环境",
        "",
        "- `pkvm-x86` 提交：",
        "- `pKVM-IA` 分支：",
        f"- `pKVM-IA` 提交：{pkvm_ia_commit}",
        "- guest kernel：",
        "- crosvm：",
        f"- `VFIO_DEV`：{vfio_dev}",
        "",
        "## 执行用例",
        "",
        "| Case | 模式 | 优先级 | 结论 | 证据目录 |",
        "|---|---|---|---|---|",
    ]
    for case in case_list:
        lines.append(f"| {case.case_id} | {case.mode} | {case.priority} | PASS / FAIL / INCONCLUSIVE | |")
    lines.extend([
        "",
        "## 执行命令",
        "",
        "```bash",
        "# paste exact commands executed by Codex",
        "```",
        "",
        "## 关键日志",
        "",
        "```text",
        "# keep 3-10 original log lines for each key signature",
        "```",
        "",
        "## Codex 分析结论",
        "",
        "- 源码对照：",
        "- 现象判断：",
        "- 是否命中新签名：是 / 否",
        "",
        "## 后续动作",
        "",
        "- 是否需要新建 Bug issue：是 / 否",
        "- 是否需要新建 Task issue：是 / 否",
        "- 是否需要补 test hook：是 / 否",
    ])
    guarded = [case for case in case_list if case.guard]
    if guarded:
        lines.extend(["", "## Guard", ""])
        for case in guarded:
            lines.append(f"- `{case.case_id}`：{case.guard}")
    return "\n".join(lines) + "\n"
