# astate RDMA Tensor传输测试

这个目录包含了用于测试astate RDMA tensor传输功能的完整脚本集合。

## 目录结构

```
test_rdma/
├── setup_trainer_env.sh   # Trainer端环境设置脚本
├── setup_infer_env.sh     # Infer端环境设置脚本
├── train.py               # Trainer端Python脚本
├── infer.py               # Infer端Python脚本
├── test_env.py            # 环境验证脚本
└── README.md              # 使用说明
```

## 功能描述

### Trainer端 (train.py)
- 初始化REMOTE类型的TensorTable
- 创建100个4000×500的随机torch.Tensor
- 使用`multi_put`方法将所有tensor数据推送到远程
- 记录传输时间和性能统计

### Infer端 (infer.py)
- 初始化REMOTE类型的TensorTable
- 创建100个4000×500的空torch.Tensor
- 使用`multi_get`方法从远程拉取tensor数据
- 验证接收到的数据完整性
- 记录传输时间和性能统计

## 环境变量配置

### 环境变量格式说明

为了解决bash不支持点号作为环境变量名的问题，我们修改了源代码中的配置key常量（位于`astate_common/config.h`），将点号格式改为下划线格式。这样既保持了代码的清晰性，又避免了复杂的workaround。

#### 完整环境变量列表
- `TRANSFER_ENGINE_TYPE`: Transfer engine类型（"utrans"）
- `TRANSFER_ENGINE_META_SERVICE_ADDRESS`: 元数据服务地址（"127.0.0.1:8081"）
- `TRANSFER_ENGINE_LOCAL_ADDRESS`: 本地服务地址（"127.0.0.1"）
- `TRANSFER_ENGINE_LOCAL_PORT`: 本地服务端口（"8080"）
- `TRANSFER_ENGINE_SERVICE_ROLE`: 服务角色（"TRAINER" 或 "INFER"）
- `TRANSFER_ENGINE_SERVICE_ADDRESS`: 服务地址（"127.0.0.1"）
- `TRANSFER_ENGINE_SERVICE_PORT`: 服务端口（Trainer: "8082", Infer: "8084"）
- `TRANSFER_ENGINE_PEERS_HOST`: 对等节点地址列表

#### Trainer端配置
- `TRANSFER_ENGINE_SERVICE_ROLE="TRAINER"`
- `TRANSFER_ENGINE_SERVICE_PORT="8082"`
- `TRANSFER_ENGINE_PEERS_HOST="127.0.0.1:8083:8084"`

#### Infer端配置
- `TRANSFER_ENGINE_SERVICE_ROLE="INFER"`
- `TRANSFER_ENGINE_SERVICE_PORT="8084"`
- `TRANSFER_ENGINE_PEERS_HOST="127.0.0.1:8082:8083"`

## 使用方法

### 前提条件
1. 确保已编译astate项目及Python绑定模块
2. 确保CUDA环境可用（如果使用GPU）
3. 确保网络端口8080-8084可用

### 运行步骤

#### 方法1：使用shell脚本（推荐）

1. **启动Trainer端**：
   ```bash
   # 在第一个终端窗口
   cd /workspace/Code/astate/astate
   ./astate/python/test_rdma/setup_trainer_env.sh
   ```

2. **启动Infer端**：
   ```bash
   # 在第二个终端窗口
   cd /workspace/Code/astate/astate
   ./astate/python/test_rdma/setup_infer_env.sh
   ```

#### 方法2：手动设置环境变量

1. **手动运行Trainer**：
   ```bash
   export TRANSFER_ENGINE_TYPE="utrans"
   export TRANSFER_ENGINE_META_SERVICE_ADDRESS="127.0.0.1:8081"
   export TRANSFER_ENGINE_LOCAL_ADDRESS="127.0.0.1"
   export TRANSFER_ENGINE_LOCAL_PORT="8080"
   export TRANSFER_ENGINE_SERVICE_ROLE="TRAINER"
   export TRANSFER_ENGINE_SERVICE_ADDRESS="127.0.0.1"
   export TRANSFER_ENGINE_SERVICE_PORT="8082"
   export TRANSFER_ENGINE_PEERS_HOST="127.0.0.1:8083:8084"
   python3 astate/python/test_rdma/train.py
   ```

2. **手动运行Infer**：
   ```bash
   export TRANSFER_ENGINE_TYPE="utrans"
   export TRANSFER_ENGINE_META_SERVICE_ADDRESS="127.0.0.1:8081"
   export TRANSFER_ENGINE_LOCAL_ADDRESS="127.0.0.1"
   export TRANSFER_ENGINE_LOCAL_PORT="8080"
   export TRANSFER_ENGINE_SERVICE_ROLE="INFER"
   export TRANSFER_ENGINE_SERVICE_ADDRESS="127.0.0.1"
   export TRANSFER_ENGINE_SERVICE_PORT="8084"
   export TRANSFER_ENGINE_PEERS_HOST="127.0.0.1:8082:8083"
   python3 astate/python/test_rdma/infer.py
   ```

### 环境验证

使用环境测试脚本验证配置是否正确：
```bash
# 设置一些测试环境变量
export TRANSFER_ENGINE_SERVICE_ROLE="TRAINER"
export TRANSFER_ENGINE_SERVICE_PORT="8082"
export TRANSFER_ENGINE_LOCAL_ADDRESS="127.0.0.1"
export TRANSFER_ENGINE_LOCAL_PORT="8080"
# 运行验证脚本
python3 astate/python/test_rdma/test_env.py
```

## 期望输出

### Trainer端
```
Setting up Trainer environment...
Trainer environment variables set:
  ROLE: TRAINER
  ADDRESS: 127.0.0.1:8082
  PEERS: 127.0.0.1:8083:8084
  LOCAL: 127.0.0.1:8080
  TYPE: utrans
Starting trainer script...
[TRAINER] 2024-06-18 12:00:00 - INFO - 🚀 Starting Trainer script...
[TRAINER] 2024-06-18 12:00:00 - INFO - ✅ ATensorStorage initialized
[TRAINER] 2024-06-18 12:00:00 - INFO - ✅ TensorTable created
[TRAINER] 2024-06-18 12:00:01 - INFO - ✅ Created 100 tensors successfully
[TRAINER] 2024-06-18 12:00:02 - INFO - ✅ multi_put completed successfully in 1.23 seconds
[TRAINER] 2024-06-18 12:00:02 - INFO - 🎉 Trainer script completed successfully!
```

### Infer端
```
Setting up Infer environment...
Infer environment variables set:
  ROLE: INFER
  ADDRESS: 127.0.0.1:8084
  PEERS: 127.0.0.1:8082:8083
  LOCAL: 127.0.0.1:8080
  TYPE: utrans
Starting infer script...
[INFER] 2024-06-18 12:00:10 - INFO - 🚀 Starting Infer script...
[INFER] 2024-06-18 12:00:10 - INFO - ✅ ATensorStorage initialized
[INFER] 2024-06-18 12:00:10 - INFO - ✅ TensorTable created
[INFER] 2024-06-18 12:00:11 - INFO - ✅ Created 100 empty tensors successfully
[INFER] 2024-06-18 12:00:12 - INFO - ✅ multi_get completed successfully in 0.98 seconds
[INFER] 2024-06-18 12:00:12 - INFO - ✅ Data verification successful - received non-zero data
[INFER] 2024-06-18 12:00:12 - INFO - 🎉 Infer script completed successfully!
```

## 技术说明

### 性能测试

脚本会自动记录和报告以下性能指标：
- 总传输时间
- 每个tensor的平均传输时间
- 数据验证结果
- 内存使用情况

## 故障排除

### 常见问题
1. **ImportError**: 确保Python绑定模块已正确编译
2. **连接失败**: 检查网络端口是否被占用
3. **环境变量问题**: 使用`test_env.py`脚本验证环境变量设置
4. **编译问题**: 修改配置key后需要重新编译项目

### 调试选项
可以通过修改脚本中的参数来调整测试：
- `num_tensors`: 修改tensor数量
- `height`, `width`: 修改tensor尺寸
- `seq_id`: 修改序列ID

## 注意事项

1. 建议先运行Trainer端，再运行Infer端
2. Infer端会等待10秒让Trainer端充分初始化
3. 确保两端的环境变量配置正确且不冲突
4. 修改配置key后需要重新编译整个项目
5. 新的环境变量格式使用下划线，符合bash标准