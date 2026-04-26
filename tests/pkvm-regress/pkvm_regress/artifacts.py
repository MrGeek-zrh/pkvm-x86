from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import StrEnum
from pathlib import Path


class RunStatus(StrEnum):
    RUNNING = "RUNNING"
    COMPLETE = "COMPLETE"
    FAILED = "FAILED"
    CRASHED_OR_INTERRUPTED = "CRASHED_OR_INTERRUPTED"


@dataclass(frozen=True)
class RunArtifact:
    run_id: str
    path: Path
    case_id: str

    @property
    def status_path(self) -> Path:
        return self.path / "status.json"

    @property
    def metadata_path(self) -> Path:
        return self.path / "metadata.json"

    @property
    def logs_dir(self) -> Path:
        return self.path / "logs"

    @property
    def trace_dir(self) -> Path:
        return self.path / "trace"

    @property
    def report_path(self) -> Path:
        return self.path / "report.md"

    @property
    def status(self) -> RunStatus:
        data = json.loads(self.status_path.read_text())
        return RunStatus(data["status"])

    def write_status(self, status: RunStatus) -> None:
        self.status_path.write_text(json.dumps({"status": status.value}, indent=2) + "\n")


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def build_run_id(case_id: str, timestamp: datetime | None = None) -> str:
    timestamp = timestamp or utc_now()
    safe_case = case_id.replace("/", "-")
    return f"t12-{timestamp:%Y%m%d-%H%M%S}-{safe_case}"


def create_run(root: Path, case_id: str, *, vfio_dev: str, timestamp: datetime | None = None) -> RunArtifact:
    timestamp = timestamp or utc_now()
    run_id = build_run_id(case_id, timestamp)
    path = root / run_id
    path.mkdir(parents=True, exist_ok=False)
    (path / "logs").mkdir()
    (path / "trace").mkdir()

    metadata = {
        "run_id": run_id,
        "case_id": case_id,
        "vfio_dev": vfio_dev,
        "created_at_utc": timestamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    artifact = RunArtifact(run_id=run_id, path=path, case_id=case_id)
    artifact.metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    artifact.write_status(RunStatus.RUNNING)
    return artifact


def _artifact_from_dir(path: Path) -> RunArtifact | None:
    metadata_path = path / "metadata.json"
    status_path = path / "status.json"
    if not metadata_path.is_file() or not status_path.is_file():
        return None
    metadata = json.loads(metadata_path.read_text())
    return RunArtifact(run_id=metadata["run_id"], path=path, case_id=metadata["case_id"])


def find_incomplete_runs(root: Path) -> list[RunArtifact]:
    if not root.exists():
        return []
    incomplete: list[RunArtifact] = []
    for child in sorted(root.iterdir()):
        if not child.is_dir():
            continue
        artifact = _artifact_from_dir(child)
        if artifact is None:
            continue
        if artifact.status == RunStatus.RUNNING:
            incomplete.append(artifact)
    return incomplete


def mark_incomplete_runs(root: Path) -> list[RunArtifact]:
    marked = find_incomplete_runs(root)
    for artifact in marked:
        artifact.write_status(RunStatus.CRASHED_OR_INTERRUPTED)
        artifact.report_path.write_text(
            "# Interrupted pKVM Regression Run\n\n"
            f"- Run: `{artifact.run_id}`\n"
            f"- Case: `{artifact.case_id}`\n"
            f"- Status: `{RunStatus.CRASHED_OR_INTERRUPTED.value}`\n\n"
            "This run was still marked RUNNING when recovery executed. "
            "Preserve logs in this directory and inspect host live logs first.\n"
        )
    return marked
