#include "nof_pool.h"

#include <glog/logging.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <set>
#include <sstream>
#include <utility>
#include <vector>

#include "master_client.h"
#include "nof_memory_pool.h"
#include "types.h"

namespace mooncake::kvtest {
namespace {

#if defined(USE_NOF_URMA)
// Mirror of stress_cluster_bench's IsUrmaEndpoint: the NoF segment's
// transfer endpoint carries its fabric type in the trtype:URMA token.
bool IsUrmaEndpoint(const std::string &endpoint) {
    std::istringstream tokens(endpoint);
    std::string token;
    while (tokens >> token) {
        if (token == "trtype:URMA") return true;
    }
    return false;
}

// Process-lifetime registration state (mirror of the bench's
// nof_pool_tokens_ / registered_nof_pools_). Tokens are released via
// ReleaseNofPoolTokens() before the buffers are freed.
std::mutex &NofPoolMutex() {
    static std::mutex mutex;
    return mutex;
}

std::vector<std::shared_ptr<void>> &NofPoolTokens() {
    static std::vector<std::shared_ptr<void>> tokens;
    return tokens;
}

std::set<std::string> &NofPoolRegistered() {
    static std::set<std::string> registered;
    return registered;
}
#endif

}  // namespace

bool EnsureNofWholePoolRegistered(
    const std::string &master_server_address,
    const std::vector<std::pair<void *, size_t>> &buffers,
    std::string *error) {
#if defined(USE_NOF_URMA)
    if (!mooncake::NofWholePoolRegistrationAvailable()) {
        *error =
            "NoF whole-pool registration is unavailable in this SPDK build; "
            "refusing per-I/O registration because large batches can exceed "
            "the URMA registration cache";
        return false;
    }
    auto master =
        std::make_unique<mooncake::MasterClient>(mooncake::generate_uuid());
    if (master->Connect(master_server_address) != mooncake::ErrorCode::OK) {
        *error = "Cannot connect to master for NoF whole-pool registration: " +
                 master_server_address;
        return false;
    }
    auto segments = master->GetAllNoFSegments();
    if (!segments || segments->empty()) {
        *error =
            "No mounted NoF segments available for whole-pool registration "
            "(master has not mounted any NoF segment yet)";
        return false;
    }
    std::lock_guard<std::mutex> lock(NofPoolMutex());
    size_t matching_endpoints = 0;
    size_t new_registrations = 0;
    for (const auto &segment : *segments) {
        if (!IsUrmaEndpoint(segment.te_endpoint)) {
            VLOG(1) << "Skipping whole-pool registration for non-URMA NoF "
                       "segment " << segment.name;
            continue;
        }
        ++matching_endpoints;
        for (const auto &buffer : buffers) {
            const std::string id =
                segment.te_endpoint + ":buffer=" +
                std::to_string(reinterpret_cast<uintptr_t>(buffer.first));
            if (NofPoolRegistered().count(id) != 0) continue;
            auto token = mooncake::RegisterNofMemoryPool(
                segment.te_endpoint, buffer.first, buffer.second);
            if (!token) {
                *error = "NoF whole-pool registration was available but "
                         "failed for segment " +
                         segment.name;
                return false;
            }
            NofPoolTokens().push_back(std::move(token));
            NofPoolRegistered().insert(id);
            ++new_registrations;
        }
    }
    if (matching_endpoints == 0) {
        *error = "No matching URMA NoF segments for whole-pool registration";
        return false;
    }
    LOG(INFO) << "NoF whole-pool registered endpoints=" << matching_endpoints
              << " buffers=" << buffers.size()
              << " new_registrations=" << new_registrations;
    return true;
#else
    (void)master_server_address;
    (void)buffers;
    *error = "NoF whole-pool registration requested without USE_NOF_URMA";
    return false;
#endif
}

void ReleaseNofPoolTokens() {
#if defined(USE_NOF_URMA)
    std::lock_guard<std::mutex> lock(NofPoolMutex());
    NofPoolTokens().clear();
    NofPoolRegistered().clear();
#endif
}

}  // namespace mooncake::kvtest
