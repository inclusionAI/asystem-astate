#pragma once

#include <any>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

#include <spdlog/spdlog.h>

#include "common/numa_aware_allocator.h"
#include "common/option.h"
#include "common/rdma_type.h"
#include "core/atensor.h"
#include "transfer/types.h"
#include "transport/base_transport.h"

namespace astate {

/*
 * RDMATransporter is a transport service that uses RDMA to transfer data.
 */
class RDMATransporter : public BaseDataTransport {
 public:
    RDMATransporter() = default;

    ~RDMATransporter() override;

    RDMATransporter(const RDMATransporter&) = delete;
    RDMATransporter& operator=(const RDMATransporter&) = delete;
    RDMATransporter(RDMATransporter&&) = delete;
    RDMATransporter& operator=(RDMATransporter&&) = delete;

    ////////////////////// Override BaseTransport methods //////////////////////
    [[nodiscard]] bool Start(const Options& options, const AParallelConfig& parallel_config) override;

    void Stop() override;

    [[nodiscard]] bool Send(
        const void* local_addr,
        size_t send_size,
        const std::string& remote_host,
        int remote_port,
        const ExtendInfo* extend_info) override;

    [[nodiscard]] bool Receive(
        const void* local_addr,
        size_t recv_size,
        const std::string& remote_host,
        int remote_port,
        const ExtendInfo* extend_info) override;

    void AsyncSend(
        const void* local_addr,
        size_t send_size,
        const std::string& remote_host,
        int remote_port,
        const ExtendInfo* extend_info,
        const SendCallback& callback) override;

    void AsyncReceive(
        const void* local_addr,
        size_t recv_size,
        const std::string& remote_host,
        int remote_port,
        const ExtendInfo* extend_info,
        const ReceiveCallback& callback) override;

    ////////////////////// RDMA specific methods //////////////////////
    /*
     * Register memory region
     * @param addr: memory address
     * @param len: memory length
     * @param is_vram: whether the memory is in VRAM
     * @param gpu_id_or_numa_node: GPU ID or NUMA node
     * @return true if registration successful, false otherwise
     * @throws std::runtime_error if memory registration fails
     */
    bool RegisterMemory(void* addr, size_t len, bool is_vram = false, int gpu_id_or_numa_node = -1);

    /*
     * Deregister memory region
     * @param addr: memory address
     * @param len: memory length
     * @return deregistered memory region
     */
    bool DeregisterMemory(void* addr, size_t len);

    ////////////////////// Getters //////////////////////
    int GetWriteTimeout() const { return write_timeout_ms_; }
    int GetReadTimeout() const { return read_timeout_ms_; }
    std::string GetLocalServerName() const { return local_server_name_; }
    int GetBindPort() const override { return local_server_port_; }
    std::string GetMetaAddr() const { return meta_addr_; }

 protected:
    static constexpr int kRdmaPortStart = 51010;

    /*
     * Setup RPC server with port retry mechanism
     * @param utrans_config: utrans configuration
     * @return true if setup successful, false otherwise
     */
    bool SetupRpcServerWithRetry(utrans_config_t& utrans_config);

    /*
     * Select RDMA devices based on GPU topology or rank ID
     * @param options: configuration options
     * @param rank_id: rank ID for non-GPU environment
     * @return comma-separated list of selected RDMA device names
     */
    static std::string SelectRdmaDevices(const Options& options, int rank_id);

    // Initialize basic options
    void InitializeFromOptions(const Options& options);

    // Initialize utrans logging configuration
    static void InitializeLoggingConfig(utrans_config_t& utrans_config);

    // Initialize RDMA device configuration
    void InitializeRdmaConfig(
        utrans_config_t& utrans_config, const Options& options, const AParallelConfig& parallel_config);

    // Setup utrans context
    bool SetupUtransContext(utrans_config_t& utrans_config);

    // Setup RPC server
    bool SetupRpcServer(const Options& options, utrans_config_t& utrans_config);

    // Initialize performance metrics logging
    void InitializePerfMetricsThread(const Options& options);

    // Performance metrics logging thread
    void PerfMetricsLoggingThread();

    Options options_;

    std::string local_server_name_;
    int local_server_port_{0};
    std::string meta_addr_;

    // Timeout settings, -1 means infinite wait
    int write_timeout_ms_{-1};
    int read_timeout_ms_{-1};

    // utrans context
    utrans_ctx_t* ctx_{nullptr};

    // Remote contexts
    // std::unordered_map<RemoteAddress, std::shared_ptr<RemoteContext>, RemoteAddressHash> rctxs_;

    // std::mutex rctx_mutex_;

    std::mutex close_mutex_;

    std::atomic<bool> enable_perf_metrics_{true};
    std::atomic<long> perf_stats_interval_ms_{500}; // Default 500ms
    std::atomic<bool> perf_logging_thread_running_{false};
    std::thread perf_logging_thread_;

    int rdma_numa_node_ = -1;
    std::vector<std::pair<std::string, int>> nic_nodes_;
    // Track last send/receive time for conditional logging
    std::atomic<long long> last_send_receive_time_{0};
};

/*
 * Convert C memory region to C++ memory region
 * @param c_mr: C memory region
 * @return C++ memory region
 */
static std::shared_ptr<RegisteredMemRegion> ConvertFromCMemRegion(const mem_region_registed_t* c_mr) {
    auto result = std::make_shared<RegisteredMemRegion>();

    // Copy memory region information
    result->mr.addr = c_mr->mr.addr;
    result->mr.len = c_mr->mr.len;
    result->mr.type = c_mr->mr.type;
    // result->mr.numa = c_mr->mr.numa;
    // result->mr.is_owned = c_mr->mr.is_owned;

    // // Set register number
    // result->register_num = c_mr->num_keys;

    // // Build device mapping
    // for (int i = 0; i < c_mr->num_keys; ++i) {
    //     const mem_region_key_t* key = &c_mr->keys[i];
    //     result->devices[key->dev_id] = key->ptr;
    // }

    return result;
}

/*
 * Get remote address from extend info
 * @param extend_info: extend info
 * @return remote address
 */
static const void* GetRemoteAddrFromExtendInfo(const ExtendInfo* extend_info) {
    // RDMA Transport Extend info:[remote_addr]
    if (extend_info == nullptr || extend_info->size() == 0) {
        SPDLOG_ERROR("Extend info is null or empty");
        return nullptr;
    }

    return std::any_cast<const void*>(extend_info->at(0));
}

static ExtendInfo GetExtendInfoFromRemoteAddr(const void* remote_addr) {
    // RDMA Transport Extend info:[remote_addr]
    ExtendInfo extend_info;
    extend_info.emplace_back(remote_addr);
    return extend_info;
}

} // namespace astate
