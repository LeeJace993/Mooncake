// NoF build options must not change ordinary client-buffer payload lengths.
#include "client_buffer.h"

#include <glog/logging.h>
#include <gtest/gtest.h>

#include <array>
#include <cstddef>
#include <cstring>
#include <vector>

namespace mooncake {

class NofBufferAlignmentTest : public ::testing::Test {
   protected:
    void SetUp() override {
        google::InitGoogleLogging("NofBufferAlignmentTest");
        FLAGS_logtostderr = 1;
    }
    void TearDown() override { google::ShutdownGoogleLogging(); }
};

TEST_F(NofBufferAlignmentTest, OrdinaryAllocationKeepsLogicalSize) {
    auto allocator = ClientBufferAllocator::create(4 * 1024 * 1024, "", false,
                                                   /*use_spdk_dma=*/false);
    ASSERT_NE(allocator, nullptr);
    EXPECT_EQ(reinterpret_cast<uintptr_t>(allocator->getBase()) % 64, 0u);
    for (size_t size : {1u, 63u, 64u, 511u, 512u, 513u, 4095u, 4096u, 4097u,
                        128u * 1024, 1024u * 1024}) {
        SCOPED_TRACE(size);
        auto handle = allocator->allocate(size);
        ASSERT_TRUE(handle.has_value());
        EXPECT_EQ(handle->size(), size);
        auto slices = split_into_slices(*handle);
        size_t payload_size = 0;
        for (const auto& slice : slices) payload_size += slice.size;
        EXPECT_EQ(payload_size, size);
    }
}

TEST_F(NofBufferAlignmentTest, SmallValuesShareAnExternalBufferWithoutPadding) {
    alignas(64) std::array<unsigned char, 4096> buffer{};
    auto allocator =
        ClientBufferAllocator::create(buffer.data(), buffer.size());
    ASSERT_NE(allocator, nullptr);
    std::vector<BufferHandle> handles;
    for (unsigned char value = 1; value <= 8; ++value) {
        auto handle = allocator->allocate(64);
        ASSERT_TRUE(handle.has_value());
        ASSERT_EQ(handle->size(), 64u);
        std::memset(handle->ptr(), value, handle->size());
        handles.push_back(std::move(*handle));
    }
    for (size_t i = 0; i < handles.size(); ++i) {
        EXPECT_EQ(static_cast<unsigned char*>(handles[i].ptr())[0], i + 1);
    }
}

TEST_F(NofBufferAlignmentTest, NofSectorSizedPayloadIsNotExpandedToFourKiB) {
    alignas(4096) std::array<unsigned char, 8192> buffer{};
    auto allocator =
        ClientBufferAllocator::create(buffer.data(), buffer.size());
    auto first = allocator->allocate(512);
    auto second = allocator->allocate(512);
    ASSERT_TRUE(first.has_value());
    ASSERT_TRUE(second.has_value());
    EXPECT_EQ(first->size(), 512u);
    EXPECT_EQ(second->size(), 512u);
    EXPECT_EQ(reinterpret_cast<uintptr_t>(first->ptr()) % 512, 0u);
    EXPECT_EQ(reinterpret_cast<uintptr_t>(second->ptr()) % 512, 0u);
}

}  // namespace mooncake

int main(int argc, char** argv) {
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
