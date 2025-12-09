#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>

#include <infiniband/verbs.h>

#include "common/rdma_type.h"
#include "core/atensor.h"
#include "core/shardedkey.h"
#include "protocol/messages.h"

namespace astate {

struct RemoteAddress {
    std::string host;
    int port{0};

    bool operator==(const RemoteAddress& other) const { return host == other.host && port == other.port; }
};

struct RemoteAddressHash {
    std::size_t operator()(const RemoteAddress& key) const {
        return std::hash<std::string>{}(key.host) ^ std::hash<int>{}(key.port);
    }
};

struct Buffer {
    void* addr;
    std::size_t len;

    Buffer(void* addr, std::size_t len)
        : addr(addr),
          len(len) {}
    bool operator==(const Buffer& o) const { return addr == o.addr && len == o.len; }
};

struct BufferHash {
    std::size_t operator()(const Buffer& b) const {
        return std::hash<void*>()(b.addr) ^ std::hash<std::size_t>()(b.len);
    }
};

/**
 * @brief Describes a memory region.
 */
struct MemRegionInfo {
    void* addr; ///< Pointer to the start of the memory region.
    std::size_t len; ///< Length of the memory region in bytes.
    int type; ///< Type of memory: RAM, VRAM, etc.
    int numa; ///< NUMA node ID (-1 if unspecified).
    int is_owned; ///< Whether the system should free this memory.
};

/**
 * @brief A structure representing a registered memory region with its keys.
 */
struct RegisteredMemRegion {
    MemRegionInfo mr;
    int register_num;
    std::unordered_map<int, ibv_mr*> devices;
};

struct RemoteNetAddress {
    std::string host;
    int port;
    bool operator==(const RemoteNetAddress& o) const { return host == o.host && port == o.port; }
};

struct TransferRequest {
    enum class OpCode : uint8_t { READ, WRITE };

    OpCode opcode{};
    void* local_mem_addr{};
    uint64_t remote_mem_addr{};
    size_t length{};

    RemoteNetAddress remote_net_addr;
};

// Hash function for NodeInfo(protocol::NodeInfo)
struct NodeInfoHash {
    std::size_t operator()(const NodeInfo& node_info) const {
        return std::hash<std::string>()(node_info.hostname_or_ip) ^ std::hash<int>()(node_info.rdma_port)
            ^ std::hash<int>()(node_info.ctrl_flow_port);
    }
};

struct TensorRDMAInfo {
    void* addr;
    size_t size;
    std::string rkey;
    NodeInfo node_info;

    std::shared_ptr<ATensor> atensor;

    TensorRDMAInfo()
        : addr(nullptr),
          size(0),
          node_info(),
          atensor(nullptr) {}

    TensorRDMAInfo(
        void* addr, size_t size, std::string rkey, NodeInfo node_info, std::shared_ptr<ATensor> atensor = nullptr)
        : addr(addr),
          size(size),
          rkey(std::move(rkey)),
          node_info(std::move(node_info)),
          atensor(std::move(atensor)) {}

    TensorRDMAInfo(void* addr, int size, std::string rkey, NodeInfo node_info, const ATensor& atensor_ref)
        : addr(addr),
          size(size),
          rkey(std::move(rkey)),
          node_info(std::move(node_info)),
          atensor(std::make_shared<ATensor>(atensor_ref)) {}

    [[nodiscard]] std::string ToString() const {
        return "TensorRDMAInfo(size=" + std::to_string(size) + ", node_info=" + node_info.ToString() + ")";
    }

    static TensorRDMAInfo CreateFromATensor(
        void* addr, size_t size, const std::string& rkey, const NodeInfo& node_info, const ATensor& atensor) {
        return {addr, size, rkey, node_info, std::make_shared<ATensor>(atensor)};
    }

    static TensorRDMAInfo
    CreateFromATensor(void* addr, size_t size, const std::string& rkey, const NodeInfo& node_info, ATensor&& atensor) {
        return {addr, size, rkey, node_info, std::make_shared<ATensor>(std::move(atensor))};
    }

    static TensorRDMAInfo CreateFromATensor(
        void* addr, size_t size, const std::string& rkey, const NodeInfo& node_info, std::shared_ptr<ATensor> atensor) {
        return {addr, size, rkey, node_info, std::move(atensor)};
    }

    // TODO(wuhanqing): remove unused code
    // TensorRDMAInfo(const TensorRDMAInfo& other) = default;
    // TensorRDMAInfo(TensorRDMAInfo&& other) noexcept = default;

    // TensorRDMAInfo& operator=(const TensorRDMAInfo& other) = default;
    // TensorRDMAInfo& operator=(TensorRDMAInfo&& other) noexcept = default;
};

using TransferTensorMeta = std::unordered_map<ShardedKey, std::vector<TensorRDMAInfo>, ShardedKeyHash>;
using TransferCache = std::unordered_map<int64_t, TransferTensorMeta>;

struct CompactTensorInfo {
    void* addr;
    size_t size;
    std::string rkey;
    NodeInfo node_info;
    std::unordered_map<ShardedKey, ATensor, ShardedKeyHash> atensors;
};

// Type conversion function implementations
inline TensorRDMAInfo
ConvertToTensorRDMAInfo(const TensorMemoryRDMAInfo& protocol_info, const NodeInfo& node_info, ATensor& atensor) {
    return TensorRDMAInfo{
        protocol_info.addr, protocol_info.size, protocol_info.rkey, node_info, std::make_shared<ATensor>(atensor)};
}

inline TensorMemoryRDMAInfo ConvertFromTensorRDMAInfo(const TensorRDMAInfo& rdma_info) {
    if (rdma_info.atensor == nullptr) {
        throw std::runtime_error("illegal state: TensorRDMAInfo has no ATensor");
    }

    return {rdma_info.addr, rdma_info.size, rdma_info.rkey, *rdma_info.atensor};
}

inline const std::vector<TensorRDMAInfo>*
GetTensorRDMAInfoVector(const ShardedKey& tensor_key, const TransferTensorMeta& tx_tensor_data) {
    auto rdma_info = tx_tensor_data.find(tensor_key);
    if (rdma_info != tx_tensor_data.end()) {
        return &(rdma_info->second);
    }
    return nullptr;
}

inline bool HasTensorRDMAInfo(const ShardedKey& tensor_key, const TransferTensorMeta& tx_tensor_data) {
    return tx_tensor_data.find(tensor_key) != tx_tensor_data.end();
}

inline void
AddTensorRDMAInfo(TransferTensorMeta& tx_tensor_data, const ShardedKey& tensor_key, TensorRDMAInfo&& rdma_info) {
    auto it = tx_tensor_data.find(tensor_key);
    if (it != tx_tensor_data.end()) {
        it->second.emplace_back(std::move(rdma_info));
    } else {
        std::vector<TensorRDMAInfo> vec;
        vec.emplace_back(std::move(rdma_info));
        tx_tensor_data.emplace(tensor_key, std::move(vec));
    }
}

inline void EmplaceTensorRDMAInfo(
    TransferTensorMeta& tx_tensor_data,
    const ShardedKey& tensor_key,
    void* addr,
    size_t size,
    const std::string& rkey,
    const NodeInfo& node_info,
    std::shared_ptr<ATensor> atensor = nullptr) {
    auto it = tx_tensor_data.find(tensor_key);
    if (it != tx_tensor_data.end() && it->second.size() > 0) {
        if (!it->second.back().atensor->IsShapeEqual(*atensor)) {
            SPDLOG_ERROR(
                "Tensor shape mismatch, tensor_key: {}, atensor: {}, "
                "node_info: {}:{}",
                tensor_key.key,
                atensor->GetTensorInfo(),
                node_info.hostname_or_ip,
                node_info.rdma_port);
            throw std::runtime_error("illegal state: Tensor shape mismatch");
        }
        it->second.emplace_back(addr, size, rkey, node_info, std::move(atensor));
    } else {
        std::vector<TensorRDMAInfo> vec;
        vec.emplace_back(addr, size, rkey, node_info, std::move(atensor));
        tx_tensor_data.emplace(tensor_key, std::move(vec));
    }
}
} // namespace astate
