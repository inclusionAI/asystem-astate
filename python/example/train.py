#!/usr/bin/env python3
"""
Trainer端测试脚本
功能：初始化TensorTable，创建指定数量和大小的torch.Tensor，调用multi_put
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
import random

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
                    format='[TRAINER] %(asctime)s - %(levelname)s - %(message)s')
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
    """将tensor的MD5值写入文件"""
    os.makedirs(output_dir, exist_ok=True)

    md5_filename = os.path.join(
        output_dir, f"train_md5_iter{iteration}_seq{seq_id}.txt")

    logger.info(f"计算并写入MD5值到文件: {md5_filename}")

    with open(md5_filename, 'w') as f:
        f.write(
            f"# Trainer MD5 values - Iteration {iteration}, Seq ID {seq_id}\n")
        f.write(f"# Format: tensor_key,md5_hash,shape,dtype\n")

        for key, tensor in tensor_data:
            md5_hash = calculate_tensor_md5(tensor)
            shape_str = "x".join(map(str, tensor.shape))
            dtype_str = str(tensor.dtype)

            f.write(f"{key.key},{md5_hash},{shape_str},{dtype_str}\n")

    logger.info(f"✅ MD5值已写入文件: {md5_filename}")
    return md5_filename


def create_test_tensors(num_tensors=100, height=4000, width=500, device='cpu'):
    """创建测试用的tensor数据"""
    logger.info(f"Creating {num_tensors} tensors of size {height}x{width} on {device}")

    # 检查CUDA可用性
    if device == 'cuda' and not torch.cuda.is_available():
        logger.warning("CUDA不可用，回退到CPU")
        device = 'cpu'
    
    # 设置设备
    torch_device = torch.device(device)
    logger.info(f"使用设备: {torch_device}")

    tensor_data = []
    for i in range(num_tensors):
        # 创建随机数据tensor，指定设备
        tensor = torch.randn(height, width, dtype=torch.float32, device=torch_device)

        # 创建ShardedKey
        key = ShardedKey()
        key.key = f"tensor_{i:03d}"
        key.globalShape = [height, width]
        key.globalOffset = [0, 0]

        tensor_data.append((key, tensor))

        if (i + 1) % 10 == 0:
            logger.info(f"Created {i + 1} tensors on {device}...")

    logger.info(f"✅ Created {num_tensors} tensors successfully on {device}")
    return tensor_data


def verify_data_generation(tensor_data):
    """验证生成的数据"""
    logger.info("Verifying generated data...")

    non_zero_count = 0
    total_elements = 0

    for key, tensor in tensor_data:
        # 计算非零元素数量
        non_zero = torch.count_nonzero(tensor).item()
        total = tensor.numel()

        non_zero_count += non_zero
        total_elements += total

        if (key.key == "tensor_000" or key.key == "tensor_099"):  # 只记录第一个和最后一个
            logger.info(f"Tensor {key.key}: {non_zero}/{total} non-zero elements "
                        f"(mean: {tensor.mean().item():.4f}, std: {tensor.std().item():.4f})")

    percentage = (non_zero_count / total_elements) * \
        100 if total_elements > 0 else 0
    logger.info(
        f"Overall: {non_zero_count}/{total_elements} non-zero elements ({percentage:.2f}%)")

    return non_zero_count > 0


def parse_args():
    parser = argparse.ArgumentParser(description="Trainer端测试脚本 - 支持循环测试和MD5校验")
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
    return parser.parse_args()


def main():
    args = parse_args()
    enable_md5 = args.md5_check
    random_sleep_max = args.random_sleep_max
    logger.info("🚀 Starting Trainer script...")

    try:
        # 创建REMOTE类型的TensorTable
        logger.info("Creating REMOTE TensorTable...")
        parallel_config = ParallelConfig.create_training_config(
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
        complete_times = []
        successful_iterations = 0
        md5_files = []  # 记录生成的MD5文件

        # 在循环外创建tensors，所有迭代使用同一批tensor
        logger.info(
            f"📦 创建共享的tensor数据 (tensors={args.num_tensors}, 尺寸={args.height}x{args.width}, 设备={args.device})...")
        tensor_data = create_test_tensors(
            num_tensors=args.num_tensors, height=args.height, width=args.width, device=args.device)

        # 验证生成的数据
        if verify_data_generation(tensor_data):
            logger.info("✅ 数据生成验证成功 - 包含非零数据")
        else:
            logger.warning("⚠️ 数据生成验证警告 - 所有tensors都为零")

        logger.info(f"🔄 开始执行 {num_iterations} 次 multi_put 循环测试...")
        logger.info(
            f"📋 测试参数: tensors={args.num_tensors}, 尺寸={args.height}x{args.width}, seq_id={seq_id}")
        logger.info(f"💡 注意: 所有迭代使用同一批tensor对象")

        for iteration in range(0, num_iterations):
            logger.info(f"\n🔄 === 第 {iteration}/{num_iterations} 次迭代 ===")

            try:
                # 计算并保存MD5值
                if enable_md5:
                    logger.info(f"[迭代{iteration}] 计算tensor MD5值...")
                    md5_file = write_md5_to_file(
                        tensor_data, iteration, seq_id + iteration, args.output_dir)
                    md5_files.append(md5_file)

                # 执行multi_put
                logger.info(
                    f"[迭代{iteration}] 调用 multi_put (seq_id={seq_id})...")

                start_time = time.time()
                # for key, tensor in tensor_data:
                #     print_refcount(tensor, key.key)
                success = table.multi_put(seq_id + iteration, tensor_data)
                # for key, tensor in tensor_data:
                #     print_refcount(tensor, key.key)
                end_time = time.time()

                # 调用complete
                logger.info(f"[迭代{iteration}] 调用 complete...")
                complete_start_time = time.time()
                table.complete(seq_id + iteration)
                complete_end_time = time.time()

                iteration_time = end_time - start_time
                total_times.append(iteration_time)

                complete_time = complete_end_time - complete_start_time
                complete_times.append(complete_time)

                if success:
                    logger.info(
                        f"[迭代{iteration}] ✅ multi_put 成功完成，耗时 {iteration_time:.2f} 秒")
                    logger.info(
                        f"[迭代{iteration}] 平均每个tensor时间: {iteration_time/len(tensor_data)*1000:.2f} ms")

                    logger.info(
                        f"[迭代{iteration}] ✅ complete 成功完成，耗时 {complete_time:.2f} 秒")
                    successful_iterations += 1

                else:
                    logger.error(f"[迭代{iteration}] ❌ multi_put 失败")

                # 在迭代之间添加延迟（除了最后一次）
                if iteration < num_iterations:
                    if random_sleep_max > 0 and iteration != num_iterations - 1:
                        sleep_time = random.uniform(0, random_sleep_max)
                        logger.info(f"[随机sleep] 本轮sleep {sleep_time:.2f} 秒")
                        time.sleep(sleep_time)
                    else:
                        logger.info(
                            f"[迭代{iteration}] 等待 {sleep_between_iterations} 秒后继续下一次迭代...")
                        time.sleep(sleep_between_iterations)

            except Exception as e:
                logger.error(f"[迭代{iteration}] ❌ 迭代过程中发生错误: {e}")
                import traceback
                traceback.print_exc()

        # 输出总体统计
        logger.info(f"\n🎉 === 循环测试统计结果 ===")
        logger.info(f"总迭代次数: {num_iterations}")
        logger.info(f"成功次数: {successful_iterations}")
        logger.info(f"成功率: {successful_iterations/num_iterations*100:.1f}%")

        if total_times:
            logger.info(
                f"multi_put 平均耗时: {sum(total_times)/len(total_times):.2f} 秒")
            logger.info(f"multi_put 最快耗时: {min(total_times):.2f} 秒")
            logger.info(f"multi_put 最慢耗时: {max(total_times):.2f} 秒")
            logger.info(f"multi_put 总耗时: {sum(total_times):.2f} 秒")

        if complete_times:
            logger.info(
                f"complete 平均耗时: {sum(complete_times)/len(complete_times):.2f} 秒")
            logger.info(f"complete 最快耗时: {min(complete_times):.2f} 秒")
            logger.info(f"complete 最慢耗时: {max(complete_times):.2f} 秒")
            logger.info(f"complete 总耗时: {sum(complete_times):.2f} 秒")

        if total_times:
            # 计算吞吐量统计
            avg_time = sum(total_times) / len(total_times)
            tensors_per_sec = args.num_tensors / avg_time
            mb_per_sec = (args.num_tensors * args.height *
                          # 假设float32
                          args.width * 4) / (1024 * 1024) / avg_time

            logger.info(f"平均吞吐量: {tensors_per_sec:.1f} tensors/秒")
            logger.info(f"平均数据吞吐量: {mb_per_sec:.1f} MB/秒")

        # 输出MD5文件信息
        logger.info(f"\n📁 === MD5文件信息 ===")
        logger.info(f"生成的MD5文件数量: {len(md5_files)}")
        for md5_file in md5_files:
            logger.info(f"MD5文件: {md5_file}")

        if successful_iterations == num_iterations:
            logger.info("🎉 所有迭代都成功完成！Trainer script 测试通过！")
            return 0
        elif successful_iterations > 0:
            logger.warning(
                f"⚠️ 部分迭代成功，{num_iterations - successful_iterations} 次失败")
            return 1
        else:
            logger.error("❌ 所有迭代都失败了")
            return 1

    except Exception as e:
        logger.error(f"❌ Trainer script 发生严重错误: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)
