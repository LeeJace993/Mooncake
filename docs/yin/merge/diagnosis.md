# Mooncake 编译部署诊断与问题总表

> 实验方案：node4 (151) 编译部署 Mooncake，node3 (149) SPDK nvmf_tgt target
> 实验分支：`nof-urma-v2-bench-merge` @ `e4bfe3d`（node4 = fork；`00b31e3` 为 WSL 镜像同内容独立提交）
> 关联文档：`adr/adr-urma-错误.md`（ADR-001）、`glm_review.md`（外部审阅）

## 问题总表

| # | 问题 | 阶段 | 根因 | 解决方案 | 状态 |
|---|------|------|------|---------|------|
| 1 | `UbGpuMode` 编译错误 | Phase 2 编译 | 分支 HEAD 的 `ub_transport.cpp:98` 嵌套 enum 类外未限定 | `UbGpuMode` → `UbTransport::UbGpuMode` | **✅ 已修复已提交** |
| 2 | DPDK 链接库缺少 | Phase 2 编译 | `SPDK_STATIC_LIBS` 缺 7 个 rte 库 | 补全 `rte_log/rte_argparse/rte_bus_vdev/rte_cmdline/rte_dmadev/rte_meter/rte_stack` | **✅ 已修复已提交** |
| 3 | SPDK_OPTIONAL_LIBS 缺项 | Phase 2 编译 | 新 SPDK fork 新增 `keyring/keyring_file/keyring_linux/fuse_dispatcher` + `fuse3` | 补全 optional 库 | **✅ 已修复已提交** |
| 4 | PATH_SUFFIXES no-op | Phase 2 编译 | 末尾 `lib` 是重复项（非第4处真正修复） | 已回退；真正修的是 `URING_LIB` 的 PATH_SUFFIXES，待补 | **已回退，待补充** |
| 5 | **mooncake_client 段错误** | Phase 3 启动 | `urma_user_ctl(SET_BONDING_MODE)` 在 `liburma-udma.so` 内部清理路径 `udma_u_delete_jetty` 空指针崩溃 | 加 `MC_URMA_SET_BONDING_MODE` env 守卫（默认关）三分支 | **✅ 已解决已提交** |
| 6 | `stress_cluster_bench` 也段错误 | Phase 4 打流 | 重编 `mooncake_client` 时未更新 `stress_cluster_bench` | `cmake --build build --target stress_cluster_bench` | **✅ 已解决** |
| 7 | NoF 注册后 bench 发现不了 | Phase 4 打流 | `NoFRegisterClient::set_register` 注册 `size=35TB` 成功（MountNoFSegment success），但 `stress_cluster_bench` 走 `GetAllNoFSegments` RPC 返回空列表。怀疑注册路径与 bench 发现路径不一致 | 待确认：可能缺少 `mooncake_client` 常驻进程；或需用 `mooncake_ssd_register.py` 完整流程 | **❌ 待解决** |
| 8 | DT_RPATH 硬编码问题 | Phase 3 启动 | DT_RPATH 优先级高于 LD_LIBRARY_PATH | `patchelf` 或 `-DCMAKE_BUILD_RPATH` | **✅ 已修复** |
| 9 | 现役 (p50065573) bench 段错误 | Phase 4 打流 | 现役二进制没有 env 守卫补丁，遇到和 #5 相同的 `urma_user_ctl` 崩溃 | 必须用自己的 patched bench | **✅ 已知，规避** |
| 10 | duration 批量读 status=4 + CQ transport error -5 卡死 | Phase 4 读 | 待定位（ADR-005 v3：H1 深度耗尽 / H2 lkey 生命周期 / H3 target 状态；单 key warmup 正常、第 1 轮 32/32 慢成功、第 2 轮报错，形状不确定） | 先取证（gdb 栈 / seg_read_ttl.log 形状 / nvmf_tgt.log）→ num_keys 阶梯；修 poll 报错不中止 | **🔄 定位中** |

## 当前环境状态

| 组件 | 节点 | PID | 端口 | 状态 |
|------|------|-----|------|------|
| mooncake_master (我们的) | 151 | 441368 | 50061 / 9004 / 9998 | ✅ 运行中 |
| nvmf_tgt (SPDK URMA) | 149 | 2157286 | 4420 (URMA) | ✅ 运行中 |
| subsystem `urma-gpu-test` | 149 | — | nsid 1 = URMA_RAID0 (5×7T raid0) | ✅ |
| mooncake_client | 151 | — | — | ✅ 可启动，当前已停 |
| stress_cluster_bench (patched) | 151 | — | — | ✅ 可运行 |
| 现役 mooncake_master (w00921547) | 151 | — | 50051/8080/9002 | ✅ 未动 |
| 现役 mooncake_client (w00921547) | 151 | — | 50052 | ✅ 未动 |

## Phase 4 当前卡点分析

### 已达成

1. `NoFRegisterClient::set_register` 用 `size=38482906972160`（35TB）注册成功：
   ```
   I20261012 19:19:08.815653 master_client.cpp:546] Master RPC pool warmup completed: 100/100 succeeded
   NoF registration succeeded
   ```
2. master logs RPC 侧确认 `MountNoFSegment` 返回 success。

### 未达成

`stress_cluster_bench --scenario=segment_write --nof_replica_num=1` 报：
```
E20261012 19:19:20.954939 stress_cluster_bench.cpp:2097] NoF replicas requested but no NoF segments were found
```

说明 `GetAllNoFSegments` RPC 返回空列表。可能原因：

| 嫌疑 | 理由 |
|------|------|
| `NoFRegisterClient::set_register` 和 `GetAllNoFSegments` 走不同数据结构 | 前者直接 RPC 到 master 的 `MountNoFSegment` handler，后者走不同查询路径 |
| segment 注册但没有持久化到 master 的状态表 | metrics 只看得到内存 segment |
| 缺少 `mooncake_client` 常驻进程（现役架构有） | 现役的 NoF 注册可能依赖 client 进程持有的 SPDK env |

### 现役 NoF 架构参考

来自 `/home/p50065573/nof/mooncake-v2/docs/yin/mooncake_nof_deployment.md`：

```
mooncake_master :50051 → Http metadata server :8080
mooncake_client（常驻）→ NoF 注册（通过 pybind MooncakeDistributedNoFRegister）
→ 验证：nof_worker_pool_bench / stress_cluster_bench
```

我们的 master `:50061` 里带 HTTP metadata server `:9998`。但缺少 `mooncake_client` 后端。

## 工具清单

| 工具 | 位置 | 用法 |
|------|------|------|
| `nof_register` | `/tmp/nof_register` | `nof_register <nqn> <nsid> <traddr> <trsvcid> <trtype> <master_addr> <size_bytes>` |
| `nof_unregister` | `/tmp/nof_unregister` | `nof_unregister <nqn> <nsid> <traddr> <trsvcid> <trtype> <master_addr>` |
| bench (patched) | `./mooncake-store/build/mooncake-store/benchmarks/stress_cluster_bench` | 已带 env 守卫补丁 |

## 知识点记录

1. **PowerShell 引号陷阱**：ssh 命令中的 `<<` `>>` `<` 被 PowerShell 解释为重定向。
   解决：`Get-Content file -Raw | ssh ... "cat > /tmp/file"` 或 base64 编码。

2. **重编必须全量**：改动 `urma_endpoint.cpp`（transfer-engine）后，所有依赖它的目标
   （`mooncake_client`、`stress_cluster_bench`）都必须重新 link。

3. **liburma 树收敛**：三棵 UMDK 库树（`UMDK_tool` + `tong` + `/usr/lib64`），建议收敛为一棵。

4. **NoF 注册 vs. bench 发现路径不一致**：`NoFRegisterClient::set_register` 的
   `MountNoFSegment` RPC 和 `stress_cluster_bench` 的 `GetAllNoFSegments` RPC
   可能是 master 上不同的数据结构/服务路径。
