# [T12] B5-3 设备 MMIO donate 第一阶段实现规划

> **给后续执行者的要求：** 实现本规划时按任务顺序推进；除非用户明确要求并确认范围，否则不要发起全量 Linux 内核编译。若需要执行计划，优先使用 `superpowers:executing-plans` 逐项执行和复核。

**目标：** 为 protected pVM 的已透传 PCI memory BAR 建立第一阶段设备 MMIO donate 主线，使 Host CPU 对受管理 BAR 的直接访问被 Host EPT owner annotation 收口，guest 直通 BAR 约定只在 Host revoke 与 DMA 视图提交后发布，并通过统一 restore 辅助函数回滚/恢复。

**总体架构：** x86 侧继续以 `struct pkvm_ptdev` 作为设备权威状态对象。实现按 `A -> C -> B` 拆分：A 阶段 revoke Host BAR 并写 Host EPT invalid owner 标注，C 阶段切换 DMA 视图，B 阶段发布 guest MMIO 约定。restore 阶段以 `touched_bar_mask` 作为 BAR 资源范围，同时收口 guest 约定、DMA 视图、Host BAR 可见性和内部记录四个平面。

**技术栈：** `pKVM-IA` 内核 C 代码、pKVM hyp Host EPT、ptdev/IOMMU 状态机、`pkvm-x86` Markdown 跟踪文档和 GitHub issue 状态同步。

---

## 范围

第一阶段只覆盖：

```text
单个 protected pVM
  + 单个启动期已知的 VFIO PCI device
  + 启动 manifest 中的 memory BAR 快照
  + Host EPT owner 标注拒绝重映射
  + 现有 guest DIRECT_BAR allowlist 保持可用
  + detach / teardown / attach 失败回滚统一进入 restore 辅助函数
```

第一阶段明确不覆盖：

- 完整 VFIO `FILE_DEL` / group remove-path 编排；继续归 `T6`。
- reset framework、hotplug、migration、多设备 group 原子切换。
- MSI-X table / PBA 的 BAR 子区间 owner 切片。
- config space direct access。
- 严格 ARM-like `OWNER_GUEST`。
- 全量 Linux 内核构建；本规划只给出最小编译目标建议。

## D0-D9 决策覆盖表

- D0 第一阶段边界：任务 0、任务 8、任务 9。
- D1 `ptdev` 状态字段：任务 3。
- D2 BAR 快照与 metadata 时序：任务 3、任务 4、任务 5。
- D3 guest 约定发布拆分：任务 4、任务 5、任务 6。
- D4 Host EPT annotation 编码：任务 1。
- D5 Host EPT helper/API 粒度：任务 1。
- D6 Host EPT fault deny-remap：任务 2。
- D7 attach A/C/B 工程顺序：任务 5。
- D8 restore 辅助函数约定：任务 5、任务 6。
- D9 最小验证边界：任务 8。

## 文件结构

**内核实现仓库：** `/home/mrgeek/pkvm-x86/pKVM-IA`

- 修改 `arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
  - 增加 `ptdev` owner/state/progress 枚举。
  - 增加 BAR 快照字段和辅助函数声明。
- 修改 `arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
  - 从 boot manifest 生成 BAR 快照。
  - 校验 metadata 范围是否落在 BAR 快照内。
  - 拆分 metadata 缓存与 guest 约定发布。
  - 实现 A/C/B attach 流程和 restore 辅助函数。
- 修改 `arch/x86/kvm/vmx/pkvm/hyp/ept.h`
  - 增加 Host EPT MMIO 标注查询的结果类型和辅助函数声明。
- 修改 `arch/x86/kvm/vmx/pkvm/hyp/ept.c`
  - 增加 Host EPT annotate / restore / lookup 包装函数。
  - 让 `handle_host_ept_violation()` 根据 annotation 拒绝 Host 重映射。
- 修改 `arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h`
  - 暴露 invalid-PTE owner annotation encode/decode 辅助函数。
  - 增加非 0 的 reserved MMIO/BAR owner tag。
- 修改 `arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
  - 删除本地重复的 invalid owner encoder，改用 header inline 辅助函数。
- 检查 `arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`
  - teardown 继续经由 `pkvm_detach_ptdev()`，由 detach 内部进入 restore-aware 路径。
- 仅在必要时修改 `arch/x86/kvm/pkvm/mmu.c`
  - 优先保持现有辅助函数名称不变，只强化 `pkvm_vm_hpa_hits_attached_boot_ptdev_bar()` 的内部判定。

**总控文档仓库：** `/home/mrgeek/pkvm-x86`

- 修改本文件。
- 修改 `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/README.md`。
- 修改 `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/当前进度.md`。
- 根据验证结果新增 `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t12-mmio-donate-phase1-YYYYMMDD.md`。

## 实现任务

### 任务 0：创建实现分支与记录入口

**文件：**
- 暂不修改内核代码。
- 可修改 `pkvm-x86` 的 `当前进度.md`。

- [ ] **步骤 1：确认 superproject 与 kernel worktree 状态**

运行：

```bash
cd /home/mrgeek/pkvm-x86
git status --short
cd /home/mrgeek/pkvm-x86/pKVM-IA
git status --short
```

期望：

```text
# 两个仓库均无输出
```

若 superproject 只有本规划文档未提交，先提交或暂存，再进入 `pKVM-IA` 代码实现。

- [ ] **步骤 2：创建短生命周期 kernel topic branch**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git branch --show-current
git switch -c codex/t12-mmio-donate-phase1
git branch --show-current
```

期望：

```text
codex/t12-mmio-donate-phase1
```

- [ ] **步骤 3：在总控进度文档记录实现分支**

修改：

```text
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/当前进度.md
```

在 `B5-3 / T12` 下一步条目中增加：

```markdown
  - `T12` 第一阶段实现分支：`pKVM-IA` / `codex/t12-mmio-donate-phase1`，实现计划入口为 [`实施跟踪/01E-T12-B5-3-device-MMIO-donate-第一阶段实现规划.md`](实施跟踪/01E-T12-B5-3-device-MMIO-donate-第一阶段实现规划.md)
```

- [ ] **步骤 4：如有进度文档变更，则提交到 `pkvm-x86`**

运行：

```bash
cd /home/mrgeek/pkvm-x86
git add DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/当前进度.md
git commit -m '记录 T12 第一阶段实现分支' -m '同步 device MMIO donate 第一阶段实现规划入口和 pKVM-IA 短生命周期分支。'
git log -1 --format=%s
```

期望：

```text
记录 T12 第一阶段实现分支
```

### 任务 1：增加 Host EPT MMIO annotation 基础设施

**文件：**
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h`
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c`
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.h`
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`

- [ ] **步骤 1：把 invalid-PTE owner 编码 helper 移到 header**

在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h` 的 include 区增加 `FIELD_PREP()` / `FIELD_GET()` 所需头文件：

```c
#include <linux/bitfield.h>
```

再在 `OWNER_ID_INV` 后增加：

```c
#define OWNER_ID_PTDEV_MMIO	FIELD_MAX(PKVM_INVALID_PTE_OWNER_MASK)

static inline u64 pkvm_init_invalid_leaf_owner(pkvm_id owner_id)
{
	return FIELD_PREP(PKVM_INVALID_PTE_OWNER_MASK, owner_id) |
		FIELD_PREP(PKVM_PAGE_STATE_PROT_MASK, PKVM_NOPAGE);
}

static inline pkvm_id pkvm_invalid_leaf_owner_id(u64 pte)
{
	return FIELD_GET(PKVM_INVALID_PTE_OWNER_MASK, pte);
}

static inline bool pkvm_invalid_leaf_has_owner(u64 pte)
{
	return pkvm_getstate(pte) == PKVM_NOPAGE &&
	       pkvm_invalid_leaf_owner_id(pte) != 0;
}
```

`OWNER_ID_PTDEV_MMIO` 必须是非 0，且不同于 `OWNER_ID_HOST`。第一版选择 owner-id 高位范围的 reserved tag，避免和低位 VM handle 冲突。

- [ ] **步骤 2：增加 reserved tag 静态检查**

在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c` 的 include 之后增加：

```c
static_assert(OWNER_ID_PTDEV_MMIO != OWNER_ID_HYP);
static_assert(OWNER_ID_PTDEV_MMIO != OWNER_ID_HOST);
```

- [ ] **步骤 3：删除 `mem_protect.c` 内的重复 encoder**

删除：

```c
static u64 pkvm_init_invalid_leaf_owner(pkvm_id owner_id)
{
	/* the page owned by others also means NOPAGE in page state */
	return FIELD_PREP(PKVM_INVALID_PTE_OWNER_MASK, owner_id) |
		FIELD_PREP(PKVM_PAGE_STATE_PROT_MASK, PKVM_NOPAGE);
}
```

已有 `host_ept_set_owner_locked()` 继续使用同名 header inline 辅助函数。

- [ ] **步骤 4：声明 Host EPT annotation lookup 类型**

在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.h` 的 include 区增加 `pkvm_id` 和 owner tag 所需头文件：

```c
#include "mem_protect.h"
```

再在 `HOST_EPT_DEF_MMIO_PROT` 后增加：

```c
enum pkvm_host_ept_lookup_kind {
	PKVM_HOST_EPT_LOOKUP_PRESENT,
	PKVM_HOST_EPT_LOOKUP_ANNOTATED,
	PKVM_HOST_EPT_LOOKUP_EMPTY,
};

struct pkvm_host_ept_lookup_result {
	enum pkvm_host_ept_lookup_kind kind;
	unsigned long hpa;
	u64 prot;
	u64 annotation;
	u64 raw_pte;
	pkvm_id owner_id;
	int level;
};
```

并在 Host EPT 辅助函数声明区增加：

```c
int pkvm_host_ept_annotate_mmio_owner(unsigned long hpa, unsigned long size,
					      pkvm_id owner_id);
int pkvm_host_ept_restore_mmio_idmap(unsigned long hpa, unsigned long size,
					    u64 prot);
int pkvm_host_ept_lookup_mmio_annotation_locked(unsigned long vaddr,
							struct pkvm_host_ept_lookup_result *res);
```

- [ ] **步骤 5：实现 raw Host EPT lookup walker**

在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c` 的 `pkvm_host_ept_map()` 前增加：

```c
struct host_ept_lookup_raw_data {
	unsigned long vaddr;
	struct pkvm_host_ept_lookup_result *res;
};

static int host_ept_lookup_raw_cb(struct pkvm_pgtable *pgt,
					 unsigned long vaddr,
					 unsigned long vaddr_end,
					 int level, void *ptep,
					 unsigned long flags,
					 struct pgt_flush_data *flush_data,
					 void *const arg)
{
	struct host_ept_lookup_raw_data *data = arg;
	struct pkvm_host_ept_lookup_result *res = data->res;
	const struct pkvm_pgtable_ops *pgt_ops = pgt->pgt_ops;
	u64 pte = atomic64_read((atomic64_t *)ptep);

	res->raw_pte = pte;
	res->annotation = 0;
	res->owner_id = OWNER_ID_INV;
	res->level = level;
	res->hpa = INVALID_ADDR;
	res->prot = 0;

	if (unlikely(!pgt_ops->pgt_entry_is_leaf(&pte, level)))
		return -EAGAIN;

	if (pgt_ops->pgt_entry_present(&pte)) {
		unsigned long offset = data->vaddr &
			~pgt_ops->pgt_level_page_mask(level);

		res->kind = PKVM_HOST_EPT_LOOKUP_PRESENT;
		res->hpa = pgt_ops->pgt_entry_to_phys(&pte) + offset;
		res->prot = pgt_ops->pgt_entry_to_prot(&pte);
		return PGTABLE_WALK_DONE;
	}

	if (pkvm_invalid_leaf_has_owner(pte)) {
		res->kind = PKVM_HOST_EPT_LOOKUP_ANNOTATED;
		res->annotation = pte;
		res->owner_id = pkvm_invalid_leaf_owner_id(pte);
		return PGTABLE_WALK_DONE;
	}

	res->kind = PKVM_HOST_EPT_LOOKUP_EMPTY;
	return PGTABLE_WALK_DONE;
}
```

- [ ] **步骤 6：实现 Host EPT annotation wrapper**

在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c` 的 `pkvm_host_ept_lookup()` 后增加：

```c
int pkvm_host_ept_annotate_mmio_owner(unsigned long hpa, unsigned long size,
					      pkvm_id owner_id)
{
	u64 annotation;
	int ret;

	if (!owner_id || owner_id == OWNER_ID_HOST)
		return -EINVAL;

	annotation = pkvm_init_invalid_leaf_owner(owner_id);

	host_ept_lock();
	ret = pkvm_pgtable_annotate(&host_ept, hpa, size, annotation);
	if (!ret)
		pkvm_flush_host_ept();
	host_ept_unlock();

	return ret;
}

int pkvm_host_ept_restore_mmio_idmap(unsigned long hpa, unsigned long size,
					    u64 prot)
{
	int ret;

	host_ept_lock();
	ret = pkvm_host_ept_map(hpa, hpa, size, 1 << PG_LEVEL_4K, prot);
	if (!ret)
		pkvm_flush_host_ept();
	host_ept_unlock();

	return ret;
}

int pkvm_host_ept_lookup_mmio_annotation_locked(unsigned long vaddr,
							struct pkvm_host_ept_lookup_result *res)
{
	struct host_ept_lookup_raw_data data = {
		.vaddr = vaddr,
		.res = res,
	};
	struct pkvm_pgtable_walker walker = {
		.cb = host_ept_lookup_raw_cb,
		.arg = &data,
		.flags = PKVM_PGTABLE_WALK_LEAF,
	};
	int ret, retry_cnt = 0;

retry:
	memset(res, 0, sizeof(*res));
	res->kind = PKVM_HOST_EPT_LOOKUP_EMPTY;
	res->hpa = INVALID_ADDR;
	res->owner_id = OWNER_ID_INV;

	ret = pgtable_walk(&host_ept, vaddr, PAGE_SIZE, true, &walker);
	if (ret == -EAGAIN && retry_cnt++ < 5)
		goto retry;

	return ret == PGTABLE_WALK_DONE ? 0 : ret;
}
```

源码复核补充：

- `ept.h` 新增结构体会直接使用 `pkvm_id`，因此必须显式包含 `mem_protect.h`；否则只在 `ept.c` 中包含 `mem_protect.h` 不足以让 header 自洽。
- `pkvm_host_ept_lookup_mmio_annotation_locked()` 只允许在 `_host_ept_lock` 已持有时调用，避免和 `handle_host_ept_violation()` 的现有锁顺序冲突。
- lookup walker 必须和 `pkvm_pgtable_lookup()` 一样使用 `page_aligned=true`，并对 `-EAGAIN` 做最多 5 次重试；否则 fault GPA 非页对齐或并发 PTE 变化时会产生不稳定结果。
- `pkvm_host_ept_annotate_mmio_owner()` 明确拒绝 `OWNER_ID_HYP=0` 和 `OWNER_ID_HOST`，避免第一阶段 BAR 标注退化为空 invalid PTE 或 Host owner。

- [ ] **步骤 7：运行窄范围静态检查**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git diff --check -- arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c arch/x86/kvm/vmx/pkvm/hyp/ept.h arch/x86/kvm/vmx/pkvm/hyp/ept.c
git grep -n "static u64 pkvm_init_invalid_leaf_owner" -- arch/x86/kvm/vmx/pkvm/hyp || true
```

期望：

```text
# git diff --check 无输出
# git grep 无输出
```

- [ ] **步骤 8：提交 Host EPT annotation 基础设施**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git add arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h \
        arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c \
        arch/x86/kvm/vmx/pkvm/hyp/ept.h \
        arch/x86/kvm/vmx/pkvm/hyp/ept.c
git commit -m '增加设备 MMIO 的 Host EPT 标注辅助函数' -m '抽出 invalid PTE owner 编码并增加 Host EPT MMIO annotate/restore/lookup 能力，为 BAR deny-remap 做准备。'
git log -1 --format=%s
```

期望：

```text
增加设备 MMIO 的 Host EPT 标注辅助函数
```

### 任务 2：拒绝 Host fault 重新映射 annotated BAR

**文件：**
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`

- [ ] **步骤 1：替换 `handle_host_ept_violation()` 的首次 Host EPT lookup**

先把 `handle_host_ept_violation()` 的局部变量声明从：

```c
unsigned long hpa, gpa = vmcs_read64(GUEST_PHYSICAL_ADDRESS);
```

调整为：

```c
unsigned long gpa = vmcs_read64(GUEST_PHYSICAL_ADDRESS);
```

避免 annotation-aware lookup 接入后留下未使用的 `hpa`。

然后把当前基于 `pkvm_pgtable_lookup()` 的检查：

```c
pkvm_pgtable_lookup(&host_ept, gpa, &hpa, NULL, &level);
if (hpa != INVALID_ADDR) {
	ret = -EAGAIN;
	goto out;
}
```

替换为 annotation-aware lookup：

```c
struct pkvm_host_ept_lookup_result lookup;

ret = pkvm_host_ept_lookup_mmio_annotation_locked(gpa, &lookup);
if (ret)
	goto out;

level = lookup.level;
if (lookup.kind == PKVM_HOST_EPT_LOOKUP_PRESENT) {
	ret = -EAGAIN;
	goto out;
}
if (lookup.kind == PKVM_HOST_EPT_LOOKUP_ANNOTATED &&
    lookup.owner_id == OWNER_ID_PTDEV_MMIO) {
	pkvm_err("pkvm: deny host BAR remap gpa=0x%lx owner_id=%u raw_pte=0x%llx\n",
		 gpa, lookup.owner_id, lookup.raw_pte);
	ret = -EPERM;
	goto out;
}
```

- [ ] **步骤 2：保留普通 MMIO lazy-map 行为**

annotated deny 分支之后，保留现有 non-RAM hole range selection 和 `pkvm_host_ept_map()` 逻辑。普通 empty MMIO hole 仍应走原有 lazy map。

- [ ] **步骤 3：运行窄范围静态检查**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git diff --check -- arch/x86/kvm/vmx/pkvm/hyp/ept.c
git grep -n "deny host BAR remap" -- arch/x86/kvm/vmx/pkvm/hyp/ept.c
```

期望：

```text
# git diff --check 无输出
# git grep 在 ept.c 中找到 deny host BAR remap 日志
```

- [ ] **步骤 4：提交 Host fault 拒绝重映射**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git add arch/x86/kvm/vmx/pkvm/hyp/ept.c
git commit -m '拒绝带 annotation 的 Host BAR remap' -m '让 Host EPT fault 识别设备 MMIO owner tag，避免 assigned BAR 被普通 MMIO lazy map 重新映回 Host。'
git log -1 --format=%s
```

期望：

```text
拒绝带 annotation 的 Host BAR remap
```

### 任务 3：增加 `ptdev` authority state 与 BAR snapshot

**文件：**
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h`
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`

- [ ] **步骤 1：增加 owner/state/progress 定义**

在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.h` 的 `struct pkvm_ptdev` 前增加：

```c
enum pkvm_ptdev_owner {
	PKVM_PTDEV_OWNER_HOST,
	PKVM_PTDEV_OWNER_HYP,
};

enum pkvm_ptdev_assignment_state {
	PKVM_PTDEV_DETACHED,
	PKVM_PTDEV_ATTACHING,
	PKVM_PTDEV_HOST_REVOKED,
	PKVM_PTDEV_GUEST_ASSIGNED,
	PKVM_PTDEV_RESTORING,
};

enum pkvm_ptdev_bar_progress {
	PKVM_PTDEV_BAR_HOST_VISIBLE,
	PKVM_PTDEV_BAR_REVOKED,
	PKVM_PTDEV_BAR_CONTRACT_PUBLISHED,
	PKVM_PTDEV_BAR_RESTORING,
};

struct pkvm_ptdev_bar_resource {
	u8 bar_index;
	u64 hpa;
	u64 size;
	enum pkvm_ptdev_bar_progress progress;
};
```

- [ ] **步骤 2：给 `struct pkvm_ptdev` 增加字段**

在 `dma_blocked` 后增加：

```c
	bool dma_view_ready;
	bool guest_contract_published;
	enum pkvm_ptdev_owner owner;
	enum pkvm_ptdev_assignment_state assignment_state;
	unsigned long managed_bar_mask;
	unsigned long touched_bar_mask;
	struct pkvm_ptdev_bar_resource bars[PCI_STD_NUM_BARS];
```

如果 `PCI_STD_NUM_BARS` 未通过现有 include 暴露，则在 `ptdev.h` 顶部增加：

```c
#include <linux/pci_regs.h>
```

- [ ] **步骤 3：在分配时初始化字段**

在 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c` 的 `__pkvm_alloc_ptdev_locked()` 中，`ptdev->pgt = pkvm_hyp->host_vm.ept;` 后增加：

```c
			ptdev->owner = PKVM_PTDEV_OWNER_HOST;
			ptdev->assignment_state = PKVM_PTDEV_DETACHED;
			ptdev->dma_view_ready = false;
			ptdev->guest_contract_published = false;
			ptdev->managed_bar_mask = 0;
			ptdev->touched_bar_mask = 0;
```

- [ ] **步骤 4：增加 BAR snapshot helper**

在 `ptdev.c` 的 `pkvm_boot_ptdev_manifest_lookup()` 后增加：

```c
static void pkvm_ptdev_clear_bar_state_locked(struct pkvm_ptdev *ptdev)
{
	memset(ptdev->bars, 0, sizeof(ptdev->bars));
	ptdev->managed_bar_mask = 0;
	ptdev->touched_bar_mask = 0;
}

static int pkvm_prepare_ptdev_bar_resources_locked(struct pkvm_ptdev *ptdev)
{
	const struct pkvm_boot_ptdev_manifest_entry *entry;
	int idx;

	if (ptdev->managed_bar_mask)
		return 0;

	entry = pkvm_boot_ptdev_manifest_lookup(ptdev->bdf);
	if (!entry)
		return -EPERM;

	pkvm_ptdev_clear_bar_state_locked(ptdev);
	for (idx = 0; idx < PCI_STD_NUM_BARS; idx++) {
		const struct pkvm_boot_ptdev_bar_entry *bar = &entry->bars[idx];

		if (!bar->size)
			continue;
		if (!PAGE_ALIGNED(bar->base) || !PAGE_ALIGNED(bar->size))
			return -EINVAL;

		ptdev->bars[idx].bar_index = idx;
		ptdev->bars[idx].hpa = bar->base;
		ptdev->bars[idx].size = bar->size;
		ptdev->bars[idx].progress = PKVM_PTDEV_BAR_HOST_VISIBLE;
		ptdev->managed_bar_mask |= BIT(idx);
	}

	return ptdev->managed_bar_mask ? 0 : -ENODEV;
}

static bool pkvm_ptdev_bar_contains_range_locked(struct pkvm_ptdev *ptdev,
						 u8 bar_index, u64 offset, u64 size)
{
	struct pkvm_ptdev_bar_resource *bar;

	if (bar_index >= PCI_STD_NUM_BARS || !size)
		return false;
	if (!(ptdev->managed_bar_mask & BIT(bar_index)))
		return false;
	bar = &ptdev->bars[bar_index];
	if (offset > U64_MAX - size)
		return false;

	return offset + size <= bar->size;
}
```

- [ ] **步骤 5：增加 guest 映射前置状态辅助函数**

在 `ptdev.c` 的 BAR helper 附近增加：

```c
static bool pkvm_ptdev_allows_guest_bar_mapping_locked(struct pkvm_ptdev *ptdev)
{
	enum pkvm_ptdev_owner owner = READ_ONCE(ptdev->owner);
	enum pkvm_ptdev_assignment_state state =
		READ_ONCE(ptdev->assignment_state);

	return owner == PKVM_PTDEV_OWNER_HYP &&
	       (state == PKVM_PTDEV_HOST_REVOKED ||
		state == PKVM_PTDEV_GUEST_ASSIGNED) &&
	       READ_ONCE(ptdev->dma_view_ready);
}
```

- [ ] **步骤 6：强化 guest direct BAR map predicate**

修改 `pkvm_vm_hpa_hits_attached_boot_ptdev_bar()`，让它检查 BAR snapshot 与状态，而不是只看 boot manifest。

将内部 manifest lookup 替换为：

```c
		if (!pkvm_ptdev_allows_guest_bar_mapping_locked(ptdev))
			continue;
		for (idx = 0; idx < PCI_STD_NUM_BARS; idx++) {
			struct pkvm_ptdev_bar_resource *bar = &ptdev->bars[idx];

			if (hpa < bar->hpa)
				continue;
			if (pkvm_ptdev_bar_contains_range_locked(ptdev, idx,
						hpa - bar->hpa, size)) {
				hit = true;
				break;
			}
		}
		if (hit)
			break;
```

在函数顶部声明：

```c
int idx;
```

在入参校验处同时拒绝 `size == 0`：

```c
if (!kvm || !size)
	return false;
```

在 `pkvm_attach_ptdev()` 中，`shadow_vm_handle` 的 `cmpxchg()` 成功后立即准备 BAR snapshot：

```c
	ret = pkvm_prepare_ptdev_bar_resources_locked(ptdev);
	if (ret) {
		ptdev->shadow_vm_handle = 0;
		pkvm_spin_unlock(&ptdev->lock);
		pkvm_put_ptdev(ptdev);
		return ret;
	}
```

源码复核补充：

- `pkvm_prepare_ptdev_bar_resources_locked()` 必须在 attach 早期被实际调用，避免中间提交留下未使用静态函数，也确保后续 A/C/B 阶段复用同一份 BAR snapshot。
- `pkvm_vm_hpa_hits_attached_boot_ptdev_bar()` 复用 `pkvm_ptdev_bar_contains_range_locked()` 做 offset/size 边界检查，避免 guest mapping predicate 和 metadata 校验出现两套范围判断。
- guest 映射前置状态辅助函数 使用 `READ_ONCE()` 读取 `owner`、`assignment_state` 和 `dma_view_ready`，因为该 predicate 持有的是 `vm->lock`，而状态更新路径会在 `ptdev->lock` 下写入。

- [ ] **步骤 7：运行窄范围静态检查**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git diff --check -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.h arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
git grep -n "PKVM_PTDEV_OWNER_HYP\|managed_bar_mask\|dma_view_ready" -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.h arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
```

期望：

```text
# git diff --check 无输出
# git grep 打印新 enum/字段/helper 调用点
```

- [ ] **步骤 8：提交 `ptdev` 状态和 snapshot**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git add arch/x86/kvm/vmx/pkvm/hyp/ptdev.h arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
git commit -m '增加 ptdev BAR authority 状态' -m '为设备 MMIO donate 添加 owner/state/progress、BAR snapshot 和 guest BAR 映射前置状态检查。'
git log -1 --format=%s
```

期望：

```text
增加 ptdev BAR authority 状态
```

### 任务 4：拆分 metadata 缓存与 guest 约定发布

**文件：**
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`

- [ ] **步骤 1：增加 metadata 校验 helper**

在 `pkvm_set_ptdev_mmio_metadata()` 前增加：

```c
static int pkvm_validate_ptdev_mmio_metadata_locked(
	struct pkvm_ptdev *ptdev,
	const struct kvm_ptdev_mmio_metadata *metadata)
{
	u16 i;
	int ret;

	ret = pkvm_prepare_ptdev_bar_resources_locked(ptdev);
	if (ret)
		return ret;

	for (i = 0; i < metadata->nr_ranges; i++) {
		const struct kvm_protected_vm_ptdev_mmio_range *range =
			&metadata->ranges[i];

		if (range->kind != KVM_PROTECTED_VM_PTDEV_MMIO_KIND_DIRECT_BAR)
			return -EINVAL;
		if (!pkvm_ptdev_bar_contains_range_locked(ptdev,
				range->bar_index, range->bar_offset, range->size))
			return -EPERM;
	}

	return 0;
}
```

- [ ] **步骤 2：增加 guest 约定发布 helper**

在校验 helper 后增加：

```c
static int pkvm_publish_ptdev_mmio_contract_locked(struct pkvm_shadow_vm *vm,
						   struct pkvm_ptdev *ptdev)
{
	int idx;

	if (!ptdev->mmio_metadata_valid)
		return 0;
	if (ptdev->guest_contract_published)
		return 0;
	if (!pkvm_ptdev_allows_guest_bar_mapping_locked(ptdev))
		return -EAGAIN;

	pkvm_update_vm_mmio_allowlist(vm, &ptdev->mmio_metadata);
	for (idx = 0; idx < PCI_STD_NUM_BARS; idx++) {
		if (ptdev->managed_bar_mask & BIT(idx))
			ptdev->bars[idx].progress = PKVM_PTDEV_BAR_CONTRACT_PUBLISHED;
	}
	ptdev->guest_contract_published = true;
	ptdev->assignment_state = PKVM_PTDEV_GUEST_ASSIGNED;
	return 0;
}
```

- [ ] **步骤 3：增加 guest contract withdraw helper**

在 publish helper 后增加：

```c
static void pkvm_withdraw_ptdev_mmio_contract_locked(struct pkvm_shadow_vm *vm,
						     struct pkvm_ptdev *ptdev)
{
	if (!ptdev->guest_contract_published)
		return;

	pkvm_clear_vm_mmio_allowlist(vm);
	ptdev->guest_contract_published = false;
}
```

- [ ] **步骤 4：修改 `pkvm_set_ptdev_mmio_metadata()` 为先缓存后发布**

在 `!ptdev->mmio_metadata_valid` 分支里，用校验 + 可选 publish 替换直接 allowlist 更新：

```c
		ret = pkvm_validate_ptdev_mmio_metadata_locked(ptdev, metadata);
		if (ret)
			goto out;
		ptdev->mmio_metadata = *metadata;
		ptdev->mmio_metadata_valid = true;
		ret = pkvm_publish_ptdev_mmio_contract_locked(vm, ptdev);
		if (ret == -EAGAIN)
			ret = 0;
		goto out;
```

对于 metadata equal 分支，追加可选 publish：

```c
	ret = pkvm_ptdev_mmio_metadata_equal(&ptdev->mmio_metadata, metadata) ?
	      pkvm_publish_ptdev_mmio_contract_locked(vm, ptdev) : -EBUSY;
	if (ret == -EAGAIN)
		ret = 0;
```

这样 metadata 早于 A/C 到达时仍可返回成功，但不会提前 publish guest allowlist。

- [ ] **步骤 5：运行窄范围静态检查**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git diff --check -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
git grep -n "pkvm_update_vm_mmio_allowlist(vm, metadata)" -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c || true
git grep -n "pkvm_publish_ptdev_mmio_contract_locked\|pkvm_withdraw_ptdev_mmio_contract_locked" -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
```

期望：

```text
# git diff --check 无输出
# 直接 pkvm_update_vm_mmio_allowlist(vm, metadata) grep 无输出
# publish/withdraw helper grep 打印定义和调用点
```

- [ ] **步骤 6：提交 metadata 拆分**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git add arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
git commit -m '拆分 MMIO metadata 缓存与发布' -m '让 SET_PTDEV_MMIO_METADATA 只记录 guest direct BAR 意图，并在 Host revoke 与 DMA view commit 后再发布 allowlist。'
git log -1 --format=%s
```

期望：

```text
拆分 MMIO metadata 缓存与发布
```

### 任务 5：实现 A/C/B attach 主线和 C 前失败回滚

**文件：**
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`

- [ ] **步骤 1：增加 Host BAR revoke helper**

在 `pkvm_attach_ptdev()` 前增加：

```c
static int pkvm_revoke_ptdev_bars_locked(struct pkvm_ptdev *ptdev)
{
	int idx;
	int ret;

	ret = pkvm_prepare_ptdev_bar_resources_locked(ptdev);
	if (ret)
		return ret;

	ptdev->assignment_state = PKVM_PTDEV_ATTACHING;
	ptdev->touched_bar_mask = 0;
	for (idx = 0; idx < PCI_STD_NUM_BARS; idx++) {
		struct pkvm_ptdev_bar_resource *bar = &ptdev->bars[idx];

		if (!(ptdev->managed_bar_mask & BIT(idx)))
			continue;

		ret = pkvm_host_ept_annotate_mmio_owner(bar->hpa, bar->size,
						     OWNER_ID_PTDEV_MMIO);
		if (ret)
			return ret;

		bar->progress = PKVM_PTDEV_BAR_REVOKED;
		ptdev->touched_bar_mask |= BIT(idx);
	}

	ptdev->owner = PKVM_PTDEV_OWNER_HYP;
	ptdev->assignment_state = PKVM_PTDEV_HOST_REVOKED;
	return 0;
}
```

- [ ] **步骤 2：增加 restore 辅助函数，覆盖 C 前失败回滚**

在 `pkvm_revoke_ptdev_bars_locked()` 后增加：

```c
static int pkvm_restore_ptdev_bars_locked(struct pkvm_shadow_vm *vm,
					  struct pkvm_ptdev *ptdev,
					  bool dma_unreachable_proven)
{
	u64 prot = pkvm_mkstate(HOST_EPT_DEF_MMIO_PROT, PKVM_PAGE_OWNED);
	unsigned long restore_mask = ptdev->touched_bar_mask;
	int idx;
	int ret;

	if (!dma_unreachable_proven && ptdev->dma_view_ready)
		return -EBUSY;

	ptdev->assignment_state = PKVM_PTDEV_RESTORING;
	for (idx = 0; idx < PCI_STD_NUM_BARS; idx++)
		if (restore_mask & BIT(idx))
			ptdev->bars[idx].progress = PKVM_PTDEV_BAR_RESTORING;

	pkvm_withdraw_ptdev_mmio_contract_locked(vm, ptdev);

	if (ptdev->dma_view_ready) {
		ptdev->pgt = pkvm_hyp->host_vm.ept;
		ret = pkvm_iommu_sync(ptdev->bdf, ptdev->pasid);
		if (ret)
			return ret;
		ptdev->dma_view_ready = false;
	}

	for (idx = 0; idx < PCI_STD_NUM_BARS; idx++) {
		struct pkvm_ptdev_bar_resource *bar = &ptdev->bars[idx];

		if (!(restore_mask & BIT(idx)))
			continue;
		ret = pkvm_host_ept_restore_mmio_idmap(bar->hpa, bar->size, prot);
		if (ret)
			return ret;
	}

	for (idx = 0; idx < PCI_STD_NUM_BARS; idx++)
		if (restore_mask & BIT(idx))
			ptdev->bars[idx].progress = PKVM_PTDEV_BAR_HOST_VISIBLE;

	ptdev->owner = PKVM_PTDEV_OWNER_HOST;
	ptdev->assignment_state = PKVM_PTDEV_DETACHED;
	ptdev->touched_bar_mask = 0;
	return 0;
}
```

该 helper 故意在失败时提前 return，从而保留 `RESTORING + owner=HYP + touched_bar_mask`，避免假成功清理。

- [ ] **步骤 3：按 A/C/B 顺序重构 `pkvm_attach_ptdev()`**

在设置 `shadow_vm_handle` 后、修改 `ptdev->pgt` 前执行 A：

```c
	ret = pkvm_revoke_ptdev_bars_locked(ptdev);
	if (ret) {
		pkvm_restore_ptdev_bars_locked(vm, ptdev, true);
		ptdev->shadow_vm_handle = 0;
		pkvm_spin_unlock(&ptdev->lock);
		pkvm_put_ptdev(ptdev);
		return ret;
	}
```

C 阶段切换 DMA 视图，但只在 sync 成功后设置 `dma_view_ready`：

```c
	WRITE_ONCE(ptdev->dma_blocked, false);
	ptdev->dma_view_ready = false;
	ptdev->pgt = &vm->pgstate_pgt;
```

`pkvm_iommu_sync()` 成功后执行：

```c
	pkvm_spin_lock(&ptdev->lock);
	ptdev->dma_view_ready = true;
	ret = pkvm_publish_ptdev_mmio_contract_locked(vm, ptdev);
	pkvm_spin_unlock(&ptdev->lock);
	if (ret) {
		pkvm_detach_ptdev(ptdev, vm);
		return ret;
	}
```

`pkvm_iommu_sync()` 失败且 C 尚未 commit 时，不再盲目走旧 detach，而是执行 C 前 rollback：

```c
	if (pkvm_iommu_sync(ptdev->bdf, ptdev->pasid)) {
		pkvm_spin_lock(&ptdev->lock);
		ptdev->pgt = pkvm_hyp->host_vm.ept;
		pkvm_restore_ptdev_bars_locked(vm, ptdev, true);
		ptdev->shadow_vm_handle = 0;
		pkvm_spin_unlock(&ptdev->lock);
		pkvm_shadow_vm_unlink_ptdev(vm, &ptdev->vm_node,
						ptdev->iommu_coherency);
		pkvm_put_ptdev(ptdev);
		return -ENODEV;
	}
```

- [ ] **步骤 4：检查锁顺序**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git diff -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c | sed -n '/int pkvm_attach_ptdev/,/^}/p'
```

期望：

```text
# A 状态更新在 ptdev->lock 下完成
# pkvm_shadow_vm_link_ptdev() 仍在 ptdev->lock 外执行
# dma_view_ready 只在 pkvm_iommu_sync() 成功后置 true
```

- [ ] **步骤 5：运行窄范围静态检查**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git diff --check -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
git grep -n "dma_view_ready = true\|pkvm_revoke_ptdev_bars_locked\|pkvm_restore_ptdev_bars_locked" -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
```

期望：

```text
# git diff --check 无输出
# grep 显示 A/C/B 和 restore 辅助函数 调用点
```

- [ ] **步骤 6：提交 A/C/B attach 流程**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git add arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
git commit -m '接入 ptdev BAR donate attach 主线' -m '按 A/C/B 顺序执行 Host BAR revoke、DMA view commit 和 guest MMIO contract publish，并补齐 C 前失败回滚。'
git log -1 --format=%s
```

期望：

```text
接入 ptdev BAR donate attach 主线
```

### 任务 6：通过 detach / teardown 进入 restore 辅助函数

**文件：**
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- 复核 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c`

- [ ] **步骤 1：重构 `pkvm_detach_ptdev()` 使用 restore 辅助函数**

在 `pkvm_detach_ptdev()` 中，将早期状态重置改为 restore-aware 顺序：

```c
	pkvm_spin_lock(&ptdev->lock);
	ret = pkvm_restore_ptdev_bars_locked(vm, ptdev,
					       READ_ONCE(ptdev->dma_blocked));
	if (ret) {
		pkvm_err("pkvm: detach ptdev restore failed bdf=0x%x pasid=0x%x ret=%d\n",
			 ptdev->bdf, ptdev->pasid, ret);
		pkvm_spin_unlock(&ptdev->lock);
		return;
	}

	ptdev->shadow_vm_handle = 0;
	WRITE_ONCE(ptdev->dma_blocked, false);
	ptdev->dma_view_ready = false;
	ptdev->mmio_metadata_valid = false;
	ptdev->guest_contract_published = false;
	memset(&ptdev->mmio_metadata, 0, sizeof(ptdev->mmio_metadata));
	ptdev->pgt = pkvm_hyp->host_vm.ept;
	pkvm_spin_unlock(&ptdev->lock);
```

保留后面的 unlink / sync / put 收尾，但如果 allowlist 已由 `pkvm_restore_ptdev_bars_locked()` withdraw，则删除旧的 `had_metadata` allowlist 清理分支。

- [ ] **步骤 2：保留 teardown caller 顺序**

复核 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/pkvm.c` 中的：

```c
list_for_each_entry_safe(ptdev, tmp, &vm->ptdev_head, vm_node)
	pkvm_detach_ptdev(ptdev, vm);
```

如果 `pkvm_detach_ptdev()` 已经 restore-aware，这里无需修改。前置 DMA-safe 条件由高层 `pkvm_quiesce_shadow_vm_ptdevs()` 提供。

- [ ] **步骤 3：确认 C commit 前 detach 不需要 quiesce**

确认 `pkvm_restore_ptdev_bars_locked()` 在以下条件成立时允许 restore：

```text
ptdev->dma_view_ready == false
```

这覆盖 attach-fail before C commit 的路径。

- [ ] **步骤 4：运行窄范围静态检查**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git diff --check -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c arch/x86/kvm/vmx/pkvm/hyp/pkvm.c
git grep -n "detach ptdev restore failed\|pkvm_restore_ptdev_bars_locked" -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
```

期望：

```text
# git diff --check 无输出
# grep 显示 restore 辅助函数 和 detach failure log
```

- [ ] **步骤 5：提交 restore-aware detach**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git add arch/x86/kvm/vmx/pkvm/hyp/ptdev.c arch/x86/kvm/vmx/pkvm/hyp/pkvm.c
git commit -m '通过统一 helper 恢复 ptdev BAR' -m '让 detach/teardown 复用 BAR restore 约定，按 guest contract、DMA view、Host BAR visibility 和 bookkeeping 四平面收口。'
git log -1 --format=%s
```

期望：

```text
通过统一 helper 恢复 ptdev BAR
```

### 任务 7：增加 bring-up 诊断点和 guard rail

**文件：**
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ptdev.c`
- 修改 `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/ept.c`

- [ ] **步骤 1：增加 attach/revoke bring-up 日志**

在 `pkvm_revoke_ptdev_bars_locked()` 每个 BAR annotation 成功后增加：

```c
pkvm_dbg("pkvm: ptdev BAR revoked bdf=0x%x bar=%d hpa=0x%llx size=0x%llx\n",
	 ptdev->bdf, idx, bar->hpa, bar->size);
```

- [ ] **步骤 2：增加 restore bring-up 日志**

在 `pkvm_restore_ptdev_bars_locked()` 每个 BAR idmap restore 成功后增加：

```c
pkvm_dbg("pkvm: ptdev BAR restored bdf=0x%x bar=%d hpa=0x%llx size=0x%llx\n",
	 ptdev->bdf, idx, bar->hpa, bar->size);
```

- [ ] **步骤 3：保持 deny-remap 日志最小化**

`handle_host_ept_violation()` 的 annotated Host fault deny 分支只保留一处 `pkvm_err()`；不要为每次普通 MMIO fault 增加噪声日志。

- [ ] **步骤 4：运行日志 grep 检查**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git grep -n "ptdev BAR revoked\|ptdev BAR restored\|deny host BAR remap" -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c arch/x86/kvm/vmx/pkvm/hyp/ept.c
```

期望：

```text
# ptdev.c 中能看到 revoked/restored 日志
# ept.c 中能看到 deny host BAR remap 日志
```

- [ ] **步骤 5：提交诊断日志**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git add arch/x86/kvm/vmx/pkvm/hyp/ptdev.c arch/x86/kvm/vmx/pkvm/hyp/ept.c
git commit -m '补充 ptdev BAR donate 诊断日志' -m '为第一阶段 bring-up 提供 BAR revoke、restore 和 Host deny-remap 的最小证据点。'
git log -1 --format=%s
```

期望：

```text
补充 ptdev BAR donate 诊断日志
```

### 任务 8：最小验证

**文件：**
- 不要求代码修改。
- 用户执行运行验证后，可在 `pkvm-x86/DOCS/.../实施跟踪/验证记录/` 下新增验证记录。

- [ ] **步骤 1：运行源码级检查**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
git diff --check HEAD~5..HEAD
git grep -n "OWNER_ID_PTDEV_MMIO" -- arch/x86/kvm/vmx/pkvm/hyp
git grep -n "pkvm_update_vm_mmio_allowlist(vm, metadata)" -- arch/x86/kvm/vmx/pkvm/hyp || true
git grep -n "dma_view_ready = true" -- arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
```

期望：

```text
# diff check 无输出
# OWNER_ID_PTDEV_MMIO 有定义和 ept/ptdev 使用点
# 直接 metadata allowlist grep 无输出
# dma_view_ready = true 只出现在 pkvm_iommu_sync() 成功后的路径
```

- [ ] **步骤 2：对变更文件运行 checkpatch**

运行：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
scripts/checkpatch.pl --no-tree --strict --file \
  arch/x86/kvm/vmx/pkvm/hyp/mem_protect.h \
  arch/x86/kvm/vmx/pkvm/hyp/mem_protect.c \
  arch/x86/kvm/vmx/pkvm/hyp/ept.h \
  arch/x86/kvm/vmx/pkvm/hyp/ept.c \
  arch/x86/kvm/vmx/pkvm/hyp/ptdev.h \
  arch/x86/kvm/vmx/pkvm/hyp/ptdev.c
```

期望：

```text
# touched code 不出现 ERROR
# 若出现既有风格 warning，只记录，不在本 PR 中顺手修无关问题
```

- [ ] **步骤 3：给出最小 object build 目标，默认不运行**

除非用户确认，否则不要执行内核编译。若用户确认，使用 object targets，而不是全量构建：

```bash
cd /home/mrgeek/pkvm-x86/pKVM-IA
make O=/home/mrgeek/pkvm-x86/build-host arch/x86/kvm/vmx/pkvm/hyp/ept.o
make O=/home/mrgeek/pkvm-x86/build-host arch/x86/kvm/vmx/pkvm/hyp/ptdev.o
make O=/home/mrgeek/pkvm-x86/build-host arch/x86/kvm/vmx/pkvm/hyp/mem_protect.o
```

期望：

```text
# 每个 object target exit 0
```

如果 build tree 缺少 `.config`，不要自动生成配置；记录为验证阻塞，并让用户确认应使用哪个构建树。

- [ ] **步骤 4：手工运行验证矩阵**

复用现有 protected pVM + VFIO 启动方式，并把日志记录到：

```text
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/
```

最小观察项：

```text
Case A: protected pVM attach with VFIO device
  expected: 每个 managed BAR 出现 ptdev BAR revoked 日志
  expected: A/C/B 后 guest DIRECT_BAR metadata query 仍返回 direct ranges
  expected: guest 继续到达现有 passthrough 正向里程碑

Case B: Host touches assigned BAR after attach
  expected: 出现 deny host BAR remap 日志
  expected: Host EPT 不会 lazy-map annotated BAR

Case C: protected pVM teardown after attach
  expected: quiesce/block DMA 先于 detach restore
  expected: 出现 ptdev BAR restored 日志
  expected: 成功 detach 后不残留 RESTORING + owner=HYP

Case D: metadata arrives before attach completes
  expected: metadata hypercall 返回成功
  expected: allowlist 直到 owner=HYP 且 dma_view_ready=1 后才发布

Case E: attach failure before C commit
  expected: touched BARs 无需 DMA quiesce 即可 restore
  expected: rollback 成功后 touched_bar_mask 清零
```

- [ ] **步骤 5：记录验证证据**

用户完成运行验证后，新建：

```text
/home/mrgeek/pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/验证记录/t12-mmio-donate-phase1-YYYYMMDD.md
```

模板：

```markdown
# T12 MMIO donate 第一阶段验证记录 - YYYY-MM-DD

## 内核仓库

- `pKVM-IA` 分支： `codex/t12-mmio-donate-phase1`
- `pKVM-IA` 提交： 运行 `git -C /home/mrgeek/pkvm-x86/pKVM-IA rev-parse --short HEAD`，并粘贴输出的 commit id

## 执行命令

```bash
粘贴 shell history 中实际执行过的命令
```

## 验证结果

- 场景 A：
- 场景 B：
- 场景 C：
- 场景 D：
- 场景 E：

## 关键日志

```text
每个关键签名粘贴 3-10 行原始日志
```

## 后续问题

- 是否需要新建 Bug 类型 issue：是/否
- 是否需要新建 Task 类型 issue：是/否
```

### 任务 9：文档、GitHub 与 PR 交接

**文件：**
- 修改 `pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/当前进度.md`
- 修改 `pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/README.md`
- 仅当实现改变已约定接口时，修改 `pkvm-x86/DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T12-B5-3-protected-pVM-device-MMIO-donate-机制总设计.md`

- [ ] **步骤 1：更新本地跟踪状态**

在 `当前进度.md` 的 T12 下一步中写入：

```markdown
  - `T12` 第一阶段实现规划已完成：[`实施跟踪/01E-T12-B5-3-device-MMIO-donate-第一阶段实现规划.md`](实施跟踪/01E-T12-B5-3-device-MMIO-donate-第一阶段实现规划.md)
  - 下一步进入 `pKVM-IA` 短生命周期分支的最小补丁序列：Host EPT 标注辅助函数 -> Host fault 拒绝重映射 -> `ptdev` BAR 状态 -> metadata 缓存与 guest 约定发布拆分 -> A/C/B attach -> restore 辅助函数
```

- [ ] **步骤 2：更新实施跟踪 README**

在 `实施跟踪/README.md` 的 T12 入口附近增加：

```markdown
- [`01E-T12-B5-3-device-MMIO-donate-第一阶段实现规划.md`](01E-T12-B5-3-device-MMIO-donate-第一阶段实现规划.md)
  - 作为 `T12` 第一阶段实现规划，拆分 Host EPT annotation、`ptdev` BAR 状态、metadata 发布、A/C/B attach、restore 辅助函数和验证矩阵。
```

- [ ] **步骤 3：同步 GitHub issue #34**

运行：

```bash
cd /home/mrgeek/pkvm-x86
gh issue comment 34 --repo MrGeek-zrh/pkvm-x86 --body '2026-04-24 同步：T12 设备 MMIO donate 第一阶段实现规划已落到本地文档 `DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T12-B5-3-device-MMIO-donate-第一阶段实现规划.md`。计划拆分为 Host EPT 标注辅助函数、Host fault 拒绝重映射、`ptdev` BAR 权威状态、metadata 缓存与发布拆分、A/C/B attach、restore 辅助函数、最小验证和 PR 交接。下一步进入 pKVM-IA 短生命周期分支实现。'
```

期望：

```text
https://github.com/MrGeek-zrh/pkvm-x86/issues/34#issuecomment-...
```

- [ ] **步骤 4：提交 superproject 规划文档**

运行：

```bash
cd /home/mrgeek/pkvm-x86
git add DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/01E-T12-B5-3-device-MMIO-donate-第一阶段实现规划.md \
        DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/实施跟踪/README.md \
        DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/当前进度.md
git commit -m '补充 T12 donate 第一阶段实现规划' -m '拆分 Host EPT annotation、ptdev BAR 状态、metadata 发布、A/C/B attach 和 restore 验证路径。'
git log -1 --format=%s
```

期望：

```text
补充 T12 donate 第一阶段实现规划
```

## 自查清单

- [ ] 总设计 D0-D9 的每个决策都能映射到本规划任务。
- [ ] 默认不要求全量内核构建。
- [ ] Host EPT annotation 使用非 0 的 `OWNER_ID_PTDEV_MMIO`，而不是 `OWNER_ID_HYP`。
- [ ] guest allowlist publish 受 `owner=HYP` 和 `dma_view_ready=1` 约束。
- [ ] restore 资源范围是 `touched_bar_mask`，完整 rollback 覆盖四个平面。
- [ ] `T6` remove-path 作为后续任务引用，不作为第一阶段完成条件。
- [ ] 未来发到 GitHub 的调用链/状态机继续使用 fenced code block。
