from __future__ import annotations

from dataclasses import dataclass

FORBIDDEN_SIGNATURES: tuple[str, ...] = (
    "DMA Read NO_PASID",
    "PTE Read access is not set",
    "do_donate failed",
    "host_initiate_donation: page refcounted",
    "pkvm: exception",
    "soft lockup",
    "RCU stall",
    "BUG:",
    "general protection fault",
    "kernel panic",
)


@dataclass(frozen=True)
class LogFinding:
    signature: str
    line_no: int
    line: str


@dataclass(frozen=True)
class RequiredPatternResult:
    present: list[str]
    missing: list[str]


def _matches(line: str, signature: str) -> bool:
    return signature.lower() in line.lower()


def scan_forbidden_signatures(log_text: str, signatures: tuple[str, ...] = FORBIDDEN_SIGNATURES) -> list[LogFinding]:
    findings: list[LogFinding] = []
    for line_no, line in enumerate(log_text.splitlines(), start=1):
        for signature in signatures:
            if _matches(line, signature):
                findings.append(LogFinding(signature=signature, line_no=line_no, line=line))
                break
    return findings


def scan_required_patterns(log_text: str, patterns: list[str] | tuple[str, ...]) -> RequiredPatternResult:
    present: list[str] = []
    missing: list[str] = []
    for pattern in patterns:
        if any(_matches(line, pattern) for line in log_text.splitlines()):
            present.append(pattern)
        else:
            missing.append(pattern)
    return RequiredPatternResult(present=present, missing=missing)
