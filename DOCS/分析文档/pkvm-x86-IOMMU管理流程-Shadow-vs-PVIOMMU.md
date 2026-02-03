# pKVM-IA（pkvm-x86）IOMMU 管理流程梳理：Shadow IOMMU vs pvIOMMU

更新时间：2026-02-03  
适用范围：本仓库 `pKVM-IA` + `linux` 树，在 Guest 内核启用 `kvm-intel.pkvm=1`，并使用 QEMU `-device intel-iommu` 暴露 vIOMMU。

本文目标：把 **不开 `CONFIG_PKVM_INTEL_PVIOMMU`（shadow IOMMU）** 与 **开启 `CONFIG_PKVM_INTEL_PVIOMMU`（pvIOMMU）** 两种模式下，IOMMU 从“发现/初始化”到“拦截寄存器访问/接管翻译”的完整链路用“缩进代码 + 文字解释”的方式梳理清楚。

---

## 0. 核心概念：host 驱动视角 vs pkvm/hyp 视角

**host 驱动视角（Linux Intel VT-d 驱动）**

- host 侧代码仍然走 `drivers/iommu/intel/*` 的常规初始化流程（`intel_iommu_init()` 等）。
- 但当 pKVM 启用后，IOMMU 的 MMIO 读写会被改道：host 驱动调用 `dmar_readl()/dmar_writel()` 之类的宏，最终走到 `pkvm_readl()/pkvm_writel()` 触发 hypercall（`iommu_mmio_access`）。

**pkvm/hyp 视角（VMX root 的 pKVM hypervisor）**

- hypervisor 收到 `iommu_mmio_access` hypercall 后，在 `pkvm_access_iommu()` 中决定“这次访问是模拟一部分寄存器，还是直接透传给硬件 IOMMU”。
- 对 `GCMD/RTADDR/GSTS/IQA/IQH/IQT` 等关键寄存器，pKVM 维护一份“虚拟寄存器视图”（`viommu.vreg`），并在 SRTP/TE/QI 等命令触发时执行自己的处理逻辑。

---

## 1. 启动阶段：IOMMU 初始化入口如何被 pKVM “改道”

### 1.1 传统 x86 启动（无 pkvm）的大体结构（对照用）

```text
start_kernel
  x86_init.iommu.iommu_init
    intel_iommu_init
      ...（解析 DMAR / 探测 CAP/ECAP / 设置 root table / 开 QI/IR/TE 等）
```

### 1.2 pkvm 启用后的结构（关键：prepare/init hooks）

```text
vmx_init
  vmx_pkvm_init
    pkvm_iommu_driver_prepare
      dmar_table_init

    __vmx_pkvm_init
      pkvm_host_deprivilege_cpus
        ...（所有 CPU 进入 VMX non-root，host 变成“guest”跑）

      pkvm_iommu_driver_init
        intel_iommu_init
          iommu_set_root_entry
          ...
```

**解释**

- `dmar_table_init()`：提前解析 ACPI DMAR 表、枚举 DRHD/RMRR 等，建立 `drhd` 链表与 IOMMU 拓扑（后续 `intel_iommu_init()` 要用）。
- `pkvm_host_deprivilege_cpus()`：将 host 内核降权成 VMX non-root 运行，pKVM hypervisor 处于 VMX root。
- `intel_iommu_init()`：仍由 host 驱动执行，但其对 IOMMU 寄存器的访问会通过 hypercall 进入 VMX root，由 pKVM 决定如何处理。

---

## 2. 发现/探测阶段：check_and_init_iommu（以 DRHD 遍历为线索）

这部分两个模式差异不大：都是 host 驱动基于 DMAR 表去探测 IOMMU 的能力。

```text
vmx_init
  vmx_pkvm_init
    pkvm_iommu_driver_prepare
      dmar_table_init
        for_each_dmar_drhd_unit(drhd)
          drhd->reg_base_addr = DRHD.base_address
          ...（记录 iommu 单元）

    __vmx_pkvm_init
      (deprivilege 已完成)
      pkvm_iommu_driver_init
        intel_iommu_init
          check_and_init_iommu
            for_each_drhd_unit(drhd)
              iommu->reg = ioremap(drhd->reg_base_addr)
              read DMAR_CAP / DMAR_ECAP
              read DMAR_GSTS / DMAR_RTADDR
              decide:
                queued invalidation (QI)
                interrupt remapping (IR)
                scalable mode (SM)
              ...
```

**解释**

- `CAP/ECAP`：决定是否支持 queued invalidation / scalable mode / page-walk coherency 等。
- `GSTS/RTADDR`：决定当前硬件状态、root table 是否已经设过等。
- 到这里为止，host 驱动的“读寄存器”在 pkvm 模式下也可能被 pKVM 部分模拟（例如 `CAP/ECAP/GSTS` 等），从而让 host 驱动看到一个“符合 pKVM 策略”的能力集合。

---

## 3. 关键分叉点：host 写 RTADDR + GCMD(SRTP) 后发生了什么

这一步是你之前 panic 的直接触发点：host 驱动发出 SRTP 后等待 `GSTS.RTPS` 置位。

### 3.1 host 侧视角（两种模式一致）

```text
intel_iommu_init
  iommu_set_root_entry
    dmar_writeq(DMAR_RTADDR_REG, root_pa)
    dmar_writel(DMAR_GCMD_REG, ... | DMA_GCMD_SRTP)
    IOMMU_WAIT_OP(DMAR_GSTS_REG, (sts & DMA_GSTS_RTPS))
```

在 pkvm-x86 中，`dmar_readl/dmar_writel/...` 宏会走到 `pkvm_readl/pkvm_writel/...`，触发 hypercall：

```text
dmar_writel -> pkvm_writel
  pkvm_hypercall(iommu_mmio_access, is_read=false, len=4, phys, val)
```

### 3.2 pkvm/hyp 侧视角：拦截/模拟 IOMMU MMIO

```text
VMExit (hypercalls)
  __pkvm__iommu_mmio_access
    pkvm_access_iommu(is_read, len, phys, val)
      access_iommu_mmio(...)
        switch(offset)
          DMAR_RTADDR_REG: 记录 viommu.vreg.rta = val
          DMAR_GCMD_REG:
            handle_global_cmd(val)
              if (val & DMA_GCMD_SRTP)
                handle_gcmd_srtp()
              if (changed & DMA_GCMD_TE)
                handle_gcmd_te()
              if (changed & DMA_GCMD_QIE)
                handle_gcmd_qie()
          DMAR_GSTS_REG: 返回 viommu.vreg.gsts
          default: direct_access_iommu_mmio (透传真实硬件)
```

源码入口（本仓库）：

- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/vmexit.c`：hypercall dispatch
- `pKVM-IA/arch/x86/kvm/vmx/pkvm/hyp/iommu.c`：`pkvm_access_iommu()` / `access_iommu_mmio()` / `handle_gcmd_srtp()`

---

## 4. Shadow IOMMU（不开 PVIOMMU）下的“接管与保护”流程

### 4.1 内存与数据结构：iommu_mem_base / iommu_pool

```text
pkvm 初始化（VMX root）
  divide_memory_pool
    iommu_mem_base = pkvm_early_alloc_contig(nr_pages)

  create_iommu
    pkvm_init_iommu(mem_base=phys(iommu_mem_base), nr_pages)
      hyp_pool_init(&iommu_pool, mem_base_pfn, nr_pages)
      （后续 iommu_zalloc_pages 从 iommu_pool 分配）
```

目的：保证 hypervisor 侧 IOMMU 相关结构（QI desc、shadow IOMMU 页表、状态数组等）有稳定的内存来源。

### 4.2 SRTP 处理：activate_iommu() 典型步骤（shadow）

```text
handle_gcmd_srtp(iommu)
  activate_iommu(iommu)
    initialize_qi(iommu)
      allocate qi->desc / qi->desc_status from iommu_pool
      program real hardware IQA + enable QI (写硬件寄存器并 wait QIES)

    initialize_iommu_pgt(iommu)
      allocate shadow IOMMU pgtable root (iommu->pgt.root_pa)

    sync_shadow_id(iommu, ...)
      将 host 视角的 IOMMU 翻译结构同步/投影到 shadow 结构

    set_root_table(iommu)
      将 IOMMU root table 指向 pKVM 维护/控制的结构

    pkvm_host_ept_unmap(iommu MMIO range)
      从 host EPT 中移除 IOMMU MMIO 直通映射，确保 host 后续访问必须走 hypercall

  vreg->gsts |= DMA_GSTS_RTPS    （host 再读 GSTS 就能看到 RTPS=1）
```

**解释**

- shadow 模式的核心是：pKVM 在 hypervisor 内维护自己的 IOMMU 翻译/保护视图，必要时同步 host 的配置并施加限制。
- `pkvm_host_ept_unmap()` 是“收口动作”：避免 host 绕过 hypercall 直接 MMIO IOMMU。

---

## 5. pvIOMMU（开启 PVIOMMU）下的“接管与保护”流程

### 5.1 设计意图：不再固定预留 iommu_mem_base/iommu_pool

pvIOMMU 的目标是减少 pKVM 预留内存 footprint：IOMMU 相关结构的内存由 host 动态分配，并在需要时 donate 给 hypervisor。

对应表现（你提到的 commit message 要点）：

- `divide_memory_pool()` 不再为 IOMMU 单独切一块 `iommu_mem_base`
- `pkvm_init_iommu()` 不再 `hyp_pool_init(&iommu_pool, ...)`

### 5.2 预期（理想）SRTP 流程：以 donate 的页为基础

```text
handle_gcmd_srtp(iommu)
  （pvIOMMU 目标：IOMMU 翻译结构/必要缓冲由 host 提供并 donate）

  if need root table:
    iommu->pgt.root_pa = host_provided_root_pa
    __pkvm_host_donate_hyp_share_ro(root_pa, VTD_PAGE_SIZE)

  if need QI memory:
    use host provided IQA ring (or host donates a new ring)
    take ownership / pin / share-as-needed

  program hardware / update vreg->gsts.RTPS
```

### 5.3 当前仓库实际问题（与你的 panic 对应）

你遇到的 panic 属于 “pvIOMMU 关闭预留内存” 与 “实现仍依赖 iommu_pool 分配” 之间的不自洽：

```text
pvIOMMU enabled
  divide_memory_pool: 不分配 iommu_mem_base
  pkvm_init_iommu: 不 hyp_pool_init(iommu_pool)

但是：
  handle_gcmd_srtp
    activate_iommu
      initialize_qi
        qi->desc = iommu_zalloc_pages(8192)  // 仍从 iommu_pool 分配
        -> hyp_alloc_pages(&iommu_pool, order=1) = -ENOMEM

结果：
  SRTP 失败 -> vreg.gsts 不置 RTPS -> host IOMMU_WAIT_OP 超时 -> panic
```

这也是为什么“方案 1：关闭 `CONFIG_PKVM_INTEL_PVIOMMU`”能直接绕过该问题并成功启动。

---

## 6. 一句话对比（方便快速回忆）

```text
Shadow IOMMU:
  - pKVM 预留/自管 IOMMU 内存池（iommu_mem_base/iommu_pool）
  - pKVM 维护 shadow 翻译结构并同步/限制
  - SRTP 路径依赖 iommu_pool 分配 QI / shadow pgtable 等

pvIOMMU:
  - 目标：不预留 IOMMU 内存池，host 动态分配并 donate
  - pKVM 更“直接”拥有/管理 IOMMU 硬件与关键结构
  - 要求实现完全改成 donate 路线，否则会出现 -ENOMEM/RTPS 超时类问题
```

