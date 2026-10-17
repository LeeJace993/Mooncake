#include <glog/logging.h>

#include <charconv>
#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <string>
#include <string_view>
#include <system_error>

#include "master_client.h"
#include "ssd_register_client.h"
#include "types.h"

namespace {

bool ParseSize(std::string_view text, size_t* value) {
    if (text.empty()) return false;
    const char* begin = text.data();
    const char* end = begin + text.size();
    auto [ptr, error] = std::from_chars(begin, end, *value);
    return error == std::errc{} && ptr == end;
}

void PrintUsage(const char* program) {
    std::cerr << "Usage:\n"
              << "  " << program
              << " <nqn> <nsid> <traddr> <trsvcid> <trtype> "
                 "<master_addr>\n"
              << "  " << program << " --list [master_addr]\n";
}

std::string DefaultMasterAddress() {
    const char* address = std::getenv("MC_MASTER_SERVER_ADDR");
    return address && address[0] != '\0'
               ? address
               : mooncake::DEFAULT_MASTER_SERVER_ADDR;
}

int ListSegments(const std::string& master_address) {
    mooncake::MasterClient client(mooncake::generate_uuid(), nullptr);
    const auto connect_result = client.Connect(master_address);
    if (connect_result != mooncake::ErrorCode::OK) {
        std::cerr << "Failed to connect to master " << master_address
                  << ": " << static_cast<int>(connect_result) << '\n';
        return 1;
    }

    auto segments_result = client.GetAllNoFSegments();
    if (!segments_result) {
        std::cerr << "Failed to list NoF segments: "
                  << static_cast<int>(segments_result.error()) << '\n';
        return 1;
    }

    const auto& segments = segments_result.value();
    std::cout << "Registered NoF segments: " << segments.size() << '\n';
    for (const auto& segment : segments) {
        std::cout << "id=" << segment.id << " name=" << segment.name
                  << " base=" << segment.base << " size=" << segment.size
                  << " endpoint=" << segment.te_endpoint << '\n';
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    google::InitGoogleLogging(argv[0]);
    FLAGS_logtostderr = true;

    if (argc >= 2 && std::string_view(argv[1]) == "--list") {
        if (argc > 3) {
            PrintUsage(argv[0]);
            return 2;
        }
        return ListSegments(argc == 3 ? argv[2] : DefaultMasterAddress());
    }

    if (argc != 7) {
        PrintUsage(argv[0]);
        return 2;
    }

    size_t nsid = 0;
    size_t trsvcid = 0;
    if (!ParseSize(argv[2], &nsid) || nsid == 0 ||
        !ParseSize(argv[4], &trsvcid) || trsvcid == 0) {
        std::cerr << "Invalid nsid or trsvcid\n";
        PrintUsage(argv[0]);
        return 2;
    }

    mooncake::NoFRegisterClient client;
    const int result = client.set_unregister_by_endpoint(
        argv[1], nsid, argv[3], trsvcid, argv[5], argv[6]);
    if (result != OPERATION_OK) {
        std::cerr << "NoF unregistration failed\n";
        return 1;
    }

    std::cout << "NoF unregistration succeeded\n";
    return 0;
}
