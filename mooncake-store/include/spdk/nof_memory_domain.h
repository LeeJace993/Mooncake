/**
 * nof_memory_domain.h
 * Modified By Yida (v3): NoF GPU Direct —— buffer 类型识别与 SPDK memory
 * domain 管理。
 *
 * 职责（对应 docs/mooncakeEnablenof.md 8.9.4）：
 *   1. 调用 Store 已有 accelerator 接口严格识别 pointer；
 *   2. 为每张 GPU 创建并缓存一个 SPDK memory_domain（命名 cuda:mooncake:<id>，
 *      dma_device_id 含 "cuda"，SPDK URMA 侧据此选择 CUDA 内存注册）；
 *   3. 向 SPDK 提供 GPU 内存注册所需的 pin / DMA-BUF export / unpin 回调
 *      （spdk_nvme_urma_memory_provider，进程级注册一次）。
 *
 * 错误策略（8.9.7）：已识别为 GPU 的 buffer 若 provider/domain 初始化失败，
 * 返回错误，绝不静默回退 host staging。
 */
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>

#include <spdk/dma.h>
#include <spdk/env.h>
#include <spdk/nvme_urma.h>

namespace mooncake {

enum class NofMemoryType {
    kHost,          ///< 普通 CPU 内存：走非 ext 提交（SPDK 按HOST注册）
    kCuda,          ///< NVIDIA 设备内存：GPU Direct 提交
    kRocm,          ///< 预留：同一框架后续接入
    kNpu,           ///< 预留：同一框架后续接入
    kNotSupported,  ///< 识别为受管设备内存，但本进程未实现对应 provider
    kError,         ///< 探测/初始化错误：禁止静默回退 host staging
};

struct NofBufferInfo {
    NofMemoryType type = NofMemoryType::kHost;
    int32_t device_id = -1;                 ///< CPU 为 -1，GPU 例如 0、1
    struct spdk_memory_domain *domain = nullptr;  ///< 传给 SPDK ext I/O
};

class NofMemoryDomainManager {
   public:
    static NofMemoryDomainManager &GetInstance();
    ~NofMemoryDomainManager();

    NofMemoryDomainManager(const NofMemoryDomainManager &) = delete;
    NofMemoryDomainManager &operator=(const NofMemoryDomainManager &) = delete;

    /**
     * @brief 自动识别 pointer 类型并解析出对应的 memory domain。
     *
     * 返回 kHost 时 domain 可能为 system domain；返回 kCuda 时 domain 为
     * 该 GPU 对应的 vendor-specific domain（cuda:mooncake:<id>）。
     * 返回 kError / kNotSupported 时不应继续提交 NoF I/O。
     */
    NofBufferInfo ResolveBuffer(void *ptr, size_t length);

    /// GPU Direct 是否可用（CUDA provider + 至少一张可用 GPU）
    bool IsGpuDirectAvailable() const;

    /// 验收指标（8.9.7）
    uint64_t host_io_total() const { return host_io_total_.load(std::memory_order_relaxed); }
    uint64_t cuda_io_total() const { return cuda_io_total_.load(std::memory_order_relaxed); }
    uint64_t classify_fail_total() const { return classify_fail_total_.load(std::memory_order_relaxed); }
    uint64_t dmabuf_registration_total() const {
        return dmabuf_registration_total_.load(std::memory_order_relaxed);
    }
    uint64_t gpu_staging_fallback_total() const {
        return gpu_staging_fallback_total_.load(std::memory_order_relaxed);
    }
    uint64_t payload_staged_bytes() const {
        return payload_staged_bytes_.load(std::memory_order_relaxed);
    }

    void OnIoSubmitted(const NofBufferInfo &info) {
        if (info.type == NofMemoryType::kCuda) {
            cuda_io_total_.fetch_add(1, std::memory_order_relaxed);
        } else if (info.type == NofMemoryType::kHost) {
            host_io_total_.fetch_add(1, std::memory_order_relaxed);
        }
    }
    void OnClassifyFail() { classify_fail_total_.fetch_add(1, std::memory_order_relaxed); }
    void OnDmabufRegistration() {
        dmabuf_registration_total_.fetch_add(1, std::memory_order_relaxed);
    }
    void OnGpuStagingFallback() {
        gpu_staging_fallback_total_.fetch_add(1, std::memory_order_relaxed);
    }
    void AddPayloadStagedBytes(uint64_t bytes) {
        payload_staged_bytes_.fetch_add(bytes, std::memory_order_relaxed);
    }

    /// 供验收脚本查询：SPDK URMA 注册统计（dmabuf/peer/失败次数）
    static void GetUrmaMemoryStats(struct spdk_nvme_urma_memory_stats *stats);

   private:
    NofMemoryDomainManager() = default;

    struct spdk_memory_domain *GetOrCreateCudaDomain(int32_t device_id,
                                                     std::string &error);

    std::mutex mutex_;
    std::unordered_map<int32_t, struct spdk_memory_domain *> cuda_domains_;
    bool provider_registered_ = false;

    std::atomic<uint64_t> host_io_total_{0};
    std::atomic<uint64_t> cuda_io_total_{0};
    std::atomic<uint64_t> classify_fail_total_{0};
    std::atomic<uint64_t> dmabuf_registration_total_{0};
    std::atomic<uint64_t> gpu_staging_fallback_total_{0};
    std::atomic<uint64_t> payload_staged_bytes_{0};
};

}  // namespace mooncake
