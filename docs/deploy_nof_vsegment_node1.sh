#!/usr/bin/env bash
###############################################################################
# NoF vsegment → k8s 测试「第 1 步：编译部署」一键脚本（在 node1 上执行）
#
# 设计原则：不改动已验证的 build_mooncake_930.sh（4 节点编译验收通过），
#   本脚本只做三件事：
#     [0] 前置预检（缺什么直接报出处置命令，不会编到一半才失败）
#     [1] 调用 build_mooncake_930.sh 完成 NoF 编译 + install + 原验收
#     [2] 额外编译 mooncake_kvtest（Mooncake-Performance@yh 需要），
#         并把产物整理成 k8s runtime 镜像脚本要求的 outputs 布局
#
# 【URMA 库前提 · 重要】SPDK 已与 GDR 解耦（host-only），USE_NOF_GPU_DIRECT=OFF：
#   - 链接期和运行期一律用「系统 URMA 库」：
#       /usr/lib64/liburma.so + liburma_common.so* + /usr/lib64/urma/ provider 目录
#   - 不再需要导出 urma_register_seg_dmabuf / is_gpu_seg 的改造库
#     （/usr/local/gdr-umdk、UMDK_netlab、tong 库等）；容器/base image 里也没有这些 so。
#   - 因此产物包绝不打包定制 liburma，镜像直接用基础镜像自带的系统库。
#   - 若以后要跑 GDR peermem：URMA_MODE=custom + URMA_LIB_DIR=<定制库目录>，
#     此时才检查 urma_register_seg_dmabuf，且不生成 host-urma 补丁副本。
#
# 【为什么你「已经编译部署过」还要再跑一次本脚本】
#   裸机那次（6.mooncake-vesegment/deploy/deploy_record.md，4/4 节点验收通过）
#   编译参数里是 -DURMA_LIBRARY=/usr/local/gdr-umdk/lib/liburma.so，
#   且 -DCMAKE_EXE_LINKER_FLAGS=-L/usr/local/gdr-umdk/lib；二进制无 RPATH，
#   运行期靠 LD_LIBRARY_PATH=/usr/local/gdr-umdk/lib 才能加载。
#   容器/base image 里没有这份改造 so → 那批二进制搬进容器会报
#   undefined symbol: urma_register_seg_dmabuf（系统 liburma.so.0 无此符号）。
#   所以本脚本不是「重做实验」，而是给同一份源码换一个链接目标（系统库）、
#   补编 yh 需要的 mooncake_kvtest，并把散落在 /usr/local/bin、build/、venv/
#   的产物收拢成镜像能直接吃的 outputs/{bin,lib,dist} 布局。
#
# 依据：
#   5.Mooncake-Performance/scripts/env.mooncake.sh 开头注释
#     「host-only SPDK 不再要求 GDR 版 liburma」
#   0.Bonding_liburma_fix/4.review_spdk_decoupling.md（构建时能力拆分）
#   0.Bonding_liburma_fix/2.build_deploy.md §5（旧 CMakeCache 会钉死 URMA_LIBRARY，
#     换库必须 --clean）
#   6.mooncake-vesegment/deploy/deploy_record.md 是解耦前用 gdr-umdk 的旧记录，
#     仅用于 CMake 参数与路径，不再作为 liburma 选择的依据。
#
# 用法（node1 上）：
#   bash docs/deploy_nof_vsegment_node1.sh --check     # 只预检，不编译
#   bash docs/deploy_nof_vsegment_node1.sh             # 编译部署 + 验收（系统库）
#   bash docs/deploy_nof_vsegment_node1.sh --clean     # 清 build 目录后全量重编
#   bash docs/deploy_nof_vsegment_node1.sh --no-etcd   # 不启用 etcd（默认 ON）
#   bash docs/deploy_nof_vsegment_node1.sh --gdr       # 切回 GDR 定制库模式
#
# 常用环境变量覆盖：
#   URMA_LIB_DIR=/usr/lib64        URMA_HEADER_DIR=/usr/include/ub/umdk/urma
#   UMDK_PREFIX=/usr               （一键脚本 --umdk 要的是「前缀目录」）
#   ONEKEY=/abs/path/build_mooncake_930.sh
#   ONEKEY_PATCH=off               （node1 一键脚本已自行更新为系统库时关闭补丁）
#   SRC_ROOT=/home/yin/nof/mooncake-vesegment \
#   BUILD_DIR=/home/yin/nof/mooncake-builds/mooncake-vesegment-build \
#     bash docs/deploy_nof_vsegment_node1.sh
#
# 输出：
#   /usr/local/bin/{mooncake_master,mooncake_client,...}   ← install（裸机跑脚本用）
#   $OUTPUT_ROOT/mooncake-<CID>-aarch64-linux/{bin,lib,dist}  ← 第 2 步打镜像用
#   $OUTPUT_ROOT/{bin,lib,dist}/                            ← 上述目录的软链
###############################################################################
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# 重要：node1 上已验证的那份在 /home/yin/nof/mooncake-930/docs/（md5 1508a466...），
# 它比源码树 docs/ 里的版本多 -DNOF_URMA_LIBRARY / -DNOF_URMA_INCLUDE_DIR 两个参数。
# 本地 worktree 的 docs/build_mooncake_930.sh 是另一个版本（md5 77a2299a...），别混用。
ONEKEY="${ONEKEY:-/home/yin/nof/mooncake-930/docs/build_mooncake_930.sh}"

# ---- node1 上的默认路径 ----
SRC_ROOT="${SRC_ROOT:-/home/yin/nof/mooncake-vesegment}"
BUILD_DIR="${BUILD_DIR:-/home/yin/nof/mooncake-builds/mooncake-vesegment-build}"
VENV="${VENV:-/home/yin/venvs/mooncake-vesegment}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$SRC_ROOT/outputs}"

# ---- URMA / host-only ----
URMA_MODE="${URMA_MODE:-system}"                 # system | custom(GDR)
URMA_LIB_DIR="${URMA_LIB_DIR:-/usr/lib64}"       # 系统库目录
URMA_HEADER_DIR="${URMA_HEADER_DIR:-/usr/include/ub/umdk/urma}"
UMDK_PREFIX="${UMDK_PREFIX:-/usr}"              # 一键脚本 --umdk：前缀目录
ONEKEY_PATCH="${ONEKEY_PATCH:-auto}"             # auto | off

GIT_BRANCH="${GIT_BRANCH:-mooncake-vesegment}"
GIT_COMMIT="${GIT_COMMIT:-}"
USE_ETCD="${USE_ETCD:-ON}"          # k8s 集群是 etcd HA，必须 ON
PATCH_930="${PATCH_930:-false}"     # vesegment 分支结构已变，930 三补丁不能用
JOBS="${JOBS:-$(nproc)}"
CLEAN_BUILD="${CLEAN_BUILD:-false}"
CHECK_ONLY="${CHECK_ONLY:-false}"

log()  { echo -e "\n\033[1;36m[$(date '+%H:%M:%S')] $*\033[0m"; }
ok()   { echo -e "  \033[1;32m[OK]\033[0m   $*"; }
warn() { echo -e "  \033[1;33m[WARN]\033[0m $*" >&2; }
die()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*\n" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

usage() { cat <<'EOF'
NoF vsegment 第 1 步：node1 编译部署（host-only SPDK / 系统 liburma）

  bash docs/deploy_nof_vsegment_node1.sh --check    只预检，不编译
  bash docs/deploy_nof_vsegment_node1.sh            编译部署 + 验收
  bash docs/deploy_nof_vsegment_node1.sh --clean    清 build 目录后全量重编
                                                    （从 GDR 库切到系统库时必加）
  bash docs/deploy_nof_vsegment_node1.sh --no-etcd  不启用 etcd（默认 ON）
  bash docs/deploy_nof_vsegment_node1.sh --gdr      切回 GDR 定制库模式
  bash docs/deploy_nof_vsegment_node1.sh --system   显式系统库模式（默认）

默认 URMA_MODE=system：/usr/lib64/liburma.so + liburma_common.so*，
不要求 urma_register_seg_dmabuf。ONEKEY_PATCH=auto 会在检测到一键脚本
仍强制检查 dmabuf 符号时生成一个最小补丁副本（原脚本不改）。
EOF
exit 0; }
while [ $# -gt 0 ]; do
    case "$1" in
        --check)    CHECK_ONLY=true;;
        --clean)    CLEAN_BUILD=true;;
        --no-etcd)  USE_ETCD=OFF;;
        --gdr)      URMA_MODE=custom;;
        --system)   URMA_MODE=system;;
        --help|-h)  usage;;
        *)          die "未知参数: $1（见 --help）";;
    esac
    shift
done

[ "$URMA_MODE" = system ] || [ "$URMA_MODE" = custom ] \
    || die "URMA_MODE 只能是 system 或 custom（当前 $URMA_MODE）"

# ============================================================================
# [0] 前置预检
# ============================================================================
log "[0/3] 前置预检（node1 本机）"
echo "  host        = $(hostname)  ($(id -un), uid=$(id -u))"
echo "  arch        = $(uname -m)"
echo "  SCRIPT_DIR  = $SCRIPT_DIR"
echo "  SRC_ROOT    = $SRC_ROOT"
echo "  BUILD_DIR   = $BUILD_DIR"
echo "  VENV        = $VENV"
echo "  URMA_MODE   = $URMA_MODE"
echo "  URMA_LIB    = $URMA_LIB_DIR"
echo "  URMA_HEADER = $URMA_HEADER_DIR"
echo "  UMDK_PREFIX = $UMDK_PREFIX（传给 --umdk）"
echo "  INSTALL     = $INSTALL_PREFIX"
echo "  OUTPUT_ROOT = $OUTPUT_ROOT"
echo "  USE_ETCD=$USE_ETCD  PATCH_930=$PATCH_930  JOBS=$JOBS  CLEAN=$CLEAN_BUILD  ONEKEY_PATCH=$ONEKEY_PATCH"

for c in git cmake make nm flock python3 tar bash; do need "$c"; done
[ -f "$ONEKEY" ] || die "找不到一键编译脚本: $ONEKEY
  前置准备：node1 上应存在 /home/yin/nof/mooncake-930/docs/build_mooncake_930.sh
  （即 4 节点编译验收用、md5 1508a466... 的那份；如路径不同用 ONEKEY=/abs/path 覆盖）"
if ! grep -q 'NOF_URMA_LIBRARY' "$ONEKEY"; then
    warn "$ONEKEY 里没有 -DNOF_URMA_LIBRARY —— 可能不是 node1 上那份已验证脚本
  deploy_record.md 记录的 4 节点版本带该参数；用错了会在 NoF 链接期找不到 urma 符号
  确认：md5sum $ONEKEY  应为 1508a466f88f937086acc4d4e888b671"
fi
[ -d "$SRC_ROOT/.git" ] || die "源码树不是 git 仓库: $SRC_ROOT
  前置准备：把本地 ~/nof/upstream/mooncake-supercache-nof-gdr-worktree 同步到 node1 该路径
  （kvtest 尚未提交，必须用 rsync/scp 整树同步，或先 commit 再 git pull）"

# --- 分支 ---
CUR_BRANCH="$(git -C "$SRC_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '<unknown>')"
echo "  branch      = $CUR_BRANCH"
[ "$CUR_BRANCH" = "$GIT_BRANCH" ] \
    || warn "当前分支 $CUR_BRANCH != $GIT_BRANCH；确认源码是 vesegment 版本（GIT_BRANCH 可覆盖）"
CID="$(git -C "$SRC_ROOT" rev-parse --short HEAD)"
echo "  commit      = $CID"
[ -z "$GIT_COMMIT" ] || [ "$CID" = "${GIT_COMMIT:0:${#CID}}" ] \
    || warn "HEAD=$CID 与期望 $GIT_COMMIT 不同（仅提示，不中断）"

# --- submodule ---
for sm in extern/pybind11 extern/yalantinglibs; do
    if [ -e "$SRC_ROOT/$sm/CMakeLists.txt" ] || [ -e "$SRC_ROOT/$sm/include" ]; then
        ok "submodule $sm"
    else
        die "submodule 未初始化: $sm
  处置：cd $SRC_ROOT && git submodule update --init --recursive"
    fi
done

# --- kvtest（Mooncake-Performance@yh 的硬依赖） ---
KVTEST_DIR="$SRC_ROOT/mooncake-store/benchmarks/kvtest"
BENCH_CMAKE="$SRC_ROOT/mooncake-store/benchmarks/CMakeLists.txt"
[ -f "$KVTEST_DIR/src/main.cpp" ] || die "源码树缺少 kvtest benchmark: $KVTEST_DIR
  处置：把本地 worktree 的 mooncake-store/benchmarks/kvtest/ 整个目录同步到 node1
  （来源 wangyuqi0429/Mooncake@supercache-snapshot-930）"
grep -q 'add_subdirectory(kvtest)' "$BENCH_CMAKE" || die "benchmarks/CMakeLists.txt 缺少 add_subdirectory(kvtest)
  处置：echo 'add_subdirectory(kvtest)' >> $BENCH_CMAKE"
# yh 分支要求新版 kvtest：start_paused / POST /start
grep -q 'start_paused' "$KVTEST_DIR/src/main.cpp" \
    || die "kvtest 是旧版（缺 start_paused），yh 的 /start 健康门会失败"
grep -q '"/start"' "$KVTEST_DIR/src/main.cpp" \
    || warn "kvtest 里没找到 /start 路由，确认版本"
ok "kvtest 已合入（新版，含 start_paused）"

# --- URMA 库（host-only：系统库；custom：GDR 定制库） ---
URMA_LIB="$URMA_LIB_DIR/liburma.so"
[ -r "$URMA_LIB" ] || die "找不到可读的 $URMA_LIB
  host-only 部署用系统 URMA 包。检查：
    ls -l /usr/lib64/liburma.so* /usr/lib64/liburma_common.so*
  若系统只有 liburma.so.0.x 而没有开发用 liburma.so，用 URMA_LIB_DIR 指到
  同时含 liburma.so 与 liburma_common.so* 的目录（不要指向 GDR 定制库）。"
URMA_INIT_CNT="$(nm -D "$URMA_LIB" 2>/dev/null | grep -c urma_init || true)"
[ "${URMA_INIT_CNT:-0}" -gt 0 ] \
    || die "$URMA_LIB 未导出 urma_init —— 不是可用的 URMA 库"
if compgen -G "$URMA_LIB_DIR/liburma_common.so*" >/dev/null; then
    ok "liburma_common: $(ls "$URMA_LIB_DIR"/liburma_common.so* | tr '\n' ' ')"
else
    die "缺 $URMA_LIB_DIR/liburma_common.so* —— SPDK host-only 需要系统配套库
  处置：安装系统 URMA 用户态包（liburma / liburma-common）"
fi
[ -d "$URMA_LIB_DIR/urma" ] \
    && ok "provider 目录: $URMA_LIB_DIR/urma/" \
    || warn "缺 $URMA_LIB_DIR/urma/ provider 目录：urma_init() 靠 dlopen 该目录注册
  udma/ubagg provider，缺了会静默丢设备（get_device_list count=0）
  见 0.Bonding_liburma_fix/2.build_deploy.md §6 坑 3"
[ -f "$URMA_HEADER_DIR/urma_api.h" ] \
    || die "缺 URMA 头文件 $URMA_HEADER_DIR/urma_api.h
  处置：安装系统 UMDK 开发包，或用 URMA_HEADER_DIR 指到含 urma_api.h 的目录"
ok "URMA header: $URMA_HEADER_DIR/urma_api.h"

DMABUF_LIB_CNT="$(nm -D "$URMA_LIB" 2>/dev/null | grep -c urma_register_seg_dmabuf || true)"
if [ "$URMA_MODE" = system ]; then
    # 解耦后 host-only SPDK 不引用 dmabuf / is_gpu_seg，绝不能拿它们当准入条件
    if [ "${DMABUF_LIB_CNT:-0}" -gt 0 ]; then
        warn "$URMA_LIB 仍导出 urma_register_seg_dmabuf（GDR 定制库？）
  host-only 场景下无害，但请确认它不是被 LD_LIBRARY_PATH 优先加载的改造库"
    fi
    ok "host-only 模式：$URMA_LIB（不检查 dmabuf / is_gpu_seg）"
    if [ "$URMA_LIB_DIR" != /usr/lib64 ]; then
        warn "URMA_LIB_DIR=$URMA_LIB_DIR 不是系统默认路径；容器/base image 里未必有，
  打镜像前确认镜像内同样路径存在 liburma.so + liburma_common.so*"
    fi
else
    [ "${DMABUF_LIB_CNT:-0}" -gt 0 ] \
        || die "GDR(custom) 模式要求 $URMA_LIB 导出 urma_register_seg_dmabuf"
    ok "custom 模式：GDR 定制库 $URMA_LIB"
fi

# --- SPDK（host-only 产物；顺便确认它真的解耦了 GDR 符号） ---
SPDK_A=/usr/local/lib/libspdk_nvme.a
if [ -f /usr/local/include/spdk/nvme_urma.h ] && [ -f "$SPDK_A" ]; then
    ok "SPDK: /usr/local/include/spdk/nvme_urma.h + $SPDK_A"
    if [ "$URMA_MODE" = system ]; then
        DMABUF_REFS="$(nm -A "$SPDK_A" 2>/dev/null | grep -c 'urma_register_seg_dmabuf' || true)"
        if [ "${DMABUF_REFS:-0}" -gt 0 ]; then
            warn "$SPDK_A 里仍有 $DMABUF_REFS 处 urma_register_seg_dmabuf 引用
  这说明 /usr/local 装的不是 host-only 重编产物，链接期会向系统库要该符号而失败
  处置：重编 host-only SPDK（--with-urma，不编 peermem/dmabuf）后 sudo make install"
        else
            ok "SPDK 静态库无 dmabuf 符号引用（host-only 已解耦）"
        fi
    fi
else
    warn "SPDK 自检未通过（/usr/local/include/spdk/nvme_urma.h 或 libspdk_nvme.a 缺失）
  NoF 链接需要它；若已装在其他前缀请确认 cmake 能找到，否则编译会在 USE_NOF 处失败"
fi

# --- 一键脚本的过时 GDR 库探测（提示，补丁在 [1] 生成） ---
if [ "$URMA_MODE" = system ] && grep -q 'grep -q urma_register_seg_dmabuf' "$ONEKEY"; then
    if [ "$ONEKEY_PATCH" = off ]; then
        warn "$ONEKEY 仍强制检查 dmabuf 符号，但 ONEKEY_PATCH=off：编译会在这里失败
  处置：去掉 ONEKEY_PATCH=off，或先把一键脚本的库探测改成系统库"
    else
        ok "一键脚本含旧 GDR 探测 → [1] 会生成 host-urma 最小补丁副本（原脚本不改）"
    fi
fi

# --- 安装权限 ---
if [ ! -w "$INSTALL_PREFIX" ] && [ "$(id -u)" != 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        ok "非 root，但 sudo -n 可用（install 阶段会用 sudo -E）"
    else
        die "$INSTALL_PREFIX 不可写且 sudo -n 不可用；请用 root 执行，或设 INSTALL_PREFIX 到可写目录"
    fi
else
    ok "$INSTALL_PREFIX 可写"
fi

# --- 代理（go mod tidy / submodule / pip 需要） ---
if (exec 3<>/dev/tcp/127.0.0.1/3128) 2>/dev/null; then
    ok "proxy 127.0.0.1:3128 可达"
else
    warn "proxy 127.0.0.1:3128 不通：USE_ETCD=ON 的 go mod tidy 可能失败
  处置：PROXY_URL=http://127.0.0.1:21428 bash $0   （node2 上 3128 曾失效，21428 为备用）
  或临时改用 --no-etcd（仅编译，不用于 k8s）"
fi

# --- 旧 build 缓存：从 GDR 库切到系统库必须清缓存 ---
# 二进制无 RPATH，CMakeCache 会把 URMA_LIBRARY / -L<umdk lib> 钉死在旧库上；
# 不清缓存，-DURMA_LIBRARY=/usr/lib64/liburma.so 不会生效（2.build_deploy.md §5）。
CACHE_FILE="$BUILD_DIR/CMakeCache.txt"
if [ "$URMA_MODE" = system ] && [ -f "$CACHE_FILE" ]; then
    STALE_CACHE="$(grep -E '^(URMA_LIBRARY|NOF_URMA_LIBRARY|CMAKE_(EXE|SHARED|MODULE)_LINKER_FLAGS)' "$CACHE_FILE" \
        | grep -Ei 'gdr-umdk|UMDK_netlab|UMDK_tool|umdk_b026|tong|gpu_isolated' || true)"
    if [ -n "$STALE_CACHE" ]; then
        die "$BUILD_DIR 的 CMakeCache 还钉在 GDR 定制库上：
  $STALE_CACHE
  这正是「容器里跑不起来」的根因：旧产物链接的是容器没有的改造 so。
  处置：bash $0 --clean   （清 build 目录全量重编，重新链接系统 /usr/lib64/liburma.so）
  若你确认缓存已更新，可用 ONEKEY_PATCH=off / URMA_MODE=custom 绕过此检查。"
    else
        ok "CMakeCache 未发现 GDR 定制库残留"
    fi
fi

# --- 架构（runtime-image 脚本按 aarch64 拼产物目录名） ---
[ "$(uname -m)" = "aarch64" ] \
    || warn "架构 $(uname -m) != aarch64；第 2 步的 build-mooncake-runtime-image.sh 默认按 aarch64 拼目录名"

# --- 第 2 步所需环境（只提示，不属于本步） ---
echo
echo "  [第 2 步预告] 打镜像/分发需要：docker + 基础镜像 + /home/check-mooncake-{ldd,wheel}.sh"
echo "                基础镜像必须自带系统 URMA 包（liburma / liburma-common + /usr/lib64/urma/）"
echo "                本脚本不碰 docker，也不把定制 liburma 打进产物包"

if [ "$CHECK_ONLY" = "true" ]; then
    log "预检通过（--check，未编译）"
    exit 0
fi

# ============================================================================
# [1] 调用已验证的一键脚本：NoF 编译 + install + 原验收
# ============================================================================
log "[1/3] 调用 build_mooncake_930.sh（NoF 编译 / install / 验收）"

ONEKEY_EFFECTIVE="$ONEKEY"
if [ "$URMA_MODE" = system ] && [ "$ONEKEY_PATCH" != off ] \
   && grep -q 'grep -q urma_register_seg_dmabuf' "$ONEKEY"; then
    # node1 上那份已验证脚本（md5 1508a466）的 probe_umdk 仍强制要求
    # urma_register_seg_dmabuf，会拒绝系统库。不改原脚本，只生成本次运行的副本：
    # 把符号准入条件放宽到基础 API urma_init，其余逻辑/参数完全不动。
    ONEKEY_EFFECTIVE="${TMPDIR:-/tmp}/nof-vsegment-onekey.host-urma.sh"
    sed -e 's|urma_register_seg_dmabuf|urma_init|g' \
        -e 's|（旧版，缺 urma_init）|（host-only 下可用）|g' \
        -e 's|系统 /usr/lib64/liburma.so 是旧版，缺该符号，不能用于 930 分支。|host-only SPDK 已解耦 GDR：系统 /usr/lib64/liburma.so 可用；本副本只把库探测放宽为 urma_init。|' \
        "$ONEKEY" > "$ONEKEY_EFFECTIVE"
    bash -n "$ONEKEY_EFFECTIVE" || die "host-urma 补丁副本语法校验失败: $ONEKEY_EFFECTIVE"
    grep -q 'grep -q urma_init' "$ONEKEY_EFFECTIVE" \
        || die "host-urma 补丁未生效（未找到放宽后的库探测）: $ONEKEY_EFFECTIVE"
    ok "host-urma 补丁副本: $ONEKEY_EFFECTIVE"
    ok "原脚本未改动：$ONEKEY"
fi

ONEKEY_ARGS=(
    --src "$SRC_ROOT"
    --build-dir "$BUILD_DIR"
    --venv "$VENV"
    --umdk "$UMDK_PREFIX"
    --prefix "$INSTALL_PREFIX"
    --jobs "$JOBS"
)
if [ "$CLEAN_BUILD" = "true" ]; then ONEKEY_ARGS+=(--clean); fi

env \
    GIT_BRANCH="$GIT_BRANCH" \
    GIT_COMMIT="${GIT_COMMIT:-$CID}" \
    PATCH_930="$PATCH_930" \
    USE_ETCD="$USE_ETCD" \
    URMA_ROOT="$URMA_HEADER_DIR" \
    bash "$ONEKEY_EFFECTIVE" "${ONEKEY_ARGS[@]}"

# ============================================================================
# [2] 编译 mooncake_kvtest + 收集产物 + 验收
# ============================================================================
log "[2/3] 编译 mooncake_kvtest 并整理 k8s 产物"

# host-only：系统库目录优先，绝不把 GDR 定制库目录塞进 LD_LIBRARY_PATH
export LD_LIBRARY_PATH="$URMA_LIB_DIR":/usr/local/lib:/usr/local/lib64:/usr/lib64:${LD_LIBRARY_PATH:-}

# 不带 -D 参数重跑一次 configure：复用 CMakeCache 的全部已有设置，
# 但让 CMake 拾取新加的 add_subdirectory(kvtest)（增量 build 目录不会自动感知）
cmake -S "$SRC_ROOT" -B "$BUILD_DIR" >/dev/null \
    || die "cmake 重新配置失败（$BUILD_DIR），用 --clean 重跑"

cmake --build "$BUILD_DIR" -j"$JOBS" --target mooncake_kvtest \
    || die "mooncake_kvtest 编译失败
  常见原因：源码树 benchmarks/CMakeLists.txt 未加 add_subdirectory(kvtest)，
  或 build 目录是旧缓存 → 用 --clean 重跑"

ARCH="$(uname -m)"
BUNDLE="$OUTPUT_ROOT/mooncake-${CID}-${ARCH}-linux"
mkdir -p "$BUNDLE"/{bin,lib,dist} "$OUTPUT_ROOT"/{bin,lib,dist}

BUILT_BIN="$BUILD_DIR/mooncake-store/src"
BUILT_BENCH="$BUILD_DIR/mooncake-store/benchmarks"
cp -f "$BUILT_BIN/mooncake_master" "$BUILT_BIN/mooncake_client" \
      "$BUILT_BIN/nof_register" "$BUILT_BIN/nof_unregister" \
      "$BUILT_BENCH/stress_cluster_bench" \
      "$BUILT_BENCH/kvtest/mooncake_kvtest" "$BUNDLE/bin/"

for so in "$BUILD_DIR/mooncake-common/libasio.so" \
          "$BUILD_DIR/mooncake-common/etcd/libetcd_wrapper.so"; do
    [ -f "$so" ] && cp -f "$so" "$BUNDLE/lib/" || warn "跳过缺失的库: $so"
done

# host-only：产物包里只放 mooncake 自己的库；URMA 由镜像内系统包提供。
# 清掉上一轮 GDR 部署可能残留的定制 liburma 软链，避免 check-mooncake-ldd.sh
# 因为 outputs/lib 在 LD_LIBRARY_PATH 前面而误加载改造 so。
for stale in "$BUNDLE/lib"/liburma.so* "$OUTPUT_ROOT/lib"/liburma.so*; do
    [ -e "$stale" ] || [ -L "$stale" ] || continue
    warn "移除残留的定制 liburma: $stale"
    rm -f "$stale"
done

WHEEL_SRC="$SRC_ROOT/mooncake-wheel/dist"
if ls "$WHEEL_SRC"/mooncake_transfer_engine-*.whl >/dev/null 2>&1; then
    cp -f "$WHEEL_SRC"/mooncake_transfer_engine-*.whl "$BUNDLE/dist/"
    ok "wheel 已收集（第 2 步 runtime 镜像的 pip install 需要）"
else
    warn "没有 wheel（一键脚本默认不构建，且该环境 wheel+auditwheel 链路未跑通）
  cmake install 已把 store.so 装进 $VENV；但第 2 步 build-mooncake-runtime-image.sh 的 STEP 6
  会 pip install dist/*.whl 而失败。处置（二选一）：
    a) bash build_mooncake_930.sh --with-wheel  成功后重跑本脚本
    b) 改 runtime-image 脚本，跳过 pip install，直接 COPY venv 里的 mooncake 包"
fi

for d in bin lib dist; do
    for f in "$BUNDLE/$d"/*; do
        [ -e "$f" ] || continue
        ln -sfn "$(readlink -f "$f")" "$OUTPUT_ROOT/$d/$(basename "$f")"
    done
done
ok "产物目录: $BUNDLE"

# --- 验收 ---
log "验收"
MISS=0
for b in mooncake_master mooncake_client nof_register nof_unregister stress_cluster_bench mooncake_kvtest; do
    [ -x "$BUNDLE/bin/$b" ] && ok "$BUNDLE/bin/$b" || { warn "缺失 $b"; MISS=1; }
done
"$INSTALL_PREFIX/bin/mooncake_master" --version 2>&1 | sed 's/^/  /' \
    || { warn "mooncake_master --version 失败"; MISS=1; }
"$BUNDLE/bin/mooncake_kvtest" \
    "$KVTEST_DIR/config/writer.json.example" --check-config 2>&1 | sed 's/^/  /' \
    || { warn "mooncake_kvtest --check-config 失败"; MISS=1; }
"$VENV/bin/python" -c \
    'from mooncake.store import MooncakeDistributedNoFRegister; print("  store.so OK")' \
    || { warn "store.so 导入失败"; MISS=1; }
for b in mooncake_master mooncake_client mooncake_kvtest; do
    BAD="$(ldd "$BUNDLE/bin/$b" 2>/dev/null | grep 'not found' || true)"
    [ -z "$BAD" ] || { warn "$b 缺动态库: $BAD"; MISS=1; }
done
URMA_RESOLVED="$(ldd "$BUNDLE/bin/mooncake_master" 2>/dev/null \
    | grep 'liburma\.so' | tail -1 | awk '{print $3}' || true)"
echo "  mooncake_master → liburma: ${URMA_RESOLVED:-<未动态依赖>}"
if [ -n "${URMA_RESOLVED:-}" ] && [ "$URMA_MODE" = system ]; then
    case "$URMA_RESOLVED" in
        /usr/lib64/*|/lib64/*) ok "liburma 解析到系统库（容器/base image 需自带同款系统包）";;
        *) warn "liburma 解析到 $URMA_RESOLVED —— 不是系统库，容器里可能不存在
  检查 LD_LIBRARY_PATH / RPATH，确认没有把 GDR 定制库路径编进二进制";;
    esac
fi
[ "$MISS" = 0 ] || die "验收未通过（见上）"

log "第 1 步完成"
cat <<EOF

  产物：
    二进制(本机)  : $INSTALL_PREFIX/bin/
    产物包(打镜像): $BUNDLE
    软链          : $OUTPUT_ROOT/{bin,lib,dist}/

  URMA：$URMA_MODE 模式，$URMA_LIB_DIR/liburma.so + liburma_common.so*
    产物包内不含任何定制 liburma；镜像用基础镜像的系统 URMA 包。

  运行期环境（裸机 / 容器内一致，host-only）：
    export LD_LIBRARY_PATH=$URMA_LIB_DIR:/usr/local/lib:/usr/local/lib64:/usr/lib64
    export SPDK_URMA_DEV_NAME=udmac0d1e2 SPDK_URMA_CAPSULE_TRANSPORT=urma
    export MC_HIFREQ_LOG_SAMPLE_RATE=0 MC_SLICE_SIZE=1048576
    export MC_STORE_MEMCPY=1 MC_STORE_MEMCPY_INLINE=1

  第 2 步（镜像分发）：把 $BUNDLE 交给 build-mooncake-runtime-image.sh
    COMMIT_ID=$CID（产物目录名必须为 mooncake-$CID-$ARCH-linux）
    基础镜像检查清单：
      /usr/lib64/liburma.so*、/usr/lib64/liburma_common.so*、/usr/lib64/urma/
      urma_admin（k8s-mooncake_common.sh 会用它探测 URMA_DEVICE）
      SPDK nvmf_tgt / libspdk（③④ 起 NoF target 时才需要）
EOF
