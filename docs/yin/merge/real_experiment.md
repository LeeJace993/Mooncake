# Mooncake 真实实验方案（real experiment）

版本：v6（2026-10-13 Phase 4 打流跟进：lease TTL 修复）
日期：2026-10-13
状态：Phase 4 NoF 注册 ✅ / segment_write ✅（~2 GB/s）/ segment_read 🔄（lease 修复生效，batch_get_into 仍卡 status=4）

---

## 1. 实验目标

在 **node4 (141.61.84.151)** 上编译部署 Mooncake（分支 `nof-urma-v2-bench-merge`），
target 数据通路部署在 **node3 (141.61.84.149)**，采用 **A：NoF/nvmf_tgt 流程**
（`--scenario=segment_write / segment_read --nof_replica_num=1`），验证 URMA
数据面打流吞吐。

## 2. 拓扑与节点角色

| 节点 | IP (数据面) | 角色 | 说明 |
|------|-------------|------|------|
| node3 | 141.61.84.149 | target（nvmf_tgt + SPDK，URMA） | 5 块 NVMe 组 raid0（URMA_RAID0），PID 2157286 |
| node4 | 141.61.84.151 | master + client + stress_cluster_bench | V100 GPU（本次未用 GDR） |

## 3. 端口规划（避开现役进程）

| 服务 | 端口 | 说明 |
|------|------|------|
| master gRPC | **50061** | 现役用 50051 |
| master metrics | **9004** | 现役用 9002/9003 |
| master metadata | **9998** | 现役用 9997 |
| client 数据面 | **50062** | 现役用 50052 |

## 4. 环境事实

| 项目 | 值 |
|------|-----|
| mooncake 分支 | `nof-urma-v2-bench-merge` @ `e4bfe3d`（node4 = fork；`00b31e3` 为 WSL 镜像同内容独立提交） |
| git remote | `https://github.com/LeeJace993/Mooncake.git` |
| SPDK 分支 (node3) | `urma_enable_v2` |
| UMDK 编译 (151) | `/home/yin/gdr/UMDK_tool_netlab-sp4_umdk` |
| UMDK 运行 (151) | `/home/tong/umdk_gpu_isolated/lib`（用户指定） |
| UMDK (149) | `/home/yin/gdr/UMDK_netlab` |
| 内核 (151) | `6.6.0-gdr_w00921547+` |
| 传输设备 | `udmac0d1e2`（用户指定，bonding_dev_0 不可用） |

## 5. 执行状态总表

| Phase | 内容 | 状态 | 备注 |
|-------|------|------|------|
| Phase 0 | node3 SPDK 重编 `urma_enable_v2` | ✅ 完成 | `nvmf_tgt` + `make install` |
| Phase 1 | node3 起 target（5 盘 raid0） | ✅ 完成 | PID 2157286，`141.61.84.149:4420` |
| Phase 2 | node4 mooncake 编译 | ✅ 完成 | 含 3 个 compile fix，已提交到 git |
| Phase 3 | node4 起 master + client | ✅ 完成（有坑） | master 441368 正常；client 段错误已修（env 守卫） |
| Phase 4 | NoF 注册 + 打流 | 🔄 写 ✅ 读 🔄 | 注册 ✅（34.93 TB）；segment_write ✅；segment_read：lease 修复生效（warmup 5 key read_ok），duration 批量仍卡 status=4 |

### 5.1 Phase 3 关键记录（段错误修复）

见 `adr/adr-urma-错误.md`（ADR-001，已解决）。

根因：`urma_user_ctl(SET_BONDING_MODE)` 在 `liburma-udma.so` 清理路径空指针崩溃。

修复：加 `MC_URMA_SET_BONDING_MODE` env 守卫（默认关闭），三分支结构。

提交：`00b31e3`（3 files, +27/-6），已 force push 到 `nof-urma-v2-bench-merge`。

### 5.2 Phase 4 当前结果（2026-10-13）

| # | 项目 | 结果 | 详情 |
|---|------|------|------|
| 1 | NoF 注册 | ✅ | `NoFRegisterClient::set_register` → master `MountNoFSegment` OK，34.93 TB，心跳 attach 成功 |
| 2 | list_segments 冒烟 | ✅ | 1 个 NoF segment |
| 3 | segment_write 打流 | ✅ | 256 keys × 4MB = 1GB，`256 succeeded, 0 failed`；首跑 253 MB/s，hard_pin 后 **2.0~2.3 GB/s** |
| 4 | 单 key NoF 读（warmup） | ✅ | `--warmup_keys=5` 全部 `read_ok`，约 3~5 ms/key |
| 5 | segment_read（duration 模式，lease TTL=10s） | ❌ | `batch_get_into` 把 NoF replica 当 MEMORY 处理，`client_->BatchGet` 卡 35.6s 后全 LEASE_EXPIRED（见 ADR-005） |
| 6 | **二次验证（2026-10-13 10:41，lease TTL=600s）** | 🔄 | master 加 `--default_kv_lease_ttl=600000` 重启后：write 256/256 ✅；read warmup 5 key 全 `read_ok` ✅（lease 不再过期）；但 duration 批量读在 `client_->BatchGet` 并发读 URMA 时 `nvme_urma.c status=4` (LOC_ACCESS_ERR) + `CQ transport error -5`，`poll completion error: ret -5`，进程卡死不退出 |

## 6. Git 提交记录

```bash
# 定案（2026-10-13 node4 实测）：node4 HEAD = fork tip = e4bfe3d，无分歧、无需对齐
commit e4bfe3d (HEAD -> nof-urma-v2-bench-merge, origin/nof-urma-v2-bench-merge)
    fix: compile fixes + guard urma_user_ctl SET_BONDING_MODE behind MC_URMA_SET_BONDING_MODE
    3 files changed, 26 insertions(+), 5 deletions(-)   # adr.md 原始记录口径
# 00b31e3（3 files +27/-6）仅存在于 WSL 镜像：同一修复的独立提交，不是 fork tip
# e4bfe3d 存档：/tmp/0001-fix-compile-fixes-guard-urma_user_ctl_SET_BONDING_MO.patch
```

## 7. 备份清单

| 文件 | 位置 | 用途 |
|------|------|------|
| `urma_endpoint.cpp.bak` | 与源文件同目录 | ADR-001 修复前原始文件 |
| `mooncake_client.bak` | 同目录 | patchelf RPATH 实验备份（已过时） |
| `/tmp/nof_register` | node4 | NoF 注册工具（C++，已传 size 参数） |
| `/tmp/nof_unregister` | node4 | NoF 注销工具（C++） |

## 8. 编译 / 部署 / 运行指令全集（2026-10-13 实测）

### 8.0 环境变量（关键，initiator 侧必须双设）

```bash
# node4（master / bench / 任何创建 URMA context 的进程都要设）
export SPDK_URMA_DEV_NAME=udmac0d1e2        # 指定传输设备，否则错选 bonding_dev_0 → LOC_ACCESS_ERR (status=4)
export SPDK_URMA_CAPSULE_TRANSPORT=urma     # 指定 capsule 传输，否则发 tcp capsule → 对端握手失败 (-104 / -93)

# node3（target，nvmf_tgt 已由启动脚本设好，同样需要 SPDK_URMA_DEV_NAME=udmac0d1e2）
```

### 8.1 编译（node4，分支 `nof-urma-v2-bench-merge`）

```bash
cd /home/yin/nof/mooncake/mooncake-store
# 全量构建（含 3 个 compile fix，见 ADR-001 与 git log）
cmake --build build -j64
# 仅重编关键目标（改完 transfer-engine 后只需这俩）
cmake --build build -j64 --target mooncake_master
cmake --build build -j64 --target stress_cluster_bench
```

### 8.2 部署：node3 target（nvmf_tgt，5 盘 URMA_RAID0）

```bash
# node3，SPDK `urma_enable_v2` 分支编译产物
cd /home/yin/nof/spdk/build/bin
SPDK_URMA_DEV_NAME=udmac0d1e2 ./nvmf_tgt -m 0x3 --wait-for-rpc &
# 然后通过 RPC 创建 bdev raid0 + URMA transport 子系统（subsystem JSON 里设 capsule_transport=urma）
# 子系统：nqn.2026-01.io.spdk:urma-gpu-test，监听 4420，5×NVMe raid0（URMA_RAID0，34.93 TB）
```

### 8.3 部署：node4 master

```bash
cd /home/yin/nof/mooncake/mooncake-store/build/mooncake-store/src
SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma ./mooncake_master \
  --rpc_port=50061 --enable_http_metadata_server --http_metadata_server_port=9998 \
  --metrics_port=9004 --nof_heartbeat_interval_sec=120 --nof_heartbeat_failures_threshold=5 \
  --default_kv_lease_ttl=600000
# 当前 PID 2757398（2026-10-13 10:30 起），日志 /tmp/master4.log
# 旧：PID 950533 / 日志 /tmp/master3.log（无 --default_kv_lease_ttl）
```

> ⚠️ 心跳参数拉大（120s / 5 次）是为防止打流间歇导致 NoF segment 被误摘除，属实验调优。
>
> ⚠️ `--default_kv_lease_ttl=600000`（600s）：解决读侧 LEASE_EXPIRED。写 client 退出后 key lease 默认 10s 过期（master.cpp:44 `kDefaultKvLeaseTtlFlagValue=10000`），`--hard_pin` 只防 eviction 不续 lease；拉大到 600s 后 warmup 单 key 读不再 LEASE_EXPIRED（2026-10-13 实测）。
>
> ⚠️ **master 重启会丢失内存中 NoF segment 注册**，重启后必须重新执行 §8.4 的 `nof_register`。

### 8.4 注册 NoF segment（node4，`/tmp/nof_register` 工具）

```bash
# 用法：<nqn> <nsid> <traddr> <trsvcid> <trtype> <master_addr> [size_bytes]
/tmp/nof_register nqn.2026-01.io.spdk:urma-gpu-test 1 141.61.84.149 4420 URMA \
  141.61.84.151:50061 38407505182720
# 期望输出：NoF registration succeeded
# master 侧日志：master_service.cpp:866 NoF segment mount ... action=mount_segment
# 确认：master 指标 NVMe-oF SSD: 0 B / 34.93 TB
```

> 该工具调 `NoFRegisterClient::set_register` → master `MountNoFSegment` RPC（`BuildTeEndpoint` 生成 `traddr:... trsvcid:... subnqn:... trtype:... adrfam:IPv4 ns:...`）。
>
> ⚠️ **2026-10-13 实测：`/tmp` 可能被清理导致二进制丢失**，源码 `/tmp/nof_register.cpp` 还在时需重编。编译命令（复用 bench 的 flags/库，见 §8.1 后说明）：
> ```bash
> # 1) 编译 object（含全部宏与 include，与 stress_cluster_bench 的 flags.make 一致）
> /usr/bin/c++ -DASIO_DYN_LINK -DASIO_SEPARATE_COMPILATION -DCONFIG_ERDMA -DGFLAGS_IS_A_DLL=0 \
>   -DGLOG_CUSTOM_PREFIX_SUPPORT -DGLOG_USE_GLOG_EXPORT -DSPDIAG_DISABLE -DUSE_CUDA -DUSE_HTTP \
>   -DUSE_NOF -DUSE_NOF_GPU_DIRECT -DUSE_NOF_URMA -DUSE_TCP -DUSE_UB -DUSE_URING -DWITH_METRICS \
>   -DYLT_ENABLE_DL -DYLT_ENABLE_IBV \
>   -I/usr/local/cuda/include -I.../mooncake-common/etcd -I.../mooncake-common/k8s-lease \
>   -I.../mooncake-common/include -I.../mooncake-transfer-engine/include \
>   -I.../mooncake-store/include/cachelib_memory_allocator/include \
>   -I.../mooncake-store/include/cachelib_memory_allocator/fake_include \
>   -I.../mooncake-store/include/cachelib_memory_allocator \
>   -I.../mooncake-store/include/mooncake-store/proto -I.../mooncake-store/include \
>   -I.../build/mooncake-store/include -I.../mooncake-common/src/../include \
>   -I.../build/mooncake-transfer-engine/src/spdiag-src/include \
>   -I/home/yin/gdr/UMDK_tool_netlab-sp4_umdk/src/urma/lib/urma/core/include \
>   -I/home/yin/gdr/UMDK_tool_netlab-sp4_umdk/src/urma/lib/urma/bond/include \
>   -isystem /usr/local/cuda-12.9/targets/sbsa-linux/include \
>   -Wall -Wextra -Wno-unused-parameter -fPIC -g -fcoroutines -O2 -g -DNDEBUG -std=gnu++20 \
>   -fno-tree-slp-vectorize -c /tmp/nof_register.cpp -o /tmp/nof_register_new.o
> # 2) 链接（复用 stress_cluster_bench 的 link.txt 完整库列表，把 .cpp.o 换成 nof_register_new.o）
> #    → /tmp/nof_register（140 MB，含 SPDK/URMA/DPDK 全套静态库）
> ```
> 实际链接命令取 `build/mooncake-store/benchmarks/CMakeFiles/stress_cluster_bench.dir/link.txt` 全量替换即可。

### 8.5 打流：segment_write（node4）

```bash
cd /home/yin/nof/mooncake/mooncake-store/build/mooncake-store/benchmarks

# 正式（--hard_pin=true，约 2.0~2.3 GB/s）——2026-10-13 实测命令（flag 名已修正）
SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma ./stress_cluster_bench \
  --scenario=segment_write --protocol=tcp \
  --local_hostname=141.61.84.151:50071 \
  --metadata_server=http://141.61.84.151:9998/metadata \
  --master_server=141.61.84.151:50061 \
  --num_keys=256 --value_size=4194304 \
  --replica_num=0 --global_segment_size=0 --nof_replica_num=1 \
  --hard_pin=true --wait_seconds=300
```

> ⚠️ **正确 flag 名（2026-10-13 实测纠错）**：
> - `--master_server=141.61.84.151:50061`（**不是** `--remote_hostname`，后者不存在会报 `unknown command line flag`）
> - `--metadata_server=http://141.61.84.151:9998/metadata`（**必须显式指定**，默认 `http://127.0.0.1:8080/metadata` 连不上 → `Failed to initialize transfer engine, rc=-200`）
> - NoF segment 自动发现（不传 `--nof_segments`），依赖 `--master_server` 的 `GetAllNoFSegments` RPC
> - `--replica_num=0`：不建内存副本（memory client=0）；`--global_segment_size=0`：不建内存 segment
> - `--wait_seconds=300`：写完后保持进程存活（供随后读；且旧 10s lease 下靠它防 LEASE_EXPIRED，lease TTL 修复后非必需）

# 实测（后台 writer / 日志 /tmp/seg_write_ttl.log）：
#   Segment [0] ... type=NoF complete: 256 succeeded, 0 failed
#   All segments write complete: 256 succeeded, 0 failed

### 8.6 打流：segment_read（node4，duration 批量读仍卡）

```bash
# 单 key warmup 读（✅ 验证 NoF 读通路）：--warmup_keys=5 全部 read_ok，约 3~5 ms/key
SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma ./stress_cluster_bench \
  --scenario=segment_read --protocol=tcp \
  --local_hostname=141.61.84.151:50072 \
  --metadata_server=http://141.61.84.151:9998/metadata \
  --master_server=141.61.84.151:50061 \
  --num_keys=256 --value_size=4194304 \
  --replica_num=0 --global_segment_size=0 --nof_replica_num=1 \
  --duration=30 --warmup_keys=5
```

> - **lease TTL=600s（2026-10-13）**：warmup 5 key 全部 `read_ok`（不再 LEASE_EXPIRED），证明 lease 修复生效。
> - **duration 批量读卡死**：批量 `BatchGet` 路径 NoF 端到端是通的（ADR-005 v2 逐层核对；"无 NoF 分支、
>   当 MEMORY 处理"已被推翻，那只是日志标签 bug）。32 路并发 URMA 读下
>   `nvme_urma.c:971 capsule completion failed: status=4` (LOC_ACCESS_ERR) + `CQ transport error -5` +
>   `poll completion error: ret -5`，进程 90% CPU 空转不退出。
>   ⚠️ warmup 单 key `get_into` 正常（host buffer 不走 GPU Direct 分支，见 ADR-005 v2 勘误）；
>   第 1 轮曾 35.6s 慢成功、第 2 轮报错——形状不确定，待定位（见 diagnosis.md 问题 #10 / ADR-005 v3）。

> ⚠️ `--local_hostname` 端口必须避让：若 50071 已被后台 writer 占用，读客户端会 `ret=-600` setup 失败，需换 50072（见 ADR-006）。

### 8.7 冒烟：list_segments

```bash
SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma ./stress_cluster_bench \
  --scenario=list_segments --protocol=tcp \
  --local_hostname=141.61.84.151:50071 \
  --master_server=141.61.84.151:50061
# 输出 1 个 NoF segment：traddr:141.61.84.149 trsvcid:4420 subnqn:nqn.2026-01.io.spdk:urma-gpu-test trtype:URMA adrfam:IPv4 ns:1
```

### 8.8 关键日志位置（node4）

| 文件 | 内容 |
|------|------|
| `/tmp/master4.log` | 当前 master（PID 2757398，含 `--default_kv_lease_ttl=600000`），NoF mount / 打流 RPC 全记录 |
| `/tmp/master3.log` | 旧 master（PID 950533，无 lease 参数） |
| `/tmp/master.log` | 2026-10-12 首次 attach 失败（-104 capsule 不匹配） |
| `/tmp/master2.log` | 2026-10-13 二次 attach 失败（status=4 LOC_ACCESS_ERR） |
| `/tmp/seg_write_hold.log` / `seg_write_hold2.log` | 后台 writer（hard_pin，~2.0 GB/s） |
| `/tmp/seg_write_ttl.log` | **2026-10-13 最新 writer**（lease TTL=600s 重启后，256/256 ✅） |
| `/tmp/seg_read_full.log` | reader：warmup read_ok + duration 模式 LEASE_EXPIRED（旧，lease TTL=10s） |
| `/tmp/seg_read_ttl.log` | **2026-10-13 最新 reader**（lease TTL=600s）：warmup 5 key read_ok，duration 批量 status=4 卡死 |
| `/tmp/seg_write_r0.log` | 失败启动日志（用错 flag 名 `remote_hostname`/`segment_name`，`unknown command line flag`） |
| `/tmp/nvmf_tgt.log` (node3) | target 侧日志（capsule mismatch local=urma remote=tcp rc=-93） |
