#include <glog/logging.h>

#include <charconv>
#include <cstddef>
#include <iostream>
#include <string>
#include <string_view>
#include <system_error>

#include "ssd_register_client.h"

namespace {

constexpr size_t kDefaultSegmentSize = 1ULL << 40;  // 1 TiB

bool ParseSize(std::string_view text, size_t* value) {
    if (text.empty()) return false;
    const char* begin = text.data();
    const char* end = begin + text.size();
    auto [ptr, error] = std::from_chars(begin, end, *value);
    return error == std::errc{} && ptr == end;
}

void PrintUsage(const char* program) {
    std::cerr << "Usage: " << program
              << " <nqn> <nsid> <traddr> <trsvcid> <trtype> <master_addr> "
                 "[size_bytes]\n";
}

}  // namespace

int main(int argc, char** argv) {
    google::InitGoogleLogging(argv[0]);
    FLAGS_logtostderr = true;

    if (argc != 7 && argc != 8) {
        PrintUsage(argv[0]);
        return 2;
    }

    size_t nsid = 0;
    size_t trsvcid = 0;
    size_t size = kDefaultSegmentSize;
    if (!ParseSize(argv[2], &nsid) || nsid == 0 ||
        !ParseSize(argv[4], &trsvcid) || trsvcid == 0 ||
        (argc == 8 && (!ParseSize(argv[7], &size) || size == 0))) {
        std::cerr << "Invalid nsid, trsvcid, or size_bytes\n";
        PrintUsage(argv[0]);
        return 2;
    }

    mooncake::NoFRegisterClient client;
    const int result = client.set_register(
        argv[1], nsid, argv[3], trsvcid, argv[5], 0, size, argv[6]);
    if (result != OPERATION_OK) {
        std::cerr << "NoF registration failed\n";
        return 1;
    }

    std::cout << "NoF registration succeeded\n";
    return 0;
}
