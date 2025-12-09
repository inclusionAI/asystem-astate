#!/bin/bash

# Trainer端环境变量设置脚本
echo "Setting up Trainer environment..."

export ASTATE_OPTIONS_LOAD_MODE="ENV"
export TENSOR_TRANSFER_SERVICE_TYPE="PULL"
export TRANSFER_ENGINE_SERVICE_SKIP_DISCOVERY="true"
export TRANSFER_ENGINE_SERVICE_FIXED_PORT="true"

# Transfer Engine 基本配置
export TRANSFER_ENGINE_LOCAL_ADDRESS="33.184.123.49"
export TRANSFER_ENGINE_LOCAL_PORT="18001"

# Transfer Engine Service 配置 - Trainer端
export TRANSFER_ENGINE_SERVICE_ADDRESS="33.184.123.49"
export TRANSFER_ENGINE_SERVICE_PORT="19001"
export TRANSFER_ENGINE_PEERS_HOST="33.184.123.49:28001:29001"

# Python路径设置
# export PYTHONPATH="${PYTHONPATH}:$(pwd)/build/python"

# 其他可能需要的环境变量
export CUDA_VISIBLE_DEVICES="0"

echo "Trainer environment variables set:"
echo "  ROLE: $TRANSFER_ENGINE_SERVICE_ROLE"
echo "  ADDRESS: $TRANSFER_ENGINE_SERVICE_ADDRESS:$TRANSFER_ENGINE_SERVICE_PORT"
echo "  PEERS: $TRANSFER_ENGINE_PEERS_HOST"
echo "  LOCAL: $TRANSFER_ENGINE_LOCAL_ADDRESS:$TRANSFER_ENGINE_LOCAL_PORT"
echo "  TYPE: $TRANSFER_ENGINE_TYPE"
echo "  PYTHONPATH: $PYTHONPATH"

# 运行trainer脚本
echo "Starting trainer script..."
python3 train.py "$@"