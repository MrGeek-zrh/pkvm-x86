from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable


@dataclass(frozen=True)
class TestCase:
    case_id: str
    title: str
    mode: str
    priority: str
    objective: str
    trigger: str
    pass_conditions: tuple[str, ...]
    fail_conditions: tuple[str, ...]
    evidence: tuple[str, ...]
    first_wave_order: int | None = None
    requires_allow_host_bar_touch: bool = False
    guard: str = ""
    miss_policy: str = ""
    notes: tuple[str, ...] = field(default_factory=tuple)


CASES: tuple[TestCase, ...] = (
    TestCase(
        case_id="T12-G2",
        title="protected pVM 无 VFIO baseline",
        mode="scripted",
        priority="P0",
        objective="验证无透传设备时 protected pVM 基本启动不受 T12 逻辑影响。",
        trigger="PROTECTED=1 且不设置 VFIO_DEV。",
        pass_conditions=("guest 到达 login", "host dmesg 不出现 ptdev BAR 日志"),
        fail_conditions=("无 VFIO 也出现 ptdev BAR revoked/restored/deny 日志", "guest 启动失败"),
        evidence=("host dmesg", "guest serial"),
        first_wave_order=1,
    ),
    TestCase(
        case_id="T12-G1",
        title="normal VM + VFIO 不回归",
        mode="scripted",
        priority="P0",
        objective="验证 T12 Host BAR owner 逻辑不误伤普通 VM legacy path。",
        trigger="PROTECTED=0 VFIO_DEV=<BDF> 启动普通 VM。",
        pass_conditions=("guest 到达 login", "普通 VM 不被 protected-only 逻辑拦截"),
        fail_conditions=("普通 VM 被 BAR revoke / manifest reject 错误拦截", "guest NVMe probe 失败"),
        evidence=("crosvm serial", "host dmesg", "guest lsblk"),
        first_wave_order=2,
    ),
    TestCase(
        case_id="T12-A1",
        title="protected VFIO attach 后 BAR revoke",
        mode="scripted",
        priority="P0",
        objective="验证 attach 阶段确实对受管理 BAR 执行 Host EPT revoke / annotation。",
        trigger="protected pVM + VFIO NVMe 启动到 guest login。",
        pass_conditions=("host 新增日志出现 ptdev BAR revoked", "guest 能到 login"),
        fail_conditions=("未出现 revoke 日志", "guest 早期失败", "出现 forbidden signature"),
        evidence=("host dmesg", "crosvm serial", "BDF 与 BAR index"),
        first_wave_order=3,
    ),
    TestCase(
        case_id="T12-B1",
        title="guest DIRECT_BAR direct MMIO 与 NVMe DMA 证据链",
        mode="agent-runbook",
        priority="P0",
        objective="验证 guest NVMe BAR MMIO 命中 direct 分支，块设备 I/O 经过 DMA 建图路径。",
        trigger="guest 对 /dev/nvme0n1 做只读 direct I/O，并运行 T11 host/guest trace helper。",
        pass_conditions=("guest direct MMIO 计数 > 0", "DMA map / NVMe submit 路径可见", "host fallback MMIO 不增长或为 0"),
        fail_conditions=("direct MMIO 计数为 0", "host fallback MMIO 明显增长", "guest I/O 失败"),
        evidence=("guest-summary.txt", "host-summary.txt", "guest dd 输出"),
        first_wave_order=4,
    ),
    TestCase(
        case_id="T12-R1",
        title="clean poweroff 后 BAR restore",
        mode="scripted",
        priority="P0",
        objective="验证 detach / teardown 会恢复 Host EPT BAR idmap。",
        trigger="guest 完成只读 I/O 后执行 poweroff -f 或正常退出 crosvm。",
        pass_conditions=("host 新增日志出现 ptdev BAR restored", "退出后无 forbidden signature"),
        fail_conditions=("未出现 restore 日志", "出现 detach ptdev restore failed", "VFIO 后续无法再次打开"),
        evidence=("host dmesg", "crosvm 退出状态", "下一轮启动结果"),
        first_wave_order=5,
    ),
    TestCase(
        case_id="T12-G3",
        title="repeat boot / destroy 3 次",
        mode="scripted",
        priority="P0",
        objective="捕获 stale touched_bar_mask、旧 allowlist、restore 不完整、VFIO group busy 等重复运行问题。",
        trigger="连续 3 轮 protected VFIO boot / guest 只读 I/O / poweroff。",
        pass_conditions=("3 轮都能启动、I/O、退出", "每轮都有 revoke / restore", "无 forbidden signature"),
        fail_conditions=("任意一轮 VFIO 打不开", "guest I/O 失败", "restore 失败", "host fault 新增"),
        evidence=("每轮单独日志目录", "汇总表"),
        first_wave_order=6,
    ),
    TestCase(
        case_id="T12-A2a",
        title="Host BAR deny-remap 被动观测",
        mode="agent-runbook",
        priority="P0",
        objective="验证 Host EPT 缺页命中 assigned BAR annotation 时拒绝 lazy remap。",
        trigger="正常 protected pVM + VFIO attach；如果 host 自然触发 assigned BAR fault，则观察 deny-remap。",
        pass_conditions=("出现 pkvm: deny host BAR remap", "Host EPT 不重新 idmap 该 BAR", "guest VFIO I/O 不被破坏"),
        fail_conditions=("host assigned BAR fault 后没有 deny", "deny 后 guest direct BAR / VFIO I/O 被破坏"),
        evidence=("host dmesg", "对应 BAR HPA/size", "guest I/O 结果"),
        first_wave_order=7,
        miss_policy="本轮没有 host 侧自然 BAR fault 时记录为 INCONCLUSIVE，不判 fail。",
    ),
    TestCase(
        case_id="T12-C1",
        title="DMA view ready 后才发布 guest contract",
        mode="agent-runbook",
        priority="P0",
        objective="验证 guest DIRECT_BAR allowlist 不会早于 DMA view commit 发布。",
        trigger="protected VFIO attach，同时采集 host trace / dmesg / guest allowlist 查询结果。",
        pass_conditions=("BAR revoke 先发生", "pkvm_iommu_sync() 成功后 dma_view_ready=true", "随后 guest contract 才发布"),
        fail_conditions=("metadata 早到时直接暴露 guest allowlist", "guest 在 DMA view 未 ready 前命中 direct BAR"),
        evidence=("host trace summary", "guest direct MMIO trace", "源码对照分析"),
        first_wave_order=8,
    ),
    TestCase(
        case_id="T12-R2",
        title="detach 时撤回 guest MMIO contract",
        mode="agent-runbook",
        priority="P0",
        objective="验证 detach 时不留下旧 guest allowlist，下一轮 VM 不继承旧 DIRECT_BAR contract。",
        trigger="连续两轮 protected VFIO boot / I/O / poweroff。",
        pass_conditions=("每轮 attach 都重新经历 revoke / publish", "第二轮没有使用上一轮残留状态"),
        fail_conditions=("第二轮启动复用旧 allowlist", "出现 VFIO group busy", "出现 restore 失败"),
        evidence=("两轮 host dmesg 时间窗口", "guest serial", "crosvm 退出状态"),
        first_wave_order=8,
    ),
    TestCase(
        case_id="T12-A2b",
        title="Host BAR touch injection 主动触发",
        mode="agent-runbook",
        priority="P1",
        objective="主动触发 host 对 assigned BAR 的访问，证明 deny-remap 分支可被稳定命中。",
        trigger="attach 后 host 侧通过 resourceN 或等价调试路径触碰已分配 BAR。",
        pass_conditions=("出现 pkvm: deny host BAR remap", "Host EPT 不 lazy-remap BAR", "guest 不崩", "后续 NVMe 只读 I/O 成功"),
        fail_conditions=("Host touch 后 BAR 被重新 idmap", "guest 崩溃", "出现 forbidden signature", "设备需要物理复位才能恢复"),
        evidence=("注入命令", "resourceN 选择依据", "host dmesg", "guest 后续 I/O", "设备恢复状态"),
        first_wave_order=9,
        requires_allow_host_bar_touch=True,
        guard="需要显式传入 --allow-host-bar-touch，或在验证记录中写明允许 host BAR touch injection。",
        notes=("危险点是测试手段，不是 deny-remap 现象。",),
    ),
    TestCase(
        case_id="T12-N1",
        title="metadata 早到时缓存但不提前发布",
        mode="agent-runbook",
        priority="P1",
        objective="验证 metadata 可先缓存，但 guest allowlist 只能在 owner/DMA 条件满足后发布。",
        trigger="让 SET_PTDEV_MMIO_METADATA 早于 dma_view_ready=true 到达，或通过 trace 观察当前 crosvm 提交时序。",
        pass_conditions=("metadata hypercall 返回成功", "guest direct BAR 不提前可用"),
        fail_conditions=("allowlist 在 DMA view ready 前发布", "metadata 早到导致 attach 失败"),
        evidence=("host trace", "crosvm log", "guest allowlist 查询结果"),
    ),
    TestCase(
        case_id="T12-F1",
        title="BAR revoke 部分失败回滚",
        mode="fault-injection-required",
        priority="P2",
        objective="验证某个 BAR annotate 失败后，已 touched BAR 能恢复。",
        trigger="注入 pkvm_host_ept_annotate_mmio_owner() 或 pkvm_pgtable_annotate() 失败。",
        pass_conditions=("已 touched BAR restore", "touched_bar_mask 清零", "owner 回 HOST"),
        fail_conditions=("半 revoke 状态残留", "host / guest BAR 视图不一致"),
        evidence=("注入配置", "host dmesg", "状态 dump"),
    ),
)

_CASE_BY_ID = {case.case_id: case for case in CASES}


def get_case(case_id: str) -> TestCase:
    try:
        return _CASE_BY_ID[case_id]
    except KeyError as exc:
        known = ", ".join(sorted(_CASE_BY_ID))
        raise KeyError(f"unknown case {case_id!r}; known cases: {known}") from exc


def iter_cases(*, first_wave_only: bool = False) -> Iterable[TestCase]:
    cases = CASES
    if first_wave_only:
        cases = tuple(case for case in cases if case.first_wave_order is not None)
    return sorted(cases, key=lambda case: (case.first_wave_order is None, case.first_wave_order or 999, case.case_id))
