#include "rdma_transporter.h"

#include <algorithm>
#include <chrono>
#include <climits>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <random>
#include <stdexcept>
#include <thread>

#include <unistd.h>

#include <spdlog/spdlog.h>

#include "common/cuda_utils.h"
#include "common/gpu_topology_manager.h"
#include "common/network_utils.h"
#include "common/option.h"
#include "common/rdma_type.h"
#include "common/retry/counting_retry.h"
#include "common/retry/retry_utils.h"
#include "transport/base_transport.h"


namespace astate {

static int NumaNodeOfInfiniband(const std::string& dev) {
    // /sys/class/infiniband/mlx5_bond_0/device/numa_node
    std::string p = "/sys/class/infiniband/" + dev + "/device/numa_node";
    std::ifstream f(p);
    int node = -1;
    if (f && (f >> node)) {
        return node;
    }
    return -1;
}

void RDMATransporter::InitializeFromOptions(const Options& options) {
    local_server_name_ = GetLocalHostnameOrIP();
    meta_addr_ = GetOptionValue<std::string>(options, TRANSFER_ENGINE_META_SERVICE_ADDRESS);
    read_timeout_ms_ = GetOptionValue<int>(options, TRANSFER_ENGINE_READ_TIMEOUT_MS);
    write_timeout_ms_ = GetOptionValue<int>(options, TRANSFER_ENGINE_WRITE_TIMEOUT_MS);
}

void RDMATransporter::InitializeLoggingConfig(utrans_config_t& utrans_config) {
    auto log_name = std::string("utrans-") + std::to_string(getpid());
    auto log_dir = std::string("/tmp/astate");

    // 复制 log_dir
    size_t len = std::min(static_cast<size_t>(log_dir.size()), static_cast<size_t>(PATH_MAX - 1));
    std::copy(log_dir.begin(), log_dir.begin() + len, utrans_config.log_conf.log_dir);
    utrans_config.log_conf.log_dir[len] = '\0';

    size_t len_name = std::min(log_name.size(), static_cast<size_t>(NAME_MAX - 1));
    std::copy(log_name.begin(), log_name.begin() + len_name, utrans_config.log_conf.log_name);
    utrans_config.log_conf.log_name[len_name] = '\0';

    utrans_config.log_conf.log_max_file_count = 16;
    utrans_config.log_conf.log_max_size = static_cast<long>(1024 * 1024) * 1024;
    utrans_config.log_conf.self_delete = 1;
}

void RDMATransporter::InitializeRdmaConfig(
    utrans_config_t& utrans_config, const Options& options, const AParallelConfig& parallel_config) {
    int puller = GetOptionValue<int>(options, TRANSFER_ENGINE_RDMA_NUM_POLLERS);
    utrans_config.rdma_conf.num_pollers = puller;
    SPDLOG_INFO("Set RDMA num_pollers={}", puller);
    SPDLOG_INFO("[Affinity] cpu mask={} mempolicy={}", CpuMaskStr(), MemPolicyStr());
    // 选择RDMA设备
    std::string selected_devices = SelectRdmaDevices(options, parallel_config.role_rank);
    SPDLOG_INFO("selectRdmaDevices role_rank {} nic_devices: '{}'", parallel_config.role_rank, selected_devices);
    if (!selected_devices.empty()) {
        // 设置RDMA设备配置 - valid_dev_patt是char*指针，需要分配内存
        std::vector<std::string> nics = SplitByComma(selected_devices);
        nic_nodes_.clear();
        for (auto& n : nics) {
            nic_nodes_.emplace_back(n, NumaNodeOfInfiniband(n));
        }
        // TODO(lhb): try find numa by gpu, not nic
        rdma_numa_node_ = nic_nodes_.empty() ? -1 : nic_nodes_[0].second;
        SPDLOG_INFO("RDMA primary NIC NUMA node = {}", rdma_numa_node_);

        auto numa_enabled = GetOptionValue<bool>(options, TRANSFER_ENGINE_ENABLE_NUMA_ALLOCATION);
        if (numa_enabled) {
            numa_run_on_node(rdma_numa_node_);

            struct bitmask* bm = numa_allocate_nodemask();
            numa_bitmask_clearall(bm);
            numa_bitmask_setbit(bm, rdma_numa_node_);
            numa_set_membind(bm);
            numa_free_nodemask(bm);
            SPDLOG_INFO("Bound RDMA threads/mempolicy to NUMA node {}", rdma_numa_node_);
        }

        SPDLOG_INFO("[Affinity] cpu mask={} mempolicy={}", CpuMaskStr(), MemPolicyStr());

        size_t dev_len = selected_devices.size();
        utrans_config.rdma_conf.valid_dev_patt = new char[dev_len + 1];
        std::copy(selected_devices.begin(), selected_devices.end(), utrans_config.rdma_conf.valid_dev_patt);
        utrans_config.rdma_conf.valid_dev_patt[dev_len] = '\0';
        SPDLOG_INFO("Selected RDMA devices: {}", selected_devices);
    } else {
        SPDLOG_WARN("No RDMA devices selected, using default configuration");
        utrans_config.rdma_conf.valid_dev_patt = nullptr;
    }
}

bool RDMATransporter::SetupUtransContext(utrans_config_t& utrans_config) {
    if (utrans_setup(&utrans_config, &ctx_) != UTRANS_RET_SUCC) {
        SPDLOG_ERROR("utrans setup failed");
        return false;
    }
    SPDLOG_INFO("utrans setup success, instanceId={}", utrans_get_instid(ctx_));
    return true;
}

bool RDMATransporter::SetupRpcServer(const Options& options, utrans_config_t& utrans_config) {
    auto fixed_port = GetOptionValue<bool>(options, TRANSFER_ENGINE_SERVICE_FIXED_PORT);
    if (fixed_port) {
        auto* uconfig = utrans_get_conf(ctx_);
        uconfig->rpc_listen_port = GetOptionValue<int>(options, TRANSFER_ENGINE_LOCAL_PORT);
        // Setup utrans local rpc server
        if (utrans_setup_rpcsrv(ctx_) != UTRANS_RET_SUCC) {
            SPDLOG_ERROR("utrans setup_rpcsrv failed");
            return false;
        }
        local_server_port_ = uconfig->rpc_listen_port;
    } else {
        if (!SetupRpcServerWithRetry(utrans_config)) {
            SPDLOG_ERROR("utrans setup_rpcsrv failed after retry");
            return false;
        }
    }
    SPDLOG_INFO("utrans setup_rpcsrv success on port {}", local_server_port_);
    return true;
}

void RDMATransporter::InitializePerfMetricsThread(const Options& options) {
    // Initialize performance metrics options
    enable_perf_metrics_ = GetOptionValue<bool>(options, TRANSFER_ENGINE_ENABLE_PERF_METRICS);
    perf_stats_interval_ms_ = GetOptionValue<long>(options, TRANSFER_ENGINE_PERF_STATS_INTERVAL_MS);

    // Start performance metrics logging thread if enabled
    if (enable_perf_metrics_ && (ctx_ != nullptr)) {
        perf_logging_thread_running_ = true;
        perf_logging_thread_ = std::thread(&RDMATransporter::PerfMetricsLoggingThread, this);
        SPDLOG_INFO("Performance metrics logging thread started with interval {}ms", perf_stats_interval_ms_.load());
    }
}

bool RDMATransporter::SetupRpcServerWithRetry(utrans_config_t& /*utrans_config*/) {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<> dis(0, 1000);
    int random_offset = dis(gen);
    int base_port = kRdmaPortStart + random_offset;

    SPDLOG_INFO("Starting RPC server setup with base port {} (random offset: {})", base_port, random_offset);

    auto retry_policy = std::make_unique<CountingRetry>(kBindPortMaxRetry);

    int attempt_count = 0;
    bool success = false;

    auto setup_func = [this, base_port, &attempt_count, &success]() -> void {
        int current_port = base_port + attempt_count;
        if (attempt_count >= kBindPortMaxRetry) {
            throw std::runtime_error(
                "Failed to bind RPC server on port " + std::to_string(current_port) + ", max retry attempts reached");
        }

        auto* uconfig = utrans_get_conf(ctx_);
        uconfig->rpc_listen_port = current_port;

        SPDLOG_INFO(
            "Attempt {}/{} - Trying to bind RPC server on port {}",
            (attempt_count + 1),
            kBindPortMaxRetry,
            current_port);

        int result = utrans_setup_rpcsrv(ctx_);
        if (result == UTRANS_RET_SUCC) {
            local_server_port_ = current_port;
            SPDLOG_INFO("Successfully bound RPC server on port {}", current_port);
            success = true;
            return;
        }
        SPDLOG_WARN("Failed to bind RPC server on port {}, error code: {}", current_port, result);
        attempt_count++;
        throw std::runtime_error("Port binding failed for port " + std::to_string(current_port));
    };

    try {
        RetryUtils::Retry("RPC server setup", setup_func, *retry_policy);
    } catch (const std::exception& e) {
        SPDLOG_ERROR(
            "Failed to setup RPC server after {} attempts, tried ports {} to "
            "{}. Last error: {}",
            attempt_count,
            base_port,
            (base_port + attempt_count - 1),
            e.what());
        return false;
    }

    return success;
}

std::string RDMATransporter::SelectRdmaDevices(const Options& options, int rank_id) {
    SPDLOG_INFO("DEBUG: selectRdmaDevices called with rank_id={}", rank_id);
    int max_devices = GetOptionValue<int>(options, TRANSFER_ENGINE_MAX_RDMA_DEVICES);
    SPDLOG_INFO("DEBUG: max_devices={}", max_devices);

    static std::unique_ptr<GpuTopologyManager> topology_manager = std::make_unique<GpuTopologyManager>();
    if (!topology_manager->IsInitialized()) {
        if (!topology_manager->Initialize()) {
            SPDLOG_WARN("Failed to initialize GPU topology manager, using "
                        "fallback strategy");
        }
    }

    int current_cuda_device = -1;
    cudaError_t cuda_result = cudaGetDevice(&current_cuda_device);

    if (cuda_result == cudaSuccess && current_cuda_device >= 0) {
        SPDLOG_INFO("CUDA device detected: {}", current_cuda_device);
        return topology_manager->SelectRdmaDevices(current_cuda_device, max_devices);
    }
    SPDLOG_INFO(
        "No CUDA device detected, using rank-based selection with rank_id: "
        "{}",
        rank_id);
    return topology_manager->SelectRdmaDevicesByRank(rank_id, max_devices);
}

bool RDMATransporter::Start(const Options& options, const AParallelConfig& parallel_config) {
    // Initialize basic options
    InitializeFromOptions(options);

    // Initialize utrans context
    utrans_config_t utrans_config = {};

    InitializeLoggingConfig(utrans_config);
    InitializeRdmaConfig(utrans_config, options, parallel_config);

    // Setup utrans context
    if (!SetupUtransContext(utrans_config)) {
        return false;
    }

    // Setup RPC server
    if (!SetupRpcServer(options, utrans_config)) {
        return false;
    }

    // Initialize performance metrics logging
    InitializePerfMetricsThread(options);

    is_running_ = true;
    SPDLOG_INFO("RDMATransporter started");
    // sleep 1s for server to start
    std::this_thread::sleep_for(std::chrono::milliseconds(1000));

    return true;
}

void RDMATransporter::Stop() {
    if (!is_running_) {
        return;
    }

    std::lock_guard<std::mutex> lock_close(close_mutex_);
    if (!is_running_) {
        return;
    }

    // Stop performance metrics logging thread
    if (perf_logging_thread_running_) {
        perf_logging_thread_running_ = false;
        if (perf_logging_thread_.joinable()) {
            perf_logging_thread_.join();
        }
        SPDLOG_INFO("Performance metrics logging thread stopped");
    }

    // std::lock_guard<std::mutex> lock_ctx(rctx_mutex_);
    // for (const auto& [addr, ctx] : rctxs_) {
    //     // Clean up each remote context
    //     if (ctx && (ctx->qp_ctx != nullptr)) {
    //         // TODO(root): Implement resource cleanup logic
    //     }
    // }
    // rctxs_.clear();
    is_running_ = false;
}

bool RDMATransporter::Send(
    const void* local_addr,
    size_t send_size,
    const std::string& remote_host,
    int remote_port,
    const ExtendInfo* extend_info) {
    if (ctx_ == nullptr) {
        SPDLOG_ERROR("Context not initialized");
        return false;
    }
    if (local_addr == nullptr || send_size == 0) {
        SPDLOG_ERROR("Send data is null or size is zero");
        throw std::invalid_argument("RDMATransporter::Send: send_data is null or size is zero");
    }
    const void* rbuf = GetRemoteAddrFromExtendInfo(extend_info);
    if (rbuf == nullptr) {
        SPDLOG_ERROR("Remote address is null");
        throw std::invalid_argument("RDMATransporter::Send: remote address is null");
    }

    // Update last send/receive time
    auto now
        = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch())
              .count();
    last_send_receive_time_ = now;

    int retry_count = GetOptionValue<int>(options_, TRANSPORT_SEND_RETRY_COUNT);
    int retry_sleep_ms = GetOptionValue<int>(options_, TRANSPORT_SEND_RETRY_SLEEP_MS);

    auto send_func = [&]() -> bool {
        uint64_t remote_inst_id = UTRANS_INVALID_INST_ID;
        int ret = utrans_query_instid(ctx_, remote_host.c_str(), remote_port, &remote_inst_id);
        if (ret != UTRANS_RET_SUCC) {
            SPDLOG_ERROR("Query remote instance id failed, remote_addr={}:{}, ret={}", remote_host, remote_port, ret);
            throw std::runtime_error(
                "Query remote instance id failed, remote_addr= " + remote_host + ":" + std::to_string(remote_port)
                + ", ret=" + std::to_string(ret));
        }
        trans_req_t req{
            remote_inst_id,
            USER_OP_WRITE,
            1,
            const_cast<void*>(rbuf),
            nullptr,
            {{const_cast<void*>(local_addr), static_cast<uint32_t>(send_size)}}};
        trans_conf_t conf{4, 1024 * 1024, write_timeout_ms_};
        utrans_req_info_t* op_info = utrans_exec_transfer(ctx_, &req, &conf);
        if (op_info == nullptr) {
            SPDLOG_ERROR(
                "Transfer execution failed (utrans_exec_transfer returned "
                "nullptr), remote_addr={}:{}",
                remote_host,
                remote_port);
            throw std::runtime_error("utrans_exec_transfer failed");
        }
        if (utrans_get_req_exec_result(op_info) != URES_SUCCESS) {
            int status = utrans_get_req_exec_result(op_info);
            SPDLOG_ERROR(
                "Transfer execution failed with status: {}, remote_addr={}:{}, "
                "inst_id={}, laddr={}, raddr={}, "
                "length={}",
                status,
                remote_host,
                remote_port,
                req.inst_id,
                PointerToHexString(req.lbuf_seg[0].addr_beg),
                PointerToHexString(req.rbuf),
                req.lbuf_seg[0].trz_size);
            utrans_unref_req_info(op_info);
            throw std::runtime_error("Transfer execution failed with status: " + std::to_string(status));
        }
        utrans_unref_req_info(op_info);
        return true;
    };

    try {
        CountingAndSleepRetryPolicy retry_policy(retry_count, retry_sleep_ms);
        return RetryUtils::Retry<bool>(
            "RDMATransporter::Send",
            [&]() {
                try {
                    bool result = send_func();
                    return result;
                } catch (const NonRetryableException&) {
                    throw; // 立即终止重试
                } catch (const std::exception& e) {
                    SPDLOG_ERROR(
                        "RDMATransporter::Send failed after retry: {}, "
                        "remote_addr={}:{}",
                        e.what(),
                        remote_host,
                        remote_port);
                    throw;
                }
            },
            retry_policy);
    } catch (const NonRetryableException& e) {
        SPDLOG_ERROR(
            "RDMATransporter::Send non-retryable error: {}, remote_addr={}:{}", e.what(), remote_host, remote_port);
        return false;
    } catch (const std::exception& e) {
        SPDLOG_ERROR(
            "RDMATransporter::Send failed after retry: {}, remote_addr={}:{}", e.what(), remote_host, remote_port);
        return false;
    }
}

bool RDMATransporter::Receive(
    const void* local_addr,
    size_t recv_size,
    const std::string& remote_host,
    int remote_port,
    const ExtendInfo* extend_info) {
    if (ctx_ == nullptr) {
        SPDLOG_ERROR("Context not initialized");
        throw std::invalid_argument("RDMATransporter::Receive: context not initialized");
    }
    if (local_addr == nullptr || recv_size == 0) {
        SPDLOG_ERROR("Receive data is null or size is zero");
        throw std::invalid_argument("RDMATransporter::Receive: recv_data is null or size is zero");
    }
    const void* rbuf = GetRemoteAddrFromExtendInfo(extend_info);
    if (rbuf == nullptr) {
        SPDLOG_ERROR("Remote address is null");
        throw std::invalid_argument("RDMATransporter::Receive: remote address is null");
    }

    // Update last send/receive time
    auto now
        = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch())
              .count();
    last_send_receive_time_ = now;

    int retry_count = GetOptionValue<int>(options_, TRANSPORT_RECEIVE_RETRY_COUNT);
    int retry_sleep_ms = GetOptionValue<int>(options_, TRANSPORT_RECEIVE_RETRY_SLEEP_MS);

    auto recv_func = [&]() -> bool {
        uint64_t remote_inst_id = UTRANS_INVALID_INST_ID;
        int ret = utrans_query_instid(ctx_, remote_host.c_str(), remote_port, &remote_inst_id);
        if (ret != UTRANS_RET_SUCC) {
            SPDLOG_ERROR("Query remote instance id failed, remote_addr={}:{}, ret={}", remote_host, remote_port, ret);
            throw std::runtime_error(
                "Query remote instance id failed, remote_addr= " + remote_host + ":" + std::to_string(remote_port)
                + ", ret=" + std::to_string(ret));
        }

        trans_req_t req{
            remote_inst_id,
            USER_OP_READ,
            1,
            const_cast<void*>(rbuf),
            nullptr,
            {{const_cast<void*>(local_addr), static_cast<uint32_t>(recv_size)}}};
        trans_conf_t conf{4, 1024 * 1024, read_timeout_ms_};
        utrans_req_info_t* op_info = utrans_exec_transfer(ctx_, &req, &conf);
        if (op_info == nullptr) {
            SPDLOG_ERROR(
                "Transfer execution failed (utrans_exec_transfer returned "
                "nullptr), remote_addr={}:{}, inst_id={}, "
                "laddr={}, raddr={}, length={}",
                remote_host,
                remote_port,
                req.inst_id,
                PointerToHexString(req.lbuf_seg[0].addr_beg),
                PointerToHexString(req.rbuf),
                req.lbuf_seg[0].trz_size);
            throw std::runtime_error("utrans_exec_transfer failed");
        }

        if (utrans_get_req_exec_result(op_info) != URES_SUCCESS) {
            int status = utrans_get_req_exec_result(op_info);
            SPDLOG_ERROR(
                "Transfer execution failed with status: {}, remote_addr={}:{}, "
                "inst_id={}, laddr={}, raddr={}, "
                "length={}",
                status,
                remote_host,
                remote_port,
                req.inst_id,
                PointerToHexString(req.lbuf_seg[0].addr_beg),
                PointerToHexString(req.rbuf),
                req.lbuf_seg[0].trz_size);
            utrans_unref_req_info(op_info);
            throw std::runtime_error("Transfer execution failed with status: " + std::to_string(status));
        }
        utrans_unref_req_info(op_info);

        return true;
    };

    try {
        CountingAndSleepRetryPolicy retry_policy(retry_count, retry_sleep_ms);
        return RetryUtils::Retry<bool>(
            "RDMATransporter::Receive",
            [&]() {
                try {
                    bool result = recv_func();
                    return result;
                } catch (const NonRetryableException&) {
                    throw; // 立即终止重试
                } catch (const std::exception& e) {
                    SPDLOG_ERROR(
                        "RDMATransporter::Receive failed after retry: {}, "
                        "remote_addr={}:{}",
                        e.what(),
                        remote_host,
                        remote_port);
                    throw;
                }
            },
            retry_policy);
    } catch (const NonRetryableException& e) {
        SPDLOG_ERROR(
            "RDMATransporter::Receive non-retryable error: {}, "
            "remote_addr={}:{}",
            e.what(),
            remote_host,
            remote_port);
        return false;
    } catch (const std::exception& e) {
        SPDLOG_ERROR(
            "RDMATransporter::Receive failed after retry: {}, "
            "remote_addr={}:{}",
            e.what(),
            remote_host,
            remote_port);
        return false;
    }
}

void RDMATransporter::AsyncSend(
    const void* /*local_addr*/,
    size_t /*send_size*/,
    const std::string& /*remote_host*/,
    int /*remote_port*/,
    const ExtendInfo* /*extend_info*/,
    const SendCallback& /*callback*/) {
    throw std::runtime_error("Not implemented");
}

void RDMATransporter::AsyncReceive(
    const void* /*local_addr*/,
    size_t /*recv_size*/,
    const std::string& /*remote_host*/,
    int /*remote_port*/,
    const ExtendInfo* /*extend_info*/,
    const ReceiveCallback& /*callback*/) {
    throw std::runtime_error("Not implemented");
}

bool RDMATransporter::RegisterMemory(void* addr, size_t len, bool is_vram, int gpu_id_or_numa_node) {
    if (ctx_ == nullptr) {
        SPDLOG_ERROR("Context not initialized");
        return false;
    }

    const mem_region_registed_t* mr = nullptr;
    if (is_vram) {
        mr = utrans_regist_vram(ctx_, addr, len, gpu_id_or_numa_node);
    } else {
        mr = utrans_regist_ram(ctx_, addr, len, rdma_numa_node_);
    }

    if (mr == nullptr) {
        SPDLOG_ERROR("Memory registration failed");
        throw std::runtime_error("Memory registration failed, mr is null");
    }

    return true;
}

bool RDMATransporter::DeregisterMemory(void* addr, size_t len) {
    if (ctx_ == nullptr) {
        SPDLOG_ERROR("Context not initialized");
        return false;
    }
    bool result = utrans_dereg_mem(ctx_, addr, len) == 0;
    SPDLOG_INFO("Deregistering memory result={}, addr={}, len={}", result, addr, len);
    return result;
}

void RDMATransporter::PerfMetricsLoggingThread() {
    SPDLOG_INFO("Performance metrics logging thread started");

    while (perf_logging_thread_running_) {
        // Sleep for the configured interval
        std::this_thread::sleep_for(std::chrono::milliseconds(perf_stats_interval_ms_.load()));

        // Check if we should print metrics (only if there was activity in the last 1 second)
        auto now
            = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch())
                  .count();
        auto last_activity = last_send_receive_time_.load();

        // Only print if there was activity in the last 1 second
        if (now - last_activity < 1000) {
            // Call the utrans performance info printing function
            if (ctx_ != nullptr) {
                utrans_print_perf_info(ctx_);
            }
        }
    }

    SPDLOG_INFO("Performance metrics logging thread exiting");
}

RDMATransporter::~RDMATransporter() {
    Stop();

    if (ctx_ != nullptr) {
        utrans_clean(ctx_);
        ctx_ = nullptr;
    }
}
} // namespace astate
