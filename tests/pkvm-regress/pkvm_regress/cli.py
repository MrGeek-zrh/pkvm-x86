from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .artifacts import create_run, mark_incomplete_runs
from .collectors import build_collector_plan
from .commands import build_case_plan
from .logscan import scan_forbidden_signatures, scan_required_patterns
from .registry import get_case, iter_cases
from .runner import run_shell_action
from .report import render_report_skeleton


def _print_case(case) -> None:
    print(f"{case.case_id}\t{case.priority}\t{case.mode}\t{case.title}")


def cmd_list(args: argparse.Namespace) -> int:
    for case in iter_cases(first_wave_only=args.first_wave):
        _print_case(case)
    return 0


def cmd_describe(args: argparse.Namespace) -> int:
    case = get_case(args.case_id)
    print(f"# {case.case_id} {case.title}")
    print(f"mode: {case.mode}")
    print(f"priority: {case.priority}")
    print(f"objective: {case.objective}")
    print(f"trigger: {case.trigger}")
    if case.guard:
        print(f"guard: {case.guard}")
    if case.miss_policy:
        print(f"miss_policy: {case.miss_policy}")
    print("pass_conditions:")
    for item in case.pass_conditions:
        print(f"  - {item}")
    print("fail_conditions:")
    for item in case.fail_conditions:
        print(f"  - {item}")
    return 0


def cmd_plan(args: argparse.Namespace) -> int:
    plan = build_case_plan(
        args.case_id,
        vfio_dev=args.vfio_dev,
        repo_root=args.repo_root,
        allow_host_bar_touch=args.allow_host_bar_touch,
    )
    print(f"# {plan.case_id} command plan")
    print("\n## commands")
    print("```bash")
    for command in plan.commands:
        print(command)
    print("```")
    if plan.required_patterns:
        print("\n## required patterns")
        for pattern in plan.required_patterns:
            print(f"- {pattern}")
    if plan.notes:
        print("\n## notes")
        for note in plan.notes:
            print(f"- {note}")
    return 0


def cmd_scan_log(args: argparse.Namespace) -> int:
    text = Path(args.log_file).read_text(errors="replace")
    forbidden = scan_forbidden_signatures(text)
    required = scan_required_patterns(text, args.require or [])
    if forbidden:
        print("forbidden signatures:")
        for finding in forbidden:
            print(f"{finding.line_no}: {finding.signature}: {finding.line}")
    if required.present:
        print("present required patterns:")
        for pattern in required.present:
            print(f"- {pattern}")
    if required.missing:
        print("missing required patterns:")
        for pattern in required.missing:
            print(f"- {pattern}")
    return 1 if forbidden or required.missing else 0


def cmd_report(args: argparse.Namespace) -> int:
    cases = [get_case(case_id) for case_id in args.case_id]
    report = render_report_skeleton(
        cases=cases,
        vfio_dev=args.vfio_dev,
        pkvm_ia_commit=args.pkvm_ia_commit,
    )
    if args.out:
        Path(args.out).write_text(report)
    else:
        print(report, end="")
    return 0


def cmd_prepare_run(args: argparse.Namespace) -> int:
    run = create_run(Path(args.artifacts_root), args.case_id, vfio_dev=args.vfio_dev)
    collector_plan = build_collector_plan(run)
    print(f"run_id: {run.run_id}")
    print(f"run_dir: {run.path}")
    print(f"status: {run.status.value}")
    print("\n# Start these collectors before risky actions")
    print("```bash")
    for collector in collector_plan.collectors:
        print(f"# {collector.name} -> {collector.output_path}")
        print(collector.command)
    print(collector_plan.sync_command)
    print("```")
    print("\n# Final snapshots if host survives")
    print("```bash")
    for command in collector_plan.final_snapshot_commands:
        print(command)
    print("```")
    return 0


def cmd_recover_runs(args: argparse.Namespace) -> int:
    marked = mark_incomplete_runs(Path(args.artifacts_root))
    if not marked:
        print("no incomplete runs found")
        return 0
    for run in marked:
        print(f"{run.run_id}: CRASHED_OR_INTERRUPTED ({run.path})")
    return 0


def cmd_run_shell(args: argparse.Namespace) -> int:
    if not args.command:
        print("error: run-shell requires a command after --", file=sys.stderr)
        return 2
    run = create_run(Path(args.artifacts_root), args.case_id, vfio_dev=args.vfio_dev)
    collector_plan = build_collector_plan(run)
    print(f"run_id: {run.run_id}")
    print(f"run_dir: {run.path}")
    print("collector_plan:")
    for collector in collector_plan.collectors:
        print(f"  {collector.name}: {collector.command}")
    print(f"  sync: {collector_plan.sync_command}")
    active_collectors = None if args.no_host_collectors else collector_plan
    try:
        result = run_shell_action(run, args.command, timeout_sec=args.timeout_sec, collector_plan=active_collectors)
    except TimeoutError as exc:
        print(f"timeout: {exc}", file=sys.stderr)
        return 124
    print(f"status: {run.status.value}")
    print(f"returncode: {result.returncode}")
    print(f"stdout: {result.stdout_path}")
    print(f"stderr: {result.stderr_path}")
    return result.returncode


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="pKVM T12 regression harness")
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="list known cases")
    list_parser.add_argument("--first-wave", action="store_true", help="only list first-wave cases")
    list_parser.set_defaults(func=cmd_list)

    describe_parser = subparsers.add_parser("describe", help="describe one case")
    describe_parser.add_argument("case_id")
    describe_parser.set_defaults(func=cmd_describe)

    plan_parser = subparsers.add_parser("plan", help="print a command plan for one case")
    plan_parser.add_argument("case_id")
    plan_parser.add_argument("--vfio-dev", default="0000:01:00.0")
    plan_parser.add_argument("--repo-root", default="/home/mrgeek/pkvm-x86")
    plan_parser.add_argument("--allow-host-bar-touch", action="store_true")
    plan_parser.set_defaults(func=cmd_plan)

    scan_parser = subparsers.add_parser("scan-log", help="scan a log for forbidden and required signatures")
    scan_parser.add_argument("log_file")
    scan_parser.add_argument("--require", action="append", default=[])
    scan_parser.set_defaults(func=cmd_scan_log)

    report_parser = subparsers.add_parser("report", help="render a markdown report skeleton")
    report_parser.add_argument("case_id", nargs="+")
    report_parser.add_argument("--vfio-dev", default="0000:01:00.0")
    report_parser.add_argument("--pkvm-ia-commit", default="")
    report_parser.add_argument("--out")
    report_parser.set_defaults(func=cmd_report)


    prepare_parser = subparsers.add_parser("prepare-run", help="create run artifacts and print collector commands")
    prepare_parser.add_argument("case_id")
    prepare_parser.add_argument("--artifacts-root", default="DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts")
    prepare_parser.add_argument("--vfio-dev", default="0000:01:00.0")
    prepare_parser.set_defaults(func=cmd_prepare_run)

    recover_parser = subparsers.add_parser("recover-runs", help="mark stale RUNNING artifacts as crashed/interrupted")
    recover_parser.add_argument("--artifacts-root", default="DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts")
    recover_parser.set_defaults(func=cmd_recover_runs)

    run_shell_parser = subparsers.add_parser("run-shell", help="create a run artifact and execute a command with log capture")
    run_shell_parser.add_argument("case_id")
    run_shell_parser.add_argument("--artifacts-root", default="DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/artifacts")
    run_shell_parser.add_argument("--vfio-dev", default="0000:01:00.0")
    run_shell_parser.add_argument("--timeout-sec", type=float)
    run_shell_parser.add_argument("--no-host-collectors", action="store_true", help="do not start live dmesg/journal collectors")
    run_shell_parser.set_defaults(func=cmd_run_shell)

    return parser


def main(argv: list[str] | None = None) -> int:
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    command_after_separator: list[str] | None = None
    if raw_argv and raw_argv[0] == "run-shell":
        if "--" in raw_argv:
            separator = raw_argv.index("--")
            command_after_separator = raw_argv[separator + 1:]
            raw_argv = raw_argv[:separator]
        else:
            command_after_separator = []
    parser = build_parser()
    args = parser.parse_args(raw_argv)
    if command_after_separator is not None:
        args.command = command_after_separator
    try:
        return args.func(args)
    except (KeyError, PermissionError, RuntimeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
