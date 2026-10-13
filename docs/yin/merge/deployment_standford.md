# Mooncake 编译部署讲解（深入浅出）

> 本文是 [`real_deployment.md`](./real_deployment.md) 的「理解向」配套：先用大白话建立心智模型（为什么这么做），
> 再落到命令（怎么做）。命令的完整版、端口检查、故障排查表在 `real_deployment.md`，本文帮你「先理解为什么」，
> 理解了再去看命令就顺了。
>
> 阅读顺序：本文（懂原理）→ `real_deployment.md`（照着做）→ 出问题查 `adr.md`（根因）。

---

# 一、先搞懂：Mooncake 在解决什么问题

别急着看命令。先建立一个画面：

**传统世界里，内存和硬盘是「绑在某台机器上的私有资源」。** 你机器上有 128GB 内存、2TB SSD，别人用不了。

**Mooncake 做的事是：把这些资源「池化」成集群共享资源。** 就像把「每人自己带硬盘上班」变成「机房有一个大磁盘阵列，大家共享」。

谁来当这个「大磁盘阵列」？

```
                ┌─────────────────────────────────┐
                │   谁是谁？（角色分配）            │
                ├─────────────────────────────────┤
   node3(149) ──┤  target：出盘的人（磁盘阵列柜）   │  ← 它有 5 块 NVMe
                │                                  │
   node4(151) ──┤  initiator：用盘的人（应用机）    │  ← 它跑应用、做压测
                └─────────────────────────────────┘
```

- **node3 = target**：它插着 5 块 NVMe 盘，组个 raid0（叫 `URMA_RAID0`，约 35TB），对外提供存储。它要跑一个程序叫 **`nvmf_tgt`**（SPDK 的 NVMe-oF target），专门「把本地盘通过网络协议暴露出去」。
- **node4 = initiator**：它没有那么多盘，它要「用」node3 的盘。它上面会跑 master、client、压测工具。

**为什么要两个节点分开？** 因为真实场景就是「存储和应用分离」——盘柜归盘柜，计算归计算，中间用网络（这里是 URMA，一种类似 RDMA 的高速传输）连起来。

---

# 二、那到底要编译哪些东西？

记住一句话：**谁要跑什么程序，谁就得编译对应的代码。**

## 一张总清单

```
node3 (target)   只编译 SPDK        → 产出 nvmf_tgt
node4 (initiator) 编译 SPDK + Mooncake → 产出 mooncake_master / stress_cluster_bench
```

### 为什么 node4 要编译「两个」？

这是新手最容易懵的点。讲清楚：

**Mooncake 不是凭空能跑的——它「调用」了 SPDK 的底层能力。** 就像你写了个 Python 程序 `import numpy`，你得先装好 numpy 才能跑。

Mooncake 里的 transfer engine（数据搬运引擎）**静态链接**了 SPDK 的库（`.a` 文件）。所以：

1. **node4 必须先编译 SPDK**，并 `make install` 到 `/usr/local`，让 Mooncake 在 cmake 阶段能 `find_package` 找到它、链接进去。
2. **然后再编译 Mooncake**，产物里就带着 SPDK 能力了。

**而 node3 只跑 `nvmf_tgt` 这一个 SPDK 自带程序**，不需要 Mooncake 的任何东西——所以 node3 只编 SPDK 就够了。

### 两个分支要配对（别搞错）

| 编译什么 | 在哪编 | 用哪个分支 |
|---|---|---|
| SPDK（给 target） | node3 | `urma_enable_v2` |
| SPDK（给 Mooncake 链接） | node4 | 同样 `urma_enable_v2`，装到 `/usr/local` |
| Mooncake | node4 | `nof-urma-v2-bench-merge`（commit `00b31e3`） |

> 这两个分支是「配对」的：SPDK 的 URMA transport 和 Mooncake 的 NoF 适配要版本对齐，否则会出现握手失败（后面故障排查会讲）。

---

# 三、编译命令（精简版）

**node3 / node4 都要的 SPDK**（urma_enable_v2 分支）：
```bash
cd /path/to/spdk
./configure --with-rdma --with-urma=<UMDK路径>
make -j$(nproc)
sudo make install          # 关键！不 install，Mooncake 找不到
```

**node4 的 Mooncake**（核心）：
```bash
cd /home/yin/nof/mooncake/mooncake-store
cmake --build build -j64
# 只改了 transfer-engine，重编这两个目标即可：
cmake --build build -j64 --target mooncake_master
cmake --build build -j64 --target stress_cluster_bench
```

编译完，你会得到三个关键产物：

| 产物 | 路径 | 干什么的 |
|---|---|---|
| `nvmf_tgt` | node3 `build/bin/` | target 进程（出盘） |
| `mooncake_master` | node4 `build/.../src/` | 全局调度（地址簿） |
| `stress_cluster_bench` | node4 `build/.../benchmarks/` | 压测工具（内置 client） |

---

# 四、编译完了，怎么启动？—— 核心：依赖顺序

这是最容易出错的地方。**进程之间有「谁必须先活着」的依赖关系**，顺序反了就启动失败。

## 依赖链（一定要按这个顺序）

```
① nvmf_tgt (node3)      必须先有「盘柜」
        ↓ 没有 target，master 注册个寂寞
② mooncake_master (node4)  「地址簿」要能连到 target
        ↓ master 不活着，注册没地方收
③ nof_register (node4)     一次性：把 target 告诉 master
        ↓ 没注册，bench 找不到 NoF segment
④ stress_cluster_bench (node4)  一次性：打流
```

**为什么是这个顺序？** 因为每一步都「依赖上一步的状态」：
- master 要 attach target，target 没起，attach 必失败；
- bench 要通过 master 发现 NoF segment，没注册就没有 segment；
- 这是一条「自下而上」的启动链。

## 每一步的启动命令

### ① node3 起 target（一键脚本）

```bash
# node3（root），先无 -d 跑一次看空闲盘，再现查填 5 块盘名
cd /home/yin/nof/spdk
sudo ./target_nvme_takeover.sh                 # 只分析：列系统盘/候选盘（不做变更）
sudo ./target_nvme_takeover.sh -d <5块空闲盘名,逗号分隔> -p urma -R 4096 \
    -I 8192,8192,640,4194304 -O 4194304 -C 64 -m 0x3f -s 10 \
    -N udmac0d1e2 -L /home/tong/umdk_gpu_isolated/lib -i 141.61.84.149
# 一条命令干完：vfio-pci 接管 → nvmf_tgt → iobuf 池 → raid0 → URMA transport + subsystem + ns + listener
```
验证：脚本末尾打印 `Target 就绪` + `ss -tlnp | grep 4420` 有监听。

> 盘名每次开机重排，必须现查（脚本注释原话）；5 块合 raid0（`-R`）→ 单 namespace。
> `-p urma` 让 capsule 走 urma，和 initiator 那边的 `SPDK_URMA_CAPSULE_TRANSPORT=urma` 对上（ADR-002）。
> `-O 4194304` 走大 I/O 路径，initiator 也要 `SPDK_URMA_MAX_IO_SIZE=4194304`（见 §六）。

### ② node4 起 master

```bash
# node4
cd /home/yin/nof/mooncake/mooncake-store/build/mooncake-store/src
SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma ./mooncake_master \
  --rpc_port=50061 \
  --enable_http_metadata_server --http_metadata_server_port=9998 \
  --metrics_port=9004 \
  --nof_heartbeat_interval_sec=120 --nof_heartbeat_failures_threshold=5
```
验证：`curl http://127.0.0.1:9998/metadata` 返回 200。

### ③ node4 注册 NoF（一次性）

```bash
# node4
/tmp/nof_register nqn.2026-01.io.spdk:urma-gpu-test 1 141.61.84.149 4420 URMA \
  141.61.84.151:50061 38407505182720
```
期望输出：`NoF registration succeeded`，master 指标出现 `NVMe-oF SSD: 0 B / 34.93 TB`。

### ④ node4 打流

```bash
# 写打流（~2 GB/s）
SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma ./stress_cluster_bench \
  --scenario=segment_write --protocol=tcp \
  --local_hostname=141.61.84.151:50071 --remote_hostname=141.61.84.151:50061 \
  --segment_name=test_nof_segment --num_keys=256 --value_size=4194304 \
  --nof_replica_num=1 --hard_pin=true --wait_seconds=300
```

---

# 五、几个「角色」到底谁是谁？

你问「各个客户端等等」——这套系统里有几个名字像客户端的东西，容易混。逐个讲清楚：

```
┌─────────────────────────────────────────────────────────────┐
│  mooncake_master    =「调度员/地址簿」                          │
│  不搬数据。它记住「哪个 segment 在哪台 target」                  │
│  常驻进程，是其他一切的中心枢纽                                  │
├─────────────────────────────────────────────────────────────┤
│  mooncake_client     =「真正搬数据的客户端」(库/进程)             │
│  应用调它，它去 master 查地址，再去 target 搬数据               │
│  本场景里它被「内嵌」进 bench 了，不单独常驻起                    │
├─────────────────────────────────────────────────────────────┤
│  stress_cluster_bench =「压测工具」(内含 client 逻辑)            │
│  本场景的「客户端」就是它。一次性运行，写完/读完即退出           │
│  --scenario=segment_write / segment_read / list_segments     │
├─────────────────────────────────────────────────────────────┤
│  nof_register        =「一次性注册工具」                       │
│  不是客户端，是把 target 登记进 master 的小工具，跑完即退         │
└─────────────────────────────────────────────────────────────┘
```

**关键澄清**：在本场景，你**不需要单独起一个常驻的 `mooncake_client` 进程**。`stress_cluster_bench` 自己就包含了 client 的数据搬运逻辑，它既是「发起请求的人」也是「搬数据的人」。所以你真正常驻的只有两个：node3 的 `nvmf_tgt` + node4 的 `mooncake_master`。

---

# 六、两个「救命」环境变量——为什么缺一不可

这一节决定你能不能跑通。**两个 env 必须同时设，少一个就报完全不同的错：**

| 环境变量 | 管什么 | 不设的后果 |
|---|---|---|
| `SPDK_URMA_DEV_NAME=udmac0d1e2` | **用哪块传输卡** | 选错卡（bonding_dev_0）→ `status=4` LOC_ACCESS_ERR |
| `SPDK_URMA_CAPSULE_TRANSPORT=urma` | **握手用什么协议** | 发错协议（tcp）→ `capsule mismatch`，attach `-104` |

打个比方：第一个是「走哪条路」，第二个是「说什么语言」。路走对了但说错语言，对方听不懂照样握手失败。所以**两个都要设**，每个创建 URMA context 的进程都要设。

还有一个**反向**的：`MC_URMA_SET_BONDING_MODE` **千万别设**——设了会触发一个会段错误的旧代码路径，默认关闭才是对的。

> 还有个**配套**的：因为 target 用了 `-O 4194304`（大 I/O 路径），initiator 侧还要 `export SPDK_URMA_MAX_IO_SIZE=4194304`——它和 target 的 `-O` 协商取小值，不设就会按默认 135168 协商，大于它的 I/O 下发失败。

---

# 七、一张图串起全程

```
[node3]                              [node4]
 nvmf_tgt:4420  ←──URMA attach───  mooncake_master:50061
   (盘柜)                            (地址簿, 常驻)
                                         ▲
                                         │ ③注册
                                         │
                                    nof_register (一次性)
                                         ▲
                                         │ ④打流(内含client)
                                         │
                                  stress_cluster_bench:5007x
                                    segment_write ✅ ~2GB/s
                                    segment_read  ⚠️ 批量模式有bug
```

**启动顺序就是「从下往上」：先盘柜 → 再地址簿 → 再注册 → 再打流。** 牢记这条依赖链，90% 的启动失败都是顺序/env 没对。

---

# 八、已知的一个坑（别慌，不是你配错）

`segment_read` 的**批量连续读模式**（`--duration`）目前会失败，报 `LEASE_EXPIRED`。这不是你环境的问题，是代码里 `batch_get_into_internal` 缺了 NoF 分支（ADR-005，待修）。

- ✅ **单 key warmup 读**：通过，验证了 NoF 读通路是通的；
- ❌ **duration 批量读**：待修复。

所以现阶段「读」用 warmup 模式验证通路即可，「写」完全可用（~2 GB/s）。

---

# 九、一句话总结

> **编两个东西（SPDK + Mooncake），起两个常驻进程（nvmf_tgt + master），跑两个一次性命令（register + bench）**；顺序是「盘柜→地址簿→注册→打流」；两个 env 必设（设备名+协议），一个 env 别设（bonding mode）。

---

## 文档关系

```
deployment_standford.md   本文：理解向讲解（为什么这么做，先建立心智模型）
real_deployment.md        操作向手册（照着做，逐步命令 + 端口检查 + 故障排查）
adr.md                    ADR-001~006（出问题时查根因）
diagnosis.md              问题总表
real_experiment.md        实测数据
```
