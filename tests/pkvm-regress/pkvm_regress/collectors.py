from __future__ import annotations

from dataclasses import dataclass

from .artifacts import RunArtifact


@dataclass(frozen=True)
class CollectorCommand:
    name: str
    command: str
    output_path: str


@dataclass(frozen=True)
class CollectorPlan:
    collectors: tuple[CollectorCommand, ...]
    sync_command: str
    final_snapshot_commands: tuple[str, ...]


def shell_quote(path: object) -> str:
    text = str(path)
    return "'" + text.replace("'", "'\"'\"'") + "'"


def build_collector_plan(run: RunArtifact) -> CollectorPlan:
    dmesg_live = run.logs_dir / "host-dmesg-live.log"
    journal_live = run.logs_dir / "host-journal-live.log"
    dmesg_final = run.logs_dir / "host-dmesg-final.log"
    trace_snapshot = run.trace_dir / "trace-final.txt"

    collectors = (
        CollectorCommand(
            name="host-dmesg-live",
            command=f"sudo -n stdbuf -oL dmesg -wT >> {shell_quote(dmesg_live)}",
            output_path=str(dmesg_live),
        ),
        CollectorCommand(
            name="host-journal-live",
            command=f"sudo -n stdbuf -oL journalctl -kf >> {shell_quote(journal_live)}",
            output_path=str(journal_live),
        ),
    )
    final_snapshot_commands = (
        f"sudo -n dmesg -T > {shell_quote(dmesg_final)}",
        f"sudo -n cat /sys/kernel/tracing/trace > {shell_quote(trace_snapshot)} || true",
    )
    return CollectorPlan(
        collectors=collectors,
        sync_command="sync",
        final_snapshot_commands=final_snapshot_commands,
    )
