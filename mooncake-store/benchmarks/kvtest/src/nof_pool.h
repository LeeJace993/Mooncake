/**
 * nof_pool.h — kvtest NoF whole-pool registration (vsegment medium=nof).
 *
 * Mirrors stress_cluster_bench::EnsureNofPools: registers kvtest-owned
 * buffers against every mounted URMA NoF segment once, up front, so the
 * URMA registration cache stays flat and the per-qpair first-touch
 * urma_register_seg cost stays out of the measured window. See
 * 6.mooncake-vesegment/k8s_deploy/kvtest-nof-vsegment-adaptation.md and
 * vsegment_read_failed/exp5_wholepool_verify/ for the measured rationale.
 */
#pragma once

#include <cstddef>
#include <string>
#include <utility>
#include <vector>

namespace mooncake::kvtest {

/// Registers the given process-owned buffers against every mounted URMA NoF
/// segment. VSegment placement is chosen by the master's vsegment profile,
/// so every mounted URMA endpoint is covered (no per-segment filtering).
/// Returns false on any failure and fills *error: a per-I/O registration
/// fallback is deliberately refused because large batches can exhaust the
/// URMA registration cache (exp5: 21336 registrations before the fix).
bool EnsureNofWholePoolRegistered(
    const std::string &master_server_address,
    const std::vector<std::pair<void *, size_t>> &buffers,
    std::string *error);

/// Releases the registration tokens. Must be called before the registered
/// buffers are freed (ownership contract in nof_memory_pool.h).
void ReleaseNofPoolTokens();

}  // namespace mooncake::kvtest
