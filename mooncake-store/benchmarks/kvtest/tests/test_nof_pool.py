"""Run the production pool-registration helper with a connected-client fixture.

No etcd server, SPDK library or URMA hardware is required. The fixture supplies
the client-discovery and provider boundaries; the registration loop is real.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "src"


class NofPoolTests(unittest.TestCase):
    def test_connected_client_registration_and_token_lifetime(self):
        compiler = shutil.which("g++")
        if not compiler:
            self.skipTest("g++ is required")
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "glog").mkdir()
            (work / "glog/logging.h").write_text(
                "#pragma once\n#include <iostream>\n"
                "#define LOG(level) std::cerr\n#define VLOG(level) std::cerr\n"
            )
            (work / "real_client.h").write_text(r'''
#pragma once
#include <optional>
#include <string>
#include <vector>
namespace mooncake {
struct NoFSegment { std::string name, te_endpoint; };
class RealClient {
 public:
    std::optional<std::vector<NoFSegment>> segments;
    unsigned queries = 0;
    auto GetAllNoFSegments() { ++queries; return segments; }
};
}
''')
            (work / "nof_memory_pool.h").write_text(r'''
#pragma once
#include <cstddef>
#include <memory>
#include <string>
namespace mooncake {
bool NofWholePoolRegistrationAvailable();
std::shared_ptr<void> RegisterNofMemoryPool(const std::string&, void*, size_t);
}
''')
            (work / "test.cpp").write_text(r'''
#include "nof_pool.h"
#include "real_client.h"
#include <cassert>
#include <memory>
#include <string>
#include <vector>
namespace mooncake {
bool available = true, fail_registration = false;
unsigned registrations = 0, live = 0;
bool NofWholePoolRegistrationAvailable() { return available; }
std::shared_ptr<void> RegisterNofMemoryPool(const std::string&, void* p, size_t) {
    if (fail_registration) return {};
    ++registrations; ++live;
    return {p, [](void*) { --live; }};
}
}
int main() {
    using namespace mooncake;
    using namespace mooncake::kvtest;
    RealClient client;
    char first[128], second[128];
    std::vector<std::pair<void*, size_t>> buffers = {
        {first, sizeof(first)}, {second, sizeof(second)}};
    std::string error;
#ifdef USE_NOF_URMA
    available = false;
    assert(!EnsureNofWholePoolRegistered(client, buffers, &error));
    assert(client.queries == 0);
    available = true;
    assert(!EnsureNofWholePoolRegistered(client, buffers, &error));
    assert(error.find("connected client") != std::string::npos);
    client.segments = std::vector<NoFSegment>{};
    assert(!EnsureNofWholePoolRegistered(client, buffers, &error));
    client.segments = std::vector<NoFSegment>{{"tcp", "trtype:TCP"}};
    assert(!EnsureNofWholePoolRegistered(client, buffers, &error));
    client.segments = std::vector<NoFSegment>{
        {"a", "trtype:URMA traddr:a"}, {"b", "trtype:URMA traddr:b"},
        {"tcp", "trtype:TCP"}};
    assert(EnsureNofWholePoolRegistered(client, buffers, &error));
    assert(registrations == 4 && live == 4);
    assert(EnsureNofWholePoolRegistered(client, buffers, &error));
    assert(registrations == 4 && live == 4);
    // Every call reads the connected client's current view, not a saved address.
    client.segments = std::vector<NoFSegment>{{"c", "trtype:URMA traddr:c"}};
    assert(EnsureNofWholePoolRegistered(client, buffers, &error));
    assert(registrations == 6 && live == 6);
    client.segments = std::vector<NoFSegment>{{"d", "trtype:URMA traddr:d"}};
    fail_registration = true;
    assert(!EnsureNofWholePoolRegistered(client, buffers, &error));
    assert(live == 6);
    ReleaseNofPoolTokens();
    assert(live == 0);
    fail_registration = false;
    assert(EnsureNofWholePoolRegistered(client, buffers, &error));
    assert(registrations == 8 && live == 2);
    ReleaseNofPoolTokens();
    ReleaseNofPoolTokens();
    assert(live == 0);
#else
    assert(!EnsureNofWholePoolRegistered(client, buffers, &error));
    assert(client.queries == 0 && live == 0);
    assert(error.find("without USE_NOF_URMA") != std::string::npos);
#endif
}
''')
            for urma in (True, False):
                with self.subTest(urma=urma):
                    binary = work / ("urma" if urma else "no-urma")
                    command = [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                               "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                               "-I" + str(work), "-I" + str(SOURCE),
                               str(SOURCE / "nof_pool.cpp"), str(work / "test.cpp"),
                               "-o", str(binary)]
                    if urma:
                        command.append("-DUSE_NOF_URMA")
                    built = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    ran = subprocess.run([str(binary)], capture_output=True, text=True)
                    self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)


if __name__ == "__main__":
    unittest.main()
