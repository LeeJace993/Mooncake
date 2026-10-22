# Mooncake NoF (URMA) 部署与验证指南

> 本文档是 [`spdk_urma_deploment.md`](../spdk/spdk_urma_deploment.md) 的上层续篇：
> 前者完成了 **SPDK + URMA 传输层**的部署与 `urma_perf` 级验证，本文在同一个
> 双节点环境上叠加 **Mooncake Store**，并通过 Mooncake 的 NoF 路径完成
> GPU Direct 端到端验证。SPDK target 侧的详细踩坑记录（vfio-pci noiommu、
> listener 必须绑定精确 IP 等）不再重复展开，直接引用原文档对应阶段。
> 文中 `/home/yin/nof/...` 为部署节点路径示例，按各节点实际布局替换。

## 版本与代码来源

| 组件 | 仓库 | 分支 / Commit | 说明 |
|---|---|---|---|
| SPDK | `https://github.com/yyyuanhao426-hash/spdk.git` | `urma_modified_v6` (`c44ccce27`) | URMA transport + 注册缓存 + CID 位图 + 4K 对齐；v4~v6 追加合并发送/TCP_NODELAY/批量排空/大 I/O（wire 兼容 v3） |
| Mooncake | `https://github.com/LeeJace993/Mooncake.git` | `nof-urma-v2` (`5a71d963`) | [LinQuickDev/Mooncake](https://github.com/LinQuickDev/Mooncake) `supercache-snapshot` 的 fork，NoF/URMA 适配在其上（变更清单见附录 B） |
| UMDK | 本地安装 | `netlab-sp4_umdk` | 路径见原文档附录 A |

**分支配对关系**（原 `nof-urma-v3`/`nof-urma-v6` 已按序更名为 `nof-urma-v1`/`nof-urma-v2`）：

| Mooncake 分支 | 对应 SPDK 分支 | 状态 |
|---|---|---|
| `nof-urma-v1` (`884d10a1`) | `urma_modified_v3` (`5509ef28c`) | 历史版本，可用 |
| `nof-urma-v2` (`5a71d963`) | `urma_modified_v6` (`c44ccce27`) | **当前推荐**：大 I/O 支持、install 判据修正、target 大 I/O 部署工具 |

Mooncake 侧的关键编译开关：

| CMake 开关 | 作用 |
|---|---|
| `-DUSE_NOF=ON` | NoF SSD pool 支持（注册脚本、对齐测试等随之安装） |
| `-DUSE_NOF_URMA=ON` | SPDK NVMe/URMA transport（要求 `USE_NOF=ON`，否则 CMake 直接报错；configure 期会校验 `/usr/local` 下 `nvme_urma.h` 存在） |
| `-DUSE_NOF_GPU_DIRECT=ON` | NoF GPU Direct（memory domain + provider，要求 `USE_NOF_URMA=ON`） |

## 总体架构

```
        141.61.84.151 (node4, initiator)              141.61.84.247 (node2, target)
  ┌────────────────────────────────────────┐    ┌──────────────────────────────────┐
  │  mooncake_master        :50051         │    │  nvmf_tgt -m 0x3                 │
  │  http_metadata_server   :8080          │    │   └─ bdev Nvme0 (PCIe 0000:a3:00.0│
  │  mooncake_client        :50052         │    │      = nvme3n1)                  │
  │   ├─ Mooncake Store (全局段 4GB)        │    │   ├─ URMA transport              │
  │   ├─ NoF: mooncake_ssd_register.py ────┼────┼─→ 子系统 nqn.2026-01.io.spdk:…   │
  │   │    (SSH 读 target listener → 注册)  │    │   └─ listener 141.61.84.247:4420 │
  │   └─ nof_worker_pool_bench (验证工具)   │    │                                  │
  │  Tesla V100 (GPU Direct 发起端)         │    │  SPDK_URMA_DEV_NAME=udmac0d1e2   │
  │  SPDK_URMA_DEV_NAME=udmac0d1e2          │    │                                  │
  └────────────────────────────────────────┘    └──────────────────────────────────┘
                    ═══════════════ URMA (udmac0d1e2) ═══════════════
```

- **只有 151（initiator）需要编译 Mooncake**；247（target）只需要 SPDK（`nvmf_tgt`）。
- 客户端进程（`mooncake_client`、`nof_worker_pool_bench`）内部都会执行
  `SpdkWrapper::InitializeEnv()` 初始化 SPDK 环境，因此 **151 同样需要大页内存**。
- 247 上的 Mooncake 代码只需要 Python 脚本可见？——不需要。注册脚本在 151 上
  通过 SSH（paramiko）读取 247 的 listener 信息，247 无需装 Mooncake。

## 进程与窗口总览（⚠️ 先读这一节）

Mooncake 是多进程系统，**每个常驻进程必须在独立窗口（或独立 tmux pane）里
前台运行**，不要都塞进一个窗口用 `&` 挂后台——否则日志混在一起、
Ctrl-C 一次全死、坏了都不知道死的是谁。下表是全部进程的总账：

| 编号 | 进程 / 命令 | 节点 | 窗口 | 启动时机 | 是否常驻 | 存活确认 |
|---|---|---|---|---|---|---|
| P0 | `nvmf_tgt` | 247 | T1 | 阶段 4（**每次 247 重启后都要重跑**） | 常驻 | `ss -tlnp \| grep 4420` |
| P1 | `http_metadata_server` | 151 | T2 | 阶段 5 | 常驻 | `curl http://127.0.0.1:8080/metadata` |
| P2 | `mooncake_master` | 151 | T3 | 阶段 5 | 常驻 | `ss -tlnp \| grep 50051` |
| P3 | `mooncake_ssd_register.py` | 151 | T4 | 阶段 6，跑一次即退 | 一次性 | 命令输出无报错 |
| P4 | `mooncake_client` | 151 | T5 | 阶段 7 | 常驻 | 日志出现 SPDK env 初始化成功 |
| P5 | 对齐测试 / bench | 151 | T6 | 阶段 8，跑一次即退 | 一次性 | 退出码 = 0 |

> 一次性命令（P3、P5）不挑窗口，在 T4/T6 里前台跑就行。P0 的拉起方式
> 见阶段 4（`sudo -E` 环境必须显式传递）。

## 部署节点信息

同 [`spdk_urma_deploment.md`](../spdk/spdk_urma_deploment.md)「部署节点信息」一节：

| 节点 | IP | 角色 | 关键资源 |
|---|---|---|---|
| node4 | 141.61.84.151 | Mooncake master / client / GPU Direct 发起端 | Tesla V100, udmac0d1e2 |
| node2 | 141.61.84.247 | SPDK NoF target | nvme3n1 @ 0000:a3:00.0 (Huawei 19e5:3755), udmac0d1e2 |

下文以 `yin` 为远端用户名（与原文档一致）。

---

## 阶段 0：前置检查（两节点）

**完全复用** [`spdk_urma_deploment.md`](../spdk/spdk_urma_deploment.md) 阶段 0，包括：

- `udma/ubcore/uburma/ummu` 内核模块、`/dev/uburma/udmac0d1e2` 设备检查；
- `SPDK_URMA_DEV_NAME=udmac0d1e2` 环境变量（**必须 `sudo -E` 传递**）；
- 151 上的 `nvidia-smi`，重启后 `modprobe nvidia_peermem`；
- 247 上的 NVMe 盘 PCI 地址确认（`readlink /sys/block/nvme3n1` → `0000:a3:00.0`）。

**本文档新增一项：151 上也配置大页内存**（客户端进程会初始化 SPDK env）：

```bash
# 151 与 247 都执行
sudo sysctl -w vm.nr_hugepages=2048
grep Huge /proc/meminfo          # HugePages_Total = 2048
```

⚠️ 若 151 上大页不足，`mooncake_client` / `nof_worker_pool_bench` 启动时会在
`InitializeEnv()` 处直接失败。

---

## 阶段 1：获取代码（两节点）

```bash
# === 247（target，只需要 SPDK）===
cd /home/yin/nof
git clone -b urma_modified_v6 https://github.com/yyyuanhao426-hash/spdk.git spdk-urma
cd spdk-urma
git submodule update --init

# === 151（initiator，SPDK + Mooncake 都要）===
cd /home/yin/nof
git clone -b urma_modified_v6 https://github.com/yyyuanhao426-hash/spdk.git spdk-urma
cd spdk-urma && git submodule update --init && cd ..

git clone -b nof-urma-v2 https://github.com/LeeJace993/Mooncake.git mooncake
cd mooncake
git submodule update --init        # yalantinglibs 等
cd ..
```

也可以用 Mooncake 自带脚本一步完成 SPDK 获取+编译+安装（见阶段 2 的方式 B）。

⚠️ **SPDK 分支自检**（若复用旧克隆，目录名可能不是 `spdk-urma`）：

```bash
cd /home/yin/nof/spdk-urma
git branch --show-current    # 必须是 urma_modified_v6
git log --oneline -1         # 必须是 c44ccce27 docs(CONTEXT): 补数据面与吞吐词汇……
```

不是的话：

```bash
git fetch origin && git checkout urma_modified_v6 && git submodule update --init
make -j$(nproc)              # 换分支后必须重新编译
```

⚠️ **两端统一 v6**：v6 与 v3 wire 兼容（新旧互通），但合并发送、TCP_NODELAY、
批量排空、大 I/O 等改进只在 v6 生效——initiator 与 target 必须都用 v6，
不要混搭（仅固定分支名不够，固定到 commit；见 `dependencies.sh` 的
`SPDK_URMA_REF_DEFAULT`）。

---

## 阶段 2：编译并安装 SPDK（两节点）

**方式 A：手动编译**（同原文档阶段 1）

```bash
cd /home/yin/nof/spdk-urma
./scripts/pkgdep.sh
./configure --with-rdma --with-urma=/home/yin/gdr/UMDK_tool_netlab-sp4_umdk
make -j$(nproc)
sudo make install                  # 装到 /usr/local —— Mooncake CMake 的默认搜索路径
# DPDK 静态库拷贝（Mooncake 的 DPDK_LIB_DIR 默认 /usr/local/lib，dependencies.sh 同款动作）
sudo cp dpdk/build/lib/*.a /usr/local/lib/
```

**方式 B：Mooncake 依赖脚本一键完成**（在 Mooncake 克隆目录里）

```bash
cd /home/yin/nof/mooncake
./dependencies.sh --with-rdma --with-urma --umdk-root=/home/yin/gdr/UMDK_tool_netlab-sp4_umdk
```

`--with-urma` 时脚本默认拉取 `yyyuanhao426-hash/spdk` 的 `urma_modified_v6`
（固定 commit `c44ccce27`）并自动 `make install`，与方式 A 等价。

**验证安装**（两节点都做）：

```bash
ls /usr/local/include/spdk/nvme_urma.h          # URMA 头文件存在
ls /usr/local/lib/libspdk_nvme.a
ldd /usr/local/bin/nvmf_tgt | grep urma         # liburma 不能指向 /usr/lib64 的旧库
```

⚠️ **`make install` 必做**：`urma_perf` / `nvmf_tgt` 能从 `build/bin` 直接跑
**不代表已安装**——Mooncake 的 CMake 只认 `/usr/local`，漏掉 install 会在
阶段 3 cmake 时报找不到 SPDK。

⚠️ **make install 末尾报 `hatchling`/`uv` 相关 Error 2 ≠ install 失败**（ADR-0018）：
SPDK 26.x 的 install 链最后一步是打包 `spdk/python`（需在线拉 hatchling），
出口受限或 `sudo` 剥离代理 env 时该步失败，但静态库/头文件此时已全部装完。
**以"验证安装"三行的产物检查为准**，不必重装；要干净退出则 `sudo -E make install`。
（`dependencies.sh` 方式 B 已内置该判据，自动做完整性检查。）

⚠️ **激活 venv 后 `make install` 报 `python3 is missing modules: elftools`**：
venv 的 python3 抢占了 PATH，DPDK 重新 configure 时缺 pyelftools。修复：

```bash
pip install pyelftools      # ⚠️ 包名是 pyelftools，装 `elftools` 会报"找不到版本"
```

（或 `deactivate` 后用系统 python 执行 make install，二选一。）

---

## 阶段 3：编译 Mooncake（仅 151）

**Python 环境（venv）**——configure 时用哪个 Python，`make install` 就把
pybind 模块装进哪个 Python 的 site-packages，建议专门建一个：

```bash
python3 --version                 # 要求 ≥ 3.10
python3 -m venv /root/venv        # 路径自定；root 用户常见为 /root/venv
source /root/venv/bin/activate    # ⚠️ 每开一个新窗口都要重新激活
pip install -U pip
pip install aiohttp paramiko      # metadata server / 注册脚本的运行期依赖
# pybind11 无需 pip 安装——cmake 用的是仓库内 extern/pybind11 子模块

# 编译前置检查
ls /usr/include/python3*/Python.h || dnf install -y python3-devel  # pybind11 扩展需要 Python 头文件
cmake --version                   # < 3.18 则 pip install cmake ninja
```

**安装 yalantinglibs（仅 151）**——Mooncake 不直接编仓库里的子模块，而是
`find_package` 找**已安装**的 ylt（`/usr/local`）。机器上若有旧版残留，
编译会报错在 `/usr/local/include/ylt/...` 路径下（而非仓库路径）——此时必须
从子模块重建覆盖：

```bash
cd /home/yin/nof/mooncake/extern/yalantinglibs
mkdir -p build && cd build
cmake .. -DBUILD_EXAMPLES=OFF -DBUILD_BENCHMARK=OFF -DBUILD_UNIT_TESTS=OFF
cmake --build . -j$(nproc)
cmake --install .
```

```bash
cd /home/yin/nof/mooncake
mkdir -p build && cd build

cmake .. -DUSE_NOF=ON \
         -DUSE_NOF_URMA=ON \
         -DUSE_NOF_GPU_DIRECT=ON \
         -DCMAKE_BUILD_TYPE=Release \
         -DUMDK_ROOT=/home/yin/gdr/UMDK_netlab   # 按实际 UMDK 前缀调整，
                                                 # 见下方 UMDK 查找说明
make -j$(nproc) mooncake_master mooncake_client \
                 nof_worker_pool_bench nof_buffer_alignment_test
make install                      # 安装 C++ 二进制 + python 模块到 site-packages
```

`make install` 会把 pybind 模块 `store.so` 和 NoF 相关脚本
（`mooncake_ssd_register.py`、`mooncake_ssd_unregister.py`、`spdk_tgt_create.py`）
装进 configure 时那个 Python 的 `site-packages/mooncake/`。**运行注册脚本必须
用同一个 venv**，否则 `from mooncake.store import MooncakeDistributedNoFRegister`
会失败。

编译产物检查：

```bash
ls build/mooncake-store/mooncake_master build/mooncake-store/mooncake_client
ls build/mooncake-store/benchmarks/nof_worker_pool_bench
python -c "from mooncake.store import MooncakeDistributedNoFRegister; print('store.so OK')"
```

⚠️ **GPU Direct 需要真实的 CUDA 头文件/驱动库**：`USE_NOF_GPU_DIRECT=ON` 会
`find_package(CUDAToolkit REQUIRED)` 并链接 `CUDA::cuda_driver` + `CUDA::cudart`。
151 上有 V100 与完整 CUDA toolkit，正常可直接通过；若报找不到 CUDA，
先 `nvcc --version` 确认 toolkit 安装，必要时
`-DCUDAToolkit_ROOT=/usr/local/cuda`。

⚠️ **UMDK 前缀**：`USE_NOF_URMA=ON` 时 CMake 要找到 `urma_api.h` 和
`liburma`（默认搜 `/usr`、`/usr/local`，找不到则要求 `-DUMDK_ROOT=<前缀>`）。
先定位本机 UMDK 安装前缀再传：

```bash
find /home/yin/gdr -name urma_api.h 2>/dev/null
# 若结果为 /home/yin/gdr/UMDK_netlab/include/ub/umdk/urma/urma_api.h
# 则 UMDK_ROOT=/home/yin/gdr/UMDK_netlab
```

若 cmake 报 `USE_NOF_URMA=ON but UMDK (urma_api.h / liburma) not found`，
就是这一步没传对。

⚠️ **URMA SPDK 版本守卫（configure 期）**：`USE_NOF_URMA=ON` 时 CMake 还会检查
`${SPDK_INCLUDE_DIR}/spdk/nvme_urma.h` 是否存在——这是 URMA 分支 SPDK 才有的
头文件，因此装错成上游 SPDK（或 install 漏掉，见阶段 2 ⚠️）会在 cmake 阶段
直接 FATAL_ERROR，而不是拖到链接期才炸。报错信息里会给出两个修复方向：
重新按阶段 2 安装 urma_modified_v6 产物，或用 `-DSPDK_INCLUDE_DIR=` 指向
正确前缀。

---

## 阶段 4：启动 SPDK NoF target（247）

> 🪟 **窗口：247-T1 ｜ 进程 P0 `nvmf_tgt`：新开进程，常驻**。
> 每次节点重启后本阶段（含 vfio 绑定）全部重来。

**完全复用** [`spdk_urma_deploment.md`](../spdk/spdk_urma_deploment.md) 阶段 2（vfio-pci
noiommu 绑定 + `nvmf_tgt` + RPC 配置），核心命令摘录：

```bash
# 247, 每次重启后都要执行
export SPDK_URMA_DEV_NAME=udmac0d1e2
sudo -E /home/yin/nof/spdk-urma/build/bin/nvmf_tgt -m 0x3 &

sudo /home/yin/nof/spdk-urma/scripts/rpc.py \
  bdev_nvme_attach_controller -b Nvme0 -t PCIe -a 0000:a3:00.0
sudo /home/yin/nof/spdk-urma/scripts/rpc.py nvmf_create_transport -t URMA
sudo /home/yin/nof/spdk-urma/scripts/rpc.py \
  nvmf_create_subsystem nqn.2026-01.io.spdk:urma-gpu-test -a -s URMAGPU0001
sudo /home/yin/nof/spdk-urma/scripts/rpc.py \
  nvmf_subsystem_add_ns nqn.2026-01.io.spdk:urma-gpu-test Nvme0n1
sudo /home/yin/nof/spdk-urma/scripts/rpc.py \
  nvmf_subsystem_add_listener nqn.2026-01.io.spdk:urma-gpu-test \
  -t URMA -a 141.61.84.247 -s 4420        # ⚠️ 必须精确 IP，不能 0.0.0.0
```

可选：用 Mooncake 的 target 创建脚本替代上面的手动 RPC（通过 SSH 从 151 执行）。

**基础用法**（4K~128K I/O，与手动 RPC 等价）：

```bash
# 151 上执行；脚本 SSH 到 247 拉起 nvmf_tgt 并下发 RPC
python -m mooncake.spdk_tgt_create \
  --spdk_target_info "ip:141.61.84.247 path:/home/yin/nof/spdk-urma pci:0000:a3:00.0" \
  --transport-type URMA \
  --username yin --key-file ~/.ssh/id_rsa \
  --urma-env SPDK_URMA_DEV_NAME=udmac0d1e2 \
  --core-mask 0x3
```

**大 I/O 用法**（>135168B，如 1M/2M——v6 的 `SPDK_URMA_MAX_IO_SIZE` 路径）：
需要同时放大小/大 iobuf 池，并用 `--wait-for-rpc` 流程（脚本自动处理：
先以 `--wait-for-rpc` 拉起 `nvmf_tgt`，RPC 下发 `iobuf_set_options` 后再
`framework_start_init`，否则默认 iobuf 池撑不住首轮 `populate`）：

```bash
# 151 上执行；2MB 示例（已验证配置，见 ADR-0017）
python -m mooncake.spdk_tgt_create \
  --spdk_target_info "ip:141.61.84.247 path:/home/yin/nof/spdk-urma pci:0000:a3:00.0" \
  --transport-type URMA \
  --username yin --key-file ~/.ssh/id_rsa \
  --urma-env SPDK_URMA_DEV_NAME=udmac0d1e2 \
  --core-mask 0x3 \
  --max-io-size 2097152 \
  --iobuf-options "16384,8192,320,2097152" \
  --iobuf-large-cache-size 64
```

参数含义与槽位账（每核 large = 32+cache，small = 1280）见
`spdk_tgt_create.py --help` 头部说明与 ADR-0017；`-C`（per-PG 峰值并发）
必须 ≥ 实际并发，否则首轮 populate 打满池报 `populate 0/16`。

> 替代路线：也可不用该脚本，直接照 SPDK 文档的 `target_nvme_takeover.sh`
> （urma_perf 级配置）手工拉 target——脚本与手工二选一，参数语义相同。

验收：247 上 `ss -tlnp | grep 4420` 有监听；原文档阶段 2 的自测通过。

---

## 阶段 5：启动 master 与 metadata server（151）

> 🪟 **窗口：151-T2（P1 metadata server）+ 151-T3（P2 master），两个新进程，都常驻**。
> ⚠️ 两个窗口分开前台跑，各占一个终端；先起 P1 再起 P2。

**窗口 151-T2** —— metadata server（P1，常驻，前台）：

```bash
# 151
cd /home/yin/nof/mooncake
source ~/venv/bin/activate
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
export SPDK_URMA_DEV_NAME=udmac0d1e2

python -m mooncake.http_metadata_server --port 8080     # 前台，别加 &
```

**窗口 151-T3** —— master（P2，常驻，前台）：

```bash
# 151
cd /home/yin/nof/mooncake
source ~/venv/bin/activate
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
export SPDK_URMA_DEV_NAME=udmac0d1e2

./build/mooncake-store/mooncake_master --port 50051 --metrics_port 9003
```

验收：

```bash
ss -tlnp | grep -E '50051|8080'
curl -s http://127.0.0.1:8080/metadata | head    # 200 响应即可
```

---

## 阶段 6：注册 NoF SSD target（151 → 247）

> 🪟 **窗口：151-T4 ｜ 进程 P3 注册脚本：一次性，跑完即退**。
> 前置：T3 里的 master（P2）必须已经活着。

注册脚本会 SSH 到 247 读取 listener 信息，并按 `transport-type` 过滤
（这里必须是 `URMA`），随后通过 pybind 接口向 master 注册：

```bash
# 151
python -m mooncake.mooncake_ssd_register \
  --master_server_address 141.61.84.151:50051 \
  --spdk_target_info "ip:141.61.84.247 path:/home/yin/nof/spdk-urma" \
  --transport-type URMA \
  --username yin --key-file ~/.ssh/id_rsa
```

> 说明：
> - `--spdk_target_info` 可重复传多个 target；格式为 `ip:<ip> path:<spdk 源码目录>`，
>   脚本会从该目录读取 `nvmf_tgt` 的 listener RPC 信息。
> - `--transport-type` 默认 `RDMA`，**这里必须显式给 `URMA`**，否则 URMA listener
>   会被过滤掉，master 上看不到 SSD。
> - SSH 认证用 `--username` + `--password` 或 `--key-file` 二选一。

验收：注册输出无报错；或在 master 日志 / `:9003` metrics 中看到新的 SSD 设备。

---

## 阶段 7：启动 client（151）

> 🪟 **窗口：151-T5 ｜ 进程 P4 `mooncake_client`：新开进程，常驻，前台**。
> 至此 151 上常驻三件套齐了：T2 metadata server、T3 master、T5 client。

```bash
# 151, 窗口 151-T5
export SPDK_URMA_DEV_NAME=udmac0d1e2
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH

./build/mooncake-store/mooncake_client \
  --host 141.61.84.151 \
  --metadata_server http://141.61.84.151:8080/metadata \
  --master_server_address 141.61.84.151:50051 \
  --protocol tcp \
  --global_segment_size 4GB \
  --threads 4
```

验收：client 日志出现 `SpdkWrapper::InitializeEnv` 成功（USE_NOF 构建下 client
启动时会初始化 SPDK env），无 `NoF buffer resolve failed` 等错误。

---

## 阶段 8：验证阶梯（151）

> 🪟 **窗口：151-T6 ｜ 进程 P5（对齐测试 / bench）：一次性，跑完即退**。
> 前置：T1 nvmf_tgt、T2/T3/T5 已在跑。阶段 6 的注册只需做过一次。

从底层到上层逐级验证，每一级通过后再进入下一级。以下 endpoint 字符串是
SPDK transport-id 格式 + `ns:` 字段（与 client 内部 `BuildTeEndpoint` 生成的
格式一致）：

```bash
export EP="trtype:URMA adrfam:IPv4 traddr:141.61.84.247 trsvcid:4420 subnqn:nqn.2026-01.io.spdk:urma-gpu-test ns:1"
```

多个 target 用逗号分隔传给 `--endpoints`。

### 8.1 单元测试：块对齐

```bash
./build/mooncake-store/tests/nof_buffer_alignment_test
```

预期：全部用例 PASS（覆盖 buffer_address_/size/用户指针的三重对齐校验）。

### 8.2 基线：host 内存 read

```bash
./build/mooncake-store/benchmarks/nof_worker_pool_bench \
  --endpoints "$EP" --op=read --io_size=128K --iodepth=64 \
  --duration_sec=20 --range_bytes=1G
```

预期：IOPS/带宽稳定输出、errors=0。此时全部 I/O 走 host 注册路径，
`nof_host_io` 计数增长。

### 8.3 GPU Direct 功能验证：`--memory=cuda --op=verify`

verify 模式对每个 endpoint 做 `fill → H2D → WRITE → READ → D2H → memcmp`，
是 GPU Direct 数据通路正确性的决定性测试：

```bash
./build/mooncake-store/benchmarks/nof_worker_pool_bench \
  --endpoints "$EP" --op=verify --memory=cuda \
  --io_size=128K --iodepth=4 --verify_rounds=2 \
  --duration_sec=60 --range_bytes=1G
```

预期：每轮 verify PASS（memcmp 一致），全程无
`NoF buffer resolve failed` / registration failure。

⚠️ **首次运行建议保持小 `--iodepth`、少 `--verify_rounds`**，确认通过后再放大。

### 8.4 GPU Direct 吞吐：`--memory=cuda --op=read`

```bash
./build/mooncake-store/benchmarks/nof_worker_pool_bench \
  --endpoints "$EP" --op=read --memory=cuda \
  --io_size=128K --iodepth=64 --duration_sec=30 --range_bytes=1G
```

### 8.5 指标验收

bench 退出时会打印 URMA 注册统计与 Mooncake NoF 指标（`ReportUrmaMemoryStats`）：

| 指标 | 来源 | 验收标准 |
|---|---|---|
| `urma_host` | SPDK URMA 注册统计 | > 0（host 缓冲正常注册） |
| `accelerator` | 同上 | **> 0**（GPU 内存被识别并以设备内存注册 —— GPU Direct 生效的硬指标） |
| `registration_failures` | 同上 | = 0 |
| `dmabuf` | 同上 | **V100 + 闭源驱动：预期 0**，见下方说明 |
| `peer_memory_fallback` | 同上 | V100 平台 > 0 是正常形态 |
| `nof_host_io` / `nof_cuda_io` | Mooncake NoF 指标 | `--memory=cuda` 后 `cuda_io` 持续增长 |
| `classify_fail` | 同上 | = 0 |
| `staging_fallback` | 同上 | = 0（出现说明走了回退搬运，需查原因） |

**关于 DMA-BUF（重要）**：`cuMemGetHandleForAddressRange`（DMA-BUF 导出，
CUDA ≥ 12.2）**仅在 NVIDIA Open Kernel Module 上受支持**。当前 151 为
V100 + 闭源驱动 575.57.08，调用返回 `CUDA error 801`（操作不支持）——这是
**平台能力限制，不是 bug**。此时 provider 自动回退到 peer-memory 注册路径，
依然是 GPU Direct（数据不经过 host 中转）。

- ✅ **V100 平台验收标准**：8.3 verify PASS + `accelerator > 0` +
  `registration_failures = 0` + `dmabuf = 0`（peer-memory 路径）。
- ❌ 不要在此平台加 `--require_dmabuf`，它必然以非零退出。
- 换 Open Kernel Module + CUDA ≥ 12.2 的平台后，`dmabuf > 0` 才是预期。

### 8.6 Store 级端到端（可选）

**8.6.1 数据面直通确认**：client 启动后（阶段 7），数据面即经过
`execute_ranged_read` 的 GPU 直通分支（NoF replica + URMA transport + GPU 指针
→ 直接 GPU Direct 读取到用户显存）。可通过 client 日志确认：GPU 目标读请求
不应出现 `staging fallback` 警告；若出现，检查目标 buffer 是否确实为 CUDA
device memory（`cudaMalloc` 分配），以及 `MC_NOF_GPU_STAGING_FALLBACK` 是否
被意外打开。

**8.6.2 NoF SSD pool 挂载（store_kv_bench）**：用 store 层的 KV bench 验证
NoF SSD replica 通路（`mooncake-store/benchmarks/store_kv_bench.py`，venv 内运行）：

```bash
python mooncake-store/benchmarks/store_kv_bench.py \
  --metadata-server "http://141.61.84.151:8080/metadata" \
  --master-server  141.61.84.151:50051 \
  --local-hostname 141.61.84.151:50071 \
  --protocol tcp \
  --memory-replica-num 0 \
  --nof-replica-num 1        # 纯 NoF：内存副本 0，SSD 副本 1
# 两者都为 0 会在参数校验处直接报错（二者至少其一 > 0）
```

验收：put/get 成功率 100%，master 上能看到注册的 NoF SSD（阶段 6 的
`MooncakeDistributedNoFRegister`），无 `staging fallback`。`--memory-replica-num 1
--nof-replica-num 1` 的混合模式也可用（SSD 作为第二副本）。

**8.6.3 长稳观察（store_client_e2e）**：`store_client_e2e.py` 同样支持
`nof_replica` 参数，可用于长时间挂载观察。重点盯：NoF 路径错误计数、
URMA 重连日志、master 侧 SSD 心跳是否持续（heartbeat probe qpair 路径）。

> ⚠️ **stress_cluster_bench.py 暂不支持 NoF**：该脚本尚未加 `nof_replica_num`
> 参数（截至 `nof-urma-v2`），压测 NoF 路径请先用 8.6.2 的 store_kv_bench。

### 8.7 大 I/O 验证（v6 特有，可选）

仅当阶段 4 target 用了大 I/O 配置（`--max-io-size 2097152` + iobuf 池）时进行。
v6 起 initiator 与 target 协商 `SPDK_URMA_MAX_IO_SIZE`（取两端较小值），超过
135168B 默认上限的 I/O 才能下发：

```bash
# initiator 侧放开上限（与 target 的 --max-io-size 配套）
export SPDK_URMA_MAX_IO_SIZE=2097152

# 分片 ≤ 协商值（MC_NOF_SUBMIT_CHUNK_BYTES 默认远小于此，通常无需调）
./build/mooncake-store/benchmarks/nof_worker_pool_bench \
  --endpoints "$EP" --op=verify --memory=host \
  --io_size=1M --iodepth=4 --verify_rounds=2 \
  --duration_sec=30 --range_bytes=1G
```

验收：verify PASS；target 侧无 `populate 0/16`（出现说明 iobuf 槽位账不够，
回到阶段 4 的 `--iobuf-options` 调参，参考 ADR-0017）。

---

## 阶段 9：故障排查

以下前半部分沿用 [`spdk_urma_deploment.md`](../spdk/spdk_urma_deploment.md) 阶段 3
排查表（设备不匹配 sc=6/status=4、0.0.0.0 listener → sct=1 sc=132、
nvidia_peermem 未加载 → accelerator=0 等），此处补充 **Mooncake 层特有**错误：

| 现象 / 日志 | 原因 | 处理 |
|---|---|---|
| `--memory=cuda requires a build with USE_NOF_URMA` | bench 编译时未开 URMA | 按 阶段 3 的 cmake 参数重新编译 |
| `NoF buffer resolve failed type=...` 且 I/O 失败 | 指针被识别为设备内存，但 provider/domain 初始化失败；**设计上不静默回退 host** | 看前一行具体错误（probe 失败 / provider 注册失败）；确认 `nvidia-smi` 可用、进程有 CUDA 上下文 |
| `MC_NOF_GPU_STAGING_FALLBACK` 相关 WARNING，`staging_fallback` 计数增长 | GPU 直通分支未命中（非 URMA transport、或显式开启回退），数据经 host 暂存 | 确认 replica 的 `transport_endpoint_` 含 `trtype:URMA`；确认注册时用了 `--transport-type URMA` |
| client/bench 启动即失败，SPDK env 初始化报错 | 151 大页不足（阶段 0 新增项） | `sysctl vm.nr_hugepages=2048` 后重试 |
| `from mooncake.store import ...` ImportError | 注册脚本用了与 cmake configure 不同的 Python | 激活同一 venv 再执行（阶段 3 说明） |
| 注册后 master 看不到 SSD | `--transport-type` 用了默认 RDMA | 显式传 `--transport-type URMA` |
| `--io_size not aligned to block size` | io_size / range_bytes 未按扇区对齐 | 用 4K 整数倍（如 128K）；SPDK 侧已修 4K 对齐，客户端仍需对齐 |
| `CUDA error 801`（cuMemGetHandleForAddressRange） | 闭源驱动不支持 DMA-BUF 导出 | 预期行为，peer-memory 回退即可；`--require_dmabuf` 勿用 |
| 编译报错位于 `/usr/local/include/ylt/...` | `find_package` 命中了 `/usr/local` 里安装的**旧版** ylt，而非仓库子模块（版本不符） | 按阶段 3「安装 yalantinglibs」从子模块重建并 `cmake --install .` 后重编 |
| cmake `FATAL_ERROR: USE_NOF_URMA=ON but .../spdk/nvme_urma.h not found` | `/usr/local` 装的不是 URMA 分支 SPDK，或 install 漏掉 | 重跑阶段 2（确认分支自检 + `make install`）；或 `-DSPDK_INCLUDE_DIR=` 指向正确前缀 |
| `make install` 末尾报 `hatchling`/`uv` Error 2 | SPDK 26.x 在线打包 spdk/python 失败（假象，库已装完） | 按 ADR-0018 以产物为准：`ls /usr/local/lib/libspdk_nvme.a`；要干净退出用 `sudo -E make install` |
| target 侧 RPC 报 `populate 0/16`（iobuf 池打满） | 大 I/O 配置下 iobuf 槽位不足（槽位账见 ADR-0017） | 调大 `--iobuf-options`（large_count ≥ 每核并发×核数）、`--iobuf-large-cache-size`；确认 `-C` ≥ per-PG 峰值并发 |
| `trtype:URMA` endpoint 解析失败 | SPDK 未装 URMA transport 的版本 | 确认 `/usr/local` 安装的是 `urma_modified_v6` 分支产物（nvme_urma.h 存在） |
| `submodule update` 报 `not our ref b12fbfd8...` | 原 pin 的 yalantinglibs commit 上游已不可达（已在 fork `f702fbfe` 修复） | `git pull` 后重跑 `git submodule update --init`；网络不通时手工绕过：`cd extern/yalantinglibs && git checkout e46cbf08`（上次失败时对象多半已 fetch 到本地）→ `git config submodule.extern/yalantinglibs.update none` → 重跑 submodule update，status 显示 "new commits" 无害 |
| `CONNECT tunnel failed, response 504` | 出口代理抖动，clone/fetch 中断 | **直接重跑同一条命令**（幂等，已完成的 submodule 不会重拉） |

---

## 附录 A：Mooncake NoF 相关环境变量

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `SPDK_URMA_DEV_NAME` | 无（必填） | URMA 设备名（`udmac0d1e2`），**两节点所有相关进程（含 sudo 拉起的 nvmf_tgt）都需要** |
| `MC_NOF_WORKERS` | 默认值 | NoF worker pool 线程数（bench 可用 `--nof_workers` 覆盖） |
| `MC_NOF_SUBMIT_CHUNK_BYTES` | 默认值 | 单次提交分片大小（bench 可用 `--nof_submit_chunk_bytes` 覆盖） |
| `MC_NOF_INFLIGHT_BYTES_LIMIT` | 默认值 | 在途字节上限（bench 可用 `--nof_inflight_bytes_limit` 覆盖） |
| `MC_NOF_GPU_REG_MODE` | `dmabuf` | `dmabuf`：优先 DMA-BUF 导出，失败回退 peer-memory；`peer`：跳过 dmabuf 直接 peer-memory |
| `MC_NOF_GPU_STAGING_FALLBACK` | 未设置 | 置 `1` 时，GPU 直通分支未命中的读请求允许回退 host 暂存（计数 `staging_fallback`）；未设置时严格报错 |
| `SPDK_URMA_MAX_IO_SIZE` | 135168 | initiator 侧大 I/O 上限（与 target `--max-io-size` 协商取小值，v6 起支持；见 8.7） |
| `SPDK_URMA_TRACE` | 未设置 | 置 `1` 开启 URMA 数据面 per-I/O trace（v6 起，用于定位丢包/重传问题，有开销） |
| `SPDK_URMA_TRANS_MODE` / `SPDK_URMA_EID_INDEX` / `SPDK_LOG_LEVEL` | 见原文档附录 B | URMA 传输层参数，语义同原文档 |

## 附录 B：Mooncake 分支变更清单

**`nof-urma-v1`（`884d10a1`，基线）**——对应外部评审
[`adr/enablenof_review_archive.md`](./adr/enablenof_review_archive.md) 意见
8.1–8.9 的落点（核心 commit `6bce8808`，25 files，+1519/-90）：

| 模块 | 文件 | 内容 |
|---|---|---|
| 内存域 | `mooncake-store/src/spdk/nof_memory_domain.cpp`（新增）+ 头文件 | CUDA provider（pin/unpin/export_dmabuf）、per-GPU domain 管理、严格 buffer 识别、验收指标 |
| 设备识别 | `accelerator_device.h` / `cuda_like_accelerator_device.cpp` | 新增 `ProbePointerStrict`（区分 kNotDevice 与 kProbeError） |
| I/O 路径 | `transfer_task.h/.cpp` | 提交前 `ResolveBuffer` 分类；CUDA I/O 走 ext I/O + memory domain；host I/O 走原路径 |
| 直通分支 | `real_client.cpp` | `execute_ranged_read` 全量读 GPU 分支：NoF replica + URMA transport 时直接 GPU Direct 读入显存；严格错误策略 + 可选回退 |
| 构建开关 | `mooncake-store/CMakeLists.txt` 及 benchmarks | `USE_NOF_URMA` / `USE_NOF_GPU_DIRECT` 选项与链接 |
| 测试/工具 | `nof_worker_pool_bench.cpp`（`--memory`/`--op=verify`/`--require_dmabuf`/指标打印）、`nof_buffer_alignment_test` | 验证阶梯的工具支撑 |
| 链接自适应 | `dependencies.sh`、`mooncake-store/src/CMakeLists.txt` | SPDK 26.x rdma 三库拆分兼容（ADR-0014）、dmabuf 导出 API 修正 |

**`nof-urma-v2`（`5a71d963`，当前推荐）相对 v1 的增量**（SPDK urma_modified_v6
适配，3 个 commit）：

| commit | 文件 | 内容 |
|---|---|---|
| `070d2c86` | `dependencies.sh` | `--with-urma` 默认引用升级到 urma_modified_v6（固定 commit）；install 判据收敛为 `/usr/local` 产物完整性（ADR-0018） |
| `42deeea7` | `mooncake-store/src/CMakeLists.txt` | configure 期校验 `spdk/nvme_urma.h`，装错 SPDK 版本在 cmake 阶段即报错 |
| `5a71d963` | `mooncake-wheel/mooncake/spdk_tgt_create.py` | target 工具新增大 I/O 支持：`--iobuf-options` / `--iobuf-large-cache-size` / `--max-io-size` 校验、`--wait-for-rpc` + `iobuf_set_options` 启动流程（ADR-0017） |

## 文档关系

```
README.md                        本目录导航：每份文档是干什么的、建议阅读顺序
spdk_urma_deploment.md           SPDK + URMA 传输层部署与 urma_perf 验证（前置）
mooncake_nof_deployment.md       本文档：Mooncake 编译部署 + GPU Direct 端到端验证
mooncake_nof_architecture.md     系统全景与改造原理（为什么这么做）
mooncake_nof_compile_pitfalls.md 编译部署踩坑总账（时间线汇总表）
adr/ADR-0012~0018                上述坑的决策记录；adr/enablenof_review_archive.md
                                 为外部评审存档（意见 8.1–8.9 的编号出处）
```
