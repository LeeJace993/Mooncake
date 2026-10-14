#include "../benchmarks/stress_bench_validation.h"
#include "nof_gpu_direct_report.h"
#include "gpu_direct_read.h"

#include <array>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {

void Require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

void TestGpuPaths() {
    mooncake::bench::GpuPathOptions path;
    path.mode = "gdr-peermem";
    path.protocol = "tcp";
    path.cuda_build = true;
    path.ub_build = true;
    path.nof_gpu_build = true;
    path.nof_gpu_available = true;
    path.require_direct = true;
    path.nof_replicas = true;
    Require(mooncake::bench::ValidateGpuPath(path).empty(),
            "pure NoF must allow TCP as the Store transport");
    path.memory_replicas = true;
    Require(!mooncake::bench::ValidateGpuPath(path).empty(),
            "TCP memory staging must not pass UB GDR validation");
    path.protocol = "ub";
    Require(mooncake::bench::ValidateGpuPath(path).empty(),
            "mixed UB memory and URMA NoF direct paths must be accepted");
    path.nof_gpu_build = false;
    Require(!mooncake::bench::ValidateGpuPath(path).empty(),
            "NoF GPU I/O must fail before submission without its build option");
    path.nof_gpu_build = true;
    path.mode = "staging";
    Require(!mooncake::bench::ValidateGpuPath(path).empty(),
            "memory staging cannot satisfy require_gpu_direct");
    path.memory_replicas = false;
    Require(mooncake::bench::ValidateGpuPath(path).empty(),
            "UB staging choice must not change the independent SPDK GPU path");
    path.mode = "host";
    Require(!mooncake::bench::ValidateGpuPath(path).empty(),
            "host buffers cannot satisfy require_gpu_direct");
    path.require_direct = false;
    path.cuda_build = false;
    path.ub_build = false;
    Require(mooncake::bench::ValidateGpuPath(path).empty(),
            "CPU-only builds must keep host benchmarks available");
}

void TestDirectReadSelection() {
    Require(mooncake::CanReadUbGpuDirect(true, "ub", "gdr-peermem", true,
                                       4096, 256, 1024),
            "registered GPU subranges must bypass the host read buffer");
    Require(!mooncake::CanReadUbGpuDirect(true, "ub", "gdr-peermem", false,
                                        4096, 256, 1024),
            "an unregistered GPU pointer must retain the staging path");
    Require(!mooncake::CanReadUbGpuDirect(true, "ub", "gdr-peermem", true,
                                        4096, 4097, 1),
            "offset overflow must not grant direct access");
    Require(!mooncake::CanReadUbGpuDirect(true, "ub", "gdr-peermem", true,
                                        4096, 4000, 1024),
            "direct reads must fit entirely in the registered range");
    Require(!mooncake::CanReadUbGpuDirect(true, "tcp", "gdr-peermem", true,
                                        4096, 0, 1024),
            "TCP reads must keep staging even when the UB mode is direct");
    Require(!mooncake::CanReadUbGpuDirect(true, "ub", "staging", true,
                                        4096, 0, 1024),
            "explicit staging must retain its host buffer");
    Require(!mooncake::CanReadUbGpuDirect(false, "ub", "gdr-peermem", true,
                                        4096, 0, 1024),
            "NoF/disk replicas must use their own read implementations");
}

void TestPlacement() {
    mooncake::bench::PlacementRegion region{1024, 4096, "endpoint-A", "ub"};
    Require(region.Contains(1024, 4096, "endpoint-A"), "full range is valid");
    Require(!region.Contains(1024, 4096, "endpoint-B"),
            "same address on a fallback endpoint is not the requested segment");
    Require(!region.Contains(1023, 8, "endpoint-A"), "lower bound must be checked");
    Require(!region.Contains(5120, 1, "endpoint-A"), "end address is exclusive");
    Require(!region.Contains(1024, std::numeric_limits<uint64_t>::max(), "endpoint-A"),
            "overflowing lengths must be rejected");
    region.base = std::numeric_limits<uint64_t>::max() - 4096;
    Require(region.Contains(region.base + 2048, 2048, "endpoint-A"),
            "range containment must avoid overflowing base+length arithmetic");
}

void TestPayloadAndExitStatus() {
    std::array<unsigned char, 19> data{};
    mooncake::bench::FillPattern(data.data(), data.size(), 7);
    Require(mooncake::bench::CheckPattern(data.data(), data.size(), data.size(), 7),
            "unaligned value sizes must round-trip");
    Require(!mooncake::bench::CheckPattern(data.data(), 8, data.size(), 7),
            "a successful short read must fail verification");
    Require(!mooncake::bench::CheckPattern(data.data(), data.size(), data.size(), 8),
            "the wrong segment key seed must fail verification");
    data.back() = 1;
    Require(!mooncake::bench::CheckPattern(data.data(), data.size(), data.size(), 7),
            "corruption in trailing bytes must be detected");
    Require(mooncake::bench::ExitCode(0) == 0, "successful operations must exit zero");
    Require(mooncake::bench::ExitCode(1) != 0, "read/remove failures must exit nonzero");
    Require(mooncake::bench::ExitCode(0, -1) != 0,
            "verification failure must propagate to the process exit status");
}

void TestGpuAcceptance() {
    mooncake::NofGpuDirectStats stats;
    stats.available = true;
    stats.writes = {128, 128, 0};
    stats.peer_memory_registrations = 1;
    Require(mooncake::NofGpuDirectPassed(stats, false, true),
            "one cached GPU registration may serve many successful writes");
    Require(!mooncake::NofGpuDirectPassed(stats, true, true),
            "a write-only run must not satisfy a read acceptance requirement");
    stats.writes.success = 127;
    Require(!mooncake::NofGpuDirectPassed(stats, false, true),
            "accepted submissions without all completions must fail");
    stats.writes.success = 128;
    stats.writes.failed = 1;
    Require(!mooncake::NofGpuDirectPassed(stats, false, true),
            "failed completions must be reported");
    stats.writes.failed = 0;
    stats.peer_memory_registrations = 0;
    stats.accelerator_attempts = 128;
    stats.dmabuf_exports = 128;
    Require(!mooncake::NofGpuDirectPassed(stats, false, true),
            "registration attempts and DMA-BUF exports do not prove registration");
    stats.dmabuf_registrations = 1;
    stats.staged_bytes = 4096;
    Require(!mooncake::NofGpuDirectPassed(stats, false, true),
            "host staging must fail direct acceptance");
    stats.staged_bytes = 0;
    stats.registration_failures = 1;
    Require(!mooncake::NofGpuDirectPassed(stats, false, true),
            "registration failures must fail acceptance");
}

}  // namespace

int main() {
    try {
        TestGpuPaths();
        TestDirectReadSelection();
        TestPlacement();
        TestPayloadAndExitStatus();
        TestGpuAcceptance();
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
    std::cout << "stress benchmark validation: PASS\n";
    return 0;
}
