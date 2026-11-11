#pragma once

#include <cstdlib>
#include <cstring>

namespace mooncake::vsegment {

// vsegment oplog 模式开关（进程启动时读取一次，运行期不可切换）：
//   full    （默认）：保持现状 —— 每次 put 提交 2 条 O(N) 的 VSEGMENT_STATE
//   aligned         ：put 热路径只写 1 条 O(1) 的 VSEGMENT_RESERVE（+ 对象 PUT_END），
//                     分配器状态退化为纯内存，重启由 checkpoint + 对象元数据
//                     reconcile + RESERVE/RELEASE 重放共同重建。
//
// 详见 tasks/任务-性能优化-20261109/提案-vsegment-oplog对齐-v2-20261110.md
inline bool VSegmentOplogAlignedMode() {
    static const bool aligned = [] {
        const char* value = std::getenv("MC_VSEGMENT_OPLOG_MODE");
        if (value == nullptr || *value == '\0') {
            return false;  // 默认 full：零行为变化
        }
        return std::strcmp(value, "aligned") == 0;
    }();
    return aligned;
}

}  // namespace mooncake::vsegment
