from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .logscan import FORBIDDEN_SIGNATURES
from .registry import get_case

DEFAULT_REPO_ROOT = Path("/home/mrgeek/pkvm-x86")
DEFAULT_VFIO_DEV = "0000:01:00.0"


@dataclass(frozen=True)
class CasePlan:
    case_id: str
    commands: tuple[str, ...]
    required_patterns: tuple[str, ...]
    forbidden_signatures: tuple[str, ...] = FORBIDDEN_SIGNATURES
    notes: tuple[str, ...] = ()


def _run_crosvm_cmd(*, repo_root: Path, protected: bool, vfio_dev: str | None) -> str:
    env = [f"PROTECTED={1 if protected else 0}", "SETUP_NET=0"]
    if vfio_dev:
        env.append(f"VFIO_DEV={vfio_dev}")
    return f"cd {repo_root} && sudo -n env {' '.join(env)} ./scripts/run-crosvm.sh"


def build_case_plan(
    case_id: str,
    *,
    vfio_dev: str = DEFAULT_VFIO_DEV,
    repo_root: str | Path = DEFAULT_REPO_ROOT,
    allow_host_bar_touch: bool = False,
) -> CasePlan:
    case = get_case(case_id)
    repo = Path(repo_root)

    if case.requires_allow_host_bar_touch and not allow_host_bar_touch:
        raise PermissionError(f"{case_id} requires --allow-host-bar-touch")

    if case_id == "T12-G2":
        return CasePlan(
            case_id=case_id,
            commands=(
                "date -u '+%F %T'",
                _run_crosvm_cmd(repo_root=repo, protected=True, vfio_dev=None),
                "sudo -n dmesg -T | grep -E 'ptdev BAR revoked|ptdev BAR restored|deny host BAR remap|pkvm: exception|DMAR|IOMMU|soft lockup|RCU stall|BUG:' || true",
            ),
            required_patterns=("login:",),
            notes=("无 VFIO baseline 不应出现 ptdev BAR revoked/restored/deny 日志。",),
        )

    if case_id == "T12-G1":
        return CasePlan(
            case_id=case_id,
            commands=(
                "date -u '+%F %T'",
                _run_crosvm_cmd(repo_root=repo, protected=False, vfio_dev=vfio_dev),
                "sudo -n dmesg -T | grep -E 'reject bdf|ptdev BAR revoked|deny host BAR remap|pkvm: exception|DMAR|IOMMU|soft lockup|RCU stall|BUG:' || true",
            ),
            required_patterns=("login:",),
            notes=("普通 VM + VFIO 不应被 protected-only BAR owner 逻辑误伤。",),
        )

    if case_id == "T12-A1":
        return CasePlan(
            case_id=case_id,
            commands=(
                "date -u '+%F %T'",
                _run_crosvm_cmd(repo_root=repo, protected=True, vfio_dev=vfio_dev),
                "sudo -n dmesg -T | grep -E 'ptdev BAR revoked|pkvm: exception|DMAR|IOMMU|soft lockup|RCU stall|BUG:'",
            ),
            required_patterns=("ptdev BAR revoked", "login:"),
        )

    if case_id == "T12-B1":
        return CasePlan(
            case_id=case_id,
            commands=(
                "# Host: sudo bash DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t11-p1-nvme-mmio-dma-trace-helper/host-trace.sh start --out-dir /tmp/t11-host",
                "# Guest: sudo bash guest-trace.sh --dev /dev/nvme0n1 --count 64 --bs 4096 --out-dir /tmp/t11-guest",
                "# Guest fallback: dd if=/dev/nvme0n1 of=/dev/null bs=4M count=8 iflag=direct status=none",
                "# Host: sudo bash host-trace.sh stop --out-dir /tmp/t11-host",
            ),
            required_patterns=("pkvmdma_guest_direct_mmio_write", "pkvmdma_guest_dma_map", "pkvmdma_host_sev_mmio_write=0"),
            notes=("这是 agent-runbook case，命令需要按现场路径执行并归档 summary。",),
        )

    if case_id == "T12-R1":
        return CasePlan(
            case_id=case_id,
            commands=(
                "# Guest: printf '\\n' | sudo -S poweroff -f",
                "sudo -n dmesg -T | grep -E 'ptdev BAR restored|detach ptdev restore failed|pkvm: exception|DMAR|IOMMU|soft lockup|RCU stall|BUG:'",
            ),
            required_patterns=("ptdev BAR restored",),
        )

    if case_id == "T12-G3":
        return CasePlan(
            case_id=case_id,
            commands=(
                "for i in 1 2 3; do",
                f"  echo T12-G3 round=$i",
                f"  cd {repo} && sudo -n env PROTECTED=1 SETUP_NET=0 VFIO_DEV={vfio_dev} ./scripts/run-crosvm.sh",
                "  sudo -n dmesg -T | grep -E 'ptdev BAR revoked|ptdev BAR restored|pkvm: exception|DMAR|IOMMU|soft lockup|RCU stall|BUG:' || true",
                "done",
            ),
            required_patterns=("ptdev BAR revoked", "ptdev BAR restored"),
            notes=("每轮应单独保存日志；这个 plan 只给出执行骨架。",),
        )

    if case_id == "T12-A2a":
        return CasePlan(
            case_id=case_id,
            commands=(
                "sudo -n dmesg -T | grep -E 'deny host BAR remap|ptdev BAR revoked|ptdev BAR restored|pkvm: exception|DMAR|IOMMU|soft lockup|RCU stall|BUG:' || true",
            ),
            required_patterns=("deny host BAR remap",),
            notes=("未自然触发 deny host BAR remap 时记录为 INCONCLUSIVE，不判 FAIL。",),
        )

    if case_id == "T12-A2b":
        resource_base = f"/sys/bus/pci/devices/{vfio_dev}/resource"
        return CasePlan(
            case_id=case_id,
            commands=(
                f"BDF={vfio_dev}",
                "RESOURCE_N=${RESOURCE_N:-0}",
                f"cat {resource_base}",
                f"sudo -n dd if={resource_base}$RESOURCE_N of=/dev/null bs=4 count=1 status=none",
                "sudo -n dmesg -T | grep -E 'deny host BAR remap|pkvm: exception|DMAR|IOMMU|soft lockup|RCU stall|BUG:'",
                "# Guest after injection: dd if=/dev/nvme0n1 of=/dev/null bs=4M count=8 iflag=direct status=none",
            ),
            required_patterns=("deny host BAR remap",),
            notes=("危险的是主动 host BAR touch 测试手段；执行前必须确认 resourceN 对应受管理 memory BAR。",),
        )

    if case_id in {"T12-C1", "T12-R2"}:
        return CasePlan(
            case_id=case_id,
            commands=(
                "# agent-runbook: 启动 host trace / guest trace，按源码锚点核对 A/C/B 或 withdraw/restore 顺序。",
                "sudo -n dmesg -T | grep -E 'ptdev BAR revoked|ptdev BAR restored|deny host BAR remap|pkvm: exception|DMAR|IOMMU|soft lockup|RCU stall|BUG:' || true",
            ),
            required_patterns=("ptdev BAR revoked",),
            notes=("需要 Codex 结合 trace、日志和源码进行判断。",),
        )

    return CasePlan(
        case_id=case_id,
        commands=("# This case requires a dedicated agent runbook or fault injection hook.",),
        required_patterns=(),
        notes=(case.objective,),
    )
