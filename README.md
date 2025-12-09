# AState: High-performance State Management for RL

**AState is a general-purpose state data management system for RL workloads**. It is designed to address several core challenges in RL:
- Low I/O efficiency in training and inference；
- Insufficient weight synchronization performance；
- The lack of robust state recovery for multi-turn conversations and external environment calls.

Within Ant Group, AState has been deployed as a key component of ASystem and is already supporting high-performance weight exchange for large-scale RL training in production. **At trillion-parameter scale, AState can complete weight synchronization in about 6 seconds**, compared to the minute-level latency seen in many industry solutions.

---

## System Architecture

![Figure 1](doc/images/image.png)

To address the challenges of large-scale RL weight synchronization, AState provides a unified weight management API for RL workloads. It can support arbitrary model architectures and various deployment and pipeline patterns, without intrusive changes or extra adaptation in the RL framework itself.
As shown in Figure 1, AState’s architecture is organized into three layers:

- **API Layer**

    Provides tensor-native interfaces that integrate quickly with different training/inference frameworks. The APIs expose one-sided read/write semantics, naturally supporting more complex or asynchronous computation and data exchange flows.

- **Service Layer**

    To support multiple deployment patterns and pipeline modes with a single API, AState introduces a middle service layer that offers different weight sync services and protocols, shielding upper layers from the complexity of exchange and scheduling. For example:
    - In co-located training/inference, inference nodes can pull weights on demand.
    - In off-policy setups, training and inference can perform fully asynchronous weight updates.
    The service layer also provides tensor sharding management with zero redundancy and synchronization plans that are aware of RL topology and cluster layout.

- **Transport Layer**

    This foundational layer provides efficient, scalable data transfer capabilities, including:
    - NUMA topology and affinity awareness;
    - Multiple transport backends (PCIe / NVLink / RoCE / InfiniBand, etc.) to exploit the full potential of underlying hardware bandwidth and topology.

## Features

- **Unified tensor-level API**
  - One-sided read/write semantics (`put/get/multi_put/multi_get/complete`)
  - Decoupled from specific training/inference frameworks

- **High-performance weight synchronization**
  - Zero-redundancy transfer for row-parallel & column-parallel tensors
  - RDMA-based P2P data paths with DMA zero-copy
  - In-place weight update on inference side (no extra GPU memory copy)

- **Topology-aware, scalable design**
  - NUMA-aware scheduling and CPU/GPU/RDMA affinity
  - Multi-channel transport: RDMA/RoCE/IB, shared memory, NCCL etc.
  - Global execution planning to avoid hotspots and long-tail latency

- **RL-native state management (ongoing)**
  - KV cache persistence & recovery for long-context RL
  - Activation caching & memory offload
  - Agent state (multi-turn dialog, tool calls) caching and recovery

---

## Getting Started

```bash
git clone https://github.com/inclusionAI/asystem-astate.git
cd asystem-astate
make deps install      # installs as a Python library

# development build:
make develop      # build in develop mode + install as Python library
make test
```

## Simple Usage Example

> The internal library currently only supports RDMA NICs and does not support the use of soft-RoCE (TCP). A TCP-based demo will be tested after the integration of UCX.

``` bash
# start train process
cd python/example
bash setup_trainer_env.sh

# start infer process
bash setup_infer_env.sh
```

Typical usage in RL:

- Training side writes updated weights to AState every K steps or per iteration.
- Inference side periodically or asynchronously pulls the latest weights via get/multi_get.
- AState handles sharding, resharding, transport, and in-place update for you.

## Performance

| Method                           | Supported Deployment Modes | Supported Pipeline Modes | Data Redundancy | External Services Required | End-to-End Sync (100B¹) | End-to-End Sync (1T¹) |
| -------------------------------- | -------------------------- | ------------------------ | --------------- | -------------------------- | ----------------------- | --------------------- |
| Load data from FS                | All                        | On-policy                | Yes             | Yes                        | ~10 min                 | N/A²                  |
| Layer-by-layer gather → NCCL P2P | All?                       | All?                     | Yes             | Yes                        | ~30 s                   | ~1 min                |
| AState: simultaneous RDMA P2P    | All                        | All                      | No              | No                         | ~4 s                    | ~6 s                  |

$^?$  It may not be the optimal solution. For example, the co-located mode introduces an additional GPU memory offload pipeline; moreover, due to NCCL’s bilateral semantics, training and inference must be synchronized during data transfer, which can effectively cause an off‑policy scheme to degenerate into on‑policy.

$^1$ 100B(FP16) [Training-Inference Parallel Configuration: train: tp=1, etp=1; infer: tp=4];

$^1$ 1T(FP8) [Training-Inference Parallel Configuration: train: tp=1, etp=1; infer: tp=16].

$^2$ Time proportion is excessively long, rendering it nearly unusable.

## Roadmap (High-level)

- Supports using UCX as the underlying RDMA dependency, adapting to NCCL and the industry ecosystem.
- KV cache persistence & fast failover for long-context RL.
- Activation caching & GPU memory extension.
- Elastic training runtime support.
- Unified agent state (dialog + tools) cache & recovery.

## Community & Links

- 📦 GitHub: https://github.com/inclusionAI/asystem-astate
- 🤗 Hugging Face (InclusionAI models): https://huggingface.co/inclusionAI
- 🤖 ModelScope: https://www.modelscope.cn/organization/inclusionAI

Contributions via Issues / PRs / Discussions are very welcome.
If AState helps your RL system, please consider leaving a ⭐ Star!