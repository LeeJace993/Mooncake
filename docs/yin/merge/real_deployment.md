# Mooncake NoF (URMA) 编译部署手册

> 本手册指导在双节点环境上编译部署 Mooncake（分支 `nof-urma-v2-bench-merge`），
> 通过 `stress_cluster_bench` 的 NoF 路径验证 URMA 数据面打流：用哪个分支、设哪些环境变量、
> 按什么顺序起进程、用什么命令打流、每步的通过标准与已知限制。
>
> 与通用部署文档 [`../mooncake_nof_deployment.md`](../mooncake_nof_deployment.md) 的差异见 §0。
> 根因分析与完整问题记录见 [`adr.md`](./adr.md)（ADR-001~006）、[`diagnosis.md`](./diagnosis.md)（问题总表）、
> [`real_experiment.md`](./real_experiment.md)（实测数据）。

---

## 0. 与通用部署文档的差异

通用部署文档（`mooncake_nof_deployment.md`）基于 `nof-urma-v2` 分支 + `nof_worker_pool_bench`；
本手册基于 **bench-merge 分支 + `stress_cluster_bench` NoF 路径**，是当前打流场景。关键差异：

| 维度 | 通用部署 | **本手册** |
|---|---|---|
| Mooncake 分支 | `nof-urma-v2` (`5a71d963`) | **`nof-urma-v2-bench-merge`**（commit `00b31e3`） |
| SPDK 分支（target） | `urma_modified_v6` (`c44ccce27`) | **`urma_enable_v2`**（node3） |
| target 节点 | node2 (141.61.84.247)，单盘 | **node3 (141.61.84.149)，5 盘 raid0**（URMA_RAID0，~34.93 TiB） |
| 打流工具 | `nof_worker_pool_bench` | **`stress_cluster_bench`**（`--scenario=segment_write/read/list_segments --nof_replica_num=1`） |
| 注册工具 | `mooncake_ssd_register.py`（pybind） | **`/tmp/nof_register`**（C++，`NoFRegisterClient::set_register`） |
| metadata server | 独立 python 进程 :8080 | **master 内置** `--enable_http_metadata_server :9998` |
| 关键 env | 仅 `SPDK_URMA_DEV_NAME` | **`SPDK_URMA_DEV_NAME` + `SPDK_URMA_CAPSULE_TRANSPORT=urma`**（缺一不可） |

> ⚠️ 通用文档里"stress_cluster_bench 暂不支持 NoF"的结论已过时：bench-merge 分支的
> `stress_cluster_bench` 已支持 `--nof_replica_num` / `--scenario=segment_write/read/list_segments`。

---

## 1. 拓扑与节点角色

| 节点 | IP（数据面） | 角色 | 说明 |
|---|---|---|---|
| node3 | 141.61.84.149 | target（nvmf_tgt + SPDK，URMA） | 5 块 NVMe 组 raid0（URMA_RAID0），子系统 `nqn.2026-01.io.spdk:urma-gpu-test` |
| node4 | 141.61.84.151 | master + client + stress_cluster_bench | V100 GPU（本路径未用 GDR）；编译 + 部署 + 打流都在此节点 |

```
   node4 (141.61.84.151)                          node3 (141.61.84.149)
   master :50061 (metrics :9004 / metadata :9998)  nvmf_tgt :4420 (URMA)
   stress_cluster_bench --local_hostname :5007x   └─ URMA_RAID0 (5×NVMe raid0, 34.93 TiB)
        │  --remote_hostname 141.61.84.151:50061        ▲
        ▼                                                │
   master ──MountNoFSegment──► NoF segment ──attach(URMA)──┘
            (BuildTeEndpoint: traddr:149 trsvcid:4420 subnqn:... trtype:URMA ns:1)
   ═══════════════════ URMA (udmac0d1e2) ═══════════════════
```

## 2. 端口规划（启动前检查是否被占用，被占用则改用空闲端口）

本实验使用以下端口。**每个服务启动前先检查端口是否空闲**，若已被占用则改用其它空闲端口
（并同步改该端口在所有命令里的引用处）：

```bash
# 启动任意服务前：检查目标端口是否被占用
ss -tlnp | grep -E '50061|9998|9004|50062|50071|50072'
# 若某端口有输出 → 被占用：要么停掉占用进程，要么本服务改用其它空闲端口
```

| 服务 | 默认端口 | 被占用时换用示例 |
|---|---|---|
| master gRPC | 50061 | 50063 / 50064 … |
| master metrics | 9004 | 9005 / 9006 … |
| master metadata（内置） | 9998 | 9999 … |
| bench 数据面 | 50062 / 50071 / 50072 | 写/读各自换一个空闲端口 |

> ⚠️ bench 的 `--local_hostname` 是本进程数据面监听端口，**写/读不能复用同一端口**：
> writer 占 50071 时 reader 必须换 50072，否则 reader setup 报 `ret=-600`（ADR-006）。

> 改端口要改全：master 的 `--rpc_port` / `--metrics_port` / `--http_metadata_server_port`，
> bench 的 `--remote_hostname`（指向 master gRPC 端口）与 `--local_hostname`。

## 3. 环境事实

| 项目 | 值 |
|---|---|
| Mooncake 分支 | `nof-urma-v2-bench-merge`（commit `00b31e3`） |
| git remote | `https://github.com/LeeJace993/Mooncake.git` |
| SPDK 分支（node3） | `urma_enable_v2` |
| UMDK 编译期（151） | `/home/yin/gdr/UMDK_tool_netlab-sp4_umdk` |
| UMDK 运行期（151） | `/home/tong/umdk_gpu_isolated/lib`（用户指定） |
| UMDK（149） | `/home/yin/gdr/UMDK_netlab` |
| 内核（151） | `6.6.0-gdr_w00921547+` |
| 传输设备 | `udmac0d1e2`（用户指定；`bonding_dev_0` 不可用 → LOC_ACCESS_ERR） |

> 该 commit 已包含 §5.2 的编译修复与 §4 的段错误守卫，clone 后无需手动打补丁。

---

## 4. 关键环境变量（initiator 侧双设，缺一不可）

**任何创建 URMA context 的进程（master / bench / client）都要设这两个**，否则分别触发 ADR-002 / ADR-003：

```bash
# node4：master / bench / 任何创建 URMA context 的进程都要设
export SPDK_URMA_DEV_NAME=udmac0d1e2        # 指定传输设备；否则错选 bonding_dev_0 → LOC_ACCESS_ERR (status=4)（ADR-003）
export SPDK_URMA_CAPSULE_TRANSPORT=urma     # 指定 capsule 传输；否则发 tcp capsule → 对端握手失败 -104/-93（ADR-002）
export SPDK_URMA_MAX_IO_SIZE=4194304        # 大 I/O 路径：与 target -O 4194304 配套（协商取小值，不设则按默认 135168 协商，>135168 的 I/O 下发失败）

# node3：target 侧同样需要 SPDK_URMA_DEV_NAME=udmac0d1e2（nvmf_tgt 启动脚本已设）；
#        capsule_transport 在子系统 JSON 里设为 urma，不是 env。
```

| 环境变量 | 必设？ | 作用 | 不设的后果 |
|---|---|---|---|
| `SPDK_URMA_DEV_NAME` | ✅ 必设 | 选传输设备 `udmac0d1e2` | 错选 `bonding_dev_0` → attach `status=4` LOC_ACCESS_ERR（ADR-003） |
| `SPDK_URMA_CAPSULE_TRANSPORT` | ✅ 必设 | capsule 走 urma | initiator 发 tcp capsule，target 侧 `capsule mismatch local=urma remote=tcp rc=-93`，attach `-104`（ADR-002） |
| `SPDK_URMA_MAX_IO_SIZE` | 大 I/O 路径必设 | initiator 侧大 I/O 上限，与 target `-O` 协商取小值 | 不设则按默认 135168 协商，>135168 的 I/O 下发失败；target 用 `-O 4194304` 时 initiator 须设 `=4194304` |
| `MC_URMA_SET_BONDING_MODE` | ⛔ **不要设** | ADR-001 段错误守卫 | **默认关闭=跳过崩溃调用**；若设为 `1` 会重新触发 `urma_user_ctl(SET_BONDING_MODE)` → `udma_u_delete_jetty` 空指针段错误 |

> `MC_URMA_SET_BONDING_MODE` 的守卫逻辑已编译进 `00b31e3`（三分支结构，默认 skip）。**保持不设**即正确；
> 只有当你确实需要 bonding mode 且确认 `liburma-udma.so` 无该 bug 时才设 `1`。详见 [`adr.md`](./adr.md) ADR-001。

---

## 5. 编译（node4，分支 `nof-urma-v2-bench-merge`）

### 5.1 全量 / 目标构建

```bash
cd /home/yin/nof/mooncake/mooncake-store

# 全量构建（含 3 个 compile fix，见 5.2）
cmake --build build -j64

# 改完 transfer-engine（如 urma_endpoint.cpp）后只需重编这两个目标
cmake --build build -j64 --target mooncake_master
cmake --build build -j64 --target stress_cluster_bench
```

产物路径：
- master：`build/mooncake-store/src/mooncake_master`
- bench：`build/mooncake-store/benchmarks/stress_cluster_bench`

### 5.2 该 commit 已包含的编译修复

`00b31e3` 已合入以下 3 个修复（3 files +27/-6），clone 后无需手动处理：

| # | 文件 | 修复 |
|---|---|---|
| 1 | `CMakeLists.txt` | 补 DPDK 链接库（`rte_log/rte_argparse/rte_bus_vdev/rte_cmdline/rte_dmadev/rte_meter/rte_stack`） |
| 2 | `CMakeLists.txt` | 补 SPDK optional 库（`keyring/keyring_file/keyring_linux/fuse_dispatcher` + 系统 `fuse3`） |
| 3 | `ub_transport.cpp` | `UbGpuMode` → `UbTransport::UbGpuMode`（嵌套 enum 类外未限定） |

> 同次提交还含 ADR-001 的运行时修复：`urma_endpoint.cpp` 加 `MC_URMA_SET_BONDING_MODE` 守卫（见 §4）。

### 5.3 ⚠️ 重编必须全量 link

改动 `urma_endpoint.cpp`（transfer-engine）后，**所有依赖它的目标**（`mooncake_master`、`stress_cluster_bench`）都要重新 link。
只编 `mooncake_master` 不重编 bench，会让 bench 仍用旧符号 → 运行时段错误。改完 transfer-engine 一律：

```bash
cmake --build build -j64 --target mooncake_master stress_cluster_bench
```

---

## 6. 部署：node3 target（nvmf_tgt，5 盘 URMA_RAID0）

node3 用 SPDK `urma_enable_v2` 分支自带的 **`target_nvme_takeover.sh`** 一键拉起 target——
它一条命令干完：vfio-pci noiommu 接管 → `nvmf_tgt` 启动 → iobuf 池配置 → raid0 → URMA transport
+ subsystem + namespace + listener（内置根分区 rw 自检、上次残留还原、hugepages 自动上调、core mask 占用检测）。

**第 1 步：先无 `-d` 跑一次，看系统盘和空闲候选盘**（脚本只分析、不做任何变更）：

```bash
# node3（root），SPDK urma_enable_v2 树
cd /home/yin/nof/spdk
sudo ./target_nvme_takeover.sh
```

输出列出所有 `nvmeXn1` 的 BDF / 状态（空闲/禁碰）/ 说明。**盘名每次开机重排，旧记录不可信，
必须现查**——从「空闲」行里选 5 块。

**第 2 步：接管 5 块空闲盘 → 起 target**（把上一步选的 5 块盘名填进 `-d`）：

```bash
cd /home/yin/nof/spdk
sudo ./target_nvme_takeover.sh \
  -d nvmeXn1,nvmeYn1,nvmeZn1,nvmeUn1,nvmeVn1 \   # ← 现查的 5 块空闲盘名（逗号分隔）
  -p urma \                  # capsule 走 urma，与 initiator SPDK_URMA_CAPSULE_TRANSPORT=urma 一致（ADR-002）
  -R 4096 \                  # 5 盘合 raid0（strip 4MB）→ 单 namespace nsid 1（URMA_RAID0）
  -I 8192,8192,640,4194304 \ # iobuf 池：small 8192×8192B / large 640×4MB
  -O 4194304 \               # transport max_io_size=4MB（大 I/O 路径）→ initiator 也要 SPDK_URMA_MAX_IO_SIZE=4194304
  -C 64 \                    # 每 PG large iobuf 缓存 64（钉地址，防注册缓存崩塌）
  -m 0x3f \                  # nvmf_tgt core mask（6 核）
  -s 10 \                    # target 每 10s 打点一次
  -N udmac0d1e2 \            # URMA 设备名
  -L /home/tong/umdk_gpu_isolated/lib \  # URMA 库目录（须成套含 liburma + liburma_common）
  -i 141.61.84.149           # listener IP（node3）
```

脚本跑完打印 `Target 就绪` + subsystem / listener / iobuf 汇总，产物：
- subsystem `nqn.2026-01.io.spdk:urma-gpu-test`，listener `141.61.84.149:4420 (URMA)`，capsule `urma`
- 5×NVMe → `URMA_RAID0`（raid0）→ 单 namespace nsid 1，~34.93 TiB
- nvmf_tgt 后台运行，日志 `/tmp/nvmf_tgt.log`，PID `/var/tmp/nvmf_tgt.pid`

验收：脚本末尾 `Target 就绪` + `ss -tlnp | grep 4420` 有监听。

停止：`kill $(cat /var/tmp/nvmf_tgt.pid)`。RPC 配置不持久化，**node3 重启后重跑本脚本**。
失败中断后补救：`sudo ./target_nvme_takeover.sh -r`（把残留盘还原回 nvme 驱动后退出）。

---

## 7. 部署：node4 master

> **master 内置 HTTP metadata server**，不需要单独起 python metadata 进程。

```bash
cd /home/yin/nof/mooncake/mooncake-store/build/mooncake-store/src

SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma SPDK_URMA_MAX_IO_SIZE=4194304 ./mooncake_master \
  --rpc_port=50061 \
  --enable_http_metadata_server --http_metadata_server_port=9998 \
  --metrics_port=9004 \
  --nof_heartbeat_interval_sec=120 --nof_heartbeat_failures_threshold=5
```

参数说明：
- `--rpc_port=50061`：gRPC 端口（启动前按 §2 检查，被占用则换）
- `--enable_http_metadata_server --http_metadata_server_port=9998`：metadata 内置在 master（被占用则换）
- `--metrics_port=9004`：指标端口（被占用则换）
- `--nof_heartbeat_interval_sec=120 --nof_heartbeat_failures_threshold=5`：**心跳拉大**（120s / 5 次失败才摘除），
  防止打流间歇抖动导致 NoF segment 被误摘除。属实验调优，不是默认值。

验收：
```bash
ss -tlnp | grep -E '50061|9998|9004'
curl -s http://127.0.0.1:9998/metadata | head    # 200 响应即可
```

> client / bench 启动时的段错误（ADR-001）只发生在创建 UB transport context 时，master 本身不受影响。

---

## 8. 注册 NoF segment（node4，`/tmp/nof_register` 工具）

前置：§7 的 master 已活着、§6 的 target 已监听 4420。

```bash
# 用法：<nqn> <nsid> <traddr> <trsvcid> <trtype> <master_addr> [size_bytes]
/tmp/nof_register nqn.2026-01.io.spdk:urma-gpu-test 1 141.61.84.149 4420 URMA \
  141.61.84.151:50061 38407505182720
```

期望：
- 工具输出 `NoF registration succeeded`
- master 日志：`master_service.cpp:866 NoF segment mount ... action=mount_segment`
- master 指标确认：`NVMe-oF SSD: 0 B / 34.93 TB`（注册后心跳 attach 成功）

注销（需要时）：
```bash
/tmp/nof_unregister nqn.2026-01.io.spdk:urma-gpu-test 1 141.61.84.149 4420 URMA 141.61.84.151:50061
```

> 工具调 `NoFRegisterClient::set_register` → master `MountNoFSegment` RPC（`BuildTeEndpoint` 生成
> `traddr:... trsvcid:... subnqn:... trtype:... adrfam:IPv4 ns:...`）。与通用部署的 python
> `mooncake_ssd_register.py`（pybind）是两条注册路径，本场景用 C++ 工具。

---

## 9. 打流：segment_write（node4）

256 keys × 4MB = 1 GB。

```bash
cd /home/yin/nof/mooncake/mooncake-store/build/mooncake-store/benchmarks

# 首次（无 hard_pin，约 253 MB/s —— 仅冒烟，不作为吞吐基准）
SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma SPDK_URMA_MAX_IO_SIZE=4194304 ./stress_cluster_bench \
  --scenario=segment_write --protocol=tcp \
  --local_hostname=141.61.84.151:50071 --remote_hostname=141.61.84.151:50061 \
  --segment_name=test_nof_segment --num_keys=256 --value_size=4194304 \
  --nof_replica_num=1 --wait_seconds=300

# 正式（--hard_pin=true，约 2.0~2.3 GB/s）
SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma SPDK_URMA_MAX_IO_SIZE=4194304 ./stress_cluster_bench \
  --scenario=segment_write --protocol=tcp \
  --local_hostname=141.61.84.151:50071 --remote_hostname=141.61.84.151:50061 \
  --segment_name=test_nof_segment --num_keys=256 --value_size=4194304 \
  --nof_replica_num=1 --hard_pin=true --wait_seconds=300
```

预期输出（成功时）：
```
Segment [0] ... type=NoF complete: 256 succeeded, 0 failed
Total data: 1.00 GB | Throughput (avg): 2015.02 MB/s (1.97 GB/s)
```

| flag | 作用 |
|---|---|
| `--hard_pin=true` | 防止 segment 被 eviction；**不开只有 ~253 MB/s，开了 ~2 GB/s**（10×） |
| `--wait_seconds=300` | writer 写完后台持活 300s，给 reader 留窗口（ADR-004：写进程退出后 lease 10s 过期 → 读全 LEASE_EXPIRED） |
| `--nof_replica_num=1` | 每个 object 1 个 NoF SSD 副本（纯 NoF） |
| `--local_hostname` / `--remote_hostname` | 本进程数据面 :50071 / master gRPC :50061 |

---

## 10. 打流：segment_read（node4）

单 key warmup 读可用；duration（批量）模式有已知限制（ADR-005，见 10.2）。

### 10.1 单 key warmup 读（验证 NoF 读通路）

```bash
SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma SPDK_URMA_MAX_IO_SIZE=4194304 ./stress_cluster_bench \
  --scenario=segment_read --protocol=tcp \
  --local_hostname=141.61.84.151:50072 --remote_hostname=141.61.84.151:50061 \
  --segment_name=test_nof_segment --num_keys=256 --value_size=4194304 \
  --nof_replica_num=1 --duration=20 --warmup_keys=5
```

预期：`--warmup_keys=5` 全部 `read_ok`，约 3~5 ms/key（首 key ~1.78s 含 NoF 连接建立）：
```
key_0: type[disk] status[read_ok]   ← 1.78s（首次，含 NoF 连接）
key_1: type[disk] status[read_ok]   ← 5.3ms
...
```

### 10.2 已知限制：duration（批量）模式失败

duration 连续读当前会全部失败：

```
batch_get_into_breakdown ... read_us[35654637] mem_ops[32] disk_ops[0] success[0]
32 keys 全部 BatchGet failed ... LEASE_EXPIRED
```

根因：`batch_get_into_internal`（`real_client.cpp` ~5560-5800）只处理 `is_local_disk_replica()` /
`is_disk_replica()`，**没有 `is_nof_replica()` 分支** → NoF replica 落入默认 MEMORY 路径 →
调 `client_->BatchGet` 卡 35.6s → lease 过期。单 key `get_into` 有 NoF 分支（所以 10.1 warmup 通过）。

修复方向（详见 [`adr.md`](./adr.md) ADR-005）：
- 方案 A：`batch_get_into_internal` 为 NoF replica 逐 key 走 `get_into`（已验证通路）
- 方案 B：修 `client_service.cpp` `BatchGet` 的 NoF 分支卡 35s 问题

> 在修复前，NoF 读通路用 10.1 的单 key warmup 验证（已通过）。

> ⚠️ `--local_hostname` 端口必须避让：若 50071 已被后台 writer 占用，reader setup 报 `ret=-600`，
> 换 50072（ADR-006）。

---

## 11. 冒烟：list_segments

```bash
SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma SPDK_URMA_MAX_IO_SIZE=4194304 ./stress_cluster_bench \
  --scenario=list_segments --protocol=tcp \
  --local_hostname=141.61.84.151:50071 --remote_hostname=141.61.84.151:50061
```

预期输出 1 个 NoF segment：
```
traddr:141.61.84.149 trsvcid:4420 subnqn:nqn.2026-01.io.spdk:urma-gpu-test trtype:URMA adrfam:IPv4 ns:1
```

> 若 list_segments 返回空，说明 `GetAllNoFSegments` 没发现 segment：回 §8 确认注册成功 +
> 心跳 attach（master 指标能看到 `NVMe-oF SSD: ... / 34.93 TB`）。

---

## 12. 日志建议

建议把每个常驻进程的输出重定向到独立日志，便于按进程排查（不要塞进一个窗口用 `&` 挂后台——
日志混在一起、Ctrl-C 一次全死）：

| 进程 | 建议日志 | 主要排查内容 |
|---|---|---|
| master（node4） | `master.log` | NoF mount / 打流 RPC；attach 失败查 `capsule mismatch` / `LOC_ACCESS_ERR` |
| nvmf_tgt（node3） | `nvmf_tgt.log` | target 侧 `capsule mismatch local=urma remote=tcp rc=-93` |
| writer | `seg_write.log` | `Segment [0] ... succeeded/failed` + `Throughput` |
| reader | `seg_read.log` | warmup `read_ok` / duration 模式 `LEASE_EXPIRED` |

---

## 13. 故障排查

| 现象 / 日志 | 根因 | 处理 | ADR |
|---|---|---|---|
| client/bench 启动即段错误，崩在 `udma_u_delete_jetty` | `urma_user_ctl(SET_BONDING_MODE)` 库内清理路径空指针 | 用 `00b31e3` 编译的 bench（守卫默认关）；**不要设** `MC_URMA_SET_BONDING_MODE` | ADR-001 |
| 用未含守卫补丁的 bench 二进制跑 `--protocol=ub` 段错误 | 该二进制无 `MC_URMA_SET_BONDING_MODE` 守卫，走到 `urma_user_ctl` 崩溃 | 用 `00b31e3` 编的 bench | ADR-001 |
| master attach 失败 `-104`；target 日志 `capsule mismatch local=urma remote=tcp rc=-93` | initiator 默认发 tcp capsule | `export SPDK_URMA_CAPSULE_TRANSPORT=urma` | ADR-002 |
| attach `status=4`（LOC_ACCESS_ERR） | 未设设备名 → 错选 `bonding_dev_0` | `export SPDK_URMA_DEV_NAME=udmac0d1e2` | ADR-003 |
| segment_read 全 `LEASE_EXPIRED`（写进程已退出） | master lease TTL 10s，写 client 退出即过期 | 后台 writer 持活（`--wait_seconds=300`）或调大 `--default_kv_lease_ttl` | ADR-004 |
| segment_read duration 全失败，`batch_get_into ... mem_ops[32] disk_ops[0] success[0]` 卡 35.6s | `batch_get_into_internal` 缺 `is_nof_replica()` 分支 | **已知限制**：见 §10.2；读通路用单 key warmup 验证 | ADR-005 |
| reader setup `ret=-600` | `--local_hostname` 端口被 writer 占用 | reader 换端口（50071→50072） | ADR-006 |
| 重编 master 后 bench 段错误 | 只编 master 没重编 bench（transfer-engine 改动未 link 进 bench） | `cmake --build build -j64 --target mooncake_master stress_cluster_bench` | — |
| `NoF replicas requested but no NoF segments were found` | 注册路径/心跳未就绪 | 回 §8 确认注册 + attach；确认 `--nof_replica_num` 与 `--segment_name` | — |
| master / bench 启动报端口被占用 | 目标端口已被本机其它进程占用 | 按 §2 检查 `ss -tlnp \| grep <port>`，停占用进程或换空闲端口 | — |

---

## 14. 启动前的进程与端口检查

每个服务启动前确认端口空闲，避免与本机其它进程冲突：

```bash
# 1. 检查目标端口是否被占用
ss -tlnp | grep -E '50061|9998|9004|50062|50071|50072'

# 2. 若被占用，查出占用进程决定是停掉还是换端口
ss -tlnp | grep 50061      # 看 PID/进程名
# 占用进程无需保留 → 停掉；需保留 → 本服务改用其它空闲端口，同步改所有引用处端口号

# 3. 重启同名服务（如重启 master）前，先确认旧实例已退出
ss -tlnp | grep 50061      # 无输出 = 旧实例已退出，可重启
```

- 改端口要改全：master 的 `--rpc_port` / `--metrics_port` / `--http_metadata_server_port`，
  bench 的 `--remote_hostname`（指向 master gRPC 端口）与 `--local_hostname`。
- 重复启动同一服务前，务必确认旧实例已退出，否则新旧实例抢端口。

---

## 文档关系

```
real_deployment.md           本文：编译部署手册（可复现的操作步骤）
real_experiment.md           实验方案 + 实测数据
adr.md                       ADR-001~006（段错误/capsule/设备名/lease/batch_get_into/端口冲突）
diagnosis.md                 问题总表 + 环境状态
details.md                   ADR-001 段错误 gdb 取证
glm_review.md                外部审阅
../mooncake_nof_deployment.md  通用部署文档（nof-urma-v2 + nof_worker_pool_bench，对照参考）
```
