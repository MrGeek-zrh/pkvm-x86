from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .artifacts import RunArtifact, RunStatus
from .collectors import CollectorPlan


@dataclass(frozen=True)
class ActionResult:
    returncode: int
    stdout_path: Path
    stderr_path: Path
    result_path: Path


def _utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_result(run: RunArtifact, *, command: list[str], returncode: int, status: RunStatus) -> Path:
    result_path = run.path / "result.json"
    result_path.write_text(
        json.dumps(
            {
                "command": command,
                "finished_at_utc": _utc_timestamp(),
                "returncode": returncode,
                "status": status.value,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    return result_path


def _start_collectors(run: RunArtifact, collector_plan: CollectorPlan | None) -> list[tuple[str, subprocess.Popen]]:
    if collector_plan is None:
        return []
    processes: list[tuple[str, subprocess.Popen]] = []
    for collector in collector_plan.collectors:
        process = subprocess.Popen(
            collector.command,
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        processes.append((collector.name, process))
    deadline = time.monotonic() + 2.0
    output_paths = [Path(collector.output_path) for collector in collector_plan.collectors]
    while output_paths and time.monotonic() < deadline:
        if any(process.poll() is not None for _, process in processes):
            break
        if all(path.exists() for path in output_paths):
            break
        time.sleep(0.05)
    for name, process in processes:
        returncode = process.poll()
        if returncode is not None:
            message = f"collector {name} exited early with rc={returncode}"
            (run.logs_dir / "runner-error.log").write_text(message + "\n")
            run.write_status(RunStatus.FAILED)
            _stop_collectors(processes)
            raise RuntimeError(message)
    subprocess.run(collector_plan.sync_command, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return processes


def _stop_collectors(processes: list[tuple[str, subprocess.Popen]]) -> None:
    for _, process in processes:
        if process.poll() is None:
            process.terminate()
    for _, process in processes:
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


def _run_final_snapshots(collector_plan: CollectorPlan | None) -> None:
    if collector_plan is None:
        return
    for command in collector_plan.final_snapshot_commands:
        subprocess.run(command, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def run_shell_action(
    run: RunArtifact,
    command: list[str],
    *,
    timeout_sec: float | None = None,
    collector_plan: CollectorPlan | None = None,
) -> ActionResult:
    stdout_path = run.logs_dir / "action-stdout.log"
    stderr_path = run.logs_dir / "action-stderr.log"
    runner_error_path = run.logs_dir / "runner-error.log"

    collectors = _start_collectors(run, collector_plan)
    try:
        with stdout_path.open("w") as stdout_file, stderr_path.open("w") as stderr_file:
            try:
                completed = subprocess.run(
                    command,
                    stdout=stdout_file,
                    stderr=stderr_file,
                    text=True,
                    timeout=timeout_sec,
                    check=False,
                )
            except subprocess.TimeoutExpired as exc:
                runner_error_path.write_text(
                    f"timeout while running command at {_utc_timestamp()}\n"
                    f"command: {command!r}\n"
                    f"timeout_sec: {timeout_sec}\n"
                )
                raise TimeoutError(str(exc)) from exc
        _run_final_snapshots(collector_plan)
    finally:
        _stop_collectors(collectors)

    status = RunStatus.COMPLETE if completed.returncode == 0 else RunStatus.FAILED
    run.write_status(status)
    result_path = _write_result(run, command=command, returncode=completed.returncode, status=status)
    return ActionResult(
        returncode=completed.returncode,
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        result_path=result_path,
    )
