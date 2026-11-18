/**
 * nof_memory_pool.h — NoF whole-pool host memory registration.
 *
 * SPDK-free 头：不包含任何 SPDK 头，无 SPDK include 路径的目标可以安全
 * 包含。实现在 spdk_wrapper.cpp，仅于 USE_NOF_URMA 构建中编译——调用方
 * 必须用 #if defined(USE_NOF_URMA) 守卫，否则非 URMA 构建会产生未定义
 * 符号链接错误。
 *
 * 这里是 host 内存整池注册（spdk_nvme_urma_register_memory_for_qpair，
 * 单 lane 注册、region 按 urma_context 全 lane 共享、常驻不随 I/O 释放），
 * 与 GPU Direct / CUDA / dmabuf 无关；GDR 验收统计见 nof_gpu_direct_report.h。
 */
#pragma once

#include <cstddef>
#include <memory>
#include <string>

namespace mooncake {

bool NofWholePoolRegistrationAvailable();
// Caller must drain I/O, release this token, then unregister/free the buffer.
std::shared_ptr<void> RegisterNofMemoryPool(const std::string& endpoint,
                                           void* buffer, size_t size);

}  // namespace mooncake
