#!/usr/bin/env python3
"""
RT-Thread BSP配置迁移工具
从Windows风格的rtconfig.py迁移到Linux风格
原理：分析提取关键信息，生成新的Linux友好配置
"""

import os
import re
import sys
import shutil
import ast
import getopt
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Tuple, Optional, Any

class RTConfigAnalyzer:
    """分析rtconfig.py文件，提取关键信息"""

    def __init__(self, file_path: str):
        self.file_path = Path(file_path)
        self.content = self.file_path.read_text(encoding='utf-8', errors='ignore')
        self.variables = {}
        self.functions = {}
        self.parsed_successfully = False
        self.dist_handle_code = ""
        self.link_script_path = None
        self.all_defines = set()
        self.all_includes = set()

        # GCC不支持的关键字列表
        self.unsupported_gcc_keywords = [
            '--apcs=interwork',
            '-D__MICROLIB',
            '--pd "__MICROLIB SETA 1"',
            '--library_type=microlib',
            '--cpu Cortex-M4.fp',
            '--diag_suppress Pa050',
            '-Dewarm',
            '--no_cse',
            '--no_unroll',
            '--no_inline',
            '--no_code_motion',
            '--no_tbaa',
            '--no_clustering',
            '--no_scheduling',
            '--target=arm-arm-none-eabi',
            '--list rt-thread.map',
            '--strict',
        ]

        # Windows路径模式
        self.windows_path_patterns = [
            r'C:\\Users\\.*',
            r'C:/.*',
            r'D:\\Progrem\\.*',
            r'Program Files.*',
        ]

    def analyze(self) -> Dict[str, Any]:
        """分析文件，返回结构化信息"""
        result = {
            'arch': None,
            'cpu': None,
            'cross_tool': None,
            'platform': None,
            'exec_path': None,
            'build': 'debug',
            'gcc_config': {},
            'unsupported_configs': [],
            'original_variables': {},
            'dist_handle_found': False,
            'linker_script': None,
            'defines': set(),
            'includes': set(),
        }

        # 首先提取dist_handle函数
        self._extract_dist_handle()

        # 提取链接脚本路径
        self._extract_link_script()

        # 方法1：尝试解析Python语法树
        try:
            tree = ast.parse(self.content)
            self._extract_from_ast(tree, result)
            self.parsed_successfully = True
        except SyntaxError as e:
            print(f"⚠️  AST解析失败，使用正则表达式提取: {e}")
            self._extract_with_regex(result)

        # 分析编译参数
        self._analyze_compiler_flags_fixed(result)

        # 提取宏定义和包含路径
        self._extract_defines_and_includes_fixed()

        result['dist_handle_found'] = bool(self.dist_handle_code)
        result['linker_script'] = self.link_script_path
        result['defines'] = self.all_defines
        result['includes'] = self.all_includes
        return result

    def _extract_from_ast(self, tree: ast.AST, result: Dict[str, Any]):
        """从AST提取变量"""
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        var_name = target.id
                        try:
                            # 尝试评估值
                            var_value = ast.literal_eval(node.value)
                            result['original_variables'][var_name] = var_value

                            # 收集关键变量
                            if var_name in ['ARCH', 'arch']:
                                result['arch'] = var_value
                            elif var_name in ['CPU', 'cpu']:
                                result['cpu'] = var_value
                            elif var_name in ['CROSS_TOOL', 'CROSS_TOOL']:
                                result['cross_tool'] = var_value
                            elif var_name in ['PLATFORM', 'platform']:
                                result['platform'] = var_value
                            elif var_name in ['EXEC_PATH', 'exec_path']:
                                result['exec_path'] = var_value
                            elif var_name in ['BUILD', 'build']:
                                result['build'] = var_value

                        except (ValueError, SyntaxError):
                            # 不是字面量，记录表达式
                            result['original_variables'][var_name] = ast.unparse(node.value)

    def _extract_with_regex(self, result: Dict[str, Any]):
        """使用正则表达式提取变量（当AST解析失败时）"""
        patterns = {
            'ARCH': r'ARCH\s*=\s*[\'"]([^\'"]+)[\'"]',
            'CPU': r'CPU\s*=\s*[\'"]([^\'"]+)[\'"]',
            'CROSS_TOOL': r'CROSS_TOOL\s*=\s*[\'"]([^\'"]+)[\'"]',
            'PLATFORM': r'PLATFORM\s*=\s*[\'"]([^\'"]+)[\'"]',
            'EXEC_PATH': r'EXEC_PATH\s*=\s*(.+?)(?:\n|$)',
            'BUILD': r'BUILD\s*=\s*[\'"]([^\'"]+)[\'"]',
        }

        for var_name, pattern in patterns.items():
            match = re.search(pattern, self.content, re.IGNORECASE)
            if match:
                value = match.group(1).strip('\'"')
                result['original_variables'][var_name] = value

                if var_name == 'ARCH':
                    result['arch'] = value
                elif var_name == 'CPU':
                    result['cpu'] = value
                elif var_name == 'CROSS_TOOL':
                    result['cross_tool'] = value
                elif var_name == 'PLATFORM':
                    result['platform'] = value
                elif var_name == 'EXEC_PATH':
                    result['exec_path'] = value
                elif var_name == 'BUILD':
                    result['build'] = value

    def _extract_dist_handle(self):
        """专门提取dist_handle函数"""
        # 查找def dist_handle函数
        pattern = r'def\s+dist_handle\s*\([^)]*\)\s*:(.*?)(?=\n\s*def\s|\n\s*$|\Z)'
        match = re.search(pattern, self.content, re.DOTALL)

        if match:
            # 获取完整函数定义
            func_start = self.content.find(match.group(0))
            func_end = func_start + len(match.group(0))

            # 向前找到def行开始
            def_line_start = self.content.rfind('\n', 0, func_start) + 1
            self.dist_handle_code = self.content[def_line_start:func_end]
        else:
            # 尝试更宽松的匹配
            pattern2 = r'def\s+dist_handle\s*\(.*?\).*?(?:\n{2,}|\Z)'
            match2 = re.search(pattern2, self.content, re.DOTALL)
            if match2:
                self.dist_handle_code = match2.group(0)

    def _extract_link_script(self):
        """提取链接脚本路径"""
        # 查找链接脚本模式
        patterns = [
            r'-T\s+([\w/\.\-_]+\.lds?)',
            r'link_script\s*=\s*[\'"]([^\'"]+)[\'"]',
            r'LINK_SCRIPT\s*=\s*[\'"]([^\'"]+)[\'"]',
        ]

        for pattern in patterns:
            match = re.search(pattern, self.content)
            if match:
                self.link_script_path = match.group(1)
                if self.link_script_path:
                    # 统一路径分隔符
                    self.link_script_path = self.link_script_path.replace('\\', '/')
                print(f"找到链接脚本: {self.link_script_path}")
                break

        # 如果没有找到，检查常见位置
        if not self.link_script_path:
            common_paths = [
                'board/linker_scripts/link.lds',
                'linker_scripts/link.lds',
                'scripts/link.lds',
                'link.lds',
                'linker.ld',
            ]
            bsp_dir = self.file_path.parent
            for path in common_paths:
                if (bsp_dir / path).exists():
                    self.link_script_path = path
                    print(f"发现链接脚本: {path}")
                    break

    def _analyze_compiler_flags_fixed(self, result: Dict[str, Any]):
        """修复的编译参数分析函数 - 支持无引号赋值"""
        unsupported = []

        # 修复的正则表达式：匹配 CFLAGS, AFLAGS, LFLAGS 的各种赋值方式
        flag_patterns = {
            'CFLAGS': r'CFLAGS\s*[+:]?=\s*(.+?)(?=\n\s*\w+\s*[=:]|\n\s*$|#)',
            'AFLAGS': r'AFLAGS\s*[+:]?=\s*(.+?)(?=\n\s*\w+\s*[=:]|\n\s*$|#)',
            'LFLAGS': r'LFLAGS\s*[+:]?=\s*(.+?)(?=\n\s*\w+\s*[=:]|\n\s*$|#)',
        }

        for flag_name, pattern in flag_patterns.items():
            matches = re.findall(pattern, self.content, re.IGNORECASE | re.MULTILINE | re.DOTALL)
            for match in matches:
                # 清理匹配的字符串
                flag_value = match.strip()
                # 移除行尾注释
                flag_value = re.sub(r'#.*$', '', flag_value)
                # 移除首尾的单引号、双引号和加号
                flag_value = flag_value.strip('"\'+ \t\n')

                if flag_value:
                    # 检查不支持的GCC关键字
                    for keyword in self.unsupported_gcc_keywords:
                        if keyword in flag_value:
                            unsupported.append({
                                'flag': flag_name,
                                'value': flag_value,
                                'unsupported_keyword': keyword
                            })
                            break

        result['unsupported_configs'] = unsupported

    def _extract_defines_and_includes_fixed(self):
        """修复的提取宏定义和包含路径函数 - 简化逻辑避免语法错误"""
        # 简单但可靠的提取方法：从整个文件中查找-D和-I参数
        # 查找所有 -Dxxx 和 -Ixxx 模式
        define_pattern = r'-D([\w_][\w\d_]*)'
        include_pattern = r'-I([^\s\'"]+)'

        # 提取所有-D定义
        for match in re.findall(define_pattern, self.content):
            if match and match != 'gcc' and f'-D{match}' not in self.unsupported_gcc_keywords:
                self.all_defines.add(match)

        # 提取所有-I包含路径
        for match in re.findall(include_pattern, self.content):
            if match and match.strip() and not match.startswith('+'):
                self.all_includes.add(match)

    def is_windows_path(self, path: str) -> bool:
        """检查是否为Windows路径"""
        if not path:
            return False
        path_lower = path.lower()
        return any(pattern.lower() in path_lower for pattern in self.windows_path_patterns)

class RTConfigGenerator:
    """生成Linux友好的rtconfig.py"""

    def __init__(self, analyzer: RTConfigAnalyzer, analysis: Dict[str, Any]):
        self.analyzer = analyzer
        self.analysis = analysis
        self.generated_lines = []
        self.removed_flags = []

    def generate(self) -> str:
        """生成新的rtconfig.py内容"""
        self.generated_lines = []

        # 头部注释
        self._add_header()

        # 导入
        self.generated_lines.append('import os')
        self.generated_lines.append('')

        # 基本配置
        self._add_basic_config()

        # 工具链配置
        self._add_toolchain_config()

        # GCC配置
        self._add_gcc_config()

        # dist_handle函数
        if self.analyzer.dist_handle_code:
            self.generated_lines.append('')
            self.generated_lines.append('# ====================================================')
            self.generated_lines.append('# 发布处理函数 (从原始文件保留)')
            self.generated_lines.append('# ====================================================')
            self.generated_lines.append(self.analyzer.dist_handle_code)

        return '\n'.join(self.generated_lines)

    def _add_header(self):
        """添加文件头"""
        self.generated_lines.append('#!/usr/bin/env python3')
        self.generated_lines.append('"""')
        self.generated_lines.append(f'RT-Thread BSP配置文件')
        self.generated_lines.append(f'从原始配置自动迁移生成，适配Linux环境')
        self.generated_lines.append(f'原始文件: {Path(self.analysis.get("original_file", "")).name}')
        self.generated_lines.append(f'生成时间: {self._get_timestamp()}')
        self.generated_lines.append('"""')
        self.generated_lines.append('')

    def _add_basic_config(self):
        """添加基本配置"""
        arch = self.analysis.get('arch', 'arm')
        cpu = self.analysis.get('cpu', 'cortex-m4')
        build = self.analysis.get('build', 'debug')

        self.generated_lines.append('# ====================================================')
        self.generated_lines.append('# 基本配置')
        self.generated_lines.append('# ====================================================')
        self.generated_lines.append(f'ARCH = \'{arch}\'')
        self.generated_lines.append(f'CPU = \'{cpu}\'')
        self.generated_lines.append(f'CROSS_TOOL = \'gcc\'')
        self.generated_lines.append('')
        self.generated_lines.append('# BSP库类型')
        self.generated_lines.append('BSP_LIBRARY_TYPE = None')
        self.generated_lines.append('')

        # 环境变量
        self.generated_lines.append('# 环境变量覆盖')
        self.generated_lines.append('if os.getenv(\'RTT_CC\'):')
        self.generated_lines.append('    CROSS_TOOL = os.getenv(\'RTT_CC\')')
        self.generated_lines.append('if os.getenv(\'RTT_ROOT\'):')
        self.generated_lines.append('    RTT_ROOT = os.getenv(\'RTT_ROOT\')')
        self.generated_lines.append('')

        # 工具链选择
        self.generated_lines.append('# 工具链选择 - Linux下只支持GCC')
        self.generated_lines.append('if CROSS_TOOL == \'gcc\':')
        self.generated_lines.append('    PLATFORM = \'gcc\'')
        self.generated_lines.append('    EXEC_PATH = \'/usr/bin\'  # Linux默认路径')
        self.generated_lines.append('elif CROSS_TOOL == \'keil\':')
        self.generated_lines.append('    print(\"警告: Keil MDK在Linux下不可用，请切换到GCC\")')
        self.generated_lines.append('    PLATFORM = \'armcc\'')
        self.generated_lines.append('    EXEC_PATH = \'/usr/bin\'')
        self.generated_lines.append('elif CROSS_TOOL == \'iar\':')
        self.generated_lines.append('    print(\"警告: IAR在Linux下不可用，请切换到GCC\")')
        self.generated_lines.append('    PLATFORM = \'iccarm\'')
        self.generated_lines.append('    EXEC_PATH = \'/usr/bin\'')
        self.generated_lines.append('else:')
        self.generated_lines.append('    print(f\"不支持的编译器: {CROSS_TOOL}\")')
        self.generated_lines.append('    exit(1)')
        self.generated_lines.append('')

        # 环境变量路径覆盖
        self.generated_lines.append('if os.getenv(\'RTT_EXEC_PATH\'):')
        self.generated_lines.append('    EXEC_PATH = os.getenv(\'RTT_EXEC_PATH\')')
        self.generated_lines.append('')

        self.generated_lines.append(f'BUILD = \'{build}\'')
        self.generated_lines.append('')

    def _add_toolchain_config(self):
        """添加工具链配置"""
        self.generated_lines.append('# ====================================================')
        self.generated_lines.append('# GCC工具链配置')
        self.generated_lines.append('# ====================================================')
        self.generated_lines.append('if PLATFORM == \'gcc\':')

        # 从原始配置中提取有用的参数
        cpu = self.analysis.get('cpu', 'cortex-m4')
        fpu = self._determine_fpu(cpu)
        float_abi = 'hard' if fpu else 'soft'

        # 工具定义
        self.generated_lines.append('    # 工具链命令')
        self.generated_lines.append('    PREFIX = \'arm-none-eabi-\'')
        self.generated_lines.append('    CC = PREFIX + \'gcc\'')
        self.generated_lines.append('    AS = PREFIX + \'gcc\'')
        self.generated_lines.append('    AR = PREFIX + \'ar\'')
        self.generated_lines.append('    CXX = PREFIX + \'g++\'')
        self.generated_lines.append('    LINK = PREFIX + \'gcc\'')
        self.generated_lines.append('    TARGET_EXT = \'elf\'')
        self.generated_lines.append('    SIZE = PREFIX + \'size\'')
        self.generated_lines.append('    OBJDUMP = PREFIX + \'objdump\'')
        self.generated_lines.append('    OBJCPY = PREFIX + \'objcopy\'')
        self.generated_lines.append('')

    def _add_gcc_config(self):
        """添加GCC编译参数"""
        cpu = self.analysis.get('cpu', 'cortex-m4')
        fpu = self._determine_fpu(cpu)
        float_abi = 'hard' if fpu else 'soft'

        # 设备参数
        device_flags = f' -mcpu={cpu} -mthumb'
        if fpu:
            device_flags += f' -mfpu={fpu} -mfloat-abi={float_abi}'
        device_flags += ' -ffunction-sections -fdata-sections'

        self.generated_lines.append('    # 编译参数')
        self.generated_lines.append(f'    DEVICE = \'{device_flags}\'')

        # CFLAGS - 从原始配置中提取，但过滤不支持的
        cflags = self._generate_safe_cflags_fixed(device_flags)
        self.generated_lines.append(f'    CFLAGS = DEVICE + \'{cflags}\'')

        # AFLAGS
        self.generated_lines.append(f'    AFLAGS = \' -c\' + DEVICE + \' -x assembler-with-cpp -Wa,-mimplicit-it=thumb \'')

        # LFLAGS - 使用探测到的链接脚本路径
        ld_script = self.analysis.get('linker_script', 'board/linker_scripts/link.lds')
        self.generated_lines.append(f'    LFLAGS = DEVICE + \' -Wl,--gc-sections,-Map=rt-thread.map,-cref,-u,Reset_Handler -T {ld_script}\'')

        self.generated_lines.append('    CPATH = \'\'')
        self.generated_lines.append('    LPATH = \'\'')
        self.generated_lines.append('')

        # 优化选项
        build = self.analysis.get('build', 'debug')
        self.generated_lines.append('    if BUILD == \'debug\':')
        self.generated_lines.append('        CFLAGS += \' -O0 -gdwarf-2 -g\'')
        self.generated_lines.append('        AFLAGS += \' -gdwarf-2\'')
        self.generated_lines.append('    else:')
        self.generated_lines.append('        CFLAGS += \' -O2\'')
        self.generated_lines.append('')

        # C++标志
        self.generated_lines.append('    CXXFLAGS = CFLAGS')
        self.generated_lines.append('')

        # 构建后操作
        self.generated_lines.append('    POST_ACTION = OBJCPY + \' -O binary $TARGET rtthread.bin\\n\' + SIZE + \' $TARGET \\n\'')
        self.generated_lines.append('')

        # 其他编译器支持（但只定义，不会被执行）
        self._add_other_compiler_stubs()

        self.generated_lines.append('else:')
        self.generated_lines.append('    print(\'不支持的平台: \' + PLATFORM)')
        self.generated_lines.append('    exit(1)')
        self.generated_lines.append('')

    def _add_other_compiler_stubs(self):
        """添加其他编译器存根（不会被执行，但保留结构）"""
        self.generated_lines.append('elif PLATFORM == \'armcc\':')
        self.generated_lines.append('    # ARMCC配置 (Linux下不可用)')
        self.generated_lines.append('    print(\"错误: ARMCC在Linux下不可用，请使用GCC\")')
        self.generated_lines.append('    exit(1)')
        self.generated_lines.append('')
        self.generated_lines.append('elif PLATFORM == \'armclang\':')
        self.generated_lines.append('    # ARMClang配置 (Linux下不可用)')
        self.generated_lines.append('    print(\"错误: ARMClang在Linux下不可用，请使用GCC\")')
        self.generated_lines.append('    exit(1)')
        self.generated_lines.append('')
        self.generated_lines.append('elif PLATFORM == \'iccarm\':')
        self.generated_lines.append('    # IAR配置 (Linux下不可用)')
        self.generated_lines.append('    print(\"错误: IAR在Linux下不可用，请使用GCC\")')
        self.generated_lines.append('    exit(1)')
        self.generated_lines.append('')

    def _determine_fpu(self, cpu: str) -> str:
        """根据CPU确定FPU类型"""
        fpu_map = {
            'cortex-m4': 'fpv4-sp-d16',
            'cortex-m7': 'fpv5-d16',
            'cortex-m33': 'fpv5-sp-d16',
        }
        return fpu_map.get(cpu, '')

    def _generate_safe_cflags_fixed(self, device_flags: str) -> str:
        """修复的CFLAGS生成函数 - 保留所有-D和-I参数，但避免语法错误"""
        safe_flags = ' -Dgcc'

        # 从原始配置中提取有用的标志
        defines = self.analysis.get('defines', set())
        includes = self.analysis.get('includes', set())

        # 添加所有-D定义
        for define in sorted(defines):
            safe_flags += f' -D{define}'

        # 添加所有-I包含路径
        for include in sorted(includes):
            # 确保包含路径是有效的
            if include and include.strip():
                safe_flags += f' -I{include}'

        # 尝试从原始配置中提取其他有用的标志
        original_cflags = ''
        for config in self.analysis.get('unsupported_configs', []):
            if config['flag'] == 'CFLAGS':
                original_cflags = config['value']
                break

        if original_cflags:
            # 过滤掉已知不支持的选项
            filtered_flags = original_cflags
            for keyword in self.analyzer.unsupported_gcc_keywords:
                filtered_flags = filtered_flags.replace(keyword, '')

            # 提取有用的通用选项
            useful_patterns = [
                r'(-fstack-usage)',
                r'(-fdump-rtl-\w+)',
                r'(-std=\w+)',
            ]

            for pattern in useful_patterns:
                match = re.search(pattern, filtered_flags)
                if match:
                    safe_flags += ' ' + match.group(1)

        return safe_flags

    def _get_timestamp(self) -> str:
        """获取当前时间戳"""
        return datetime.now().strftime('%Y-%m-%d %H:%M:%S')

def generate_migration_report(analyzer: RTConfigAnalyzer, analysis: Dict[str, Any],
                             backup_path: str, report_path: str, output_path: str) -> str:
    """生成迁移报告"""
    report_lines = []

    report_lines.append('=' * 60)
    report_lines.append('RT-Thread BSP配置迁移报告')
    report_lines.append('=' * 60)
    report_lines.append('')

    # 基本信息
    report_lines.append('📋 基本信息')
    report_lines.append('-' * 40)
    report_lines.append(f'原始文件: {analysis.get("original_file", "N/A")}')
    report_lines.append(f'架构: {analysis.get("arch", "N/A")}')
    report_lines.append(f'CPU: {analysis.get("cpu", "N/A")}')
    report_lines.append(f'原始编译器: {analysis.get("cross_tool", "N/A")}')
    report_lines.append(f'构建类型: {analysis.get("build", "N/A")}')
    report_lines.append(f'链接脚本: {analysis.get("linker_script", "未找到，使用默认")}')
    report_lines.append(f'dist_handle函数: {"找到" if analysis.get("dist_handle_found") else "未找到"}')
    report_lines.append('')

    # 宏定义和包含路径
    report_lines.append('🔧 提取的编译参数')
    report_lines.append('-' * 40)
    defines = analysis.get('defines', set())
    includes = analysis.get('includes', set())

    if defines:
        report_lines.append('✅ 宏定义 (-D):')
        for define in sorted(defines):
            report_lines.append(f'  -D{define}')
    else:
        report_lines.append('⚠️ 未提取到宏定义')

    report_lines.append('')

    if includes:
        report_lines.append('✅ 头文件路径 (-I):')
        for include in sorted(includes):
            report_lines.append(f'  -I{include}')
    else:
        report_lines.append('⚠️ 未提取到头文件路径')

    report_lines.append('')

    # 修改内容
    report_lines.append('🔧 修改内容')
    report_lines.append('-' * 40)

    # Windows路径处理
    exec_path = analysis.get('exec_path', '')
    if exec_path and analyzer.is_windows_path(exec_path):
        report_lines.append('✓ Windows路径已替换为Linux路径')
        report_lines.append(f'  原始: {exec_path}')
        report_lines.append('  新: /usr/bin (可通过RTT_EXEC_PATH环境变量覆盖)')
    else:
        report_lines.append('✓ 路径配置无需修改')

    report_lines.append('✓ 简化了编译器支持，主要保留GCC')
    report_lines.append('✓ 自动探测链接脚本路径')
    report_lines.append('')

    # 不支持的配置
    unsupported = analysis.get('unsupported_configs', [])
    if unsupported:
        report_lines.append('⚠️ 不支持的编译参数（已移除）')
        report_lines.append('-' * 40)
        for config in unsupported:
            report_lines.append(f'  {config["flag"]}:')
            report_lines.append(f'    原因: 包含GCC不支持的选项 "{config["unsupported_keyword"]}"')
            report_lines.append(f'    原始值: {config["value"][:100]}...')
            report_lines.append('')
    else:
        report_lines.append('✅ 所有编译参数都兼容GCC')
        report_lines.append('')

    # 新文件信息
    report_lines.append('📁 生成的文件')
    report_lines.append('-' * 40)
    report_lines.append(f'输出文件: {output_path}')
    report_lines.append(f'备份文件: {backup_path}')
    report_lines.append(f'报告文件: {report_path}')
    report_lines.append('')

    # 使用说明
    report_lines.append('🚀 使用说明')
    report_lines.append('-' * 40)
    report_lines.append('1. 编译测试: scons')
    report_lines.append('2. 如果编译失败，检查工具链路径:')
    report_lines.append('   export RTT_EXEC_PATH=/path/to/your/toolchain')
    report_lines.append('3. 如果链接脚本路径不正确，请手动修改LFLAGS中的-T参数')
    report_lines.append('4. 恢复原始配置:')
    report_lines.append(f'   cp {backup_path} {output_path}')
    report_lines.append('')

    report_lines.append('=' * 60)

    return '\n'.join(report_lines)

def ensure_logs_dir(bsp_dir: Path) -> Path:
    """确保日志目录存在，返回日志目录路径"""
    logs_dir = bsp_dir / "migration_logs"
    logs_dir.mkdir(exist_ok=True)
    return logs_dir

def generate_timestamp() -> str:
    """生成时间戳字符串"""
    return datetime.now().strftime('%Y%m%d_%H%M%S')

def confirm_overwrite(file_path: Path) -> bool:
    """确认是否覆盖文件"""
    if not file_path.exists():
        return True

    print(f"\n⚠️  目标文件已存在: {file_path}")
    print("是否覆盖? [y/N] ", end='')

    try:
        response = input().strip().lower()
        return response in ['y', 'yes', '是']
    except KeyboardInterrupt:
        print("\n操作已取消")
        return False

def main():
    """主函数"""
    print("🛠️  RT-Thread BSP配置迁移工具 (稳定版)")
    print("=" * 50)

    # 解析命令行参数
    force = False
    opts, args = getopt.getopt(sys.argv[1:], "fh", ["force", "help"])

    for opt, arg in opts:
        if opt in ("-f", "--force"):
            force = True
        elif opt in ("-h", "--help"):
            print("用法: python3 convert-rtconfig.py [选项] <rtconfig.py路径>")
            print("选项:")
            print("  -f, --force  强制覆盖，无需确认")
            print("  -h, --help   显示此帮助信息")
            print("")
            print("示例:")
            print("  python3 convert-rtconfig.py rtconfig.py")
            print("  python3 convert-rtconfig.py --force rtconfig.py")
            sys.exit(0)

    if len(args) != 1:
        print("用法: python3 convert-rtconfig.py [选项] <rtconfig.py路径>")
        print("示例: python3 convert-rtconfig.py rtconfig.py")
        print("      将生成整洁的migration_logs目录存放所有日志文件")
        sys.exit(1)

    input_file = Path(args[0])
    if not input_file.exists():
        print(f"❌ 文件不存在: {input_file}")
        sys.exit(1)

    # 确认覆盖
    if not force and not confirm_overwrite(input_file):
        print("操作已取消")
        sys.exit(0)

    # 创建日志目录
    bsp_dir = input_file.parent
    logs_dir = ensure_logs_dir(bsp_dir)
    print(f"📁 日志目录: {logs_dir}")

    # 生成带时间戳的文件名
    timestamp = generate_timestamp()
    file_stem = input_file.stem
    backup_filename = f"{file_stem}.{timestamp}.backup.py"
    report_filename = f"{file_stem}.{timestamp}.migration_report.txt"

    # 完整的日志文件路径
    backup_file = logs_dir / backup_filename
    report_file = logs_dir / report_filename

    # 备份原始文件到日志目录
    print(f"📋 备份原始文件到: {backup_file}")
    shutil.copy2(input_file, backup_file)

    # 分析原始文件
    print("🔍 分析原始配置...")
    analyzer = RTConfigAnalyzer(input_file)
    analysis = analyzer.analyze()
    analysis['original_file'] = str(input_file)

    # 生成新配置
    print("🔄 生成Linux配置...")
    generator = RTConfigGenerator(analyzer, analysis)
    new_content = generator.generate()

    # 写入新文件（覆盖原rtconfig.py）
    output_file = input_file
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(new_content)

    # 生成报告
    print("📊 生成迁移报告...")
    report = generate_migration_report(analyzer, analysis, str(backup_file),
                                      str(report_file), str(output_file))

    # 保存报告到日志目录
    with open(report_file, 'w', encoding='utf-8') as f:
        f.write(report)

    # 验证生成的文件
    print("\n🧪 验证生成的文件...")
    try:
        with open(output_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        print(f"✅ 新配置文件已生成: {output_file} ({len(lines)} 行)")

        # 检查关键配置
        with open(output_file, 'r', encoding='utf-8') as f:
            content = f.read()
            if 'PLATFORM = \'gcc\'' in content and 'EXEC_PATH = \'/usr/bin\'' in content:
                print("✅ 关键配置验证通过")
            else:
                print("⚠️  关键配置可能不完整，请检查生成的文件")

        # 检查dist_handle是否保留
        if analysis.get('dist_handle_found'):
            with open(output_file, 'r', encoding='utf-8') as f:
                if 'def dist_handle' in f.read():
                    print("✅ dist_handle函数已保留")
                else:
                    print("⚠️  dist_handle函数未找到，但应该存在")

    except Exception as e:
        print(f"❌ 验证失败: {e}")

    print("\n" + "="*50)
    print("🎉 迁移完成！")
    print("="*50)
    print("🎯 目录结构:")
    print(f"  {bsp_dir}/")
    print(f"  ├── rtconfig.py              # 新生成的配置文件")
    print(f"  └── migration_logs/          # 迁移日志目录")
    print(f"      ├── {backup_filename}    # 原始文件备份")
    print(f"      └── {report_filename}    # 详细迁移报告")
    print()
    print("🚀 接下来:")
    print("1. 运行: scons  # 测试编译")
    print("2. 查看报告了解修改详情: cat migration_logs/*.migration_report.txt")
    print("3. 如需恢复: cp migration_logs/*.backup.py rtconfig.py")
    print("="*50)

if __name__ == "__main__":
    main()
