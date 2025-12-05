#!/usr/bin/env python3
"""
Infer端测试脚本
功能：初始化TensorTable，创建100个4000*500的torch.Tensor，调用multi_get接收数据
支持循环测试以验证稳定性和性能
添加MD5校验功能验证数据传输正确性
"""

import torch
import sys
import os
import time
import logging
import argparse
import hashlib
from astate.parallel_config import ParallelConfig

# 添加astate客户端库到Python路径
sys.path.append(os.path.join(os.getcwd(), 'build', 'python'))

try:
    import astate
    from astate import ShardedKey, TensorTableType, TensorStorage
    print("✅ Successfully imported astate")
except ImportError as e:
    print(f"❌ Failed to import astate: {e}")
    print("请确保已编译Python绑定模块")
    sys.exit(1)

# 设置日志
logging.basicConfig(level=logging.INFO,
                    format='[INFER] %(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


from typing import Any

def print_refcount(obj: Any, name: str = "Object") -> None:
    """
    Print the reference count of the given object.
    
    Args:
    obj (Any): The object whose reference count you want to check.
    name (str): A name to identify the object in the output (default: "Object").
    """
    count = sys.getrefcount(obj) - 1  # Subtract 1 to account for the temporary reference
    print(f"Reference count for {name}: {count}")

def calculate_tensor_md5(tensor):
    """计算tensor的MD5值"""
    # 将tensor转换为连续的字节流
    tensor_bytes = tensor.detach().cpu().numpy().tobytes()
    return hashlib.md5(tensor_bytes).hexdigest()


def write_md5_to_file(tensor_data, iteration, seq_id, output_dir="md5_output"):
    """将tensor的MD5值写入文件 - 先重构分片tensor为完整tensor再计算MD5"""
    os.makedirs(output_dir, exist_ok=True)

    md5_filename = os.path.join(
        output_dir, f"infer_md5_iter{iteration}_seq{seq_id}.txt")

    logger.info(f"计算并写入MD5值到文件: {md5_filename}")

    # 第一步：按照tensor_data列表中key.key对所有tensor进行分组
    tensor_groups = {}
    for key, tensor in tensor_data:
        tensor_key = key.key
        if tensor_key not in tensor_groups:
            tensor_groups[tensor_key] = []
        tensor_groups[tensor_key].append((key, tensor))
    
    logger.info(f"分组结果: 共{len(tensor_groups)}个tensor组")

    with open(md5_filename, 'w') as f:
        f.write(
            f"# Infer MD5 values - Iteration {iteration}, Seq ID {seq_id}\n")
        f.write(f"# Format: tensor_key,md5_hash,shape,dtype\n")

        # 第二步：按照key.global_shape创建完整的tensor，按照key.global_offset将tensor的数据拷贝到完整tensor中
        for tensor_key, key_tensor_list in tensor_groups.items():
            logger.info(f"处理tensor组: {tensor_key} (包含{len(key_tensor_list)}个分片)")
            
            # 从第一个分片获取全局shape和dtype信息
            first_key, first_tensor = key_tensor_list[0]
            global_shape = first_key.globalShape
            dtype = first_tensor.dtype
            device = first_tensor.device
            
            logger.info(f"创建完整tensor: shape={global_shape}, dtype={dtype}, device={device}")
            
            # 创建完整的tensor（零初始化）
            full_tensor = torch.zeros(global_shape, dtype=dtype, device=device)
            
            # 将每个分片的数据拷贝到完整tensor的对应位置
            for key, tensor in key_tensor_list:
                global_offset = key.globalOffset
                tensor_shape = tensor.shape
                
                # 构建切片索引
                slice_indices = []
                for i, (offset, size) in enumerate(zip(global_offset, tensor_shape)):
                    slice_indices.append(slice(offset, offset + size))
                
                # 拷贝分片数据到完整tensor
                full_tensor[tuple(slice_indices)] = tensor.clone()
                logger.debug(f"拷贝分片 {key.key} 从offset {global_offset} 到完整tensor")
            
            # 计算完整tensor的MD5值
            md5_hash = calculate_tensor_md5(full_tensor)
            shape_str = "x".join(map(str, global_shape))
            dtype_str = str(dtype)

            f.write(f"{tensor_key},{md5_hash},{shape_str},{dtype_str}\n")
            logger.info(f"✅ {tensor_key}: MD5={md5_hash[:8]}..., shape={shape_str}")

    logger.info(f"✅ MD5值已写入文件: {md5_filename}")
    return md5_filename


def zero_tensors(tensor_data):
    """将所有tensor的元素置为零"""
    logger.info("将所有tensor元素置为零...")
    for key, tensor in tensor_data:
        tensor.zero_()
    logger.info("✅ 所有tensor已置零")


def create_empty_tensors(num_tensors=100, height=4000, width=500, device='cpu', shard_rows=1, shard_cols=1):
    """创建用于接收数据的空tensor，支持分片读取"""
    logger.info(
        f"Creating {num_tensors} empty tensors of size {height}x{width} on {device}")
    logger.info(f"分片配置: {shard_rows}行 x {shard_cols}列 = {shard_rows * shard_cols}个分片")

    # 检查CUDA可用性
    if device == 'cuda' and not torch.cuda.is_available():
        logger.warning("CUDA不可用，回退到CPU")
        device = 'cpu'
    
    # 设置设备
    torch_device = torch.device(device)
    logger.info(f"使用设备: {torch_device}")

    # 计算分片尺寸
    shard_height = height // shard_rows
    shard_width = width // shard_cols
    
    # 检查是否能整除
    if height % shard_rows != 0:
        logger.warning(f"高度 {height} 不能被 {shard_rows} 整除，将使用向下取整")
    if width % shard_cols != 0:
        logger.warning(f"宽度 {width} 不能被 {shard_cols} 整除，将使用向下取整")
    
    logger.info(f"每个分片尺寸: {shard_height}x{shard_width}")

    tensor_data = []
    
    for tensor_idx in range(num_tensors):
        # 为每个原始tensor创建分片读取
        for row in range(shard_rows):
            for col in range(shard_cols):
                # 计算分片的实际尺寸（处理不能整除的情况）
                # 最后一行/列的分片需要包含所有剩余的元素
                actual_height = shard_height if row < shard_rows - 1 else height - row * shard_height
                actual_width = shard_width if col < shard_cols - 1 else width - col * shard_width
                
                # 创建分片tensor
                tensor = torch.zeros(actual_height, actual_width, dtype=torch.float32, device=torch_device)

                # 创建ShardedKey，使用原始tensor的key，但设置不同的offset和shape
                key = ShardedKey()
                key.key = f"tensor_{tensor_idx:03d}"  # 使用原始tensor的key
                key.globalShape = [height, width]  # 原始tensor的全局shape
                key.globalOffset = [row * shard_height, col * shard_width]  # 分片在全局tensor中的偏移量

                tensor_data.append((key, tensor))

        if (tensor_idx + 1) % 10 == 0:
            logger.info(f"Created shard tensors for {tensor_idx + 1} original tensors...")

    logger.info(f"✅ Created {len(tensor_data)} shard tensors successfully on {device}")
    return num_tensors, tensor_data


def verify_data(tensor_data):
    """验证接收到的数据"""
    logger.info("Verifying received data...")

    non_zero_count = 0
    total_elements = 0

    for key, tensor in tensor_data:
        # 计算非零元素数量
        non_zero = torch.count_nonzero(tensor).item()
        total = tensor.numel()

        non_zero_count += non_zero
        total_elements += total

        if non_zero > 0:
            logger.info(f"Tensor {key.key}: {non_zero}/{total} non-zero elements "
                        f"(mean: {tensor.mean().item():.4f}, std: {tensor.std().item():.4f})")

    percentage = (non_zero_count / total_elements) * \
        100 if total_elements > 0 else 0
    logger.info(
        f"Overall: {non_zero_count}/{total_elements} non-zero elements ({percentage:.2f}%)")

    return non_zero_count > 0


def parse_args():
    parser = argparse.ArgumentParser(description="Infer端测试脚本 - 支持循环测试和MD5校验")
    parser.add_argument("--role_rank", type=int, default=0, help="role rank")
    parser.add_argument("--role_size", type=int, default=1, help="role size")
    parser.add_argument("--iterations", type=int,
                        default=5, help="循环测试次数 (默认: 5)")
    parser.add_argument("--sleep", type=int, default=3,
                        help="每次循环间隔秒数 (默认: 3)")
    parser.add_argument("--num_tensors", type=int,
                        default=20, help="tensor数量 (默认: 20)")
    parser.add_argument("--height", type=int, default=20000,
                        help="tensor高度 (默认: 20000)")
    parser.add_argument("--width", type=int, default=5000,
                        help="tensor宽度 (默认: 5000)")
    parser.add_argument("--seq_id", type=int, default=1, help="序列ID (默认: 1)")
    parser.add_argument("--output_dir", type=str, default="md5_output",
                        help="MD5输出目录 (默认: md5_output)")
    parser.add_argument('--md5-check', action='store_true',
                        default=os.getenv(
                            'ASTATE_ENABLE_MD5_CHECK', '1') == '1',
                        help='是否启用MD5校验，默认启用')
    parser.add_argument('--random-sleep-max', type=float, default=float(os.getenv('ASTATE_RANDOM_SLEEP_MAX', 5)),
                        help='每轮推理后最大随机sleep秒数，大于0启用随机sleep，默认5')
    parser.add_argument('--device', type=str, default='cpu', choices=['cpu', 'cuda'],
                        help='tensor创建设备 (默认: cpu, 可选: cuda)')
    # 新增分片参数
    parser.add_argument('--shard_rows', type=int, default=1,
                        help='分片行数 (默认: 1, 不分片)')
    parser.add_argument('--shard_cols', type=int, default=1,
                        help='分片列数 (默认: 1, 不分片)')
    return parser.parse_args()


def main():
    args = parse_args()
    enable_md5 = args.md5_check
    random_sleep_max = args.random_sleep_max
    logger.info("🚀 Starting Infer script...")

    # 创建REMOTE类型的TensorTable
    logger.info("Creating REMOTE TensorTable...")
    parallel_config = ParallelConfig.create_inference_config(
        role_size=args.role_size, role_rank=args.role_rank)
    table = astate.create_remote_table(
        "remote_tensor_table", parallel_config)
    logger.info("✅ TensorTable created")

    # 配置循环参数
    num_iterations = args.iterations
    sleep_between_iterations = args.sleep
    seq_id = args.seq_id

    # 记录总体统计
    total_times = []
    successful_iterations = 0
    complete_times = []
    md5_files = []  # 记录生成的MD5文件

    # 在循环外创建tensors，所有迭代使用同一批tensor
    logger.info(
        f"📦 创建共享的tensor数据 (tensors={args.num_tensors}, 尺寸={args.height}x{args.width}, 设备={args.device})...")
    logger.info(f"分片配置: {args.shard_rows}行 x {args.shard_cols}列")
    original_num_tensors, tensor_data = create_empty_tensors(
        num_tensors=args.num_tensors, height=args.height, width=args.width, 
        device=args.device, shard_rows=args.shard_rows, shard_cols=args.shard_cols)

    logger.info(f"🔄 开始执行 {num_iterations} 次 multi_get 循环测试...")
    logger.info(
        f"📋 测试参数: tensors={args.num_tensors}, 尺寸={args.height}x{args.width}, seq_id={seq_id}")
    logger.info(f"💡 注意: 所有迭代使用同一批tensor对象")

    for iteration in range(0, num_iterations):
        logger.info(f"\n🔄 == 第 {iteration}/{num_iterations} 次迭代 ===")

        try:
            # 在接收数据前，将所有tensor置零
            logger.info(f"[迭代{iteration}] 将tensor置零...")
            zero_tensors(tensor_data)

            # 执行multi_get
            logger.info(
                f"[迭代{iteration}] 调用 multi_get (seq_id={seq_id})...")

            start_time = time.time()
            # for key, tensor in tensor_data:
            #     print_refcount(tensor, key.key)
            success = table.multi_get(seq_id + iteration, tensor_data)
            # for key, tensor in tensor_data:
            #     print_refcount(tensor, key.key)
            end_time = time.time()

            # 计算并保存接收后的MD5值
            if enable_md5:
                logger.info(f"[迭代{iteration}] 计算接收后的tensor MD5值...")
                md5_file = write_md5_to_file(
                    tensor_data, iteration, seq_id + iteration, args.output_dir)
                md5_files.append(md5_file)

            logger.info(
                f"[迭代{iteration}] 调用 complete (seq_id={seq_id + iteration})...")
            table.complete(seq_id + iteration)
            complete_time = time.time()

            iteration_time = end_time - start_time
            total_times.append(iteration_time)
            complete_time = complete_time - end_time
            complete_times.append(complete_time)

            if success:
                successful_iterations += 1
                logger.info(
                    f"[迭代{iteration}] ✅ multi_get 成功完成，耗时 {iteration_time:.2f} 秒")
                logger.info(
                    f"[迭代{iteration}] 平均每个tensor时间: {iteration_time/len(tensor_data)*1000:.2f} ms")
                logger.info(
                    f"[迭代{iteration}] 调用 complete 耗时: {complete_time:.2f} 秒")

                # 验证接收到的数据
                if verify_data(tensor_data):
                    logger.info(f"[迭代{iteration}] ✅ 数据验证成功 - 接收到非零数据")
                else:
                    logger.warning(
                        f"[迭代{iteration}] ⚠️ 数据验证警告 - 所有tensors都为零")

            else:
                logger.error(f"[迭代{iteration}] ❌ multi_get 失败")

            # 随机sleep
            if random_sleep_max > 0 and iteration != num_iterations - 1:
                import random
                sleep_time = random.uniform(0, random_sleep_max)
                logger.info(
                    f"[迭代{iteration}] 本轮推理结束，随机sleep {sleep_time:.2f} 秒")
                time.sleep(sleep_time)
            # 在迭代之间添加延迟（除了最后一次）
            elif iteration < num_iterations:
                logger.info(
                    f"[迭代{iteration}] 等待 {sleep_between_iterations} 秒后继续下一次迭代...")
                time.sleep(sleep_between_iterations)

        except Exception as e:
            logger.error(f"[迭代{iteration}] ❌ 迭代过程中发生错误: {e}")
            import traceback
            traceback.print_exc()

    logger.info(f"Calling complete with seq_id={seq_id}...")
    table.complete(seq_id)

    # 输出总体统计
    logger.info(f"\n🎉 === 循环测试统计结果 ===")
    logger.info(f"总迭代次数: {num_iterations}")
    logger.info(f"成功次数: {successful_iterations}")
    logger.info(f"成功率: {successful_iterations/num_iterations*100:.1f}%")

    if total_times:
        logger.info(f"平均耗时: {sum(total_times)/len(total_times):.2f} 秒")
        logger.info(f"最快耗时: {min(total_times):.2f} 秒")
        logger.info(f"最慢耗时: {max(total_times):.2f} 秒")
        logger.info(f"总耗时: {sum(total_times):.2f} 秒")

        # 计算吞吐量统计
        avg_time = sum(total_times) / len(total_times)
        tensors_per_sec = original_num_tensors / avg_time
        mb_per_sec = (original_num_tensors * args.height *
                      # 假设float32
                      args.width * 4) / (1024 * 1024) / avg_time

        logger.info(f"平均吞吐量: {tensors_per_sec:.1f} tensors/秒")
        logger.info(f"平均数据吞吐量: {mb_per_sec:.1f} MB/秒")
        logger.info(f"分片后实际tensor数量: {len(tensor_data)} (原始: {original_num_tensors})")

    if complete_times:
        logger.info(
            f"平均complete耗时: {sum(complete_times)/len(complete_times):.2f} 秒")
        logger.info(f"最快complete耗时: {min(complete_times):.2f} 秒")
        logger.info(f"最慢complete耗时: {max(complete_times):.2f} 秒")
        logger.info(f"总complete耗时: {sum(complete_times):.2f} 秒")

    # 输出MD5文件信息
    logger.info(f"\n📁 === MD5文件信息 ===")
    logger.info(f"生成的MD5文件数量: {len(md5_files)}")
    for md5_file in md5_files:
        logger.info(f"MD5文件: {md5_file}")

    if successful_iterations == num_iterations:
        logger.info("🎉 所有迭代都成功完成！Infer script 测试通过！")
        return 0
    elif successful_iterations > 0:
        logger.warning(
            f"⚠️ 部分迭代成功，{num_iterations - successful_iterations} 次失败")
        return 1
    else:
        logger.error("❌ 所有迭代都失败了")
        return 1


if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)
