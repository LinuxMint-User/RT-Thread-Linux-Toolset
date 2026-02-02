#!/usr/bin/env python3
"""
RT-Thread编译环境专业检查工具
优化版本：状态改为文字描述，提高可读性
"""

import subprocess
import shutil
import platform
import os
import sys
import time
from pathlib import Path
from typing import Dict, List, Tuple, Optional, Union
import argparse
import json
import re
from dataclasses import dataclass, asdict, field
from enum import Enum


class CheckStatus(Enum):
    """检查状态枚举"""
    PASS = "通过"
    FAIL = "失败"
    WARNING = "警告"
    OPTIONAL = "可选"

    def __str__(self):
        """重写__str__方法，返回字符串值而不是枚举对象"""
        return self.value

    def get_symbol(self):
        """获取对应的符号"""
        symbols = {
            "通过": "✅",
            "失败": "❌",
            "警告": "⚠️",
            "可选": "🔧"
        }
        return symbols.get(self.value, self.value)


@dataclass
class ToolInfo:
    """工具信息"""
    name: str
    description: str
    required: bool
    min_version: Optional[str] = None
    max_version: Optional[str] = None
    install_cmd: Optional[Dict[str, str]] = None
    version_args: Optional[List[str]] = None
    test_cmd: Optional[List[str]] = None


@dataclass
class CheckResult:
    """检查结果"""
    tool_name: str
    description: str
    status: CheckStatus
    version: Optional[str] = None
    path: Optional[str] = None
    message: Optional[str] = None
    error: Optional[str] = None

    def to_dict(self):
        """转换为字典，确保枚举被正确序列化"""
        return {
            "tool_name": self.tool_name,
            "description": self.description,
            "status": str(self.status),  # 转换为字符串
            "version": self.version,
            "path": self.path,
            "message": self.message,
            "error": self.error
        }


class RTTEnvironmentChecker:
    """RT-Thread编译环境检查器"""

    # 超时配置
    TIMEOUT = 10  # 秒

    # 必要工具链
    REQUIRED_TOOLS = {
        "python3": ToolInfo(
            name="python3",
            description="Python 3解释器",
            required=True,
            min_version="3.8",
            version_args=["--version"],
            install_cmd={
                "debian": "apt install python3 python3-pip",
                "rhel": "dnf install python3 python3-pip",
                "arch": "pacman -S python python-pip",
                "opensuse": "zypper install python3 python3-pip"
            }
        ),
        "scons": ToolInfo(
            name="scons",
            description="SCons构建工具",
            required=True,
            min_version="4.0.0",
            version_args=["--version"],
            install_cmd={
                "debian": "pip3 install scons",
                "rhel": "pip3 install scons",
                "arch": "pip install scons",
                "opensuse": "pip3 install scons"
            }
        ),
        "arm-none-eabi-gcc": ToolInfo(
            name="arm-none-eabi-gcc",
            description="ARM GCC编译器",
            required=True,
            min_version="10.3.0",
            version_args=["--version"],
            install_cmd={
                "debian": "apt install gcc-arm-none-eabi",
                "rhel": "dnf install arm-none-eabi-gcc-cs",
                "arch": "pacman -S arm-none-eabi-gcc",
                "opensuse": "zypper install cross-arm-none-eabi-gcc"
            }
        ),
        "arm-none-eabi-objcopy": ToolInfo(
            name="arm-none-eabi-objcopy",
            description="ARM Objcopy工具",
            required=True,
            min_version="2.36",
            version_args=["--version"],
        ),
        "arm-none-eabi-size": ToolInfo(
            name="arm-none-eabi-size",
            description="ARM Size工具",
            required=True,
            min_version="2.36",
            version_args=["--version"],
        ),
    }

    # 可选工具
    OPTIONAL_TOOLS = {
        "arm-none-eabi-gdb": ToolInfo(
            name="arm-none-eabi-gdb",
            description="GDB调试器",
            required=False,
            min_version="10.1",
            version_args=["--version"],
            install_cmd={
                "debian": "apt install gdb-multiarch",
                "rhel": "dnf install gdb-gdbserver",
                "arch": "pacman -S arm-none-eabi-gdb",
                "opensuse": "zypper install gdb"
            }
        ),
        "openocd": ToolInfo(
            name="openocd",
            description="OpenOCD编程器",
            required=False,
            min_version="0.11.0",
            version_args=["-v"],  # OpenOCD使用-v参数获取版本
            install_cmd={
                "debian": "apt install openocd",
                "rhel": "dnf install openocd",
                "arch": "pacman -S openocd",
                "opensuse": "zypper install openocd"
            }
        ),
        "picocom": ToolInfo(
            name="picocom",
            description="串口终端",
            required=False,
            version_args=["--version"],
            install_cmd={
                "debian": "apt install picocom",
                "rhel": "dnf install picocom",
                "arch": "pacman -S picocom",
                "opensuse": "zypper install picocom"
            }
        ),
    }

    def __init__(self, verbose: bool = True, timeout: int = 10):
        self.verbose = verbose
        self.timeout = timeout
        self.results: List[CheckResult] = []
        self.distro_info = self._detect_distro()
        self.path_dirs = os.environ.get('PATH', '').split(':')
        self.packaging_available = self._check_packaging_module()
        self.script_dir = Path.cwd()

    def _check_packaging_module(self) -> bool:
        """检查packaging模块是否可用"""
        try:
            from packaging import version
            return True
        except ImportError:
            return False

    def _detect_distro(self) -> Dict[str, str]:
        """检测Linux发行版"""
        distro_info = {"id": "unknown", "name": "Unknown"}

        # 尝试读取/etc/os-release
        os_release_path = Path("/etc/os-release")
        if os_release_path.exists():
            try:
                with open(os_release_path, 'r') as f:
                    for line in f:
                        if line.startswith("ID="):
                            distro_info["id"] = line.strip().split('=', 1)[1].strip('"\'')
                        elif line.startswith("NAME="):
                            distro_info["name"] = line.strip().split('=', 1)[1].strip('"\'')
            except (IOError, PermissionError) as e:
                if self.verbose:
                    print(f"警告: 无法读取/etc/os-release: {e}")

        return distro_info

    def _run_command(self, cmd: List[str], capture_output: bool = True) -> Tuple[bool, str, str]:
        """
        安全运行命令，带超时和异常处理

        返回: (success, stdout, stderr)
        """
        try:
            result = subprocess.run(
                cmd,
                stdout=subprocess.PIPE if capture_output else None,
                stderr=subprocess.PIPE if capture_output else None,
                text=True,
                timeout=self.timeout,
                check=False
            )

            stdout = result.stdout if result.stdout else ""
            stderr = result.stderr if result.stderr else ""

            return (result.returncode == 0, stdout, stderr)

        except subprocess.TimeoutExpired:
            return (False, "", f"命令执行超时 ({self.timeout}秒)")
        except FileNotFoundError:
            return (False, "", "命令未找到")
        except PermissionError:
            return (False, "", "权限不足")
        except Exception as e:
            return (False, "", f"执行错误: {str(e)}")

    def _get_tool_version(self, tool_name: str, version_args: List[str] = None) -> Tuple[bool, Optional[str], str]:
        """
        获取工具版本，带完整异常处理

        返回: (success, version, error)
        """
        if version_args is None:
            version_args = ["--version"]

        cmd = [tool_name] + version_args
        success, stdout, stderr = self._run_command(cmd)

        if not success:
            return (False, None, stderr)

        # 从输出中提取版本号
        if stdout:
            # 查找版本号模式 x.y.z
            version_pattern = r'\b\d+\.\d+\.\d+\b'
            match = re.search(version_pattern, stdout)
            if match:
                return (True, match.group(0), "")

            # 查找版本号模式 x.y
            version_pattern = r'\b\d+\.\d+\b'
            match = re.search(version_pattern, stdout)
            if match:
                return (True, match.group(0), "")

        return (True, "unknown", "无法提取版本号")

    def _check_tool(self, tool_info: ToolInfo) -> CheckResult:
        """检查单个工具"""
        tool_path = shutil.which(tool_info.name)

        if not tool_path:
            return CheckResult(
                tool_name=tool_info.name,
                description=tool_info.description,
                status=CheckStatus.FAIL if tool_info.required else CheckStatus.WARNING,
                message="未安装",
                error=f"在PATH中未找到 {tool_info.name}"
            )

        # 检查工具是否可执行
        if not os.access(tool_path, os.X_OK):
            return CheckResult(
                tool_name=tool_info.name,
                description=tool_info.description,
                status=CheckStatus.FAIL if tool_info.required else CheckStatus.WARNING,
                path=tool_path,
                message="无执行权限",
                error=f"文件 {tool_path} 无执行权限"
            )

        # 获取版本
        version_args = tool_info.version_args
        success, version, error = self._get_tool_version(tool_info.name, version_args)

        if not success:
            return CheckResult(
                tool_name=tool_info.name,
                description=tool_info.description,
                status=CheckStatus.FAIL if tool_info.required else CheckStatus.WARNING,
                path=tool_path,
                version="unknown",
                message="存在但不可用",
                error=error
            )

        # 检查版本兼容性
        version_ok = True
        version_message = ""

        if tool_info.min_version and version != "unknown" and self.packaging_available:
            try:
                from packaging import version as pkg_version
                if pkg_version.parse(version) < pkg_version.parse(tool_info.min_version):
                    version_ok = False
                    version_message = f"版本过低 (当前: {version}, 需要: >={tool_info.min_version})"
            except Exception as e:
                # packaging版本解析可能出错，不影响基本功能
                version_message = f"版本检查出错: {str(e)[:50]}"
        elif tool_info.min_version and version != "unknown" and not self.packaging_available:
            version_message = "（packaging模块未安装，无法检查版本兼容性）"

        status = CheckStatus.PASS
        if not version_ok:
            status = CheckStatus.WARNING
        elif not tool_info.required:
            status = CheckStatus.OPTIONAL

        return CheckResult(
            tool_name=tool_info.name,
            description=tool_info.description,
            status=status,
            path=tool_path,
            version=version,
            message=version_message
        )

    def _check_pip_availability(self) -> CheckResult:
        """检查pip3是否可用"""
        success, stdout, stderr = self._run_command(["pip3", "--version"])

        if success:
            # 提取pip版本
            version_match = re.search(r'pip\s+(\d+\.\d+\.\d+)', stdout)
            version = version_match.group(1) if version_match else "unknown"

            return CheckResult(
                tool_name="pip3",
                description="Python包管理器",
                status=CheckStatus.PASS,
                version=version,
                message="已安装"
            )
        else:
            return CheckResult(
                tool_name="pip3",
                description="Python包管理器",
                status=CheckStatus.WARNING,
                message="未安装，将无法通过pip安装Python包",
                error=stderr
            )

    def _check_path_environment(self) -> List[CheckResult]:
        """检查PATH环境变量"""
        results = []

        # 检查常见工具链路径
        common_toolchain_paths = [
            "/usr/bin",
            "/usr/local/bin",
            "/opt/arm-gcc/bin",
            "/opt/gcc-arm-none-eabi/bin",
            "/opt/gnu-mcu-eclipse/arm-none-eabi-gcc/bin",
            os.path.expanduser("~/gcc-arm-none-eabi/bin"),
        ]

        missing_paths = []
        for path in common_toolchain_paths:
            if os.path.isdir(path) and path not in self.path_dirs:
                missing_paths.append(path)

        if missing_paths:
            # 去重并限制显示数量
            unique_paths = list(dict.fromkeys(missing_paths))
            paths_display = ", ".join(unique_paths[:3])
            if len(unique_paths) > 3:
                paths_display += f" 等 {len(unique_paths)} 个路径"

            results.append(CheckResult(
                tool_name="PATH",
                description="环境变量",
                status=CheckStatus.WARNING,
                message=f"工具链路径未加入PATH: {paths_display}"
            ))

        return results

    def run_checks(self) -> List[CheckResult]:
        """运行所有检查"""
        self.results = []

        if self.verbose:
            print(f"🔍 检查RT-Thread Linux编译环境")
            print(f"   系统: {self.distro_info['name']} ({self.distro_info['id']})")
            print(f"   Python: {platform.python_version()}")
            if not self.packaging_available:
                print(f"   注意: packaging模块未安装，部分版本检查功能受限")
                print(f"   可选安装: pip3 install packaging")
            print("=" * 60)

        # 检查必要工具
        for tool_name, tool_info in self.REQUIRED_TOOLS.items():
            result = self._check_tool(tool_info)
            self.results.append(result)

        # 检查可选工具
        for tool_name, tool_info in self.OPTIONAL_TOOLS.items():
            result = self._check_tool(tool_info)
            self.results.append(result)

        # 检查pip
        pip_result = self._check_pip_availability()
        self.results.append(pip_result)

        # 检查PATH
        path_results = self._check_path_environment()
        self.results.extend(path_results)

        return self.results

    def print_results(self):
        """打印检查结果"""
        if not self.results:
            return

        print("\n检查结果:")
        print("-" * 80)
        # 调整列宽，状态列使用4个字符宽度
        print(f"{'工具名称':<20} {'状态':<6} {'版本':<15} {'说明':<30}")
        print("-" * 80)

        for result in self.results:
            version = result.version if result.version else ""
            message = result.message if result.message else ""

            # 显示文字状态，不显示符号
            status_text = str(result.status)
            print(f"{result.description:<20} {status_text:<6} {version:<15} {message:<30}")

        print("-" * 80)

    def get_install_commands(self) -> Dict[str, List[str]]:
        """获取安装命令"""
        distro_id = self.distro_info['id']
        install_cmds = {}

        # 按工具类型分组
        required_missing = []
        optional_missing = []

        for result in self.results:
            if result.status == CheckStatus.FAIL:
                tool_info = None
                if result.tool_name in self.REQUIRED_TOOLS:
                    tool_info = self.REQUIRED_TOOLS[result.tool_name]
                    required_missing.append(result.tool_name)
                elif result.tool_name in self.OPTIONAL_TOOLS:
                    tool_info = self.OPTIONAL_TOOLS[result.tool_name]
                    optional_missing.append(result.tool_name)

                if tool_info and tool_info.install_cmd and distro_id in tool_info.install_cmd:
                    cmd = tool_info.install_cmd[distro_id]
                    install_cmds[result.tool_name] = cmd

        return {
            "required": required_missing,
            "optional": optional_missing,
            "commands": install_cmds
        }

    def print_recommendations(self):
        """打印建议"""
        print("\n📋 建议与修复:")
        print("=" * 60)

        # 检查失败的必要工具
        failed_required = [
            r for r in self.results
            if r.status == CheckStatus.FAIL and r.tool_name in self.REQUIRED_TOOLS
        ]

        if failed_required:
            print("1. 需要安装的必要工具:")
            for result in failed_required:
                print(f"   - {result.description} ({result.tool_name})")

            install_info = self.get_install_commands()
            if install_info["commands"]:
                print("\n   安装命令:")
                for tool, cmd in install_info["commands"].items():
                    if tool in [r.tool_name for r in failed_required]:
                        print(f"   sudo {cmd}  # 安装 {tool}")

        # 检查警告
        warnings = [r for r in self.results if r.status == CheckStatus.WARNING]
        if warnings:
            print("\n2. 警告:")
            for result in warnings:
                if result.message:
                    print(f"   - {result.description}: {result.message}")
                elif result.error:
                    print(f"   - {result.description}: {result.error}")

        # packaging模块提示
        if not self.packaging_available:
            print("\n3. 版本检查优化:")
            print("   - packaging模块未安装，无法进行精确的版本兼容性检查")
            print("     可选安装: pip3 install packaging")

        # PATH建议
        path_warnings = [r for r in self.results if "PATH" in r.description]
        if path_warnings:
            print("\n4. 环境变量设置:")
            for result in path_warnings:
                print(f"   - {result.message}")

            # 检测到的工具链路径（去重）
            tool_paths = set()
            for result in self.results:
                if result.path and "arm-none-eabi" in result.tool_name:
                    tool_dir = os.path.dirname(result.path)
                    if tool_dir and tool_dir not in self.path_dirs:
                        tool_paths.add(tool_dir)

            if tool_paths:
                print("\n   将以下路径添加到~/.bashrc或~/.zshrc:")
                for path in sorted(tool_paths):
                    print(f'   export PATH="{path}:$PATH"')

        # RT-Thread环境变量
        print("\n5. RT-Thread环境变量:")
        arm_gcc_path = None
        for result in self.results:
            if result.tool_name == "arm-none-eabi-gcc" and result.path:
                arm_gcc_path = os.path.dirname(os.path.dirname(result.path))
                break

        if arm_gcc_path:
            print(f'   export RTT_EXEC_PATH="{arm_gcc_path}"')
        else:
            print('   # 请先安装arm-none-eabi-gcc，然后设置:')
            print('   # export RTT_EXEC_PATH="你的工具链根目录"')

        print('   export RTT_CC=gcc')
        print('\n   应用配置: source ~/.bashrc 或 source ~/.zshrc')

        # 测试编译
        print("\n6. 测试编译:")
        print("   克隆RT-Thread示例项目:")
        print("   git clone https://github.com/RT-Thread/rt-thread.git")
        print("   cd rt-thread/bsp/stm32/stm32f407-atk-explorer")
        print("   scons")

    def get_summary(self) -> Dict:
        """获取检查摘要"""
        total = len(self.results)
        passed = len([r for r in self.results if r.status == CheckStatus.PASS])
        failed = len([r for r in self.results if r.status == CheckStatus.FAIL])
        warnings = len([r for r in self.results if r.status == CheckStatus.WARNING])

        return {
            "total": total,
            "passed": passed,
            "failed": failed,
            "warnings": warnings,
            "all_passed": (failed == 0),
            "distro": self.distro_info,
            "timestamp": time.time(),
            "packaging_available": self.packaging_available
        }

    def save_report(self, filepath: str = None):
        """保存检查报告到指定文件，如果不指定则保存到工具目录下的.env-reports子目录"""
        if filepath is None:
            # 默认保存到.env-reports子目录
            reports_dir = self.script_dir / ".env-reports"
            reports_dir.mkdir(exist_ok=True)

            # 生成带时间戳的报告文件名
            timestamp = time.strftime("%Y%m%d_%H%M%S")
            filepath = reports_dir / f"rt_env_report_{timestamp}.json"

        report = {
            "summary": self.get_summary(),
            "results": [r.to_dict() for r in self.results],
            "recommendations": self.get_install_commands()
        }

        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(report, f, indent=2, ensure_ascii=False)

            if self.verbose:
                print(f"\n📄 检查报告已保存到: {filepath}")
        except (IOError, PermissionError) as e:
            print(f"⚠️ 无法保存报告: {e}")


def main():
    """主函数"""
    parser = argparse.ArgumentParser(description='RT-Thread编译环境检查工具')
    parser.add_argument('--silent', '-s', action='store_true',
                       help='静默模式，只返回退出码')
    parser.add_argument('--json', '-j', action='store_true',
                       help='输出JSON格式结果')
    parser.add_argument('--timeout', '-t', type=int, default=10,
                       help='命令执行超时时间(秒)')
    parser.add_argument('--report', '-r', action='store_true',
                       help='保存报告到.env-reports目录')
    parser.add_argument('--report-path', type=str,
                       help='保存报告到指定路径')

    args = parser.parse_args()

    # 创建检查器
    checker = RTTEnvironmentChecker(verbose=not args.silent, timeout=args.timeout)

    # 运行检查
    results = checker.run_checks()

    # 输出结果
    if not args.silent:
        checker.print_results()
        checker.print_recommendations()

    # 保存报告
    if args.report_path:
        # 使用用户指定的路径
        checker.save_report(args.report_path)
    elif args.report:
        # 使用默认的.env-reports目录
        checker.save_report()

    # JSON输出
    if args.json:
        report = {
            "summary": checker.get_summary(),
            "results": [r.to_dict() for r in results]
        }
        print(json.dumps(report, indent=2, ensure_ascii=False))

    # 退出码
    summary = checker.get_summary()
    if args.silent:
        sys.exit(0 if summary["all_passed"] else 1)
    else:
        # 在总结行中仍然使用符号，以便于快速识别
        print(f"\n✅ 通过: {summary['passed']}, ⚠️ 警告: {summary['warnings']}, ❌ 失败: {summary['failed']}")
        if summary["all_passed"]:
            print("🎉 所有必要检查已通过，可以开始RT-Thread开发！")
            sys.exit(0)
        else:
            print("❌ 存在必要的环境缺失，请按照建议修复")
            sys.exit(1)


if __name__ == "__main__":
    main()
