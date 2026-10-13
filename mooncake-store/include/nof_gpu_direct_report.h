/**
 * nof_gpu_direct_report.h
 * Modified By Yida (v3): NoF GPU Direct 验收输出接口（外部审阅 #3）。
 *
 * 把 SPDK GPU Direct 的可用性、buffer-domain 识别统计与 SPDK URMA 注册
 * 统计暴露给 bench 等验收方，避免"bench 打印了 gdr-peermem"被当成
 * "SPDK 真的用了 GPU I/O"的证据。
 *
 * SPDK-free 头：本头文件不包含任何 SPDK 头，无 SPDK include 路径的目标
 * 可以安全包含。实现在 nof_memory_domain.cpp，仅于 USE_NOF_URMA 构建中
 * 编译——调用方必须用 #if defined(USE_NOF_URMA) 守卫，否则非 URMA 构建
 * 会产生未定义符号链接错误。
 */
#pragma once

#include <string>

namespace mooncake {

/// NoF GPU Direct 是否可用（USE_NOF_GPU_DIRECT + CUDA provider 可用）。
/// 仅在 USE_NOF_URMA 构建中有定义。
bool NofGpuDirectAvailable();

/**
 * @brief 一次性验收输出（多行，无尾随换行）。
 *
 * 内容（对应审阅意见 #3 及其复审）：
 *   - gpu_direct_available / reg_mode（MC_NOF_GPU_REG_MODE）
 *   - buffer-domain 识别统计：host_io / cuda_io_submitted /
 *     cuda_io_success / classify_fail。
 *     计数口径：cuda_io_submitted 是**提交口径**（SubmitRequest 返回成功
 *     即计数），>0 仅说明 SPDK 接受过 CUDA memory-domain I/O 提交，不证明
 *     请求最终完成成功；cuda_io_success 是**完成口径**（SPDK completion
 *     无错误计数），是 GPU I/O 真正成功的证据。两者不可混用。注意
 *     cuda_io_success 按 SPDK 子任务 chunk 计，不是完整 value/object 数，
 *     验收时结合 bench 的操作成功/失败统计解读。
 *   - GPU Direct 过程统计：dmabuf_exports（CUDA DMA-BUF 导出成功次数，
 *     导出后 SPDK 注册仍可能失败或回退 peer-memory，注册结果看
 *     spdk_urma_regs.dmabuf）/ gpu_staging_fallbacks / staged_bytes
 *   - SPDK URMA 注册统计：host / accelerator_attempts（**尝试数**——
 *     SPDK 在 provider 检查与注册之前即递增，nvme_urma_common.c:368；
 *     注册成功 = dmabuf + peer_memory，失败看 failures）/
 *     dmabuf / peer_memory / failures
 */
std::string NofGpuDirectAcceptanceReport();

}  // namespace mooncake
