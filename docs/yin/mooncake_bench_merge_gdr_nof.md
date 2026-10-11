# stress_cluster_bench 合并 NoF 测试支持 + GDR (gdr-peermem) 报告

> 本文记录 `nof-urma-v2-bench-merge` 分支把两处独立改造（NoF 测试支持 + GDR/GPU
> 显存写入）合并进 `stress_cluster_bench` 的全部工作：源码分析、合并改动、
> 编译部署指南。操作手册见 [`Deployment/mooncake_deployment_gdr.md`](./Deployment/mooncake_deployment_gdr.md)。
>
> 日期：2026-10-11。分支 `nof-urma-v2-bench-merge`（基于 `nof-urma-v2`）。

---

## 0. 这是什么

`stress_cluster_bench`（`mooncake-store/benchmarks/stress_cluster_bench.cpp`）
原本是纯 CPU（NUMA）内存读写基准。两处独立改造分别位于两个分支，要并入当前
工作分支 `nof-urma-v2`（该分支已有 NoF/URMA v6 传输栈，但 bench 文件本身仍是
共同祖先 `86c34829` 版本、未动过）：

1. **NoF 测试支持** —— `ZhiningPan/Mooncake` 分支 `nof-urma-v2-ChangeCMakeLists`：
   缺的只有 2 个只碰 bench 的 commit；其余 16 个 = nof-urma-v2 已 rebase 成 v6 的
   同一套 NoF 传输栈，不合并。
2. **GDR（GPUDirect RDMA，GPU 显存写入 Mooncake）** —— `yyyuanhao426-hash/Mooncake`
   分支 `supercache-gds`：6 个动 bench 的 commit + 缺失的 UB transport GPU 基础设施。

**目标产物**：同一个 `stress_cluster_bench` 二进制分别支持两条传输路径：
- `--nof_replica_num=N` / `--nof_segments=...` / `list_segments`（NoF/URMA 路径）
- `--gpu_mode=gdr-peermem|staging` / `--gpu_device`（UB + GPU 路径，gdr-peermem
  = NIC 经 vendor P2P 直连 DMA GPU HBM）

> ⚠️ **两条 GDR 路径要分清**。本仓库（Mooncake）里有两套独立的 GPU Direct 实现：
> - **Store NoF → SSD**（`nof_worker_pool_bench --memory=cuda`，SPDK memory domain，
>   见 `mooncake_nof_architecture.md` §3.2）：数据从 SSD 直达 GPU 显存，走 SPDK 侧。
> - **Transfer Engine UB transport → GPU HBM**（本文的 `stress_cluster_bench
>   --gpu_mode=gdr-peermem`）：数据从远端内存经 UB transport 直达 GPU HBM，走
>   Mooncake Transfer Engine 的 kunpeng UB transport 侧。
>
> 本文全程讲的是**第二条**。两条互不影响，可共存于同一构建。

---

## 1. 源码分析

### 1.1 上游两个 bench 来源分支

**NoF 来源**（`ZhiningPan/Mooncake` 分支 `nof-urma-v2-ChangeCMakeLists`）：
只需 cherry-pick 2 个 bench-only commit，其余 16 个 commit = nof-urma-v2 已
rebase 成 v6 的同一套 NoF 传输栈，内容等价、不合并。

| commit | 内容 |
|---|---|
| `7fa2b516` | NoF SSD 副本 `--nof_replica_num` + `MakeReplicateConfig()`/`RecordPutResult()` 抽取 + PUT 延迟统计 + `FinalizeSequential` 输出 |
| `82875baa` | NoF segment `--nof_segments` + `DiscoverNoFSegmentsFromMaster` + `SegmentKind{MEMORY,NOF}`/`BenchmarkSegment` 重构 + `list_segments` 场景 |

NoF bench 依赖的 API 在 nof-urma-v2 全在：`GetAllNoFSegments`（`master_client.h`）、
`preferred_segments`（`replica.h`）、`ReplicateConfig.replica_num`。

**GDR 来源**（`yyyuanhao426-hash/Mooncake` 分支 `supercache-gds`）：
6 个动 bench 的 commit + UB transport GPU 基础设施。该分支是 219 文件的大改动，
混有 scheduler / io_pattern / batch io_uring 等无关工作，**不能整文件拷**——只抽
bench commit 与 UB GPU 基础设施切片。

6 个 bench commit 的应用顺序（**跳过 `b0cfca97`**，它是 merge，bench 净贡献已含
在 `b9d82b12`+`e985e3a3`）：

| commit | 内容 |
|---|---|
| `b9d82b12` | include `cuda_alike.h`/`ub_allocator.h`；DEFINE `gpu_mode`/`gpu_device` + `GpuRuntimeConfig` + `ResolveGpuConfig()`/`ValidateGpuDevice()`/`ApplyGpuEnv()`（设 `MC_UB_GPU_MODE`）+ `checkCudaError()`；析构/`Setup()`/`AllocateThreadBuffers()` 按 `is_gpu` 分叉到 `ub_allocate_gpu_hbm`/`ub_free_gpu_hbm`；`FillBuffer/CheckBuffer` 用 thread_local shadow + `cudaMemcpy` H2D/D2H；main 加 writer-role 禁 `--gpu_mode` 守卫 |
| `e985e3a3` | 分级日志（Setup/Fill/Check 各 VLOG，main 加 `MC_VERBOSE`→`FLAGS_v`） |
| `875e0af4` | `BenchmarkStats::Print()` 加 Parameters 块 + Throughput (peak/avg/cur) + P9999；`RunSegmentReadDuration` FinalSummary 同款 |
| `9524f6ea` | `Setup()` 中 gdr-peermem 强制 `FLAGS_global_segment_size=0` |
| `30592dc9` | gdr-peermem 单块连续 HBM 分配（`(1+num_threads)*buffer_size_` 一次 `ub_allocate_gpu_hbm` + 一次 register），线程 buffer 为 `buffer_+(1+t)*per_buf_size` 子区域，跳过逐线程 register/free |

### 1.2 用户自身 GDR 实现源码（`/home/senorita/GDR/`）

对照 `/home/senorita/GDR/` 三件套 + `/home/senorita/nof/spdk` fork 的探查结论
（2026-10-11）。这是 HiSilicon UnifiedBus (UB) / URMA 栈，**不是 InfiniBand**——
有自己的 IOMMU 类硬件（"UMMU"）和自己的 NIC DMA 引擎（udma）。

**三个内核模块各司其职**（关键架构事实）：

| 模块 | 角色 | 是否 pin GPU 内存 |
|---|---|---|
| `nvidia.ko`（或 `metax.ko`） | GPU 厂商驱动，导出 P2P pin API，拥有 GPU 内存 | （导出 API） |
| `ummu.ko`（`kernel_ummu/`） | HiSilicon UMMU IOMMU 硬件驱动，做 VA→PA 翻译给 UB NIC | 否，只装翻译表项 |
| `udma.ko` + `udma_nv_p2p_bridge.ko` / `udma_metax_p2p_bridge.ko`（`urma_driver/`） | UB NIC DMA 驱动 + 厂商桥；桥调 `nvidia_p2p_get_pages` pin GPU 页，把物理地址喂给 ummu | 是（经桥） |

> ⚠️ **栈故意旁路 `nvidia_peermem.ko`**（`urma_driver/docs/GPU_P2P_PATENT_BRIEF.md:91-104`，
> 专利点 C「旁路 peermem client」）。原因是 `inherit_taint()` 会让 `TAINT_PROPRIETARY_MODULE`
> 从 nvidia.ko 经桥传播到 udma.ko，复现「Unknown symbol」。v2 设计**反转依赖**：桥在
> `module_init` 调 `udma_register_gpu_p2p_ops()` 注册函数指针，udma.ko 经指针调桥——
> 函数指针调用不走模块加载器的 `resolve_symbol()`，`inherit_taint()` 不触发。
> 加载顺序：`nvidia.ko → udma.ko → udma_nv_p2p_bridge.ko`（桥最后，init 里调 udma.ko
> 的导出）。**因此 bench 的 `MC_UB_GPU_MODE=gdr-peermem` 只是 mooncake transport-mode
> 名，不等于 `modprobe nvidia_peermem`。**

**用户态契约（核心）**：`urma_seg_cfg_t.is_gpu_seg` 是真实存在的 `uint32_t` 字段
（`UMDK_netlab/src/urma/lib/urma/core/include/urma_types.h:999`），**不是 skeleton**——
dma-buf 路径 `urma_register_seg_dmabuf()` 才是 skeleton（返回 `EOPNOTSUPP`，
`urma_seg_dmabuf.c:110-116`）。三处使用方（UMDK perftest / SPDK nvme_urma /
本合并的 mooncake）用**同一机制**：

```
userspace seg_cfg.is_gpu_seg = 1
  → udma_u_register_seg(): pack 进 struct udma_register_seg_ucmd
      {uint32_t is_gpu_seg; uint32_t reserved;} (udma_gpu_p2p.h:35-38)
      经 ubcore_udata->udrv_data 传递（不走 flag.value，避免 bit 冲突）
  → uburma_cmd_register_seg → ubcore_register_seg（用 ORIGINAL flag 校验）
  → udma_register_seg(): udma_seg_ucmd_is_gpu() copy_from_user 读回
      校验通过后置本地 UBCORE_REG_SEG_GPU_VA (BIT(15)) 于 tmp_cfg
  → udma_pin_pages_and_ioummu_map / isolated path
      udma_seg_cfg_is_gpu()==true → udma_gpu_pin_seg_pages()
          ops->pin(gpu_va, len, ...)  [厂商桥: nvidia_p2p_get_pages]
          取 pin.sgt (sg_page=NULL, sg_dma_address=GPU BAR/aperture PA)
      → ummu_sva_matt_map_phys_sg(gpu_va, sgt)
          [kernel_ummu/ummu-core/core_matt.c: iommu_map(iova=GPU VA, pa=GPU PA, IOMMU_MMIO)]
  → 数据面 NIC WQE 携带 GPU VA + token_id，UMMU 硬件翻译 VA→GPU PA→HBM
```

**GPU 内存分配契约**：`cuMemAlloc` + `cuMemSetSyncMemops`（或等价的
`cuPointerSetAttribute(SYNC_MEMOPS)`）——nvidia_p2p_get_pages 的现代 token-less 路径
要求 SYNC_MEMOPS 置位。UMDK perftest（`perftest_gpu_alloc.c:340-348`）、
本合并（`ub_allocator.cpp:105-126`）均如此。

**SPDK fork 侧**（`/home/senorita/nof/spdk`，分支 `urma_enable_v2`）：
SPDK 只在 `spdk_nvme_urma_register_memory()`（`lib/nvme/nvme_urma_common.c:398`）
置 `cfg.is_gpu_seg = (type==HOST)?0:1` 一处，把段配置经 liburma 往下传给内核。
SPDK 树内**没有**内核模块、没有 peermem hook——pin 发生在内核/UMDK 层。
 SPDK 还提供 dma-buf 路径（`urma_register_seg_dmabuf`），但那是 skeleton。

### 1.3 本合并与用户 GDR 栈的契约对齐

| 关注点 | 本合并代码 | 用户 GDR 栈 | 结论 |
|---|---|---|---|
| GPU 段标志 | `seg_cfg.is_gpu_seg = (type==kGpu)?1:0`（`urma_endpoint.cpp:368`） | `urma_seg_cfg_t.is_gpu_seg` 真实 `uint32_t`（`urma_types.h:999`） | ✓ 同机制 |
| 注册 API | `urma_register_seg(ctx,&seg_cfg)`（`urma_endpoint.cpp:371`） | 同 API，无单独入口 | ✓ |
| GPU 分配 | `cuMemAlloc` + `cuPointerSetAttribute(SYNC_MEMOPS)`（`ub_allocator.cpp`） | perftest `cuMemAlloc` + `cuMemSetSyncMemops` | ✓ 等价 |
| 内核机制 | 依赖内核 is_gpu_seg=1 时走 vendor P2P | udma 桥 `nvidia_p2p_get_pages` → 喂 UMMU `ummu_sva_matt_map_phys_sg` | ✓ 契约匹配 |
| dma-buf 路径 | 未实现（仅 peer-memory） | `urma_register_seg_dmabuf` 是 skeleton（EOPNOTSUPP） | ✓ 正确跳过 |
| CMake 探针 | `HAVE_URMA_SEG_CFG_IS_GPU_SEG` 编译期探测字段存在 | 字段确实存在 | ✓ 探针会成功，路径启用 |

**64KB 对齐**（已修复，见 §2.3）：NVIDIA 桥强制 GPU 段 VA 与长度均 64KB 对齐
（`udma_nv_p2p_bridge.c:107-123`，`UDMA_NV_GPU_PAGE_SIZE=SZ_64K`）。

---

## 2. 合并改动

### 2.1 落地的 6 个提交（在 `nof-urma-v2` 之上）

```
757d2135 fix(urma): GPU 段长度对齐到 64KB 以满足 NVIDIA P2P bridge 约束
b32b1c25 feat(bench): GDR bench 分级日志/吞吐统计/gdr-peermem 连续显存分配
16036a79 feat: add GPU link modes (gdr-peermem/staging) to stress_cluster_bench
897e0691 feat(urma): UB transport 支持 GPU Direct (gdr-peermem) 直连路径
712af9d5 feat(stress_cluster_bench): 添加NoF segment支持及segment列表功能
eb05f4a0 feat(bench): 添加NoF SSD副本支持与PUT延迟统计
```

| 提交 | 来源 | 内容 |
|---|---|---|
| `eb05f4a0` | ←`7fa2b516` | NoF SSD 副本 `--nof_replica_num` + PUT 延迟 |
| `712af9d5` | ←`82875baa` | NoF segment `--nof_segments` + `SegmentKind{MEMORY,NOF}` + `list_segments` |
| `897e0691` | Phase 2a | UB GPU 基础设施（`ub_allocate_gpu_hbm`/`UbGpuMode`/`UbMemoryRegionType`/`urma_seg_cfg_t.is_gpu_seg` 探测 + gdr-peermem 直连路径） |
| `16036a79` | ←`b9d82b12` | GDR 核心（`--gpu_mode`/`--gpu_device` + GPU buffer alloc/cudaMemcpy） |
| `b32b1c25` | ←`e985+875+9524+3059`(4合1) | 分级日志/吞吐统计(Parameters/Throughput peak\|avg\|cur/P9999)/gdr-peermem 连续 HBM 分配 |
| `757d2135` | 新增 | 64KB 对齐修复（见 §2.3） |

净改动 9 文件 / +894−164（不含 `757d2135` 的 +22/−4）。

### 2.2 改动文件清单与内容

**Phase 1 — NoF（2 commit，bench-only）**：
- `mooncake-store/benchmarks/stress_cluster_bench.cpp`：NoF SSD 副本 + segment
  + `list_segments`。仅碰 bench，不碰 CMake。

**Phase 2a — UB GPU 基础设施最小增量移植**（采用**最小增量**策略：保留
nof-urma-v2 现有 CPU-staging 机制，gdr-peermem 作为新增直连路径并存，不替换）：

| 文件 | 改动 |
|---|---|
| `include/ub_allocator.h` | 追加 3 声明：`ub_allocate_gpu_hbm`/`ub_free_gpu_hbm`/`ub_is_gpu_hbm` |
| `src/transport/kunpeng_transport/ub_allocator.cpp` | `#include <cstdint>`+`cuda_alike.h`；`#if defined(USE_CUDA)` 全局 `g_ub_gpu_hbm_mutex`+`g_ub_gpu_hbm_devices`；三函数实现（`cuInit`/`cudaSetDevice`/`cuMemAlloc`/`cuPointerSetAttribute(SYNC_MEMOPS)`/`cuMemFree`，带 `cuGetErrorString` 日志与 `#else LOG(ERROR)` 降级） |
| `include/transport/kunpeng_transport/ub_transport.h` | `enum class UbGpuMode{kHost,kStaging,kGdrPeermem}` + `gpuMode()`/`gpuModeName()` 声明。**不删**现有 StagingLease/StagingState |
| `src/transport/kunpeng_transport/ub_transport.cpp` | `gpuMode()`：读 `MC_UB_GPU_MODE`（host/staging/gdr-peermem），未设置回退现有 `MC_UB_TRANSPORT_CPU_STAGING` 语义。`registerLocalMemory()`/`submitTransferTask()` 分发：host=现有路径；staging=映射到现有 staging；gdr-peermem=新直连（`region_type=kGpu`，无 staging copy）。**保持** `isStagedSlice()` 守卫 |
| `include/transport/kunpeng_transport/ub_context.h` | `enum class UbMemoryRegionType{kHost,kGpu}`；`registerMemoryRegion` 加 `UbMemoryRegionType type = kHost` 默认参数 |
| `urma/urma_endpoint.h` + `.cpp` | override 签名同步；实现按 `urma_seg_cfg_t.is_gpu_seg` 字段（`#if defined(HAVE_URMA_SEG_CFG_IS_GPU_SEG)` 守卫）置 `is_gpu_seg = (type==kGpu)?1:0` |
| `kunpeng_transport/CMakeLists.txt` | `check_cxx_source_compiles` 探测 `urma_seg_cfg_t::is_gpu_seg` + `HAVE_URMA_SEG_CFG_IS_GPU_SEG=1`；失败时 STATUS（非 FATAL_ERROR）优雅降级 |

**Phase 2b — GDR bench（5 commit 合为 2 提交：`16036a79`+`b32b1c25`）**：
全部在 `stress_cluster_bench.cpp`。见 §1.1 的 commit 表。

### 2.3 64KB 对齐修复（`757d2135`）

对照 `udma_nv_p2p_bridge.c:107-123` 确认 NVIDIA P2P 桥要求 GPU 段 **VA 与长度
均 64KB 对齐**，否则 `nvidia_p2p_get_pages` 返回 `-EINVAL`。原 `ub_allocate_gpu_hbm`
传原始长度给 `cuMemAlloc`、`urma_endpoint registerMemoryRegion` 传原始长度给
`seg_cfg.len`，非对齐尺寸（如 `--value_size<64KB`）会注册失败。

修复两处，对齐 UMDK perftest 的 `align_up_size(size, 64KB)`：
- `ub_allocator.cpp`：`alloc_size = (total_size + 64KB-1) & ~(64KB-1)` 再
  `cuMemAlloc`（VA 由 `cuMemAlloc` 保证 GPU 页对齐，同 perftest 做法）。
- `urma_endpoint.cpp`：`type==kGpu` 时 `length` 向上取整 64KB 再填 `seg_cfg.len`
 （host 段保持原始长度）；仅 `HAVE_URMA_SEG_CFG_IS_GPU_SEG` 下生效。staging 路径
  走 `registerLogicalDeviceRegion`，不受影响。

默认 bench 尺寸（4MB×N）本就 64KB 对齐，此修复仅补全非对齐尺寸场景。

### 2.4 跳过项

- **`b0cfca97`**：supercache-gds 的 merge commit，bench 净贡献已含在
  `b9d82b12`+`e985e3a3`。
- **`e985e3a3` 的 `ub_transport.cpp`/`urma_endpoint.cpp` 改动**：引用 supercache-gds
  独有结构（`staging_map_`/`staged_read_slices_`），不能直接 apply。
- **`ub_allocator.cpp` VLOG 降级**：`897e0691` 已含。

### 2.5 验证状态

- **WSL2 静态验证（本机，已全过）**：0 冲突标记；`#if`/`#endif` 平衡（9/9）；大括号
  平衡；5+1 commit 签名均在；clean git apply 全程。**无法编译验证**——本机无
  glog/numa/gflags/asio/gtest（编辑专用机），pre-commit/clang-format 也未装。
- **GDR 契约交叉验证（已过）**：见 §1.3。
- **待做**：node2/node4 编译 + e2e（见 §3）。

---

## 3. 编译部署（精要版；完整版见 `Deployment/mooncake_deployment_gdr.md`）

### 3.1 构建配置

| 路径 | cmake 选项 | 环境 |
|---|---|---|
| NoF | `-DUSE_NOF=ON -DUSE_NOF_URMA=ON` | nof-urma-v2 现有流程不变 |
| GDR（部署节点） | `-DUSE_NOF_URMA=ON -DUSE_CUDA=ON -DUSE_UB=ON` + UMDK（含 `is_gpu_seg` 版本）+ nvidia_peermem→**否，见下** | node2/node4 |
| 开发机（无 CUDA） | `-DUSE_CUDA=OFF` 也能编 bench | WSL2 仅语法冒烟 |

`USE_CUDA`/`USE_UB` 选项在 `mooncake-common/common.cmake`。GDR 分支经
`#if defined(USE_CUDA)` 走 `#else LOG(ERROR)` 降级路径，`cuda_alike.h` 是桩头，
`-DUSE_CUDA=OFF` 可做语法冒烟。

### 3.2 部署节点 GDR 内核模块序列

**不是 `nvidia_peermem`**（栈故意旁路，见 §1.2）。正确序列：

```bash
modprobe nvidia            # 或 metax，视 GPU 厂商
# udma.ko / ummu.ko 通常随 URMA 栈加载；确认：
lsmod | grep -E 'udma|ummu|nvidia'
# 设置 vendor（若 udma.ko 支持 gpu_vendor 参数）：
# echo nvidia > /sys/module/udma/parameters/gpu_vendor   # 或 metax
# 桥模块：
modprobe udma_nv_p2p_bridge   # NVIDIA；MetaX 用 udma_metax_p2p_bridge
```

加载顺序：`nvidia.ko → udma.ko → udma_nv_p2p_bridge.ko`（桥最后，init 里调
udma.ko 的导出）。`ummu.ko` 提供 VA→PA 翻译平面。

### 3.3 运行时用法（合并后的同一二进制）

```bash
# NoF/URMA 路径
./stress_cluster_bench --protocol=ub \
    --nof_segments=<seg1,seg2> --nof_replica_num=N ...

# GDR 路径（GPU 显存写入）—— reader 角色（writer 不支持 gpu_mode）
MC_UB_GPU_MODE=gdr-peermem ./stress_cluster_bench \
    --gpu_mode=gdr-peermem --gpu_device=0 ...
MC_UB_GPU_MODE=staging ./stress_cluster_bench \
    --gpu_mode=staging --gpu_device=0 ...
# 分级日志：MC_VERBOSE=2 开 VLOG(2)
```

### 3.4 bench 关键 flag 速查

| flag | 默认 | 说明 |
|---|---|---|
| `--protocol` | tcp | tcp/rdma/ub；UB+GPU 路径需 ub |
| `--gpu_mode` | (空/host) | gdr-peermem \| staging；writer 忽略（host only） |
| `--gpu_device` | 0 | GPU 设备索引；gpu_mode 空/host 时忽略 |
| `--nof_segments` | (空) | NoF 段名逗号分隔；空=--nof_replica_num 非零时从 master 自动发现 |
| `--nof_replica_num` | 0 | 每个 object 的 NoF SSD 副本数 |
| `--segments` | (空) | 内存段名逗号分隔；空=从 master 自动发现 |
| `--scenario` | local_memory | local_memory/remote_memory/local_disk/remote_disk/segment_write/segment_read/list_segments/remove/batch_remove |
| `--role` | writer | writer(prefill)/reader(benchmark) |
| `--value_size` | 4MB | 每条 value 大小；GDR 下非 64KB 对齐会触发 64KB padding |
| `--global_segment_size` | 4GB | gdr-peermem 模式 Setup 中强制清零（无主机侧 segment） |

### 3.5 验证阶梯（部署节点）

1. 编译：`-DUSE_NOF_URMA=ON -DUSE_CUDA=ON -DUSE_UB=ON` + UMDK(含 `is_gpu_seg`)
   + 上述模块序列。cmake 日志应见 `HAVE_URMA_SEG_CFG_IS_GPU_SEG=1`（否则
   gdr-peermem 降级为 host/staging only）。
2. `--gpu_mode=gdr-peermem`：验证 GPU→Mooncake 直连写（reader 角色）。
3. `--gpu_mode=staging`：验证映射到现有 staging 机制。
4. `--nof_segments=... --nof_replica_num=N` + `list_segments`：验证 NoF 路径。
5. ⚠️ **gdr-peermem × NoF segment 交互**：gdr-peermem 清零 `global_segment_size`，
   若 `replica_num>0` 且无远端内存段，`DiscoverBenchmarkSegments()` 可能报「no
   memory segments found」——显式传 `--segments` 规避。

完整编译部署步骤见 [`Deployment/mooncake_deployment_gdr.md`](./Deployment/mooncake_deployment_gdr.md)。
