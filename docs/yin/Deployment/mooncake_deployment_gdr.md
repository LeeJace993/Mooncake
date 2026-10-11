# GDR (gdr-peermem) 部署手册 —— stress_cluster_bench GPU 显存写入

> 本文是在原 Mooncake NoF (URMA) 部署流程（见同级
> [`../mooncake_nof_deployment.md`](../mooncake_nof_deployment.md)；更详细的
> `mooncake_deployment1/2.md` 在仓库外文档树 `/home/senorita/nof/docs/mooncake/Deployment/`）之上，叠加
> `stress_cluster_bench --gpu_mode=gdr-peermem`（Transfer Engine UB transport
> 直达 GPU HBM）路径的编译、模块加载、运行与验证。
>
> 分支：`nof-urma-v2-bench-merge`（基于 `nof-urma-v2`）。日期：2026-10-11。
> 合并报告与源码分析见 [`../mooncake_bench_merge_gdr_nof.md`](../mooncake_bench_merge_gdr_nof.md)。

---

## 0. 本手册覆盖什么 / 不覆盖什么

本仓库（Mooncake）里有两套独立的 GPU Direct 实现，**不要混淆**：

| 路径 | bench | 数据通路 | 本手册覆盖 |
|---|---|---|---|
| **Store NoF → SSD** | `nof_worker_pool_bench --memory=cuda` | SSD ──URMA──→ GPU 显存（SPDK memory domain） | ✗（见原部署文档阶段 8.3–8.4） |
| **Transfer Engine UB → GPU HBM** | `stress_cluster_bench --gpu_mode=gdr-peermem` | 远端内存 ──UB transport──→ GPU HBM（`is_gpu_seg=1`） | ✓ 本文 |

原部署文档阶段 8.3–8.4 的 `--memory=cuda` 走的是**第一条**；本文的
`--gpu_mode=gdr-peermem` 走**第二条**。两条**用不同的 GPU-pin 内核模块**，互不影响，可共存于同一节点（见 §1 末）。

---

## 1. ⚠️ 关键差异：本路径**不**用 `nvidia_peermem`

原部署文档阶段 0 写「重启后 `modprobe nvidia_peermem`」——那是**第一条路径**（Store
NoF → SSD，`nof_worker_pool_bench --memory=cuda`）用的：SPDK memory domain +
CUDA provider，走 `nvidia-peermem`-on-`ib_umem` 的 InfiniBand 风格 peer-memory
client。

**本路径**（第二条：UB transport gdr-peermem）是 **HiSilicon UB/URMA 栈**，**不是
InfiniBand**，**故意旁路 `nvidia_peermem.ko`**（`urma_driver/docs/GPU_P2P_PATENT_BRIEF.md:91-104`，
因 `inherit_taint()` 让 `TAINT_PROPRIETARY_MODULE` 从 nvidia.ko 经桥传播到
udma.ko，复现「Unknown symbol」）。v2 设计反转依赖：桥在 `module_init` 调
`udma_register_gpu_p2p_ops()` 注册函数指针，udma.ko 经指针调桥，函数指针调用不
走模块加载器的 `resolve_symbol()`，`inherit_taint()` 不触发。

**两条路径的模块对比**：

| | 路径 (a) Store NoF→SSD | 路径 (b) UB→GPU HBM（本文） |
|---|---|---|
| bench | `nof_worker_pool_bench --memory=cuda` | `stress_cluster_bench --gpu_mode=gdr-peermem` |
| GPU-pin 模块 | `nvidia_peermem.ko`（IB peer-memory client） | `udma_nv_p2p_bridge.ko`（直调 `nvidia_p2p_get_pages`） |
| 翻译平面 | SPDK/NIC 自身 | `ummu.ko`（UMMU IOMMU） |
| 注册机制 | SPDK memory domain + CUDA provider | `urma_seg_cfg_t.is_gpu_seg=1` |

**正确的模块序列**（本路径，详见 §4）：

```
nvidia.ko (或 metax.ko) → udma.ko → udma_nv_p2p_bridge.ko → ummu.ko
```

- `nvidia.ko`：GPU 厂商驱动，导出 P2P pin API。
- `udma.ko`：UB NIC DMA 驱动；模块参数 `gpu_vendor=nvidia|metax|auto` 选厂商。
- `udma_nv_p2p_bridge.ko`：NVIDIA 桥，调 `nvidia_p2p_get_pages` pin GPU 页，
  把物理地址喂给 ummu。MetaX 用 `udma_metax_p2p_bridge.ko`。
- `ummu.ko`：HiSilicon UMMU IOMMU，做 VA→PA 翻译给 UB NIC（不 pin GPU 内存）。

> `MC_UB_GPU_MODE=gdr-peermem` 只是 mooncake transport-mode 名，**不**等于
> `modprobe nvidia_peermem`。**两条路径可共存**：`nvidia_peermem.ko`（路径 a）与
> `udma_nv_p2p_bridge.ko`（路径 b）都调底层 `nvidia_p2p_get_pages`，但经不同注册
> 路径（IB peer-memory client list vs udma.ko 函数指针），互不冲突。同一节点既跑
> `nof_worker_pool_bench --memory=cuda` 又跑 `stress_cluster_bench --gpu_mode=gdr-peermem`
> 时，两个模块都加载即可。

---

## 2. 前置：完成原部署阶段 0–7

本路径**依赖**原部署文档的阶段 0–7 已完成（SPDK 编译安装、Mooncake 编译、
target/master/client 启动、NoF SSD 注册）。不同之处仅在：

1. **Mooncake 编译期**额外开 `USE_CUDA=ON -DUSE_UB=ON`（见 §3）。
2. **阶段 0 模块检查**改为 §4 的 UB GDR 模块序列（替换 `modprobe nvidia_peermem`）。
3. **运行**改用 `--gpu_mode=gdr-peermem`（见 §5）。

若已按原文档部署完成，跳到 §3 重编 bench、§4 查模块、§5 跑 bench。

---

## 3. 编译（仅 151 / initiator，叠加 GDR 选项）

在原 Mooncake cmake 命令基础上加 `-DUSE_CUDA=ON -DUSE_UB=ON`。UMDK 必须是含
`urma_seg_cfg_t.is_gpu_seg` 字段的版本（`netlab-sp4_umdk`）——cmake 会
`check_cxx_source_compiles` 探测该字段，缺字段则 gdr-peermem 降级（host/staging only）。

> **UMDK 路径**（原部署文档里前缀不统一，此处澄清）：
> - **cmake 期**（`UMDK_ROOT`，`find_path`/`find_library` 搜 `urma_api.h` + `liburma`）：
>   用含 `is_gpu_seg` 的源码树，如 `/home/yin/gdr/UMDK_netlab`（已确认
>   `src/urma/lib/urma/core/include/urma_types.h:999` 有 `is_gpu_seg`）。先
>   `find /home/yin/gdr -name urma_api.h` 定位再传。
> - **运行期**（`LD_LIBRARY_PATH`，loader 找 `liburma.so.0`）：用 SPDK configure 时
>   `--with-urma=` 指向的同一 UMDK 构建产物 lib 目录，原部署文档用
>   `/home/yin/gdr/UMDK_tool_netlab-sp4_umdk/lib`。**两者可不同**——cmake 期要头文件
>   （含 `is_gpu_seg`），运行期要 `.so`；只要运行期的 `.so` 也是含 `is_gpu_seg` 的版本
>   构建出来的即可。`ldd` 确认 `liburma.so.0` 不指向 `/usr/lib64` 老版（缺符号）。

```bash
cd /home/<user>/nof/mooncake   # 分支 nof-urma-v2-bench-merge
git checkout nof-urma-v2-bench-merge
git submodule update --init --recursive   # yalantinglibs
# 若报 "not our ref b12fbfd8..."（yalantinglibs ghost-pin，见原部署文档阶段 9）：
#   git pull && git submodule update --init --recursive
# 或离线: cd extern/yalantinglibs && git checkout e46cbf08 &&
#   git config submodule.extern/yalantinglibs.update none && 重跑 submodule update

# UMDK 必须是含 urma_seg_cfg_t.is_gpu_seg 字段的版本（netlab-sp4_umdk）。
# CMake 经 find_path/find_library 在 ${UMDK_ROOT} → /usr → /usr/local 搜索，
# PATH_SUFFIXES 含 include/ub/umdk/urma（urma_api.h）、lib64/lib/build/lib（liburma）。
# 本地装在 /home/yin/gdr/UMDK_netlab（含 include/ub/umdk/urma/urma_api.h）：
export UMDK_ROOT=/home/yin/gdr/UMDK_netlab   # 按实际路径；见原部署文档附录 A

mkdir -p build && cd build
cmake .. \
    -DUSE_NOF=ON \
    -DUSE_NOF_URMA=ON \
    -DUSE_NOF_GPU_DIRECT=ON \
    -DUSE_CUDA=ON \
    -DUSE_UB=ON \
    -DUMDK_ROOT=$UMDK_ROOT \
    -DCMAKE_BUILD_TYPE=Release
make -j stress_cluster_bench
```

**关键 cmake 日志确认**：

```
URMA headers expose urma_seg_cfg_t::is_gpu_seg; gdr-peermem enabled   ← 必须出现
```

若出现 `URMA headers lack urma_seg_cfg_t::is_gpu_seg; gdr-peermem disabled
(host/staging only)`，说明 UMDK 版本太老（缺 `is_gpu_seg`），gdr-peermem 会被
`#if defined(HAVE_URMA_SEG_CFG_IS_GPU_SEG)` 降级掉——换含该字段的 UMDK 重编。

> **无 CUDA 开发机（WSL2）**：`-DUSE_CUDA=OFF` 也能编 bench（GDR 代码经
> `#if defined(USE_CUDA)` 走 `#else LOG(ERROR)` 降级，`cuda_alike.h` 是桩头），
> 仅做语法冒烟，不能跑 GPU 路径。

---

## 4. 阶段 0（修订）：GDR 内核模块检查（151）

替换原文档的 `modprobe nvidia_peermem`，改查 UB GDR 模块序列：

```bash
# 1. GPU 厂商驱动（nvidia 或 metax，随卡）
nvidia-smi | head -1    # 确认 nvidia.ko 在

# 2. UB 栈核心模块
lsmod | grep -E 'udma|ummu|ubcore|uburma'
# 期望见到: udma, ummu, ubcore, uburma

# 3. GDR 桥模块（NVIDIA 用 udma_nv_p2p_bridge，MetaX 用 udma_metax_p2p_bridge）
lsmod | grep -E 'udma_.*p2p_bridge'
# 若无，加载（顺序: nvidia → udma → 桥，桥最后）：
#   modprobe udma_nv_p2p_bridge      # NVIDIA
#   # 或 modprobe udma_metax_p2p_bridge   # MetaX

# 4. 厂商选择（若 udma.ko 支持 gpu_vendor 参数）
cat /sys/module/udma/parameters/gpu_vendor 2>/dev/null   # auto|nvidia|metax
# 设 NVIDIA:
#   echo nvidia | sudo tee /sys/module/udma/parameters/gpu_vendor

# 5. 设备节点
ls /dev/uburma/udmac0d1e2    # 应存在（与原部署阶段 0 一致）
```

**加载顺序**：`nvidia.ko → udma.ko → udma_nv_p2p_bridge.ko`（桥最后，init 里调
udma.ko 的导出 `udma_register_gpu_p2p_ops`）。`ummu.ko` 提供 VA→PA 翻译平面，
随 UB 栈加载。桥未加载时，GPU 段注册返回 `-ENODEV`——bench 会报注册失败。

---

## 5. 运行：stress_cluster_bench GDR 路径

### 5.1 环境变量（窗口顶部，与原部署 NoF 跑法一致 + GPU）

```bash
cd /home/<user>/nof/mooncake
export LD_LIBRARY_PATH=/home/yin/gdr/UMDK_tool_netlab-sp4_umdk/lib:$LD_LIBRARY_PATH
export SPDK_URMA_DEV_NAME=udmac0d1e2
export SPDK_URMA_JETTY_PRIORITY=6
export SPDK_URMA_MAX_IO_SIZE=4194304
export SPDK_URMA_CAPSULE_TRANSPORT=tcp
export SPDK_URMA_TRANS_MODE=RM
# GDR 路径模式（与 --gpu_mode 一致）：
export MC_UB_GPU_MODE=gdr-peermem   # 或 staging
# 分级日志（可选）：
export MC_VERBOSE=2                  # 开 VLOG(2)，看 Fill/Check H2D/D2H
```

### 5.2 GPU 显存写入（reader 角色跑 GDR）

> ⚠️ `--gpu_mode` 仅 **reader** 角色支持；writer 角色会 `LOG(FATAL)`（host only）。

```bash
./build/mooncake-store/benchmarks/stress_cluster_bench \
    --scenario=segment_read \
    --role=reader \
    --local_hostname=141.61.84.151 \
    --metadata_server=http://141.61.84.151:8080/metadata \
    --master_server=141.61.84.151:50052 \
    --protocol=ub --device_name=bonding_dev_0 \
    --gpu_mode=gdr-peermem --gpu_device=0 \
    --value_size=$((4*1024*1024)) \
    --batch_size=32 --num_threads=8 \
    --duration=30 --statis_interval=5 \
    --master_admin_port=9004 \
    --verify=false \
    2>&1 | tee /tmp/gdr_read.log
```

### 5.3 staging 模式（对照基准）

```bash
# 把 --gpu_mode 换成 staging，MC_UB_GPU_MODE 同步：
MC_UB_GPU_MODE=staging ./build/mooncake-store/benchmarks/stress_cluster_bench \
    --scenario=segment_read --role=reader \
    --local_hostname=141.61.84.151 \
    --metadata_server=http://141.61.84.151:8080/metadata \
    --master_server=141.61.84.151:50052 \
    --protocol=ub --device_name=bonding_dev_0 \
    --gpu_mode=staging --gpu_device=0 \
    --value_size=$((4*1024*1024)) --batch_size=32 --num_threads=8 \
    --duration=30 --statis_interval=5 --master_admin_port=9004 \
    --verify=false
```

### 5.4 NoF 路径（与 GDR 共存，照原跑法）

```bash
# 写（initiator）
MC_NVME_NUM_IO_QUEUES=64 MC_NVME_IO_QUEUE_SIZE=8 \
./build/mooncake-store/benchmarks/stress_cluster_bench \
    --scenario=segment_write \
    --local_hostname=141.61.84.151 \
    --metadata_server=http://141.61.84.151:8080/metadata \
    --master_server=141.61.84.151:50052 \
    --protocol=ub --device_name=bonding_dev_0 \
    --value_size=$((4*1024*1024)) --num_keys=100 \
    --master_admin_port=9004 --replica_num=0 --nof_replica_num=1 \
    --global_segment_size=0 \
    2>&1 | tee /tmp/write.log | grep -E "Segment \[|succeeded|failed|Throughput"

# 读（同 5.2 但不开 gpu_mode）
./build/mooncake-store/benchmarks/stress_cluster_bench \
    --scenario=segment_read \
    --local_hostname=141.61.84.151 \
    --metadata_server=http://141.61.84.151:8080/metadata \
    --master_server=141.61.84.151:50052 \
    --protocol=ub --device_name=bonding_dev_0 \
    --value_size=$((4*1024*1024)) --batch_size=32 --num_threads=8 \
    --duration=30 --statis_interval=5 --master_admin_port=9004 --verify=false
```

---

## 6. 验证与通过标准

| # | 验什么 | 怎么验 | 通过标准 |
|---|---|---|---|
| 1 | 编译使能 | cmake 日志 | `HAVE_URMA_SEG_CFG_IS_GPU_SEG=1` + `URMA headers expose ...; gdr-peermem enabled` |
| 2 | GDR 直连写 | `--gpu_mode=gdr-peermem --role=reader` | 日志见 `[ub_gdr] registering GPU region` + `[ub_gdr] direct transfer`；无 staging copy |
| 3 | staging 对照 | `--gpu_mode=staging` | 走现有 staging 机制，吞吐作为对照基线 |
| 4 | NoF 路径 | `--nof_segments=... --nof_replica_num=N` + `list_segments` | 写读成功，吞吐统计打印 |
| 5 | 64KB 对齐 | `--value_size=$((4*1024))`（非 64KB 对齐） | 不报 `nvidia_p2p_get_pages failed (-EINVAL)`；alloc 自动 64KB padding |
| 6 | GDR × NoF 交互 | gdr-peermem + `--nof_replica_num>0` | 显式传 `--segments` 规避「no memory segments found」（gdr-peermem 清零 `global_segment_size`） |

**GDR 生效的判定**（日志关键词）：
- `[ub_gdr] registering GPU region addr=... length=...`（`ub_transport.cpp:498`）
- `[ub_gdr] direct transfer gpu_va=... length=... opcode=WRITE/READ`（`ub_transport.cpp:673`）
- `Register memory region ... is_gpu_seg=1`（`urma_endpoint.cpp:347`）
- `UB GPU HBM: allocated size ... device ... addr ...`（`ub_allocator.cpp:142`）

若 `is_gpu_seg=0` 或无 `[ub_gdr]` 日志，说明 gdr-peermem 未生效（检查 §3 cmake 探针、
§4 桥模块、`MC_UB_GPU_MODE` 环境变量与 `--gpu_mode` 一致）。

---

## 7. 故障排查（GDR 特有）

| 现象 / 日志 | 原因 | 处理 |
|---|---|---|
| cmake `URMA headers lack urma_seg_cfg_t::is_gpu_seg` | UMDK 版本太老，缺字段 | 换含 `is_gpu_seg` 的 UMDK（`netlab-sp4_umdk`）重编 |
| `Register memory region ... is_gpu_seg=0`（应=1） | gdr-peermem 未启用 | 查 cmake 探针日志；确认 `--gpu_mode=gdr-peermem` 且 reader 角色 |
| `nvidia_p2p_get_pages failed ... (EINVAL)` | GPU 段长度/VA 非 64KB 对齐 | 64KB padding 应已生效（`757d2135`）；检查是否用了跳过 padding 的旧构建 |
| GPU 段注册返回 `-ENODEV` | GDR 桥模块未加载 / `gpu_vendor` 未设 | 按 §4 加载 `udma_nv_p2p_bridge.ko`，设 `gpu_vendor` |
| `writer role does not support --gpu_mode` | writer 角色传了 `--gpu_mode` | writer 不支持 GPU buffer（host only）；reader 才跑 GDR |
| `gpu_mode requires a CUDA device, none available` | 151 无 CUDA 设备 / `nvidia-smi` 失败 | 确认 GPU 在、`nvidia.ko` 加载、`--gpu_device` 索引正确 |
| gdr-peermem + NoF 报「no memory segments found」 | gdr-peermem 清零 `global_segment_size` | 显式传 `--segments=<mem_seg>`（§5 风险 3） |
| 找不到 `nvidia_peermem.ko` | 本路径不用它（见 §1） | 改查 `udma_nv_p2p_bridge.ko`（§4） |

---

## 8. bench flag 速查（合并后新增 + 原有）

| flag | 默认 | 说明 |
|---|---|---|
| `--gpu_mode` | (空/host) | `gdr-peermem \| staging`；writer 忽略（host only） |
| `--gpu_device` | 0 | GPU 设备索引；gpu_mode 空/host 时忽略 |
| `--nof_segments` | (空) | NoF 段名逗号分隔；空=从 master 自动发现（`--nof_replica_num` 非零时） |
| `--nof_replica_num` | 0 | 每个 object 的 NoF SSD 副本数 |
| `--segments` | (空) | 内存段名逗号分隔；空=从 master 自动发现 |
| `--protocol` | tcp | `tcp/rdma/ub`；UB+GPU 路径需 `ub` |
| `--scenario` | local_memory | `local_memory/remote_memory/local_disk/remote_disk/segment_write/segment_read/list_segments/remove/batch_remove` |
| `--role` | writer | `writer`(prefill)/`reader`(benchmark) |
| `--value_size` | 4MB | 每条 value 大小；GDR 下非 64KB 对齐触发自动 padding |
| `--global_segment_size` | 4GB | gdr-peermem 模式 Setup 中强制清零 |
| `--replica_num` | 1 | 内存副本数 |
| `--num_threads` | 1 | 并发 reader 线程 |
| `--duration` | 0 | segment_read 连续读秒数（0=读 num_keys 一次） |
| `--verify` | true | 读后逐字节校验 |

环境变量：`MC_UB_GPU_MODE`（host/staging/gdr-peermem，与 `--gpu_mode` 一致）、
`MC_VERBOSE`（→glog `FLAGS_v`，2 开 VLOG(2)）、`MC_UB_TRANSPORT_CPU_STAGING`
（legacy 回退，未设 `MC_UB_GPU_MODE` 时生效）。

---

## 9. 风险与注意事项

1. **gdr-peermem 依赖链**：UMDK 必须暴露 `urma_seg_cfg_t.is_gpu_seg`（cmake 探测），
   且需 GDR 桥模块（`udma_nv_p2p_bridge.ko`/`udma_metax_p2p_bridge.ko`）+ `ummu.ko`；
   缺任一只能回退 staging。全部链路只有部署节点（151）能验证。
2. **staging 语义差异**：`MC_UB_GPU_MODE=staging` 映射到 nof-urma-v2 现有全局池
   staging（supercache-gds 是每 buffer 映射）——行为略有差异，但 bench 的单 buffer
   场景功能等价，且最小增量优先保证 NoF 零回归。
3. **gdr-peermem × NoF segment 运行时交互**：gdr-peermem 清零 `global_segment_size`，
   若 `replica_num>0` 且无远端内存段，`DiscoverBenchmarkSegments()` 可能报「no
   memory segments found」——显式 `--segments` 规避。
4. **64KB 对齐**：NVIDIA 桥强制 GPU 段 VA 与长度 64KB 对齐；`757d2135` 在
   `ub_allocate_gpu_hbm` 与 `registerMemoryRegion` 两处做了 padding，非对齐
   `--value_size` 也能跑。
5. **不整文件拷 supercache-gds**：其 `ub_transport.cpp`/`ub_allocator.cpp` 混有
   scheduler/io_pattern/batch io_uring 无关工作，只取本路径需要的切片。

---

## 文档关系

```
mooncake_nof_deployment.md / Deployment/mooncake_deployment{1,2}.md
    原部署手册（阶段 0-9，NoF + SPDK GPU Direct 第一条路径）
mooncake_bench_merge_gdr_nof.md
    本合并报告（源码分析 + 6 提交改动 + 64KB 修复）
本文档 (Deployment/mooncake_deployment_gdr.md)
    在原部署上叠加 stress_cluster_bench --gpu_mode=gdr-peermem（第二条路径）
mooncake_nof_architecture.md §3.2
    SPDK GPU Direct（第一条路径）的原理
```
