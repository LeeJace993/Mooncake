# Mooncake nof-urma-v2-bench-merge 部署实验 ADR 合辑

- 实验：node4 (151) 编译部署 Mooncake + node3 (149) target NoF
- 分支：`nof-urma-v2-bench-merge` @ `7ebd69a0` -> `00b31e3`（3 patches + 后续）
- 时间：2026-10-12 ~ 2026-10-13
- 总状态：Phase 0-3 ✅ / Phase 4 segment_write ✅ ~2 GB/s / segment_read ❌ node3 设备链故障（status=4 硬件 CR 错误）

---

## ADR-001：mooncake client 启动段错误（URMA bonding mode 设置崩溃）

| 字段 | 值 |
|------|-----|
| 日期 | 2026-10-12 |
| Phase | Phase 3（client 启动） |
| 状态 | **已解决** ✅ |
| 修复 | `urma_endpoint.cpp` 加 `MC_URMA_SET_BONDING_MODE` env 守卫（默认关闭->跳过），3 分支结构 |
| Git | `e4bfe3d` force push |

### 症状

`mooncake_client --protocol=ub` 段错误，崩溃在 `udma_u_delete_jetty`（`urma_user_ctl` openDevice 内部）。
RPATH 修复后仍崩在同一位置。

### gdb bt

```
#0  udma_u_delete_jetty()  from /home/tong/umdk_gpu_isolated/lib/urma/liburma-udma.so
#1  ??()                   from /home/tong/umdk_gpu_isolated/lib/urma/liburma-udma.so
#2  urma_user_ctl()        in urma_cp_api.c:2950
#3  openDevice()           in urma_endpoint.cpp:552
    mode = {bonding_mode = BONDP_BONDING_MODE_STANDALONE, bonding_level = BONDP_BONDING_LEVEL_PORT}
    in  = {addr = ..., len = 8, opcode = 7}
```

### strace + dmesg

- strace：未捕获到 BONDP_USER_CTL ioctl -> 崩溃在用户态预检阶段，**未进入内核**
- dmesg：干净（无 Call Trace）
- **结论**：不是内核 ABI 不匹配，是 `liburma-udma.so` 库内清理路径自身的 bug

### 根因

`urma_user_ctl(SET_BONDING_MODE)` 是 commit `d8d9076e`（"Port URMA NUMA affinity mode"）
新增的无守卫必经路径。旧代码创建 context 后直接 `urma_query_device`，从不调 `urma_user_ctl`。
`multipath()` 开关关不掉它（两个分支都调）。库内清理路径 `udma_u_delete_jetty` 空指针崩溃。

### 现役对照

现役 w00921547 源码也有 `urma_user_ctl` 调用，但用 p50065573 的 bench 跑 `--protocol=ub` 同样崩。
确认**现役从未走过 UB transport 路径**（现役 workload 用 `--protocol=tcp`）。

### 运行库验证

| 配置 | LD_LIBRARY_PATH | 结果 |
|------|-----------------|------|
| tong 隔离树 | `/home/tong/umdk_gpu_isolated/lib:.../urma` | 段错误 |
| B 编译树 | `/home/yin/gdr/UMDK_tool_netlab-sp4_umdk/lib:.../urma` | 段错误 |
| 系统库 | `/usr/lib64` | 段错误 |

`liburma-udma.so` 在两棵 UMDK 树 md5 相同（`3b0674be`）。

### 修复

```cpp
static auto bondingModeSetEnabled = []() -> bool {
    const char* env = std::getenv("MC_URMA_SET_BONDING_MODE");
    return env && (std::string(env) == "1" || std::string(env) == "true" || std::string(env) == "on");
};

if (!bondingModeSetEnabled()) {
    if (multipath())
        LOG(WARNING) << "multipath requested but bonding mode set is disabled";
    LOG(WARNING) << "Skipping urma_user_ctl SET_BONDING_MODE on " << device_name;
} else if (multipath()) {
    // BALANCE/IODIE
} else {
    // STANDALONE/PORT（恢复被删的分支）
}
```

### 验证

```
W20261012 17:25:47.073770 urma_endpoint.cpp:521] Skipping urma_user_ctl SET_BONDING_MODE on udmac0d1e2
I20261012 17:25:47.085220 ub_transport.cpp:454] UbTransport: initialize Ub resources done
I20261012 17:25:47.086576 real_client.cpp:815] Successfully created client on port 13790
```

### 编译期修复（同次提交 3 文件 +26/-5）

| # | 文件 | 修复 |
|---|------|------|
| 1 | `CMakeLists.txt` | 补 DPDK 库（`rte_log/rte_argparse/rte_bus_vdev/rte_cmdline/rte_dmadev/rte_meter/rte_stack`） |
| 2 | `CMakeLists.txt` | 补 SPDK optional 库（`keyring`x3`fuse_dispatcher`）+ 系统 `fuse3` |
| 3 | `ub_transport.cpp` | `UbGpuMode` -> `UbTransport::UbGpuMode` |

---

## ADR-002：initiator capsule 传输不匹配 -> attach 失败 -104

| 字段 | 值 |
|------|-----|
| 日期 | 2026-10-12 |
| 状态 | **已解决** ✅ |

### 症状

master attach NoF target 失败：
- node4 master 日志：`Ctrlr operation failed with error: -104, Connection reset by peer`
- node3 target 日志：`capsule mismatch: local=urma remote=tcp, rc=-93`

### 根因

initiator 默认发 **tcp capsule**，target 配置 `capsule_transport=urma`，两侧不匹配。

### 修复

```bash
export SPDK_URMA_CAPSULE_TRANSPORT=urma
```

---

## ADR-003：initiator 设备错选 bonding_dev_0 -> attach 失败 status=4（LOC_ACCESS_ERR）

| 字段 | 值 |
|------|-----|
| 日期 | 2026-10-13 |
| 状态 | **已解决** ✅ |

### 症状

`capsule completion failed: status=4 user_ctx=...`（`URMA_CR_LOC_ACCESS_ERR`）。

### 根因

未设 `SPDK_URMA_DEV_NAME` 时设备选择逻辑错选 `bonding_dev_0`（不可用于本次数据通路），
用户指定传输设备为 `udmac0d1e2`（`urma_admin show --all` 可见，8 个 EID）。

### 修复

```bash
export SPDK_URMA_DEV_NAME=udmac0d1e2
```

### 验证

master 重启后 attach 成功，指标出现 `NVMe-oF SSD: 0 B / 34.93 TB`。

---

## ADR-004：segment_read LEASE_EXPIRED（lease TTL 10s，写 client 退出即过期）

| 字段 | 值 |
|------|-----|
| 日期 | 2026-10-13 |
| 状态 | **已规避** ✅ |

### 症状

写进程退出后跑 `segment_read`，全部 key `LEASE_EXPIRED`。

### 根因

master 默认 `default_kv_lease_ttl=10000`（10s）。写 client 退出后 lease 不再续期，10s 过期。
`--hard_pin=true` 只防 eviction，不续 lease。

### 规避

后台 writer 持活（`--wait_seconds=300`），或调大 master `--default_kv_lease_ttl`。

---

## ADR-005：segment_read duration 模式失败 -- batch_get_into 无 NoF 分支

| 字段 | 值 |
|------|-----|
| 日期 | 2026-10-13 |
| 状态 | **尚未解决** |

### 症状

后台 writer 持活期间，读客户端 `--scenario=segment_read --duration=20` 全部失败：

```
batch_get_into_breakdown num_keys[32] read_us[35654637] total_us[35656662]
  mem_ops[32] disk_ops[0] ssd_offload_ops[0] success[0]
  replicas[key_0=disk ... key_31=disk ]
E ... BatchGet failed for key '...': LEASE_EXPIRED（32 条）
```

单 key warmup 读（`--warmup_keys=5`）全部 `read_ok`（3~5 ms/key）：

```
get_into_breakdown ... type[disk] mode[full] ... status[read_ok]
```

### 根因（代码考古）

1. **`get_into`（单 key）** 有 NoF 分支 -> 走 `client_->Get` -> `TransferRead`（SPDK 读 149:4420） ✅
2. **`batch_get_into`（批量）** 在 `batch_get_into_internal`（`real_client.cpp` ~5560-5800）中：
   - 只处理 `is_local_disk_replica()` / `is_disk_replica()` 分支
   - **没有 `is_nof_replica()` 分支**
   - NoF replica 落入默认 MEMORY 路径 -> 调 `client_->BatchGet`
3. `client_service.cpp` `BatchGet` 虽有 `is_nof_replica()` 分支（1562），
   但执行时卡住 35.6s，lease 过期 -> `LEASE_EXPIRED`

### 修复方向

- **方案 A**：在 `batch_get_into_internal` 中为 NoF replica 逐 key 走 `get_into`（已验证通路）
- **方案 B**：修复 `client_service.cpp` `BatchGet` 的 NoF 分支卡 35s 问题

### 涉及文件

| 文件 | 位置 |
|------|------|
| `real_client.cpp` | `batch_get_into_internal`（~5560-5800）缺 `is_nof_replica()` |
| `real_client.cpp` | 单 key NoF 处理（~4087、4130-4160）可复用 |
| `client_service.cpp` | `BatchGet`（1485）NoF 分支（1562）卡 35s |
| `replica_selection.h` | `SelectBestReplica`（125-165）NoF 返回正确 |
| `stress_cluster_bench.cpp` | `RunSegmentRead`（1055）/ `RunSegmentReadDuration`（1226） |

---

## ADR-006：读客户端 setup 失败 ret=-600（本地端口冲突）

| 字段 | 值 |
|------|-----|
| 日期 | 2026-10-13 |
| 状态 | **已解决** ✅ |

### 症状

后台 writer 占用 `--local_hostname=141.61.84.151:50071`，读客户端用同一端口 setup 报 `ret=-600`。

### 修复

读换端口 50072。验证 setup 成功。

---
## ADR-007：segment_read duration 批量 NoF 读 status=4 (LOC_ACCESS_ERR)
### --open hypothesis: stale import (initiator 128 cache) vs node3 device chain fault

| 字段 | 值 |
|------|-----|
| 日期 | 2026-10-13 |
| Phase | Phase 4（segment_read，lease TTL=600s 修复后二次验证） |
| 状态 | **尚未解决** |

---

### 一、症状

lease TTL=600s 修复后（`--default_kv_lease_ttl=600000`），后台 writer 持活期间，读客户端 `--scenario=segment_read --duration=30 --warmup_keys=5`：

- ✅ warmup 5 key 全部 `read_ok`（1~5 ms/key），证明 lease 不再过期
- ❌ duration 批量读 ~17.5s 后首次报错：

```
[2026-10-13 10:43:24.741014] nvme_urma.c: 971: *ERROR*: capsule completion failed: status=4 user_ctx=0x39bd8820
[2026-10-13 10:43:24.741075] nvme_qpair.c: 914: ... CQ transport error -5 (Input/output error)
E20261013 10:43:24.741094 transfer_task.cpp:605] poll completion error: ret -5
```

进程 90% CPU 空转不退出（duration=30 已过仍存活 2:40+）。

---

### 二、完整时间线（2026-10-13 10:41 ~ 11:25）

| 时刻 | 节点 | 事件 | 来源 |
|------|------|------|------|
| 10:41:32 | node4 | writer 写完 256/256，`wait_seconds=300` | `/tmp/seg_write_ttl.log` |
| 10:43:07 | node4 | reader warmup 完成，进入 duration 批量读 | `/tmp/seg_read_ttl.log` |
| 10:43:24 | node4 | **首错**：`status=4 (LOC_ACCESS_ERR)` + `CQ transport error -5` | `/tmp/seg_read_ttl.log` |
| 10:43:49~53 | node4 | sentry poll 到 `cr.status is 4`（对 node3 eid `df00:8b00`/`df04:8b00`） | node4 dmesg |
| 10:44:26~33 | node4 | `tjetty[6]...check failed: send_cnt=4, remote_recv_cnt=0`, rebuild + lock busy | node4 dmesg |
| 10:44:47/10:46:53 | node4 | port1 link up -> down（node3 侧链路先断） | node4 dmesg |
| 10:50 | node3 | 重启（up 37min），`pcie wait link status failed, -110` | node3 dmesg |
| 11:15~17 | node3/4 | 设备栈重建：UDMA reset `elr_err`、`register_seg failed`、`create tx jetty error` | node3/4 dmesg |
| 11:25~26 | node4 | `sentry_urma_comm` 加载失败 `Unknown symbol...err -22` | node4 dmesg |

---

### 三、软件层代码考古

#### 3.1 `batch_get_into_internal` 分类逻辑（`real_client.cpp:5693-5729`）

NoF replica **没有独立分支**：

```cpp
if (replica.is_local_disk_replica()) { /* offload */ continue; }        // 5693
if (replica.is_disk_replica())       { /* file I/O */ continue; }       // 5706
// NoF replica falls here (5718) - treated as MEMORY
std::vector<Slice> key_slices;
allocateSlices(key_slices, replica, buffers[i]);                        // 5720
valid_operations.push_back({...});                                      // 5721
```

**影响**：NoF replica 被当作 MEMORY，调 `client_->BatchGet()`（5779），breakdown 标签误标为 `"disk"`（5675 的 else 分支）。

#### 3.2 `Client::BatchGet` 已有 NoF 分支（`client_service.cpp:1562-1571`）

```cpp
if (replica.is_nof_replica()) {
    auto contiguous_range = GetContiguousSliceRange(slices_it->second);
    future = transfer_submitter_->submit(
        replica, slices_it->second, TransferRequest::READ,
        contiguous_range->ptr, contiguous_range->size);
}
```

**不是死路**：`client_service.cpp:1562` 有 `is_nof_replica()` 守卫，能正确路由。

#### 3.3 Worker 线程 `ResolveBuffer` + `io_opts`（`transfer_task.cpp:489-564`）

```cpp
// Buffer classification (496-499)
task->buffer_info = NofMemoryDomainManager::GetInstance().ResolveBuffer(task->ptr, ...);

// io_opts decision (552-564): only CUDA memory gets io_opts
const bool is_cuda_io = task->buffer_info.type == NofMemoryType::kCuda;
SubmitRequest(..., is_cuda_io ? &sub_task->io_opts : nullptr);   // host -> nullptr
```

**结论**：host buffer 走 `nullptr` -> `spdk_nvme_ns_cmd_read`，这是 Yida v3 显式设计。

#### 3.6 单 key `get_into` 路径（`real_client.cpp:4087-4132`）-- 对比参照

```cpp
if (replica.is_nof_replica() && NofEndpointIsUrma(...)) {
    auto info = manager.ResolveBuffer(dst, total_size);
    if (info.type == NofMemoryType::kCuda) {
        auto get_result = client_->Get(key, filtered_qr, slices);
    }
}
```

**关键发现**：单 key 与批量在 **I/O 提交层完全一致** -- 都进 `SpdkNofWorkerPool::workerThread` -> `SubmitRequestOnQpair`。差异不在软件层。

---

### 四、从软件疑点到硬件根因的证据链

#### 4.1 第一阶段：软件疑点

| # | 假设 | 裁决 | 理由 |
|---|------|------|------|
| H1 | `batch_get_into_internal` 无 NoF 分支 -> 路径错误 | 已排除 | `Client::BatchGet` 和 `TransferData` 内部都有 NoF 分支（`client_service.cpp:1562/3894`），能正确路由到 `submitSpdkNofOperation` |
| H2 | 批量 NoF 读未带 `memory_domain` -> LOC_ACCESS_ERR | 已排除 | ① 单 key 路径的 `real_client.cpp:4087` 进入条件是 `FindDeviceForPointer` 命中 CUDA——实验中 dst 是 `thread_buffers_`（host 内存），GPU Direct 分支根本不进；② 两路在 worker 汇合后完全一致：都走 `ResolveBuffer` -> host -> `io_opts=nullptr` -> `spdk_nvme_ns_cmd_read`（`transfer_task.cpp:467/552`，`spdk_wrapper.cpp:416`），与写路径同路；③ writer 以 2 GB/s 跑通，host buffer + `cmd_read` 不会导致 status=4 |
| H3 | 并发竞争（32 keys 同 qpair） | 需定量分析 | 单 key warmup 5 次连续读也走同 qpair 未现异常，但 batch 32 key 并发度更高 |

#### 4.2 第二阶段：新假设的提出（外部审阅 2026-10-13 第 4 轮）

外部审阅提出 **假设 B：initiator 侧 URMA 注册 cache 冲突导致 stale import**。

**机制链（代码逐环验证）：**

1. **initiator 注册缓存 128 槽**：`nvme_urma.c:144/322` 维护 (va, len) 注册表，永不淘汰（release 只减引用不注销）
2. **uncached 路径完成即 unregister**：`nvme_urma.c:915-917`，缓存未命中的 IO 在 completion 后立即注销
3. **seg 字节确定性**：`nvme_urma_common.c:358-364`，token 常量 + TOKEN_NONE -> 同一 (ctx, va, len) 重复注册 = 字节相同的 seg
4. **target import 缓存契约约束**：`nvmf/urma.c:36` 注释白纸黑字要求 *"initiator 在 transport 存活期间不得 unregister 已缓存的 seg"*
5. **失效触发机制**：
   - warmup 5 key x 32 chunk（4MB / 128KiB）= 160 次注册 -> key 0-3 填满 128 槽；key_4 的 32 chunk 走 uncached -> 注册后注销
   - duration 首个 batch：task 0-3 缓存命中（region 仍有效）；task 4 用与 warmup key_4 相同的 VA 重新注册 -> 字节相同 seg -> target import 缓存命中 stale 条目 -> C2H RDMA 写打进已注销的 seg -> **status=4**
6. **中毒传播**：status=4 后 qpair 中毒 -> `-EIO` -> `CQ transport error -5` -> worker 只打日志不中止（`transfer_task.cpp:600`）-> 主线程挂在 `future.get()` -> 90% CPU 空转

**未被 B 解释的残留**：run 1（35.6s 慢成功 32/32）按此机制 task 4 也该挂，但它活了。可能消解：unregister 在 UMMU 侧是异步/惰性的（时序概率）、两次 run 之间 node3 换过 boot（10:13 reboot）状态不同。这需要实验裁决。

#### 4.3 第三阶段：新证据（内核 sentry + UB 设备层）

**诊断分隔**：B 假设中 status=4 的触发不排除后续设备链退化——status=4 的 qpair 中毒可能触发 UMDK/fabric 侧的级联失效（sentry 告警、jetty 假活、链路抖动），这些症状晚于 bench 首错 25 秒 ~ 7 分钟，可能是 status=4 的**后果**而非**原因**。

核心疑点：batch 开始前 fabric 是健康的——writer 10:41:32 以 ~2 GB/s 推完 1 GB，warmup 5 key 在 batch 前几秒全部 3~5 ms/key。如果 node3 设备在 batch 中途自发死亡（A），则时间线合理；如果 batch 的流量模式本身触发了 fabric 级访问违规（B），status=4 就是发起者。判别见第五节第 1 条。

---

### 五、判读结论与验证实验

#### 5.1 定发起者（判别前提）

**batch 开始前（10:43:06）排查**——查 node4 和 node3 的 dmesg 在 10:43:06 之前有无任何 URMA/sentry/udmac 异常：

| 检查项 | 命令 | 判断标准 |
|--------|------|---------|
| node4 dmesg 10:42~10:43 | `dmesg -T | grep -E "10:4[2-3]"` | 无 urma/sentry/udmac error = 触发者在 batch 流量里 |
| node3 本轮 boot（10:13 起）dmesg | `dmesg -T` | 无设备栈异常 = 设备在 batch 前是健康的 |
| node3 `register_seg failed` 首次出现时间 | `dmesg -T | grep "register_seg"` | 若出现在 10:43 之后，则是 status=4 的后果不是原因 |

两边都干净 -> 触发者在 batch 流量里 -> B 假设优先级上升。

#### 5.2 128 边界实验（一次 bench 跑定乾坤）

在 fabric 修好后，以下三个实验的失败边界可以区分 A/B：

| # | 实验 | B 假设预测 | A 假设预测 |
|---|------|-----------|-----------|
| 1 | `--warmup_keys=3 --num_keys=5` | ✅ 全部成功（warmup 只占 96 槽，cache 有空位，task 4 VA 为全新注册，无前置注销） | 取决于节点健康，与 warmup key 数无关 |
| 2 | `--warmup_keys=5 --num_keys=4` | ✅ 全部成功（batch 全部缓存命中） | 同 |
| 3 | `--warmup_keys=5 --num_keys=5` | ❌ task 4 死（踩 stale import），且第一个死的就是 key_4 | 同 |

**判读**：失败边界严格跟着 key 4 走 = B 定案；不跟 key 4 走 = B 出局，A 升为主嫌疑。

#### 5.3 直接开关验证 kill-switch

```bash
# target 侧（node3）重启 nvmf_tgt，禁用 import cache
SPDK_URMA_IMPORT_CACHE=0 ./nvmf_tgt -m 0x3 --wait-for-rpc &
```

失败消失 = stale import 直接实锤。

#### 5.4 排除了什么

| 排除项 | 理由 |
|--------|------|
| `batch_get_into` 缺 NoF 分支是唯一根因 | `BatchGet`/`TransferData` 内部有正确路由 |
| host buffer 未注册 memory_domain | 代码已证伪：单 key `get_into` 对 host buffer 也不进 GPU Direct 分支，两路在 worker 汇合后完全一致 |
| writer 退出导致 | writer 存活至 10:46:32 |
| node3 重启导致读失败 | 链路异常先于重启 6 分钟 |

---

### 六、修复方向

| # | 方案 | 描述 | 涉及范围 | 优先级 |
|---|------|------|---------|--------|
| **A** | `batch_get_into` 加 NoF 分支 | 逐 key 走 `get_into`（已验证通路），串行但可隔离流量模式差异 | `real_client.cpp`（5693-5729） | P1 |
| **B** | 整池注册消掉 IO 级注册税 | bench 的 `thread_buffers_` 是每线程稳定大块，用 `spdk_nvme_urma_register_memory_for_qpair` 走整池注册，所有 chunk 变 `region_external`，顺带消除违反 target import 缓存契约的 uncached unregister | `spdk_wrapper.cpp` + bench | P1 |
| **C1** | 验证 128 边界（先于任何修复） | §5.2 三个实验定案 | bench 参数 | P0 |
| **C2** | nvmf_io_complete 出错时中止 worker | `transfer_task.cpp:600` 目前只打日志不中止，导致主线程永久挂起 | `transfer_task.cpp` | P1 |

### 七、备用方案：target 迁移到 node1

如果 node3 的 UB/UMDK 设备链故障无法短期修复，可将 NoF target 迁移到 **node1（141.61.84.245）**：

| 项目 | 当前（node3） | 备用（node1） |
|------|-------------|--------------|
| IP | 141.61.84.149 | 141.61.84.245 |
| SPDK 分支 | `urma_enable_v2` | `urma_enable_v2`（需部署） |
| 盘配置 | 5xNVMe raid0 | 可复用相同配置 |
| UMDK 库 | `/home/yin/gdr/UMDK_netlab` | 需确认编译树位置 |

**迁移步骤**：
1. node1 部署 SPDK `urma_enable_v2` + nvmf_tgt（同 Phase 0 流程）
2. node1 起 target，创建同名 subsystem
3. node4 重新 `nof_register`：`--traddr=141.61.84.245 --trsvcid=4420`
4. 重跑 segment_write / segment_read 验证

迁移后可以隔离 node3 设备链不稳定的变量，确认 status=4 是 node3 特有还是 NoF+URMA 批量读的普遍问题。

---

### 八、涉及文件

| 文件 | 行号 | 说明 |
|------|------|------|
| `real_client.cpp` | 5693-5729 | `batch_get_into_internal` 分类逻辑（缺 `is_nof_replica()`） |
| `real_client.cpp` | 5670-5676 | breakdown 标签误标 NoF 为 `"disk"` |
| `real_client.cpp` | 4087-4132 | 单 key NoF GPU Direct 路径（已验证） |
| `client_service.cpp` | 1562-1571 | `BatchGet` NoF 分支（已存在） |
| `transfer_task.cpp` | 1405-1441 | `submitSpdkNofOperation` |
| `transfer_task.cpp` | 489-564 | Worker 线程 `ResolveBuffer` + `io_opts` |
| `spdk_wrapper.cpp` | 400-441 | `SubmitRequestOnQpair` / `SubmitRequest` |
| `nof_memory_domain.cpp` | 244-290 | `ResolveBuffer` 实现 |

### 九、日志位置

| 文件 | 节点 | 内容 |
|------|------|------|
| `/tmp/seg_read_ttl.log` | node4 | reader：warmup OK + duration status=4 卡死 |
| `/tmp/seg_write_ttl.log` | node4 | writer：256/256 OK |
| node4 dmesg（10:43~11:25） | node4 | sentry `cr.status is 4`, `remote_recv_cnt=0`, link down 等 |
| node3 dmesg（10:50~11:17） | node3 | 重启、`register_seg failed`、`create tx jetty error` |

---

## 汇总表

| ADR | 问题 | 状态 |
|-----|------|------|
| 001 | mooncake client 段错误（urma bonding mode 崩溃） | ✅ 已解决 |
| 002 | attach 失败 -104 / -93（capsule 不匹配） | ✅ 已解决 |
| 003 | attach 失败 status=4（设备错选 bonding_dev_0） | ✅ 已解决 |
| 004 | segment_read LEASE_EXPIRED（lease TTL 10s） | ✅ 已规避 |
| 005 | segment_read duration 全失败（batch_get_into 无 NoF 分支） | 待定（被 007 覆盖） |
| 006 | 读 client setup ret=-600（端口冲突） | ✅ 已解决 |
| 007 | **segment_read duration status=4（node3 设备链故障）** | **尚未解决** |

## 关键实验数据

### segment_write（hard_pin，~2 GB/s）

```
Segment [0] type=NoF complete: 256 succeeded, 0 failed
Total data: 1.00 GB | Throughput (avg): 2015.02 MB/s (1.97 GB/s)
```

### segment_read warmup（单 key，3~5 ms/key）

```
key_0: type[disk] status[read_ok]   <- 1.78s（首次，含 NoF 连接）
key_1: type[disk] status[read_ok]   <- 5.3ms
key_2: type[disk] status[read_ok]   <- 4.8ms
key_3: type[disk] status[read_ok]   <- 2.1ms
key_4: type[disk] status[read_ok]   <- 1.0ms
```

### segment_read duration（batch 卡死）

```
batch_get_into_breakdown: mem_ops[32] disk_ops[0] success[0] read_us[17.5s->status=4]
```
