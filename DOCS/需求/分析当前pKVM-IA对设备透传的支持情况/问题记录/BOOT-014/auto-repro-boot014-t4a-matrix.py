#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import pathlib
import re
import shlex
import signal
import subprocess
import sys
import time
from collections import defaultdict

try:
    import pexpect
except ImportError as exc:
    raise SystemExit("缺少 Python 依赖 pexpect，请先安装后再运行") from exc


CASE_MODES = {
    "A": "active_dma_host_kill",
    "B": "small_io_guest_poweroff",
    "C": "active_dma_guest_poweroff",
}

SIGNATURE_PATTERNS = {
    "dmar_no_pasid": re.compile(r"DMAR:\s+\[DMA .*NO_PASID\]", re.IGNORECASE),
    "any_dmar": re.compile(r"\bDMAR:\b", re.IGNORECASE),
    "pte_read_not_set": re.compile(r"PTE Read access is not set", re.IGNORECASE),
    "context_present_clear": re.compile(r"Present bit in context entry is clear", re.IGNORECASE),
    "pasid_present_clear": re.compile(r"Present bit in PASID (?:entry|directory entry) is clear", re.IGNORECASE),
    "pkvm_exception": re.compile(r"pkvm:\s+exception", re.IGNORECASE),
    "soft_lockup": re.compile(r"soft lockup", re.IGNORECASE),
    "stall": re.compile(r"\bstall\b", re.IGNORECASE),
    "bug": re.compile(r"\bBUG:\b"),
    "vm_mmu_map_failed": re.compile(r"vm_mmu_map failed", re.IGNORECASE),
    "addr_not_in_mem_range": re.compile(r"addr .* not in mem range", re.IGNORECASE),
    "pkvm_pin_page": re.compile(r"pkvm_pin_page", re.IGNORECASE),
    "bad_address": re.compile(r"bad address", re.IGNORECASE),
    "nvme_timeout": re.compile(r"nvme .* timeout", re.IGNORECASE),
    "nvme_probe_fail": re.compile(r"probe with driver nvme failed", re.IGNORECASE),
    "vfio_blocked": re.compile(r"Device or resource busy|group busy|vfio.*busy", re.IGNORECASE),
}

ISSUE_SIGNATURES = tuple(SIGNATURE_PATTERNS.keys())
CROSVM_RE = re.compile(r"(^|/|\s)crosvm(\s|$)")


def utc_now():
    return dt.datetime.now(dt.timezone.utc)


def utc_dir_stamp():
    return utc_now().strftime("%Y%m%d-%H%M%S")


def utc_human_stamp():
    return utc_now().strftime("%Y-%m-%d %H:%M:%S %Z")


def epoch_now():
    return int(time.time())


def normalize_bdf(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("0000:"):
        return raw
    return f"0000:{raw}"


def find_repo_root(script_path: pathlib.Path) -> pathlib.Path:
    for parent in [script_path.resolve().parent, *script_path.resolve().parents]:
        if (parent / "scripts" / "run-crosvm.sh").exists():
            return parent
    raise RuntimeError("无法定位仓库根目录")


def ensure_root():
    if os.geteuid() == 0:
        return
    os.execvp("sudo", ["sudo", "-E", sys.executable, __file__, *sys.argv[1:]])


def check_cmd(cmd, *, text=True, check=True):
    return subprocess.run(cmd, text=text, capture_output=True, check=check)


def run_cmd(cmd, *, log=None, check=True):
    cmd_text = cmd if isinstance(cmd, str) else shlex.join(cmd)
    if log:
        log(f"run: {cmd_text}")
    result = subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        check=False,
        shell=isinstance(cmd, str),
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"命令失败: {cmd_text}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def read_driver_name(bdf: str) -> str:
    driver = pathlib.Path(f"/sys/bus/pci/devices/{bdf}/driver")
    if not driver.exists():
        return ""
    try:
        return driver.resolve().name
    except FileNotFoundError:
        return ""


def write_sysfs(path: pathlib.Path, value: str):
    path.write_text(value, encoding="utf-8")


def wait_for_driver(bdf: str, expected: str, timeout: int = 20) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if read_driver_name(bdf) == expected:
            return True
        time.sleep(1)
    return read_driver_name(bdf) == expected


def parse_ps_table(ps_text: str):
    entries = []
    for line in ps_text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("PID"):
            continue
        parts = stripped.split(None, 3)
        if len(parts) < 4:
            continue
        pid, ppid, pgid, cmd = parts
        if not pid.isdigit() or not ppid.isdigit():
            continue
        entries.append(
            {
                "pid": int(pid),
                "ppid": int(ppid),
                "pgid": int(pgid),
                "cmd": cmd,
                "raw": line.rstrip(),
            }
        )
    return entries


def descendant_pids(root_pid: int, entries):
    children = defaultdict(list)
    for entry in entries:
        children[entry["ppid"]].append(entry["pid"])
    todo = [root_pid]
    seen = set()
    while todo:
        pid = todo.pop()
        if pid in seen:
            continue
        seen.add(pid)
        todo.extend(children.get(pid, []))
    return seen


def find_crosvm_hits(root_pid: int):
    ps_text = run_cmd(["ps", "-eo", "pid,ppid,pgid,cmd", "--cols", "240"], check=True).stdout
    entries = parse_ps_table(ps_text)
    descendants = descendant_pids(root_pid, entries)
    hits = [entry for entry in entries if entry["pid"] in descendants and CROSVM_RE.search(entry["cmd"])]
    if not hits:
        hits = [entry for entry in entries if CROSVM_RE.search(entry["cmd"])]
    return ps_text, hits


def collect_signatures(text: str):
    hits = {}
    matched_lines = []
    seen = set()
    for key, pattern in SIGNATURE_PATTERNS.items():
        found = False
        for line in text.splitlines():
            if pattern.search(line):
                found = True
                if line not in seen:
                    seen.add(line)
                    matched_lines.append(line)
        hits[key] = found
    return hits, matched_lines


class RunLogger:
    def __init__(self, log_path: pathlib.Path, prefix: str):
        self.log_path = log_path
        self.prefix = prefix
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.fp = self.log_path.open("w", encoding="utf-8")

    def log(self, message: str):
        line = f"[{self.prefix}] {message}"
        print(line, flush=True)
        self.fp.write(line + "\n")
        self.fp.flush()

    def close(self):
        self.fp.close()


class GuestSession:
    def __init__(self, crosvm_cmd: str, console_path: pathlib.Path, boot_timeout: int, logger: RunLogger):
        self.crosvm_cmd = crosvm_cmd
        self.console_path = console_path
        self.boot_timeout = boot_timeout
        self.logger = logger
        self.console_fp = self.console_path.open("w", encoding="utf-8", errors="replace")
        self.child = pexpect.spawn(
            "/bin/bash",
            ["-lc", self.crosvm_cmd],
            encoding="utf-8",
            timeout=self.boot_timeout,
            env=os.environ.copy(),
            echo=False,
        )
        self.child.logfile = self.console_fp

    @property
    def pid(self):
        return self.child.pid

    def close(self, force: bool = False):
        try:
            self.child.close(force=force)
        finally:
            self.console_fp.close()

    def expect_prompt(self, timeout: int = 60):
        self.child.expect("PROMPT# ", timeout=timeout)

    def boot_and_prepare(self):
        self.logger.log(f"spawn: {self.crosvm_cmd}")
        self.child.expect("localhost login:", timeout=self.boot_timeout)
        self.logger.log("guest login prompt reached")
        self.child.sendline("ubuntu")
        self.child.expect(r"[$#] ", timeout=60)
        self.child.sendline("stty -echo")
        self.child.expect(r"[$#] ", timeout=30)
        self.child.sendline("export PS1='PROMPT# '")
        self.expect_prompt(timeout=30)

    def send_and_wait_marker(self, command: str, marker: str, timeout: int = 60):
        self.child.sendline(command)
        self.child.expect(marker, timeout=timeout)
        self.expect_prompt(timeout=timeout)

    def verify_guest_nvme(self):
        self.send_and_wait_marker(
            "ls -l /dev/nvme0n1 && echo READY_NVME",
            "READY_NVME",
            timeout=40,
        )
        self.logger.log("guest nvme visible")
        self.send_and_wait_marker(
            "readlink -f /sys/block/nvme0n1/device && echo READY_BDF",
            "READY_BDF",
            timeout=20,
        )
        self.send_and_wait_marker(
            r"printf '\n' | sudo -S sh -c 'dmesg | tail -n 40' ; echo GUEST_DMESG_OK",
            "GUEST_DMESG_OK",
            timeout=40,
        )

    def start_dma_loop(self):
        self.send_and_wait_marker(
            r"printf '\n' | sudo -S sh -c 'while :; do dd if=/dev/nvme0n1 of=/dev/null bs=4M count=256 iflag=direct status=none; done >/tmp/t4-dd-loop.log 2>&1 & echo T4_BG=$!'",
            r"T4_BG=\d+",
            timeout=40,
        )
        self.logger.log("guest dma loop started")

    def run_small_io(self):
        self.send_and_wait_marker(
            r"printf '\n' | sudo -S sh -c 'dd if=/dev/nvme0n1 of=/dev/null bs=4M count=8 iflag=direct status=none && echo SMALL_IO_DONE'",
            "SMALL_IO_DONE",
            timeout=40,
        )
        self.logger.log("guest small direct io completed")

    def guest_poweroff(self):
        self.child.sendline(r"printf '\n' | sudo -S poweroff -f")
        self.child.expect(pexpect.EOF, timeout=120)

    def wait_eof_after_host_kill(self):
        self.child.expect(pexpect.EOF, timeout=60)


def bind_vfio(bdf: str, logger: RunLogger):
    devpath = pathlib.Path(f"/sys/bus/pci/devices/{bdf}")
    if not devpath.exists():
        raise RuntimeError(f"设备不存在: {devpath}")
    before = read_driver_name(bdf)
    logger.log(f"current driver before vfio bind: {before or '<none>'}")
    run_cmd(["modprobe", "vfio-pci"], log=logger.log, check=True)
    if before and before != "vfio-pci":
        write_sysfs(devpath / "driver" / "unbind", f"{bdf}\n")
        logger.log(f"write: {devpath / 'driver' / 'unbind'} <= {bdf}")
    write_sysfs(devpath / "driver_override", "vfio-pci\n")
    logger.log(f"write: {devpath / 'driver_override'} <= vfio-pci")
    write_sysfs(pathlib.Path("/sys/bus/pci/drivers_probe"), f"{bdf}\n")
    logger.log(f"write: /sys/bus/pci/drivers_probe <= {bdf}")
    if not wait_for_driver(bdf, "vfio-pci", timeout=10):
        raise RuntimeError(f"设备 {bdf} 未能绑定到 vfio-pci，当前驱动={read_driver_name(bdf) or '<none>'}")
    after = read_driver_name(bdf)
    logger.log(f"current driver after vfio bind: {after or '<none>'}")
    return before


def restore_driver(bdf: str, logger: RunLogger):
    devpath = pathlib.Path(f"/sys/bus/pci/devices/{bdf}")
    before = read_driver_name(bdf)
    logger.log(f"current driver before restore: {before or '<none>'}")
    vfio_unbind = pathlib.Path("/sys/bus/pci/drivers/vfio-pci/unbind")
    if before == "vfio-pci" and vfio_unbind.exists():
        write_sysfs(vfio_unbind, f"{bdf}\n")
        logger.log(f"write: {vfio_unbind} <= {bdf}")
    write_sysfs(devpath / "driver_override", "\n")
    logger.log(f"write: {devpath / 'driver_override'} <= <empty>")
    write_sysfs(pathlib.Path("/sys/bus/pci/drivers_probe"), f"{bdf}\n")
    logger.log(f"write: /sys/bus/pci/drivers_probe <= {bdf}")
    deadline = time.time() + 20
    while time.time() < deadline:
        after = read_driver_name(bdf)
        if after and after != "vfio-pci":
            break
        time.sleep(1)
    after = read_driver_name(bdf)
    logger.log(f"current driver after restore: {after or '<none>'}")
    return after


def capture_since(since_epoch: int, out_path: pathlib.Path, logger: RunLogger):
    result = run_cmd(["dmesg", "-T", "--since", f"@{since_epoch}"], log=logger.log, check=True)
    out_path.write_text(result.stdout, encoding="utf-8")
    return result.stdout


def write_json(path: pathlib.Path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run_one_case(args, case_name: str, iteration: int, kill_delay: int | None = None):
    repo_root = find_repo_root(pathlib.Path(__file__))
    crosvm_script = repo_root / "scripts" / "run-crosvm.sh"
    if not crosvm_script.exists():
        raise RuntimeError(f"缺少脚本: {crosvm_script}")

    case_mode = CASE_MODES[case_name]
    run_tag = f"case{case_name}-run{iteration:02d}"
    logdir = pathlib.Path(args.base_dir) / "runs" / run_tag
    logdir.mkdir(parents=True, exist_ok=True)
    logger = RunLogger(logdir / "summary.log", f"case{case_name}")
    since = utc_human_stamp()
    since_epoch = epoch_now()
    console_path = logdir / "crosvm-console.log"
    ps_before_path = logdir / ("host-ps-before-kill.log" if case_name == "A" else "host-ps-before-exit.log")
    ps_after_path = logdir / ("host-ps-after-kill.log" if case_name == "A" else "host-ps-after-exit.log")
    dmesg_after_exit_path = logdir / ("host-dmesg-after-kill.log" if case_name == "A" else "host-dmesg-after-exit.log")
    dmesg_after_restore_path = logdir / "host-dmesg-after-restore.log"
    result_path = logdir / "result.json"
    crosvm_cmd = f"sudo -n env -u DEBUG PROTECTED=1 SETUP_NET=0 VFIO_DEV={args.bdf} {shlex.quote(str(crosvm_script))}"
    status = "completed"
    error = None
    driver_before_bind = ""
    driver_after_restore = ""
    signatures_after_exit = {key: False for key in SIGNATURE_PATTERNS}
    signatures_after_restore = {key: False for key in SIGNATURE_PATTERNS}
    matched_lines_after_exit = []
    matched_lines_after_restore = []
    session = None

    try:
        driver_before_bind = bind_vfio(args.bdf, logger)
        logger.log(f"dmesg since timestamp: {since}")
        session = GuestSession(crosvm_cmd, console_path, args.boot_timeout, logger)
        session.boot_and_prepare()
        session.verify_guest_nvme()

        if case_name == "A":
            session.start_dma_loop()
            if kill_delay:
                logger.log(f"sleep before host kill: {kill_delay}s")
                time.sleep(kill_delay)
            ps_text, hits = find_crosvm_hits(session.pid)
            ps_before_path.write_text(ps_text, encoding="utf-8")
            logger.log("process hits before kill:")
            for hit in hits:
                logger.log(f"  {hit['raw'].strip()}")
            if not hits:
                raise RuntimeError("未找到 crosvm 进程，无法执行 host kill")
            crosvm_pid = hits[-1]["pid"]
            logger.log(f"killing crosvm pid={crosvm_pid} with SIGKILL")
            os.kill(crosvm_pid, signal.SIGKILL)
            session.wait_eof_after_host_kill()
            logger.log("crosvm console reached EOF after kill")
        elif case_name == "B":
            session.run_small_io()
            logger.log("requesting guest poweroff -f after small io")
            session.guest_poweroff()
            logger.log("crosvm console reached EOF after guest poweroff -f")
        elif case_name == "C":
            session.start_dma_loop()
            logger.log("requesting guest poweroff -f during active dma")
            session.guest_poweroff()
            logger.log("crosvm console reached EOF after guest poweroff -f")
        else:
            raise RuntimeError(f"未知 case: {case_name}")

        ps_after_text, _ = find_crosvm_hits(session.pid)
        ps_after_path.write_text(ps_after_text, encoding="utf-8")
        dmesg_after_exit = capture_since(since_epoch, dmesg_after_exit_path, logger)
        signatures_after_exit, matched_lines_after_exit = collect_signatures(dmesg_after_exit)
        logger.log("filtered dmesg lines after exit:")
        for line in matched_lines_after_exit:
            logger.log(f"  {line}")
    except Exception as exc:
        status = "error"
        error = str(exc)
        logger.log(f"ERROR: {error}")
        if session is not None:
            try:
                _, hits = find_crosvm_hits(session.pid)
                for hit in hits:
                    try:
                        os.kill(hit["pid"], signal.SIGKILL)
                    except OSError:
                        pass
            except Exception:
                pass
    finally:
        if session is not None:
            session.close(force=True)
        try:
            driver_after_restore = restore_driver(args.bdf, logger)
        except Exception as exc:
            restore_error = str(exc)
            logger.log(f"ERROR: restore failed: {restore_error}")
            status = "error"
            if error:
                error = f"{error}; restore failed: {restore_error}"
            else:
                error = f"restore failed: {restore_error}"
        try:
            dmesg_after_restore = capture_since(since_epoch, dmesg_after_restore_path, logger)
            signatures_after_restore, matched_lines_after_restore = collect_signatures(dmesg_after_restore)
            logger.log("filtered dmesg lines after restore:")
            for line in matched_lines_after_restore:
                logger.log(f"  {line}")
        except Exception as exc:
            dmesg_error = str(exc)
            logger.log(f"ERROR: capture after restore failed: {dmesg_error}")
            status = "error"
            if error:
                error = f"{error}; capture after restore failed: {dmesg_error}"
            else:
                error = f"capture after restore failed: {dmesg_error}"

    payload = {
        "case": case_name,
        "mode": case_mode,
        "iteration": iteration,
        "status": status,
        "since": since,
        "since_epoch": since_epoch,
        "logdir": str(logdir),
        "kill_delay_secs": kill_delay if case_name == "A" else None,
        "driver_before_bind": driver_before_bind,
        "driver_after_restore": driver_after_restore,
        "signatures_after_exit": signatures_after_exit,
        "signatures_after_restore": signatures_after_restore,
        "matched_lines_after_exit": matched_lines_after_exit,
        "matched_lines_after_restore": matched_lines_after_restore,
        "error": error,
    }
    write_json(result_path, payload)
    logger.log(f"done")
    logger.log(f"console={console_path}")
    logger.log(f"dmesg_after_exit={dmesg_after_exit_path}")
    logger.log(f"dmesg_after_restore={dmesg_after_restore_path}")
    logger.log(f"ps_before={ps_before_path}")
    logger.log(f"ps_after={ps_after_path}")
    logger.close()
    return payload


def summarize_case(results):
    summary = {
        "runs": len(results),
        "completed": sum(1 for item in results if item["status"] == "completed"),
        "errors": sum(1 for item in results if item["status"] != "completed"),
    }
    for key in SIGNATURE_PATTERNS:
        summary[key] = 0
    for item in results:
        for key in SIGNATURE_PATTERNS:
            if item["signatures_after_exit"].get(key) or item["signatures_after_restore"].get(key):
                summary[key] += 1
    return summary


def write_matrix_summary(base_dir: pathlib.Path, plan: dict, results: list[dict]):
    by_case = defaultdict(list)
    for item in results:
        by_case[item["case"]].append(item)
    summary = {case: summarize_case(items) for case, items in by_case.items()}
    json_path = base_dir / "summary.json"
    tsv_path = base_dir / "summary.tsv"
    payload = {
        "base": str(base_dir),
        "plan": plan,
        "results": results,
        "summary": summary,
    }
    write_json(json_path, payload)
    columns = [
        "case",
        "runs",
        "completed",
        "errors",
        "dmar_no_pasid",
        "pte_read_not_set",
        "context_present_clear",
        "pasid_present_clear",
        "any_dmar",
        "pkvm_exception",
        "soft_lockup",
        "stall",
        "nvme_timeout",
        "nvme_probe_fail",
        "vfio_blocked",
    ]
    lines = ["\t".join(columns)]
    for case in ("A", "B", "C"):
        case_summary = summary.get(case)
        if not case_summary:
            continue
        row = [case] + [str(case_summary[column]) for column in columns[1:]]
        lines.append("\t".join(row))
    tsv_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return json_path, tsv_path, summary


def run_once_command(args):
    result = run_one_case(args, args.case, args.iteration, kill_delay=args.kill_delay_secs)
    has_issue = result["status"] != "completed"
    for key in ISSUE_SIGNATURES:
        if result["signatures_after_exit"].get(key) or result["signatures_after_restore"].get(key):
            has_issue = True
            break
    return 1 if has_issue else 0


def build_case_a_delays(raw: str, repeat: int):
    delays = [int(part) for part in raw.split(",") if part.strip()]
    if not delays:
        raise RuntimeError("Case A delay 列表不能为空")
    sequence = []
    for _ in range(repeat):
        sequence.extend(delays)
    return delays, sequence


def run_matrix_command(args):
    base_dir = pathlib.Path(args.base_dir or f"/tmp/t4-matrix-{utc_dir_stamp()}")
    if base_dir.exists():
        raise RuntimeError(f"输出目录已存在: {base_dir}")
    base_dir.mkdir(parents=True, exist_ok=False)
    delays, sequence = build_case_a_delays(args.case_a_delays, args.case_a_repeat)
    plan = {
        "bdf": args.bdf,
        "boot_timeout": args.boot_timeout,
        "case_a_delays": delays,
        "case_a_repeat": args.case_a_repeat,
        "iterations_b": args.iterations_b,
        "iterations_c": args.iterations_c,
    }
    results = []

    for index, delay in enumerate(sequence, start=1):
        print(f"[matrix] Case A run {index:02d}/{len(sequence)} delay={delay}s", flush=True)
        results.append(run_one_case(args, "A", index, kill_delay=delay))

    for index in range(1, args.iterations_b + 1):
        print(f"[matrix] Case B run {index:02d}/{args.iterations_b}", flush=True)
        results.append(run_one_case(args, "B", index))

    for index in range(1, args.iterations_c + 1):
        print(f"[matrix] Case C run {index:02d}/{args.iterations_c}", flush=True)
        results.append(run_one_case(args, "C", index))

    json_path, tsv_path, summary = write_matrix_summary(base_dir, plan, results)
    print(f"[matrix] summary json: {json_path}", flush=True)
    print(f"[matrix] summary tsv:  {tsv_path}", flush=True)

    has_issue = False
    for item in results:
        if item["status"] != "completed":
            has_issue = True
            break
        for key in ISSUE_SIGNATURES:
            if item["signatures_after_exit"].get(key) or item["signatures_after_restore"].get(key):
                has_issue = True
                break
        if has_issue:
            break

    for case in ("A", "B", "C"):
        case_summary = summary.get(case)
        if not case_summary:
            continue
        print(
            "[matrix] "
            f"Case {case}: runs={case_summary['runs']} completed={case_summary['completed']} "
            f"errors={case_summary['errors']} dmar_no_pasid={case_summary['dmar_no_pasid']} "
            f"pte_read_not_set={case_summary['pte_read_not_set']} "
            f"context_present_clear={case_summary['context_present_clear']} "
            f"pasid_present_clear={case_summary['pasid_present_clear']} "
            f"nvme_timeout={case_summary['nvme_timeout']} "
            f"nvme_probe_fail={case_summary['nvme_probe_fail']}",
            flush=True,
        )

    return 1 if has_issue else 0


def parse_args():
    parser = argparse.ArgumentParser(
        description="T4A teardown DMA 推荐验证矩阵：Case A 20 轮（4 个 kill 时机 × 5）、Case B/C 回归轮次可配置。"
    )
    parser.add_argument("--bdf", default="0000:01:00.0", type=normalize_bdf)
    parser.add_argument("--boot-timeout", type=int, default=240)

    subparsers = parser.add_subparsers(dest="command", required=True)

    matrix = subparsers.add_parser("matrix", help="运行推荐矩阵")
    matrix.add_argument("--base-dir", default="")
    matrix.add_argument("--case-a-delays", default="0,1,3,10")
    matrix.add_argument("--case-a-repeat", type=int, default=5)
    matrix.add_argument("--iterations-b", type=int, default=5)
    matrix.add_argument("--iterations-c", type=int, default=5)

    once = subparsers.add_parser("once", help="单独运行一轮指定 case")
    once.add_argument("--base-dir", default="")
    once.add_argument("--case", choices=("A", "B", "C"), required=True)
    once.add_argument("--iteration", type=int, default=1)
    once.add_argument("--kill-delay-secs", type=int, default=0)

    return parser.parse_args()


def main():
    ensure_root()
    args = parse_args()
    if args.command == "matrix":
        return run_matrix_command(args)
    if args.command == "once":
        base_dir = pathlib.Path(args.base_dir or f"/tmp/t4-once-{args.case.lower()}-{utc_dir_stamp()}")
        if base_dir.exists():
            raise RuntimeError(f"输出目录已存在: {base_dir}")
        base_dir.mkdir(parents=True, exist_ok=False)
        args.base_dir = str(base_dir)
        return run_once_command(args)
    raise RuntimeError(f"未知命令: {args.command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
