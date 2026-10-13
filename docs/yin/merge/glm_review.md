# GLM 审阅：nof-urma-v2-bench-merge 编译部署 + ADR-001 段错误分析意见

- 日期：2026-10-12
- 审阅依据：
  - `real_experiment.md`（v3，实际执行记录）
  - `adr/adr-001-client-urma-启动段错误.md`（ADR-001）
  - 本地镜像仓库 `/home/senorita/nof/mooncake` @ **7ebd69a0**（分支 `nof-urma-v2-bench-merge`，与文档记录一致）
  - 分支自带手册：`docs/yin/mooncake_bench_merge_gdr_nof.md` + `docs/yin/Deployment/mooncake_deployment_gdr.md`
- 审阅方法：对 real_experiment.md 记录的每一步做代码级核对（git 考古 + 源码阅读 + cmake 核对）。
- **局限**：node4 上的 clone（`/home/yin/nof/mooncake`）含未提交的本地修复，本地镜像看不到该 diff；
  凡涉及"node4 实际状态"的判断，均以 real_experiment.md 记录为准，最终以你发我 diff 确认。

---

## 0. 总体结论（TL;DR）

| # | 级别 | 发现 |
|---|------|------|
| 1 | **P0** | 段错误第一嫌疑锁定：`urma_user_ctl(SET_BONDING_MODE)` 是 **d8d9076e 新增**的调用，**multipath 开关关不掉它**（两个分支都调用），旧部署从未执行过这条 ioctl——与"旧部署正常、新部署崩"完全吻合（§2） |
| 2 | **P0** | 运行时栈核对只做了一半：md5 只比了 `liburma-udma.so`；`liburma.so` 等其余库、以及**内核模块版本**（ubcore/uburma/udma/ummu/桥）均未核对。`urma_user_ctl` 是 ioctl，内核侧不匹配时用户态库会走错误清理路径（§3.3） |
| 3 | **P0** | 四个编译期修复**只存在于 node4 工作区，未提交**。本地镜像 `git status` 干净（仅 yalantinglibs submodule 变动），即：现在任何人重新 clone 该分支，Phase 2 必然在同样的四处编译失败。且其中一个（`UbGpuMode`）是分支 HEAD 的真实代码缺陷（§4.1） |
| 4 | P1 | patchelf 改 RPATH 是一次性手工操作，应改用 CMake 的 RPATH 变量固化，否则重编即回退（§4.2） |
| 5 | P1 | Phase 0 `make install` 已覆盖 149 的 `/usr/local` SPDK——若现役（或任何回退需求）依赖旧产物，回退路径已被切断，需确认（§5.3） |
| 6 | P2 | merge 代码另有 3 处小缺陷：bonding-mode 失败路径泄漏 context/device list；`eid_cnt==0` 时越界解引用；mock fallback 在真机上必失败（§6） |
| 7 | — | 方案本身（隔离、端口、盘选、阶段划分）质量良好，未发现流程性错误；两个文档级小问题见 §7 |

**答复"还需要什么文件"**：见 §8 的采集清单（P0 三项：gdb bt、内核模块清单、两树全量 md5）。

---

## 1. 段错误根因分析（对 ADR-001 的修订意见）

### 1.1 调用链代码考古（本地镜像可复现）

```
mooncake_client 启动
  → UbTransport::initializeUbResources (ub_transport.cpp:988)
      hca_list = local_topology_->getHcaList()        # --device_names=udmac0d1e2 时发现该设备
  → buildContext → UrmaContext::doConstruct (urma_endpoint.cpp:135)
  → UrmaContext::openDevice (urma_endpoint.cpp:477)
      urma_get_device_list → 命中 udmac0d1e2（8 EID）
      urma_create_context 成功
      → multipath() 默认 false（config.h:147，默认值；仅 MC_URMA_BONDING_MULTIPATH_ENABLE 可开）
      → else 分支 (urma_endpoint.cpp:541-562)
      → urma_user_ctl(context, &in, &out)   ← 552 行，opcode = BONDP_USER_CTL_SET_BONDING_MODE
                                            ← 设置 STANDALONE / PORT
      → 库内 ioctl → 错误清理路径 → udma_u_delete_jetty → Segfault
```

关键事实（均已在本地镜像核实）：

1. **这段 `urma_user_ctl` 调用是 `d8d9076e`（"Port URMA NUMA affinity mode"）新增的。**
   `git log -S "BONDP_USER_CTL_SET_BONDING_MODE"` 与 `git show d8d9076e` 确认：在该 commit
   之前，`openDevice` 创建 context 后**直接** `urma_query_device`，从不调用 `urma_user_ctl`。
2. **multipath 开关关不掉它。** `multipath()` 默认 false → 走 else 分支（552 行，即你的崩溃行）；
   即便设 `MC_URMA_BONDING_MULTIPATH_ENABLE=true` 走 if 分支（531 行）——**两个分支都调用
   `urma_user_ctl`**。这个调用在当前分支的 context 打开路径上是无条件、无守卫的。
3. **崩溃点在 UMDK 用户态库内部**（`urma_user_ctl` → ioctl → 内部 openDevice 错误路径 →
   `udma_u_delete_jetty`），mooncake 侧的 `if (ret != URMA_SUCCESS)` 守卫**根本没有机会执行**
   ——库在返回前就崩了。所以 ADR 假设 1 里"输入参数与库版本不匹配导致异常返回"即使成立，
   mooncake 也拦不住；问题在库的错误清理路径本身。
4. `urma_create_context` 已成功（崩溃发生在其后的 user_ctl），说明设备枚举、EID 获取这一段
   用户态↔内核通路是通的；崩在"设置 bonding 模式"这一步。

### 1.2 为什么"旧部署正常、新部署崩"高度指向这个新调用

- w00921547 现役部署与本次部署在同一节点（151）、同一套 UMDK 运行栈上跑通过；
  若现役代码早于 d8d9076e（**待确认**，见 §8 P2 项），则现役从未执行过这条 ioctl。
- 本分支对这条 ioctl 的两个参数组合（BALANCE/IODIE 与 STANDALONE/PORT）在 151 的
  运行栈上都没有历史验证记录。
- ADR §5 假设 2（"udmac0d1e2 需要先建 bonding_dev"）与此兼容：对一个非 bondp 管理的裸
  udmac 设备发 SET_BONDING_MODE，内核/库可能走异常路径。`urma_admin show --all` 显示该设备
  8 个 EID——它是裸设备还是 bonding 聚合设备，正是需要向 UMDK 侧确认的语义问题。

### 1.3 对 ADR §5 三个假设的重排与判定方法

| 原假设 | 重排 | 判定方法 |
|---|---|---|
| #3 段错误在清理路径，需抓 core 确认 | **升为第一步**（任何假设都依赖确切 bt） | `gdb -batch -ex run -ex bt`（§1.4 步骤 1） |
| #1 参数/版本不匹配 → 异常路径空指针 | 改写为：**运行栈（用户库+内核模块）不支持该 opcode/参数**。注意 md5 只覆盖了 liburma-udma.so，`urma_user_ctl` 的实现库未核对 | 全量 md5 + `nm -D` 找符号归属 + `modinfo`（§1.4 步骤 2/3） |
| #2 设备需先建 bonding_dev | 保留，作为版本核对后的第二嫌疑 | UMDK 自带 perftest 在 udmac0d1e2 上能否建 jetty；`urma_admin` 有无 bonding 预配置命令 |

补充一个 ADR 未列的假设：

- **#4 库错误清理路径本身是 UMDK bug**：SET_BONDING_MODE 失败（无论内核返回什么）后，
  库在清理时对未创建/已失效的 jetty 句柄调 `udma_u_delete_jetty`。如果 bt 显示崩在库内
  且入参合法、内核模块版本匹配，这就是库 bug，需要 UMDK 侧修——mooncake 侧只能规避
  （见 §1.5 的守卫补丁）。

### 1.4 建议排查顺序（命令可直接用）

```bash
# ---- 步骤 1：拿确切 bt（最高优先级，ADR §6.1 的加强版）----
ulimit -c unlimited
cat /proc/sys/kernel/core_pattern          # 确认 core 落点可写
cd /home/yin/nof/mooncake
LD_LIBRARY_PATH=/home/tong/umdk_gpu_isolated/lib:/home/tong/umdk_gpu_isolated/lib/urma \
gdb -batch -ex run -ex bt -ex 'info sharedlibrary urma' -ex 'frame 3' -ex 'info registers rdi rsi' \
    --args ./build/mooncake-store/src/mooncake_client \
    --host=192.168.84.151 --port=50062 --protocol=ub --device_names=udmac0d1e2 \
    --metadata_server=http://127.0.0.1:9998/metadata --master_server_address=127.0.0.1:50061 \
    --global_segment_size=8GB --local_buffer_size=1GB --tenant_id=default --threads=4 --logtostderr=true
# bt 里确认：崩溃帧属于哪个 .so（路径即答案：/home/tong 还是 /home/yin 的库）；rdi/rsi 是否为空指针

# ---- 步骤 2：内核模块版本（ADR 完全没覆盖的盲区）----
lsmod | grep -E 'udma|ummu|ubcore|uburma|nvidia|p2p_bridge'
for m in udma ummu ubcore uburma udma_nv_p2p_bridge; do modinfo $m 2>/dev/null | grep -E '^(version|filename|srcversion)'; done
# 崩溃后立刻：
dmesg | tail -50                            # 内核侧若有 trace/错误，是 ABI 不匹配的直接证据

# ---- 步骤 3：两树全量比对（ADR 3.3 只比了一个文件）----
md5sum /home/yin/gdr/UMDK_tool_netlab-sp4_umdk/lib/liburma* /home/tong/umdk_gpu_isolated/lib/liburma*
md5sum /home/yin/gdr/UMDK_tool_netlab-sp4_umdk/lib/libub*    /home/tong/umdk_gpu_isolated/lib/libub*   2>/dev/null
ls -la /home/yin/gdr/UMDK_tool_netlab-sp4_umdk/lib /home/tong/umdk_gpu_isolated/lib   # 有无对方没有的库
# urma_user_ctl / udma_u_delete_jetty 的符号归属（两个树各跑）：
nm -D <lib>/liburma*.so 2>/dev/null | grep -E 'urma_user_ctl|udma_u_delete_jetty'

# ---- 步骤 4：ioctl 层证据 ----
strace -f -e trace=ioctl -o /tmp/client.strace \
  env LD_LIBRARY_PATH=/home/tong/umdk_gpu_isolated/lib:/home/tong/umdk_gpu_isolated/lib/urma \
  ./build/mooncake-store/src/mooncake_client <同上参数>
grep -n -B3 -A3 '0x63\|BONDP\|bond' /tmp/client.strace | tail -40   # 崩溃前最后一次 ioctl 及返回值

# ---- 步骤 5：用 UMDK 自带工具独立验证运行栈（与 mooncake 无关的最小复现）----
# 151 上跑 UMDK perftest（或任一能建 jetty 的自带工具）对 udmac0d1e2：
#   - perftest 通 → 运行栈基本健康，嫌疑集中在 SET_BONDING_MODE 这一条调用
#   - perftest 也崩 → 运行栈自身问题（版本/模块），与 mooncake 无关
# 若 UMDK 带 urma_admin 的 bonding 子命令，直接对 udmac0d1e2 设 STANDALONE 复现同样 ioctl。

# ---- 步骤 6：判定性 bisect（5 分钟）----
# 注释 urma_endpoint.cpp 541-562 的 else 分支（恢复 d8d9076e 之前的行为），只重编 transfer-engine，重跑 client。
#   - 能起 → 根因坐实为该新调用 vs 运行栈不兼容；然后走 §1.5 守卫补丁
#   - 仍崩在别处 → 假设重排，回到步骤 1 的 bt 继续

# ---- 步骤 7：现役对照 ----
git -C /home/w00921547/Mooncake log --oneline -1            # 现役基线
grep -n "urma_user_ctl" /home/w00921547/Mooncake/mooncake-transfer-engine/src/transport/kunpeng_transport/urma/urma_endpoint.cpp
# 若现役源码无此调用 → "新调用假设"的对照证据闭合
```

### 1.5 代码侧防御性修改建议（等 bt 确认后提给分支维护者）

当前 `openDevice` 把 bonding-mode 设置写成**无守卫的必经路径**，任何 UMDK 版本差异都会
在客户启动期炸掉。建议改成能力探测 + env 逃生门（草案，默认关闭、日志说明）：

```cpp
// urma_endpoint.cpp，openDevice 内，urma_create_context 成功之后：
static bool bondingModeSetEnabled() {
    const char* env = std::getenv("MC_URMA_SET_BONDING_MODE");   // 默认关
    return env && (std::string(env) == "1" || std::string(env) == "true" ||
                   std::string(env) == "on");
}
...
if (bondingModeSetEnabled()) {
    if (multipath()) { /* BALANCE/IODIE，原 521-540 */ }
    else             { /* STANDALONE/PORT，原 541-562 */ }
} else {
    LOG(WARNING) << "Skipping urma_user_ctl SET_BONDING_MODE on " << device_name
                 << " (MC_URMA_SET_BONDING_MODE not set; legacy UMDK compat)";
}
```

- 默认关闭 = 恢复 d8d9076e 之前的启动行为（旧栈可用）；需要 multipath/chip 亲和的部署显式开启。
- 更彻底的做法是探测 `dev_attr_`（或首次 user_ctl 用一个只读 opcode 试探内核是否支持 bondp），
  但那需要 UMDK 侧提供能力位，先把 env 门做上解燃眉之急。

---

## 2. 编译部署执行审阅

### 2.1 四个编译期修复：方向全部正确（本地镜像已核实前两个是真实缺口）

| # | 修复 | 本地镜像核对结果 | 评价 |
|---|------|------|------|
| 1 | `ub_transport.cpp:98` `UbGpuMode` → `UbTransport::UbGpuMode` | **HEAD 原样就是 `UbGpuMode UbTransport::gpuMode() const`，而 `UbGpuMode` 是 `class UbTransport` 的嵌套 enum（ub_transport.h:56）**——类外定义的返回类型不在类作用域内，必须限定。这是分支自带的编译错误 | 正确。建议顺手在头文件把返回类型一致化（`UbTransport::UbGpuMode gpuMode() const;` 已如此），提交时注明"HEAD 不可编译" |
| 2 | store CMakeLists 补 DPDK 库：`rte_log/rte_argparse/rte_bus_vdev/rte_cmdline/rte_dmadev/rte_meter/rte_stack` | 在树 `SPDK_STATIC_LIBS` 只有 eal/mempool/ring/bus_pci/pci/timer/telemetry/kvargs/mbuf/mempool_ring/power/ethdev/net/vhost/cryptodev/hash/rcu——新 SPDK fork 的静态链接确实会缺这些 | 正确，但**结构性问题**：手工枚举 rte 库清单必然持续烂掉。建议改用 `pkg-config --static --libs libdpdk`（SPDK 产物本身可 `ldd -r` 验证缺符号闭环），一劳永逸 |
| 3 | SPDK_OPTIONAL_LIBS 补 `keyring keyring_file keyring_linux fuse_dispatcher` + 系统 `fuse3` | 在树 optional 清单无这四项（新 SPDK 的 NVMe-TLS keyring 与 fuse_dispatcher 是新组件）；EXISTS 守卫方式合理 | 正确。把这四项加进在树 foreach 即可，注释写明"26.x fork 新增组件" |
| 4 | `find_library` PATH_SUFFIXES 补 `lib` | 在树 `URMA_LIBRARY` 已含 `lib64 lib build/lib`；`URING_LIB` 只给了 PATH 没给 suffix | 大概率正确，但请提交时注明具体是哪个 `find_library`（我在镜像里只能对上一半），避免后人误删 |

**P0 行动项：把这四个修复整理成 patch 提交回 `nof-urma-v2-bench-merge`。** 现在的形态是
"修复只在 `/home/yin/nof/mooncake` 工作区"，风险：重 clone/重置即失败；两台机器/后来者
不可复现；review 缺位。请把 `git diff` 发我（§8 P1），我复核后可代拟 commit message。

### 2.2 patchelf/RPATH：能用，但应换成 CMake 固化

post-build `patchelf --set-rpath` 的问题：不在构建系统内 → 重编即回退；且本次实测它没有
解决问题（ADR 3.2），说明它连"诊断价值"都有限。正确的固化方式（任选其一）：

```bash
# 方案 A（推荐）：configure 时直接写死运行期检索路径，产物自带 RUNPATH
cmake -B build -S . -DUSE_NOF=ON ... \
  -DCMAKE_BUILD_RPATH="/home/tong/umdk_gpu_isolated/lib:/home/tong/umdk_gpu_isolated/lib/urma:/usr/local/cuda/lib64" \
  -DCMAKE_INSTALL_RPATH="/home/tong/umdk_gpu_isolated/lib:/home/tong/umdk_gpu_isolated/lib/urma:/usr/local/cuda/lib64"
# 现代 linker 下 CMake 生成 RUNPATH（弱于 DT_RPATH），LD_LIBRARY_PATH 仍可覆盖，行为可控
```

顺带说明：原二进制的 DT_RPATH 指向编译期 `find_library` 命中的 `$UMDK_ROOT/lib`，
优先级高于 LD_LIBRARY_PATH——这就是当初"隔离库不生效"的原因。patchelf 的观察是对的，
只是落点错了：真正要做的要么是方案 A，要么干脆**只用一棵树**（见 §3.1）。

### 2.3 "隔离库"决策的前提需要一次全量验证（P0）

ADR 3.3 的 md5 比对只覆盖 `liburma-udma.so` 一个文件，且结论是"与编译库完全一致"。
这引出两个问题：

1. `urma_user_ctl` / `udma_u_delete_jetty` 的符号在哪个 `.so` 里？若在 `liburma.so`
   而非 `liburma-udma.so`，那么"运行时库=编译库"的结论从未被验证过。
2. 若两树所有 `.so` 都一致，"隔离"还有什么意义？若答不出来，建议**收敛为一棵树**：
   编译、运行都用 `UMDK_tool_netlab-sp4_umdk`（分支手册 §3 的原始推荐就是
   `LD_LIBRARY_PATH=$UMDK工具树/lib`），patchelf、双目录、双路径全部消失，排查变量少一半。
   `/home/tong/umdk_gpu_isolated` 是用户指定的运行期目录——请向用户确认它的**预期差异**
   是什么（是不同构建？不同 vendor 补丁？），否则它只是同库的第三份拷贝，徒增排查噪音。

### 2.4 与分支自带手册（mooncake_deployment_gdr.md）的偏差清单

| 偏差 | 手册预期 | 实际执行 | 影响 |
|---|---|---|---|
| UMDK cmake 树 | `UMDK_ROOT` 指向天然含 `include/ub/umdk/urma/urma_api.h` 的树（手册示例 `/home/yin/gdr/UMDK_netlab`） | 用了 cmake 布局的 `UMDK_tool_netlab-sp4_umdk`，靠 `ln -sfn` 手工补 include 软链 | 可用但脆弱：软链指向共享源码树内部，别人动树即断；软链也不在任何文档/脚本里固化。建议要么照手册换树，要么把补链写成 setup 脚本 |
| 运行期库 | 手册 §5.1：`LD_LIBRARY_PATH=$UMDK工具树/lib`（与 cmake 同树） | 用户指定 `/home/tong/umdk_gpu_isolated/lib`（第三棵树） | 触发了 RPATH/patchelf 全套折腾，且"隔离"前提未验证（§3.3） |
| 内核模块检查 | 手册阶段 0（修订）：`lsmod` 确认 udma/ummu/ubcore/uburma + 桥模块、设备节点 | **无执行记录** | 这正是本次段错误的关键盲区——`urma_user_ctl` 是 ioctl，内核模块版本必须进证据链（§1.4 步骤 2） |
| yalantinglibs ghost-pin | 手册 §3 引用阶段 9：需落在 e46cbf08 | 本地镜像显示 submodule 处于 modified 态；node4 实况未知 | 请在 node4 跑 `git -C extern/yalantinglibs rev-parse HEAD` 确认 |

### 2.5 Phase 0 `make install` 的现役影响（已发生，需确认而非回滚）

real_experiment.md §11 把"149 重编 SPDK 破坏现役"的缓解措施写成"仅在 /home/yin/nof/spdk
内重编"——但 A.1 实际执行了 `make install`，**/usr/local 已被 urma_enable_v2 产物覆盖**。
缓解与执行不符。需要确认：

1. w00921547 现役部署是否依赖 **149** 的 `/usr/local` SPDK（现役 target 若也在 149 跑
   nvmf_tgt，或 151 的组件静态链接着旧产物备份，风险面不同）；
2. 正在运行的旧 nvmf_tgt 进程不受影响（代码已加载进内存），但**任何重启都会用新版**；
3. 若需回退能力：旧 SPDK 产物是否有备份？没有的话，从旧分支重编一份放备用前缀是低成本保险。

不要求动作，但这一条应补进 ADR/实验记录，避免下一个人以为 /usr/local 还是旧版。

---

## 3. merge 代码本身的缺陷（顺手发现，建议报给分支维护者）

按影响排序，均为本地镜像 @ 7ebd69a0 核实：

1. **bonding-mode 失败路径泄漏**（urma_endpoint.cpp:532-536 与 553-557）：`urma_user_ctl`
   返回非 SUCCESS 时直接 `return ERR_CONTEXT`，既不 `urma_delete_context(context)` 也不
   `urma_free_device_list(devices)`。对比同函数 564-571 的 query_device 失败路径（两个都
   清理）——不一致。进程生命周期内无害（启动期失败即退出），但这是ub_transport_test
   反复构建 context 的场景里会累积的泄漏。
2. **`eid_cnt == 0` 时越界**（urma_endpoint.cpp:508-511）：`eid_index` 有 `if (eid_cnt > 0)`
   守卫，但下一行 `eid_ = eid_list[0].eid;` 无条件解引用。空 EID 列表的设备会在此 UB。
   建议：`eid_cnt == 0` 时打日志并 `return ERR_CONTEXT`。
3. **mock fallback 在真机上是死路**（ub_transport.cpp:1001-1005）：`getHcaList()` 为空时
   fallback 到 `mock_urma_device`，而 `openDevice` 里 `urma_get_device_list` 返回真实设备、
   永远匹配不到 mock → 必然 `No matched device found`。这就是你第一次用
   `--device_names=bonding_dev_0` 时报错的机制。建议：hca_list 为空时**直接报错并提示
   检查 device_names/拓扑发现**，或选第一个真实设备，不要走一个注定失败的 fallback。

另有一处与 §1.5 呼应的结构性建议：bonding-mode 设置目前无任何降级/探测机制，是本次
故障的放大器（一个非关键的控制面调用失败 = 客户完全起不来）。

---

## 4. real_experiment.md 文档层面的小问题

1. §8 的 master 启动命令（`mooncake_master --master_server 0.0.0.0:50061`）与 A.4 实际
   执行（`--rpc_port=50061`）不一致——A.4 是对ctest过 flag 名的那个，建议把 §8 修成与
   A.4 一致，避免下个人照 §8 起不来。
2. 验证标准（§10）缺两条：
   - [ ] 客户启动前内核模块清单已记录（`lsmod | grep -E 'udma|ummu|ubcore|uburma'`）；
   - [ ] `md5sum` 全量比对结论已记录（哪棵树是"运行时真相"）。
3. Phase 4 预告一个 bench 层已知坑（手册 §3.5 第 5 条）：gdr-peermem 会清零
   `global_segment_size`，`--nof_replica_num>0` 且无远端内存段时可能报
   "no memory segments found"——届时显式传 `--segments` 规避，先写进方案免得现场猜。

---

## 5. 需要你提供的文件/信息（按优先级）

| 优先级 | 内容 | 用途 | 采集命令（均在 node4/151，除注明） |
|---|---|---|---|
| **P0** | gdb bt 全文 + `info sharedlibrary urma` | 确认崩溃帧责任 .so 与空指针形态；一切结论的前提 | §1.4 步骤 1 |
| **P0** | 内核模块清单 + 各模块 modinfo | 判定 userland/kernel ABI 匹配；ADR 的盲区 | §1.4 步骤 2 |
| **P0** | 两 UMDK 树 `liburma*`/`libub*` 全量 md5 + 目录清单 | 验证"隔离库"前提；确认 `urma_user_ctl` 实现库是否被比对过 | §1.4 步骤 3 |
| P1 | node4 上 `/home/yin/nof/mooncake` 的 `git diff`（四个修复） | 复核修复正确性；整理成可提交 patch | `git diff > /tmp/nof-fixes.diff` |
| P1 | 崩溃后 30 秒内 `dmesg \| tail -50` | 内核侧证据（UBI/ummu/udma 报错、taint） | — |
| P1 | strace ioctl 尾段 | 看 SET_BONDING_MODE ioctl 的返回码 | §1.4 步骤 4 |
| P2 | UMDK perftest 在 udmac0d1e2 上的结果 | 与 mooncake 无关的运行栈独立验证 | §1.4 步骤 5 |
| P2 | 现役部署基线（commit + 是否含 urma_user_ctl 调用） | 闭合"新调用假设"的对照证据 | §1.4 步骤 7 |
| P2 | `urma_admin show --all` 完整输出 + 两树的版本标识文件 | 确认 udmac0d1e2 是否 bonding 管理设备；版本三角对齐 | — |

以上发来后，我可以直接：复核四处修复的 diff → 代拟提交 patch；根据 bt 把 ADR-001 的
假设清单收敛成单一根因结论并改写 ADR。

---

## 6. 建议行动顺序

1. **先取证**（半天内可完成）：§1.4 步骤 1-3（bt / 内核模块 / 全量 md5）——三者齐了根因
   基本可以定案，再决定是"换运行栈"还是"打守卫补丁"还是"报 UMDK bug"。
2. **判定性 bisect**：若想立刻解锁 Phase 3，直接做步骤 6（注释 541-562）——这是恢复
   d8d9076e 之前行为的最小改动，能起客户即可继续 Phase 4，bonding 语义并行排查。
   ⚠️ 但要先想清楚：这个调用是 d8d9076e 为 NUMA 亲和/multipath 加的，跳过它意味着
   本次实验只验证 STANDALONE 通路——与你"单副本打流吞吐"的实验目标不冲突。
3. **固化修复**：四个编译期 patch 提交回分支；RPATH 用 CMake 变量固化（§3.2）；
   UMDK 树收敛为一棵（§3.3，待与用户确认隔离库意图后）。
4. **补记录**：ADR-001 追加本次分析（新调用考古 + 内核盲区）；实验记录补 Phase 0 的
   /usr/local 覆盖事实（§3.5）。

---

# 第二轮审阅（2026-10-12 晚：ADR-001 解决后，adr.md / details.md / diagnosis.md 复核）

> 输入：三份新文档（adr.md＝ADR-001 终稿、details.md＝问题总表、diagnosis.md＝gdb 取证）。
> 本轮结论均已对照本地镜像 7ebd69a0 代码复核（`mooncake-wheel/mooncake/mooncake_ssd_register.py`、
> `mooncake-store/include/ssd_register_client.h`、`types.h:315` 错误码、`store_py.cpp:2013` 绑定）。
> 第一轮 §5 所列 P0 三项证据（bt / 内核模块 / 全量 md5）均已回填，段错误根因定性闭环（§7.6）。

## 7.0 结论速览

| # | 级别 | 发现 |
|---|------|------|
| 1 | **P0** | 问题 #7 成为唯一卡点：注册 `size=0`（**`base=0` 无辜**）→ master 零容量 → `insufficient space (-200)`。解锁命令见 §7.5；**必须先注销坏 segment，否则注册脚本会"已注册→跳过"静默无效** |
| 2 | P1 | ADR-001 修复用了硬注释形态——提交前必须改成 env 守卫（默认关），否则 multipath 功能被物理删除且无人记得恢复 |
| 3 | P1 | adr.md §4.4 一条推断过强："三种运行库配置均崩溃→根因不在运行库"。按 diagnosis 自身记录，`liburma.so.0` 被 DT_RPATH 钉死，三组实验对唯一有 md5 差异的文件**没有形成变量**。结论仍成立，依据需改写（§7.2.2） |
| 4 | P2 | adr.md §4.2.4 留下"现役悖论"未解释，应记为待确认（§7.2.3） |
| 5 | P2 | diagnosis 取证藏了 UMDK 报 bug 的关键线索：strace 无 BONDP ioctl + dmesg 干净 → 崩溃大概率在**用户态预检**，未进内核 |

## 7.1 git 状态（"拉取最新代码"结论）

- `git fetch --all` 已执行：`fork/nof-urma-v2-bench-merge` == 本地 == **7ebd69a0**，远端无新提交；
  origin（LinQuickDev）不存在此分支。
- 含义：**四个编译修复 + bonding 跳过补丁至今只存在于 node4 工作区**，git 拉不到。收口见 §7.5 P1。

## 7.2 对 adr.md 的审阅意见

1. **修复方向正确，形态不对（P1）**。注释 521-562 = 判定性 bisect（第一轮 §1.4 步骤 6）命中，根因坐实。
   但硬注释把 d8d9076e 的 multipath/NUMA 亲和整段物理删除。提交版应为：

   ```cpp
   static bool bondingModeSetEnabled() {   // 默认关 == 已验证行为
       const char* env = std::getenv("MC_URMA_SET_BONDING_MODE");
       return env && (std::string(env) == "1" || std::string(env) == "true");
   }
   ...
   if (bondingModeSetEnabled()) { /* 原 if-else 原样保留 */ }
   else LOG(WARNING) << "Skipping urma_user_ctl SET_BONDING_MODE on " << device_name
                     << " (MC_URMA_SET_BONDING_MODE not set)";
   ```

2. **§4.4 推断依据改写**。"三种配置均崩溃→运行库无关"不成立为证据：diagnosis §1 记录 gdb 那次
   `liburma.so.0` 加载自 UMDK_tool（"DT_RPATH 未完全覆盖"）——若 RPATH 在三组配置里始终把
   **唯一 md5 有差异的文件**（liburma.so，36b0ab10 vs 87d4fb60）钉在同一棵树，三组实验等于没换变量。
   结论本身仍成立，硬依据是：① 崩溃点 `liburma-udma.so` 两树 md5 相同；② dmesg 干净（内核无责）。
   建议改写，防止日后被当作"运行库无关"的定论引用。
3. **§4.2.4 现役悖论补"待确认"**。现役源码含同款 `urma_user_ctl` 调用，且 /usr/lib64 老库
   （264KB，Jul 27）在新 client 上同样崩——现役却不崩。最可能解释：现役二进制早于其源码树
   （stale build），或现役实际不走 `--protocol=ub`。补一行待确认项即可，不影响本次结论，
   但不写清楚这份 ADR 未来会被错误引用。

## 7.3 对 details.md 的审阅意见

1. **#7 根因表述错一半**："`base=0, size=0`"——`base=0` 不是问题，官方注册脚本本来就写死
   `base=0`（`mooncake_ssd_register.py:229`）。真正的坑只有 `size=0`。不改的话，下次有人会去追 base。
2. **§2.3 推荐路线缺关键前置，直接跑会静默失败**：脚本对 `SEGMENT_ALREADY_EXISTS` 的处理是
   "已注册，跳过"（`mooncake_ssd_register.py:286-289`）——而零容量的坏 segment **已经注册在
   master 上**。不先注销，脚本"成功"跑完，master 上仍是零容量。先
   `set_unregister_by_endpoint`（同一五元组 nqn/nsid/traddr/trsvcid/trtype=URMA，
   `store_py.cpp` 有绑定），或确认 master 元数据是否随重启清空后重启 master。
3. "HTTP admin 列不出 RPC 注册的 NoF segment"：**非阻塞观察项**。权威发现路径是 master gRPC
   （bench `--scenario=list_segments`，details §2.1 已证实能发现该 segment），admin 视图缺口
   记为低优先级，不值得现在修。

## 7.4 对 diagnosis.md 的审阅意见

取证规范，留档价值高。两点补充：

1. **混载事实要写进 UMDK bug 报告**：bt 显示同进程内 `liburma.so.0`（UMDK_tool 树）与
   `liburma-udma.so`（tong 树）来自两棵树——报告里主动声明，并说明"三配置均崩、混载非必要条件"，
   免得 UMDK 侧把它当根因驳回。
2. **strace 无 BONDP ioctl + dmesg 干净 = 库内用户态预检失败/崩溃**（未进内核）。这条线索决定
   UMDK 排查方向（不是内核 ABI），报 bug 时放显眼位置。后续如再取证，`strace -ttt -k`
   （若版本支持栈解码）或 `ltrace -e 'urma_*'` 比 ioctl 过滤更有效。

## 7.5 下一步行动（第二轮）

**P0 — 解锁 #7（唯一卡点），严格按序：**

```bash
# ① 前置检查（新部署缺 wheel/paramiko 会在此暴露）
python3 -c "import mooncake.store"        # 失败 → cd mooncake-wheel && pip install -e .（或配 PYTHONPATH）
python3 -c "import paramiko"              # 失败 → pip3 install paramiko

# ② 先注销零容量坏 segment（同一五元组；跳过此步则 ③ 被"已注册→跳过"吞掉）
#    NoFRegisterClient::set_unregister_by_endpoint(nqn, nsid, traddr, 4420, "URMA", "141.61.84.151:50061")

# ③ 注册真实 size（脚本经 SPDK RPC 取 5×7T raid0 ≈ 35TB）
python3 -m mooncake.mooncake_ssd_register \
  --master_server_address 141.61.84.151:50061 \
  --spdk_target_info "ip:141.61.84.149 path:/home/yin/nof/spdk" \
  --transport-type URMA --username root --key-file ~/.ssh/id_rsa

# ④ 验收走权威路径（master gRPC），不用 HTTP admin
./stress_cluster_bench --protocol=ub --scenario=list_segments ...

# ⑤ 重打流；-200 应消失
./stress_cluster_bench --protocol=ub --scenario=segment_write --nof_replica_num=1 ...
```

⑤ 若出现新错误（如连 149 URMA listener 失败），是下一层问题，回 ADR 追加即可。
Phase 4 后续记得 gdr-peermem 清零 `global_segment_size` 的已知坑（必要时显式 `--segments`，
见第一轮 §4.3 / 分支手册 §3.5）。

**P1 — git 收口**（三个 commit 提回 `nof-urma-v2-bench-merge`）：
1. 四个编译修复（`UbGpuMode` 注明"HEAD 不可编译"）；
2. bonding skip 改 env 守卫版（§7.2.1）后提交，默认关 = 已验证行为；
3. RPATH 固化进部署脚本（`-DCMAKE_BUILD_RPATH/-DCMAKE_INSTALL_RPATH` 替代 patchelf）。
   并按 details.md §4.3 收敛三棵 UMDK 库树为一棵（建议编译树），消除混载。

**P2 — UMDK bug 报告**：diagnosis.md 材料已齐（bt、opcode 7、STANDALONE/PORT、
kernel `6.6.0-gdr_w00921547+`、四模块 srcversion、md5 表、strace 无 ioctl、dmesg 干净、
混载声明），直接打包。报告主线：**liburma-udma.so 错误清理路径空指针，纯用户态，
由 SET_BONDING_MODE 失败路径触发**。

**文档小修**：details.md #7 的 base=0 表述；adr.md §4.4 依据改写 + §4.2.4 补待确认 +
修复方案一节补"提交前改 env 守卫"；diagnosis.md 顶部关联文档路径仍指向旧 `adr/` 目录（文件已平铺）。

## 7.6 第一轮假设回填（闭环记录）

| 第一轮 P0 项 | 结果 |
|---|---|
| gdb bt | ✅ diagnosis §1：崩溃帧 `udma_u_delete_jetty`（liburma-udma.so 清理路径），调用方 `urma_user_ctl`（urma_cp_api.c:2950），入参 opcode=7 / len=8 合法 |
| 内核模块 | ✅ diagnosis §1.6：四模块版本已记录，dmesg 干净 → 内核无责 |
| 全量 md5 | ✅ diagnosis §1.5：`liburma.so` 两树不同（36b0ab10 vs 87d4fb60），但被 DT_RPATH 钉死、不影响结论；`liburma-udma.so`、`liburma_common.so` 一致 |

根因最终定性：**d8d9076e 新增的 `urma_user_ctl(SET_BONDING_MODE)` 触发 `liburma-udma.so`
错误清理路径空指针（纯用户态，与运行树版本无关）**。规避 = 跳过该调用（已验证）；
根治 = UMDK 修复清理路径（P2 报告）；复活条件 = UMDK 修复后开
`MC_URMA_SET_BONDING_MODE=1` 验证 multipath。

---

## 8. 第三轮审阅（git patch 提交复核：573bcf95 → 00b31e37）

### 8.1 第一版 patch（573bcf95，已 force-push 废弃）的三个问题

1. 🔴 **守卫结构错误**：`bondingModeSetEnabled()` **替换**了 `if (multipath())` 而非包住它，
   STANDALONE 分支被删。后果：UMDK 修复后只设 `MC_URMA_SET_BONDING_MODE=1`（不开 MULTIPATH）
   的部署会被静默设成 BALANCE/IODIE（错模式）；开 multipath 但没开新 env 的部署会在 mode
   未设时带着 `jfs multi_path=1`（urma_endpoint.cpp:829）提交传输。
2. ⚠️ no-op：`PATH_SUFFIXES lib64 lib build/lib lib`——原列表已有 `lib`，重复项。
3. 提交信息虚报 "four compile fixes"。

### 8.2 修正版（00b31e37）复核：**通过**

- ✅ 三分支结构：未设 env → skip（multipath 开着时补一条提示）；env+multipath → BALANCE/IODIE；
  env+非 multipath → STANDALONE/PORT 已恢复（对 base 无删除 hunk 可证）。
- ✅ urma_endpoint.cpp:1203 注释更新为守卫语义；提交信息修正。
- ⚠️ 残留：no-op PATH_SUFFIXES hunk 仍在。真正第 4 处修复是 **URING_LIB 的 PATH_SUFFIXES**
  （details.md 问题表 #4 已确认），follow-up commit 补上时一并清掉此 hunk。
- 操作提醒：force-push 重写历史（573bcf95 作废），所有旧 clone 需 `reset --hard` 同步到
  00b31e37（含本机镜像）。

---

## 9. 第四轮审阅（Phase 4：NoF 注册成功但 bench 发现不了 —— 代码级定位）

> 现象（real_experiment v4 / diagnosis 19:24 版）：`/tmp/nof_register` 以 size=35TB 经
> `MountNoFSegment` 注册成功（19:19:08），bench `--nof_replica_num=1` 于 19:19:20 报
> "NoF replicas requested but no NoF segments were found"（GetAllNoFSegments 空）。
> 以下结论以本地镜像 00b31e3 代码为准。

### 9.1 总答案：两个独立问题叠加；"注册/发现路径不一致"假设不成立

注册与发现读写**同一份** master 状态：`MountNoFSegment` 写
`nof_segment_manager_.mounted_segments_`（segment.cpp:1383），`GetAllNoFSegments`
对同一 map 全量快照、无任何过滤（master_service.cpp:2549）。

### 9.2 问题 A（解释 19:19:20 的空查询）：bench 默认连的是现役 master

`stress_cluster_bench.cpp:228`：

```cpp
DEFINE_string(master_server, "127.0.0.1:50051", "Master server address");
```

默认端口 **50051 = 现役 master**；本部署为 50061。漏传 flag 时 discovery 与 bench 自身
client（:607）全部打到现役——隔离承诺被击穿。时间线佐证：注册 19:19:08 → bench 19:19:20
间隔 12s，仍在 30s 免检期内（见 9.3），自家 master 当时本应查得到 → 空查询高置信是查错 master。

验证：注册后 30s 内 `curl 127.0.0.1:9004/metrics | grep -i nof`（capacity 应有 35TB）；
bench 显式 `--master_server=127.0.0.1:50061`。

### 9.3 问题 B（修好 A 后必撞）：NoF segment 默认 ~30 秒寿命（心跳探测机制）

- master 内置 `nof_heartbeat_thread_`（master_service.cpp:463）：每
  `nof_heartbeat_interval_sec`（默认 **10s**，types.h:98）经进程内
  `SpdkWrapper::ProbeNofSegment` **真实连接** te_endpoint（SPDK env init → NVMe-oF over
  URMA 连 149:4420 → 读块大小 → probe IO）。
- 连续失败 ≥ `interval × threshold`（10s × 3 = **30s**，types.h:104-105）→
  `unmount_nof_segment_by_heartbeat` 摘除。即：master 自身 SPDK/URMA 探测环境不工作，
  注册成功的 segment 30 秒后必消失。
- 排查证据：master 日志
  `grep -E "nof_heartbeat_failure|unmount_nof_segment_by_heartbeat"`，
  reason ∈ {spdk_env_init_fail, open_fail, probe_not_configured, invalid_block_size}。
- 最可能失败点：① master 二进制 liburma 解析——patchelf 只做过 client
  （`ldd mooncake_master | grep urma`）；② SPDK env（hugepages）与现役 master (50051)
  同机共存冲突；③ 短期缓解：拉大 `--nof_heartbeat_interval_sec`（TTL = interval ×
  threshold），并把"注册 → bench"串成一个脚本消除时间差。

### 9.4 对 real_experiment §5.2 三个怀疑的逐一代码裁决

| 怀疑 | 裁决 |
|---|---|
| 注册与发现走不同数据结构 | ❌ 同一 `mounted_segments_`，无过滤 |
| 注册未持久化 | ❌ 与 12s 内可见性无关；`inc_total_nof_capacity` 即时反映到 metrics，curl 即验 |
| 缺 mooncake_client 常驻进程 | ❌ 机制理解偏差：注册本就是独立 RPC；常驻 client 的真正意义是"注册→打流"连续进行不触发 TTL，外加其 SPDK 环境健康。缺的是"探测成功 + 时间窗口"，不是那个进程 |

### 9.5 行动清单

- **P0**：① 此后所有 bench 命令显式 `--master_server=127.0.0.1:50061`；② 注册后 30s 内
  curl metrics 验证 nof capacity；③ master 日志取 probe 失败 reason。
- **P1**：按 reason 修 master 探测（liburma / hugepages / SPDK env 冲突）；短期先拉大
  interval + 脚本化"注册→打流"。
- **P2**：ADR"现役悖论"可闭合——问题 #9 已证实现役 bench 同样崩在 `urma_user_ctl`，
  即现役从未在该路径跑通，不是"现役栈天然兼容"；ADR 4.2.4 的"待确认"可直接改写为此结论。
- **Git follow-up**：URING_LIB PATH_SUFFIXES 真修复 + 清掉 no-op hunk（details.md #4 已确认）。

---

## 10. 第五轮审阅（2026-10-13：real_experiment v5 + adr.md 复核 —— ADR-005 v1 根因推翻）

> 输入：real_experiment.md v5（Phase 4 打流跟进）+ adr.md（ADR-001~006）审阅请求。
> 本轮对 segment_read 失败做全链路代码级复核（batch 与单 key 两条路径逐层对照），
> **推翻 ADR-005 v1 的根因表述**；adr.md / real_experiment.md 已按 v2 结论修订（§10.6）。

### 10.0 结论速览

| # | 级别 | 发现 |
|---|------|------|
| 1 | **P0** | **ADR-005 v1 根因推翻**：batch 读 NoF 链路端到端是通的。"分类层缺 `is_nof_replica()` 分支"只对一半——NoF 副本确实落 `else` 桶，但下游每层都有 NoF 处理（§10.2）；"落入 MEMORY 路径""BatchGet 卡死"均不成立 |
| 2 | **P0** | **LEASE_EXPIRED 是"成功传输的事后覆写"**（`client_service.cpp:1636-1646`）：32 个 NoF 读全部传输成功、数据已入 my_buf，仅因 batch 总耗时 35.65s > 10s TTL 被 BatchGet 结尾统一复查覆写成 LEASE_EXPIRED。同时解开"writer 持活（ADR-004 规避）为何仍过期"——reader 侧 deadline 与 writer 存活无关（§10.3） |
| 3 | **P0** | **真正待定位问题**：并行 NoF 读聚合 ~3.7 MB/s（32×4MB / 35.65s），vs 单 key ~1 GB/s（3~5 ms/4MB）、同 worker 池写 ~2 GB/s。静态审查池机制完好 → 运行时异常，需实测定位（§10.4） |
| 4 | P1 | 日志标签误导是此前排障被带偏的直接原因：breakdown 把 NoF 标成 `disk`（`real_client.cpp:5675-5677` else 兜底）、NoF 计入 `mem_ops`（`real_client.cpp:5966`，= `valid_operations.size()`） |
| 5 | P1 | ADR-005 v1 方案 A/B 均错向：方案 A（逐 key 走 get_into）能"过"只是因为 32×~4ms ≈ 150ms < 10s TTL 绕开了覆写检查，且掩盖问题 2；方案 B 的"卡 35s"前提不成立（是慢完成，非卡死） |
| 6 | P2 | 哈希澄清：`e4bfe3d` 不在本地镜像与 fork 服务器上（`cat-file` fatal / `git fetch fork e4bfe3d` 失败），但**据用户确认存在于 node4（HEAD）**——即同一修复在 node4 侧的独立提交（adr.md 记录 3 files +26/-5），非记录错误；node4/fork canonical = `00b31e3`；本地镜像 HEAD = `573bcf95`，ahead 1 / behind 1（§10.7） |

### 10.1 复核方法与基线

- 路径覆盖：`batch_get_into_internal` 分类与计数 → `Client::BatchGet` → `TransferSubmitter::submit`
  → `submitSpdkNofOperation` → `SpdkNofWorkerPool` worker 循环 / QoS / 完成回调 → `OpenNofSegment`
  连接缓存；单 key 侧 `get_into` → `Client::Get` → `TransferRead` → `TransferData` 对照。
- 行号基线：00b31e3。本地镜像分支 HEAD 为 573bcf95，但 `git diff 00b31e3 573bcf95 --stat` 仅
  `urma_endpoint.cpp` 一个文件（4+/29-，即 ADR-001 守卫结构差异），本节所引文件两 commit 完全一致。

### 10.2 batch 读 NoF 链路逐层复核（推翻"落入 MEMORY 路径"）

| 层 | NoF 处理 | 位置 |
|----|----------|------|
| 分类 | `else` 桶 = `valid_operations`（交 BatchGet 走 transfer 路径，非 MEMORY-only） | `real_client.cpp:5718-5726` |
| allocateSlices | `is_nof_replica()` → 单连续 slice | `client_buffer.cpp:175/198` |
| FilterQueryResult | 只保留选中的 NoF 副本，防 BatchGet 另选 | `real_client.cpp:5724` |
| Client::BatchGet | `is_nof_replica()` 分支：连续性检查 → `submit(READ, ptr, size)` | `client_service.cpp:1562-1571` |
| TransferSubmitter | `is_nof_replica()` → `submitSpdkNofOperation` → `SpdkNofWorkerPool` | `transfer_task.cpp:1084-1093 / 1405` |

单 key warmup 走 `client_->Get`（`real_client.cpp:4173`）→ `Client::Get` → `TransferRead` →
`TransferData`（`client_service.cpp:3894-3911` NoF 分支）→ **同一个 submit → 同一个 worker 池**，
与 batch 路径同源——warmup 3~5 ms/key 证明池子单任务性能正常。

两点 v1 澄清：

1. `real_client.cpp:4087` 是 NoF **GPU Direct** 分支，仅 dst 为 CUDA 内存时进入（`real_client.cpp:4082`
   先做设备内存判定）；host buffer 的单 key 读不经它——v1 涉及文件表"复用 4087"不准确。
2. breakdown 的 `replicas[...=disk]` 与 `mem_ops[32]` 是标签/计数假象（§10.0 #4），不代表实际路径。

### 10.3 问题 1：事后 lease 覆写的机制与推理闭环

`Client::BatchGet`（`client_service.cpp:1485`）流程：提交全部传输（1529-1592）→ 逐个
`future.get()`（1595-1597）→ **结尾统一复查**：`now >= lease_timeout` 就把（已成功的）结果
覆写成 LEASE_EXPIRED（1636-1646）。deadline 来自 BatchQuery 时刻 master 随查询授予的
`default_kv_lease_ttl`（10s，`master_service.cpp:3199`）。

推理闭环（排除"传输失败"解释）：日志 32 条均为 LEASE_EXPIRED 而非 TRANSFER_FAIL；
覆写分支要求 `results[i].has_value()`，而 has_value 只在传输成功且 checksum 通过后设置
（`client_service.cpp:1622`）→ **32 个传输 + checksum 全部成功**，仅超时被覆写。

与 ADR-004 的关系：writer 持活保的是 master 侧对象租约；本检查用的是 reader 自己
query 时刻的 deadline，writer 无法延长——ADR-004 的规避对 ADR-005 场景天然无效，
两 ADR 并无矛盾。同一检查单 key `Client::Get` 也有（`client_service.cpp:1297-1301`），
warmup 快（3~5 ms）所以从未触发。

### 10.4 问题 2：并行 NoF 读 3.7 MB/s —— 静态已排除项与待测假设

数字三角：单 key 顺序读 ~1 GB/s；同池子写（segment_write）2.0~2.3 GB/s；batch 32 并行读
~3.7 MB/s。**并行反而比串行慢两个数量级**。

静态审查未发现机制缺陷（已排除）：

| 项 | 结论 | 位置 |
|----|------|------|
| QoS 限速 | inflight 窗口 32MiB（8192×4KB），远大于数据量；chunk 128KiB | `transfer_task.h:422-423` |
| 连接建立 | controller/qpair 有缓存，warmup 已建链 | `spdk_wrapper.cpp:321-380` |
| worker 绑定 | 每 segment 绑一个 worker（串行但非瓶颈源） | `transfer_task.cpp:353-364` |
| 完成回调 | 计数递减、`outstanding_sub_io==0` 判完成，逻辑正常 | `transfer_task.cpp:107-155` |
| poll | `process_completions(qpair, 0)` 全量处理，outstanding>0 时不空转 | `transfer_task.cpp:599-608` |

待测假设（per-task 固定成本 35.65/32≈1.11s？chunk 级 34.8ms/128KiB？target 侧慢？）与定位路径：
`MC_NOF_DEBUG=1`（worker 绑定 / QoS 日志）→ 35s 窗口 `gdb -p` 抓栈（主线程停在 `future.get()`
1597？worker 在 poll 602？→ 区分"target 慢"vs"池子没提交"）→ node3 `nvmf_tgt` 侧同步观察 →
`num_keys=1/2/4/8/16/32` 阶梯实验区分固定成本 vs 聚合效应。

### 10.5 行动清单（已并入 ADR-005 v2 与 real_experiment §9）

| 优先级 | 动作 |
|--------|------|
| P0 | master `--default_kv_lease_ttl=600000` 重启重跑 segment_read：预期 `success[32]`，拿到纯吞吐数（解耦两问题） |
| P0 | 按 §10.4 定位并行读慢（DEBUG 日志 → 抓栈 → 阶梯实验 → target 侧对照） |
| P1 | 修 breakdown 标签：`is_nof_replica() → "nof"` + `nof_ops` 计数（防再次误判） |
| P1 | 补基线：raid0 裸盘带宽（spdk_perf/fio）+ URMA 线速，给 2 GB/s / 3.7 MB/s 定位参照系 |
| P2 | 设计备注：事后 lease 覆写对 >TTL 慢 batch 是结构性脆弱点（问题 2 修复后仍在），评估对 NoF/disk 副本放宽或检查前刷新元数据 |
| P2 | 后续扩展：GDR（V100 在位未用）、多客户端并发、读写混合 |

### 10.6 本轮已执行的文档修订

- **adr.md**：ADR-005 整节重写为 v2（症状保留，根因 / 涉及文件 / 行动全部替换）；汇总表 005 行；
  ADR-004 补"writer 持活救不了 reader 侧复查"说明；头部哈希 `e4bfe3d`→`00b31e3` + 总状态更新；
  ADR-001 Git 行哈希勘误。
- **real_experiment.md**：头部状态、§5 Phase 4 行、§5.2 #5、§8.6 注释按 v2 结论同步；
  新增 §9 下一步（6 步按序）+ 哈希备忘。

### 10.7 git 状态澄清（修正 §7.1 / 第三轮脚注的哈希表述）

- `e4bfe3d`：本地镜像与 fork 服务器均无此对象（`cat-file` fatal；`git fetch fork e4bfe3d`
  返回 couldn't find remote ref）；**据用户确认 node4 HEAD = e4bfe3d**——即同一修复在
  node4 侧的独立提交（adr.md 记录 3 files +26/-5），非记录错误。该数字与本地两个 commit
  （573bcf95 = +21/-25，00b31e3 = +27/-6）均对不上，e4bfe3d 是第三个内容变体，与
  00b31e3 预期仅差 ±1 行（疑似"multipath 提示行"有无），待 node4
  `git diff e4bfe3d FETCH_HEAD` 确认。
- fork（LeeJace993/Mooncake）`nof-urma-v2-bench-merge` tip = **00b31e3**（canonical）。
- 本地镜像分支 HEAD = **573bcf95**（"four compile fixes"，v1 守卫结构，§8.1 已判废弃），
  状态 ahead 1 / behind 1：ahead = 573bcf95 未推，behind = 00b31e3 未合入。**第三轮脚注
  "本机镜像已同步该 commit"与实际不符**——本日核实尚未 reset。同步操作：
  `git reset --hard fork/nof-urma-v2-bench-merge`（573bcf95 的守卫已由 00b31e3 以正确形态覆盖，
  no-op PATH_SUFFIXES hunk 两侧相同，真正第 4 处修复 URING_LIB PATH_SUFFIXES 两侧均未包含，
  reset 无实质丢失；该修复仍待 follow-up，见 §8.2 残留项）。
- 本轮全部代码复核在 573bcf95 上进行，经 diff 证明与 00b31e3 在所引文件上一致（§10.1）。

---

*审阅所用证据均在本地镜像 /home/senorita/nof/mooncake 可复核。行号基线：第一、二轮 =
7ebd69a0；第三、四、五轮 = 00b31e3（node4/fork canonical，git 状态详见 §10.7）。注意本地
镜像分支 HEAD 实为 573bcf95（v1 废弃 patch），与 00b31e3 仅 urma_endpoint.cpp 不同（4+/29-，
ADR-001 守卫结构），本记录第三、四、五轮引用的其余文件在两 commit 完全一致，行号对两者均
有效；同步时按 §10.7 reset 即可。*



## adr7 Review
一、新证据确立了什么（我同意的部分）

爆炸半径超出 bench，这是实锤：bench 首错 10:43:24 → 25s 后内核 sentry 也在 poll 到指向 node3 EID 的 cr.status=4（10:43:49）→ tjetty send_cnt=4, remote_recv_cnt=0 收不到 → 10:44 链路断 → node3 10:50 重启（pcie -110）→ 事后设备栈一片废墟（register_seg failed / invalid PFN / IOMMU -22）。fabric/设备层真的坏了，这没问题。

二、但“定案 H1（node3 设备先坏）”还差一块证据

时间线上，内核症状全部晚于 bench 首错 25 秒。而 batch 开始前 fabric 明明是健康的：writer 10:41:32 刚以 ~2 GB/s 推完 1 GB，warmup 5 key 在 batch 前几秒还 3~5 ms/key 全通。所以“发起者”仍是开放的：要么 node3 设备在 batch 中途自发死亡（A），要么 batch 的流量模式本身触发了 fabric 级访问违规（B）——“软件违反注册契约”的签名就是硬件层 status=4，两者不矛盾。判别方法见第四节第 1 条（查 10:43:06 之前两端 dmesg 有无任何 URMA 异常）。

三、你消息里第 3 条机制断言被代码证伪（重要）

“单 key 走 4087 GPU Direct 带 memory_domain、批量走普通 cmd_read 不带”——对本实验不成立：

- real_client.cpp:4087 的进入条件是 FindDeviceForPointer(dst) 命中 CUDA（real_client.cpp:4081）。warmup 的 dst 是 thread_buffers_[t].ptr，host 内存→ GPU Direct 分支根本不进。这正是 ADR-005 v2 已勘误、我今天在 real_experiment.md 修掉的那句 v1 叙事。
- 两条路在 worker 汇合成完全相同的数据面：TransferData NoF 分支（client_service.cpp:3894）和 BatchGet NoF 分支（client_service.cpp:1562）都走 submitSpdkNofOperation → workerThread 里 ResolveBuffer（transfer_task.cpp:467，对所有 task 一视同仁）→ host buffer → io_opts=nullptr → 同一个 spdk_nvme_ns_cmd_read（spdk_wrapper.cpp:417）。
- “host buffer 未按 URMA 规则注册”也不是这个 transport 的模型：注册是 SPDK 在 submit 时按 IO 做的（nvme_urma.c:807），读/写同路，2 GB/s 的写路径就是这么跑通的。如果“普通 cmd_read + host buffer”导致 LOC_ACCESS_ERR，warmup 会以同样方式失败——它没有。

按这个断言去修（给批量读带 memory_domain）会修一个不存在的差异。

四、真正的机制链（代码逐环验证完毕，正好卡在 128 边界上）

B 的完整链条，每一环都已在本机代码里验证：

1. initiator 注册缓存 128 槽、键 (va,len)、永不淘汰（nvme_urma.c:144/322，release 只减引用不注销）；
2. uncached 路径完成即 unregister（nvme_urma.c:915-917）；
3. seg 字节确定性：token 常量 + TOKEN_NONE（nvme_urma_common.c:358-364）→ 同一 (ctx, va, len) 重复注册 = 字节相同的 seg；
4. target import 缓存按 seg 字节缓存、release 不 unimport，注释里白纸黑字写着约束：“initiator 在 transport 存活期间不得 unregister 已缓存的 seg”（nvmf/urma.c:36）——mooncake 流量恰好违反；
5. 数字严丝合缝：warmup 5 key × 32 chunk（4MB/128KiB）= 160 次注册，正好填满 128 = key 0-3，key 4 的 32 个 chunk 走 uncached → 注册后注销；duration 首个 batch 里 task 0-3 缓存命中（region 仍有效），task 4 用与 warmup key_4 相同的 VA 重新注册 → 字节相同的 seg → target import 缓存命中 stale 条目 → C2H RDMA 写打进已注销的 seg → status=4；
6. 之后 qpair 中毒 → -EIO → CQ transport error -5 → worker 只打日志不中止（transfer_task.cpp:600）→ 主线程挂在 future.get() → 90% CPU 空转。你看到的每一行日志都在这条链上。

未被 B 解释的残留：run 1（35.6s 慢成功 32/32）按此机制 task 4 也该挂，但它活了。可能消解：unregister 在 UMMU 侧是异步/惰性的（时序概率）、两次 run 之间 node3 换过 boot（10:13 reboot）状态不同。这正是需要实验裁决的点。

五、判别实验（便宜、 surgically sharp）

0. 先修 fabric 再谈复现：node3 刚重启，nvmf_tgt/subsystem/raid0/NoF 注册/writer 数据全没了（§8.2/§8.4 重做）；node4 的 master 2757398 还挂着指向已消失 target 的注册。两端先过 urma-fabric skill §6 验证序列（urma_admin show -a = 23 ACTIVE、dmesg 干净、node3 的 invalid PFN/register_seg 残留清零），否则下一次实验结果不可解释。
1. 定发起者：node4 dmesg 查 10:43:06（batch 开始）之前有无任何 urma/sentry/udmac 异常；node3 本轮 boot（10:13 起）dmesg 查 10:43 前。两边都干净 → 触发者在 batch 流量里。
2. 128 边界实验（fabric 修好后，一次 bench 跑定乾坤）：
   - --warmup_keys=3 + duration --num_keys=5：warmup 只占 96 槽，cache 还有空位 → task 4 的 VA 是全新注册（无前置注销）→ B 预测成功；
   - --warmup_keys=5（同这次）+ --num_keys=4：batch 全部缓存命中 → B 预测成功；
   - --warmup_keys=5 + --num_keys=5：task 4 踩 stale import → B 预测失败，且第一个死的就是 task 4。
     失败边界严格跟着 key 4 走 = B 定案；不跟 = B 出局，node3 设备健康升为主嫌疑。
3. 直接开关验证：target 侧加 SPDK_URMA_IMPORT_CACHE=0 重启 nvmf_tgt（文档里现成的 kill-switch）→ 失败消失 = stale import 直接实锤。
4. 全程 MC_NOF_DEBUG=1，拿 17.5s 停滞期的 nof_qos_state（inflight_read 是否在走）。

另有两个无论 A/B 都该修的代码缺陷：uncached seg 在 transport 存活期 unregister（违反 target import 缓存契约；根治方案是 bench 的 thread_buffers_ 本来就是每线程稳定大块——用 spdk_nvme_urma_register_memory_for_qpair 走整池注册，chunk 全部变 region_external，顺带消掉每 IO 注册税）；worker poll 报错不中止不上抛（挂死变成静默）。
