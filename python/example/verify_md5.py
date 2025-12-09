#!/usr/bin/env python3
"""
MD5校验脚本
功能：读取train.py和infer.py生成的MD5文件，比较数据传输的正确性
支持批量校验多个迭代的结果
"""

import os
import sys
import argparse
import logging
from typing import Dict, List, Tuple, Set, Any
from collections import defaultdict

# 设置日志
logging.basicConfig(level=logging.INFO,
                    format='[MD5_VERIFY] %(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


def parse_md5_file(file_path: str) -> Dict[str, Tuple[str, str, str]]:
    """
    解析MD5文件
    返回: {tensor_key: (md5_hash, shape, dtype)}
    """
    md5_data = {}
    
    if not os.path.exists(file_path):
        logger.error(f"MD5文件不存在: {file_path}")
        return md5_data
    
    try:
        with open(file_path, 'r') as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                # 跳过注释和空行
                if line.startswith('#') or not line:
                    continue
                
                # 解析格式: tensor_key,md5_hash,shape,dtype
                parts = line.split(',')
                if len(parts) != 4:
                    logger.warning(f"[{file_path}:{line_num}] 格式错误: {line}")
                    continue
                
                tensor_key, md5_hash, shape, dtype = parts
                md5_data[tensor_key] = (md5_hash, shape, dtype)
        
        logger.info(f"✅ 成功解析MD5文件: {file_path} (包含 {len(md5_data)} 个tensor)")
        
    except Exception as e:
        logger.error(f"❌ 解析MD5文件失败 {file_path}: {e}")
    
    return md5_data


def find_md5_files(directory: str, pattern_prefix: str) -> List[str]:
    """
    查找指定目录下匹配模式的MD5文件
    """
    md5_files = []
    
    if not os.path.exists(directory):
        logger.warning(f"目录不存在: {directory}")
        return md5_files
    
    try:
        for filename in os.listdir(directory):
            if filename.startswith(pattern_prefix) and filename.endswith('.txt'):
                md5_files.append(os.path.join(directory, filename))
        
        md5_files.sort()  # 按文件名排序
        logger.info(f"在 {directory} 中找到 {len(md5_files)} 个 {pattern_prefix} 文件")
        
    except Exception as e:
        logger.error(f"❌ 搜索MD5文件失败 {directory}: {e}")
    
    return md5_files


def extract_iteration_and_seq(filename: str) -> Tuple[int, int]:
    """
    从文件名中提取迭代次数和序列ID
    例如: train_md5_iter0_seq1.txt -> (0, 1)
    """
    try:
        basename = os.path.basename(filename)
        # 移除扩展名
        name_without_ext = basename.replace('.txt', '')
        
        # 解析 iter 和 seq
        parts = name_without_ext.split('_')
        iter_part = None
        seq_part = None
        
        for part in parts:
            if part.startswith('iter'):
                iter_part = int(part[4:])  # 移除 'iter' 前缀
            elif part.startswith('seq'):
                seq_part = int(part[3:])   # 移除 'seq' 前缀
        
        if iter_part is not None and seq_part is not None:
            return (iter_part, seq_part)
        else:
            logger.warning(f"无法解析文件名: {filename}")
            return (-1, -1)
            
    except Exception as e:
        logger.error(f"解析文件名失败 {filename}: {e}")
        return (-1, -1)


def compare_md5_data(train_data: Dict[str, Tuple[str, str, str]], 
                    infer_data: Dict[str, Tuple[str, str, str]], 
                    iteration: int, seq_id: int) -> Dict[str, Any]:
    """
    比较训练端和推理端的MD5数据
    返回比较结果统计
    """
    result = {
        'iteration': iteration,
        'seq_id': seq_id,
        'total_train': len(train_data),
        'total_infer': len(infer_data),
        'matched': 0,
        'mismatched': 0,
        'train_only': 0,
        'infer_only': 0,
        'mismatched_details': [],
        'train_only_keys': [],
        'infer_only_keys': []
    }
    
    # 获取所有tensor键的集合
    train_keys = set(train_data.keys())
    infer_keys = set(infer_data.keys())
    
    # 共同的键
    common_keys = train_keys & infer_keys
    
    # 只在train中存在的键
    train_only_keys = train_keys - infer_keys
    result['train_only'] = len(train_only_keys)
    result['train_only_keys'] = list(train_only_keys)
    
    # 只在infer中存在的键
    infer_only_keys = infer_keys - train_keys
    result['infer_only'] = len(infer_only_keys)
    result['infer_only_keys'] = list(infer_only_keys)
    
    # 比较共同的键
    for key in common_keys:
        train_md5, train_shape, train_dtype = train_data[key]
        infer_md5, infer_shape, infer_dtype = infer_data[key]
        
        if train_md5 == infer_md5 and train_shape == infer_shape and train_dtype == infer_dtype:
            result['matched'] += 1
        else:
            result['mismatched'] += 1
            result['mismatched_details'].append({
                'key': key,
                'train_md5': train_md5,
                'infer_md5': infer_md5,
                'train_shape': train_shape,
                'infer_shape': infer_shape,
                'train_dtype': train_dtype,
                'infer_dtype': infer_dtype,
                'md5_match': train_md5 == infer_md5,
                'shape_match': train_shape == infer_shape,
                'dtype_match': train_dtype == infer_dtype
            })
    
    return result


def print_comparison_result(result: Dict[str, Any], verbose: bool = False):
    """打印比较结果"""
    iteration = result['iteration']
    seq_id = result['seq_id']
    
    logger.info(f"\n🔍 === 迭代 {iteration} (seq_id={seq_id}) 校验结果 ===")
    logger.info(f"训练端tensor数量: {result['total_train']}")
    logger.info(f"推理端tensor数量: {result['total_infer']}")
    logger.info(f"✅ 匹配成功: {result['matched']}")
    logger.info(f"❌ 匹配失败: {result['mismatched']}")
    logger.info(f"⚠️ 仅训练端存在: {result['train_only']}")
    logger.info(f"⚠️ 仅推理端存在: {result['infer_only']}")
    
    # 计算成功率
    if result['total_train'] > 0 or result['total_infer'] > 0:
        total_expected = max(result['total_train'], result['total_infer'])
        success_rate = (result['matched'] / total_expected) * 100 if total_expected > 0 else 0
        logger.info(f"📊 数据传输成功率: {success_rate:.2f}%")
    
    # 详细信息
    if verbose:
        if result['mismatched_details']:
            logger.info(f"\n❌ 不匹配的tensor详情:")
            for detail in result['mismatched_details'][:5]:  # 只显示前5个
                logger.info(f"  - {detail['key']}:")
                logger.info(f"    MD5匹配: {detail['md5_match']}")
                logger.info(f"    形状匹配: {detail['shape_match']}")
                logger.info(f"    数据类型匹配: {detail['dtype_match']}")
                if not detail['md5_match']:
                    logger.info(f"    训练端MD5: {detail['train_md5']}")
                    logger.info(f"    推理端MD5: {detail['infer_md5']}")
        
        if result['train_only_keys']:
            logger.info(f"\n⚠️ 仅训练端存在的tensor: {result['train_only_keys'][:5]}")
        
        if result['infer_only_keys']:
            logger.info(f"\n⚠️ 仅推理端存在的tensor: {result['infer_only_keys'][:5]}")


def main():
    parser = argparse.ArgumentParser(description="MD5校验脚本 - 验证数据传输正确性")
    parser.add_argument("--md5_dir", type=str, default="md5_output",
                        help="MD5文件所在目录 (默认: md5_output)")
    parser.add_argument("--verbose", action="store_true",
                        help="显示详细的校验信息")
    parser.add_argument("--iteration", type=int, default=None,
                        help="指定校验特定迭代，不指定则校验所有")
    args = parser.parse_args()

    logger.info("🚀 开始MD5校验...")
    logger.info(f"MD5文件目录: {args.md5_dir}")

    try:
        # 查找训练端和推理端的MD5文件
        train_files = find_md5_files(args.md5_dir, "train_md5")
        infer_files = find_md5_files(args.md5_dir, "infer_md5")

        if not train_files:
            logger.error("❌ 未找到训练端MD5文件")
            return 1

        if not infer_files:
            logger.error("❌ 未找到推理端MD5文件")
            return 1

        # 按迭代和序列ID组织文件
        train_files_dict = {}
        infer_files_dict = {}

        for file_path in train_files:
            iteration, seq_id = extract_iteration_and_seq(file_path)
            if iteration >= 0 and seq_id >= 0:
                train_files_dict[(iteration, seq_id)] = file_path

        for file_path in infer_files:
            iteration, seq_id = extract_iteration_and_seq(file_path)
            if iteration >= 0 and seq_id >= 0:
                infer_files_dict[(iteration, seq_id)] = file_path

        logger.info(f"找到 {len(train_files_dict)} 个训练端文件")
        logger.info(f"找到 {len(infer_files_dict)} 个推理端文件")

        # 找到共同的(iteration, seq_id)对
        common_pairs = set(train_files_dict.keys()) & set(infer_files_dict.keys())

        if not common_pairs:
            logger.error("❌ 未找到匹配的训练端和推理端文件对")
            return 1

        logger.info(f"找到 {len(common_pairs)} 个匹配的文件对")

        # 过滤特定迭代
        if args.iteration is not None:
            common_pairs = [(it, seq) for it, seq in common_pairs if it == args.iteration]
            logger.info(f"筛选迭代 {args.iteration}，共 {len(common_pairs)} 个文件对")

        if not common_pairs:
            logger.error(f"❌ 未找到迭代 {args.iteration} 的文件对")
            return 1

        # 逐个比较
        overall_results = []
        total_matched = 0
        total_mismatched = 0
        total_pairs = len(common_pairs)

        for iteration, seq_id in sorted(common_pairs):
            train_file = train_files_dict[(iteration, seq_id)]
            infer_file = infer_files_dict[(iteration, seq_id)]

            logger.info(f"\n🔄 处理迭代 {iteration} (seq_id={seq_id})...")
            logger.info(f"训练端文件: {os.path.basename(train_file)}")
            logger.info(f"推理端文件: {os.path.basename(infer_file)}")

            # 解析MD5文件
            train_data = parse_md5_file(train_file)
            infer_data = parse_md5_file(infer_file)

            if not train_data or not infer_data:
                logger.error(f"❌ 跳过迭代 {iteration} - 文件解析失败")
                continue

            # 比较数据
            result = compare_md5_data(train_data, infer_data, iteration, seq_id)
            overall_results.append(result)

            # 打印结果
            print_comparison_result(result, args.verbose)

            total_matched += result['matched']
            total_mismatched += result['mismatched']

        # 打印总体统计
        logger.info(f"\n🎉 === 总体校验结果 ===")
        logger.info(f"校验的文件对数量: {total_pairs}")
        logger.info(f"总匹配成功: {total_matched}")
        logger.info(f"总匹配失败: {total_mismatched}")
        
        if total_matched + total_mismatched > 0:
            overall_success_rate = (total_matched / (total_matched + total_mismatched)) * 100
            logger.info(f"总体成功率: {overall_success_rate:.2f}%")
        
        # 统计完全成功的迭代
        perfect_iterations = [r for r in overall_results if r['mismatched'] == 0 and r['train_only'] == 0 and r['infer_only'] == 0]
        logger.info(f"完全匹配的迭代数: {len(perfect_iterations)}/{len(overall_results)}")

        if len(perfect_iterations) == len(overall_results) and total_mismatched == 0:
            logger.info("🎉 所有数据传输校验成功！")
            return 0
        elif total_matched > 0:
            logger.warning("⚠️ 部分数据传输校验成功")
            return 1
        else:
            logger.error("❌ 所有数据传输校验失败")
            return 1

    except Exception as e:
        logger.error(f"❌ MD5校验过程中发生错误: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code) 