#!/bin/bash

# RT-Thread 自动化构建脚本（生产标准版）
# 功能：检测Python虚拟环境，支持跳过软件包更新，按顺序执行构建命令，出错立即终止
# 版本：4.0
# 修复的问题：
# 1. 修复脚本静默退出的问题
# 2. 增强错误信息输出
# 3. 优化调试信息

# 配置变量（集中管理，便于修改）
PROJECT_CORE_FILE="SConstruct"
FLASH_SCRIPT_REL_PATH="hotfix/openocd/flash2mcu.sh"
BUILD_OUTPUT_PATTERNS=("rtthread.*" "rt-thread.*")
REQUIRED_COMMANDS=("python" "scons" "pkgs")
LOG_RETENTION_DAYS=7
MIN_FILE_SIZE=1024

# 基础打印函数（不依赖颜色，用于最早期的输出）
print_basic_message() {
    local message="$1"
    echo "[INFO] $message" >&2
}

print_basic_warning() {
    local message="$1"
    echo "[WARNING] $message" >&2
}

print_basic_error() {
    local message="$1"
    echo "[ERROR] $message" >&2
}

# 检查是否为Bash环境
if [ -z "$BASH_VERSION" ]; then
    print_basic_error "此脚本需要在Bash环境下运行，当前Shell为: $(basename "$SHELL" 2>/dev/null || echo 'unknown')"
    print_basic_error "请使用以下方式运行: bash $0 或 chmod +x $0 && ./$0"
    exit 1
fi

# 检查Bash版本
BASH_MAJOR_VERSION=$(echo "$BASH_VERSION" | cut -d. -f1 2>/dev/null || echo "0")
if [ "$BASH_MAJOR_VERSION" -lt 4 ]; then
    print_basic_warning "检测到Bash版本较低: ${BASH_VERSION:-unknown}，建议升级到Bash 4.0及以上"
fi

# 检查脚本自身可执行权限
if [ ! -x "$0" ]; then
    print_basic_warning "当前脚本没有可执行权限，尝试添加执行权限..."
    if chmod +x "$0" 2>/dev/null; then
        print_basic_message "成功添加执行权限，请重新运行脚本"
    else
        print_basic_error "无法添加执行权限，请手动执行: chmod +x $0"
        exit 1
    fi
    exit 0
fi

# 设置错误处理：任何命令失败立即退出脚本
set -e
set -o pipefail 2>/dev/null || {
    print_basic_warning "当前Bash版本不支持pipefail选项，某些错误可能无法正确捕获"
}

# 颜色定义用于输出美化
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 重写打印函数以支持颜色
print_message() {
    local message="$1"
    echo -e "${BLUE}[INFO]${NC} $message" >&2
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARNING]${NC} $message" >&2
}

print_error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" >&2
}

print_success() {
    local message="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $message" >&2
}

print_status() {
    local message="$1"
    echo -e "${BLUE}[INFO]${NC} $message" >&2
}

# 调试模式控制
DEBUG_MODE=false
DEBUG_LOG="/tmp/rtthread_build_debug.log"

# 启用调试信息输出
debug_log() {
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] $1" >> "$DEBUG_LOG"
    fi
}

# 初始化变量
AUTO_CONFIRM=false
SKIP_PKGS=false
SKIP_FLASH=false
CLEAN_BUILD=false
FLASH_ONLY=false
ENABLE_LOGGING=false
CLEAN_OLD_LOGS=false
LOG_RETENTION=7
SCRIPT_NAME=$(basename "$0" 2>/dev/null || echo "build_rtthread.sh")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "$PWD")"

debug_log "脚本初始化完成: 名称=$SCRIPT_NAME, 目录=$SCRIPT_DIR"

# 显示使用说明
show_usage() {
    cat << EOF
用法: $SCRIPT_NAME [OPTIONS]
选项:
  -y, --auto          自动模式，跳过所有确认提示
      --no-pkgs       跳过软件包更新步骤 (pkgs --update)
      --no-flash      跳过烧录步骤 (hotfix/openocd/flash2mcu.sh)
  -c, --clean-build   强制执行清理构建 (scons -c)
  -fo, --flash-only   只执行烧录部分，跳过其他所有步骤
  -l, --log           启用日志记录到 logs/rtthread_build_<timestamp>.log
      --clean-logs N  清理超过N天的旧日志文件 (默认: 7)
  -d, --debug         启用调试模式
  -h, --help          显示此帮助信息

示例:
  $SCRIPT_NAME                     # 交互模式，每个步骤需要确认
  $SCRIPT_NAME -y                  # 自动模式，无需确认
  $SCRIPT_NAME -c                  # 强制清理构建
  $SCRIPT_NAME -fo                 # 只烧录，跳过其他步骤
  $SCRIPT_NAME --no-pkgs           # 跳过软件包更新
  $SCRIPT_NAME -c --no-flash       # 强制清理但不烧录
  $SCRIPT_NAME -y --no-pkgs -l     # 自动模式、跳过包更新并记录日志
  $SCRIPT_NAME -l --clean-logs 30  # 启用日志并清理30天前的旧日志
  $SCRIPT_NAME -d                  # 启用调试模式
EOF
}

# 参数解析
debug_log "开始解析参数: $*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--auto)
            AUTO_CONFIRM=true
            debug_log "设置 AUTO_CONFIRM=true"
            shift
            ;;
        --no-pkgs)
            SKIP_PKGS=true
            debug_log "设置 SKIP_PKGS=true"
            shift
            ;;
        --no-flash)
            SKIP_FLASH=true
            debug_log "设置 SKIP_FLASH=true"
            shift
            ;;
        -c|--clean-build)
            CLEAN_BUILD=true
            debug_log "设置 CLEAN_BUILD=true"
            shift
            ;;
        -fo|--flash-only)
            FLASH_ONLY=true
            debug_log "设置 FLASH_ONLY=true"
            shift
            ;;
        -l|--log)
            ENABLE_LOGGING=true
            debug_log "设置 ENABLE_LOGGING=true"
            shift
            ;;
        -d|--debug)
            DEBUG_MODE=true
            debug_log "设置 DEBUG_MODE=true"
            shift
            ;;
        --clean-logs)
            CLEAN_OLD_LOGS=true
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                LOG_RETENTION="$2"
                debug_log "设置 LOG_RETENTION=$LOG_RETENTION"
                shift 2
            else
                print_error "--clean-logs 参数需要一个数字参数"
                show_usage
                exit 1
            fi
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            print_error "错误: 未知选项 $1"
            show_usage
            exit 1
            ;;
    esac
done

debug_log "参数解析完成: AUTO_CONFIRM=$AUTO_CONFIRM, SKIP_PKGS=$SKIP_PKGS, SKIP_FLASH=$SKIP_FLASH, CLEAN_BUILD=$CLEAN_BUILD, FLASH_ONLY=$FLASH_ONLY"

# 参数冲突检查和处理
check_parameter_conflicts() {
    debug_log "开始检查参数冲突"

    # 处理冲突：FLASH_ONLY 和 SKIP_FLASH 不能同时指定
    if [ "$FLASH_ONLY" = true ] && [ "$SKIP_FLASH" = true ]; then
        print_error "参数冲突: --flash-only 和 --no-flash 不能同时使用"
        exit 1
    fi

    # 当 FLASH_ONLY=true 时，其他构建选项自动设为 false
    if [ "$FLASH_ONLY" = true ]; then
        if [ "$CLEAN_BUILD" = true ] || [ "$SKIP_PKGS" = true ]; then
            print_warning "注意: --flash-only 模式下，构建相关选项 (--clean-build, --no-pkgs) 将被忽略"
        fi
        CLEAN_BUILD=false
        SKIP_PKGS=true
    fi

    debug_log "参数冲突检查完成"
    return 0
}

# 检查参数冲突
check_parameter_conflicts

# 项目根目录检测
PROJECT_ROOT=""
LOG_FILE=""
FLASH_SCRIPT_PATH=""

# 清理旧日志文件
clean_old_logs() {
    local logs_dir="$1"
    local retention_days="$2"

    if [ ! -d "$logs_dir" ]; then
        return 0
    fi

    print_status "清理超过 ${retention_days} 天的旧日志文件..."
    debug_log "开始清理旧日志: 目录=$logs_dir, 保留天数=$retention_days"

    # 使用find命令查找并删除旧文件
    if find "$logs_dir" -name "rtthread_build_*.log" -type f -mtime +"$retention_days" 2>/dev/null | grep -q .; then
        find "$logs_dir" -name "rtthread_build_*.log" -type f -mtime +"$retention_days" -delete 2>/dev/null
        local result=$?
        if [ $result -eq 0 ]; then
            print_success "旧日志文件清理完成"
        else
            print_status "没有需要清理的旧日志文件"
        fi
    else
        print_status "没有需要清理的旧日志文件"
    fi
}

# 查找项目根目录（包含 SConstruct 文件的目录）
find_project_root() {
    local current_dir="$PWD"
    local test_dir="$current_dir"

    debug_log "开始查找项目根目录，当前目录: $current_dir"

    # 向上查找 SConstruct 文件
    while [[ "$test_dir" != "/" ]]; do
        debug_log "检查目录: $test_dir"
        if [[ -f "$test_dir/$PROJECT_CORE_FILE" ]]; then
            PROJECT_ROOT="$test_dir"
            print_status "找到项目根目录: $PROJECT_ROOT"
            debug_log "找到项目根目录: $PROJECT_ROOT"

            # 设置烧录脚本路径
            FLASH_SCRIPT_PATH="$PROJECT_ROOT/$FLASH_SCRIPT_REL_PATH"
            debug_log "烧录脚本路径: $FLASH_SCRIPT_PATH"

            # 设置日志文件路径
            local logs_dir="$PROJECT_ROOT/logs"
            if [ ! -d "$logs_dir" ]; then
                mkdir -p "$logs_dir"
                print_status "创建日志目录: $logs_dir"
                debug_log "创建日志目录: $logs_dir"
            fi

            # 清理旧日志
            if [ "$CLEAN_OLD_LOGS" = true ]; then
                clean_old_logs "$logs_dir" "$LOG_RETENTION"
            fi

            local timestamp=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo "unknown")
            LOG_FILE="$logs_dir/rtthread_build_${timestamp}.log"
            debug_log "日志文件路径: $LOG_FILE"

            return 0
        fi
        test_dir="$(dirname "$test_dir" 2>/dev/null || echo "/")"
    done

    print_error "未找到 RT-Thread 项目根目录（未找到 $PROJECT_CORE_FILE 文件）"
    print_error "请确保在 RT-Thread 项目目录或其子目录中运行此脚本"
    debug_log "未找到项目根目录"
    exit 1
}

# 查找项目根目录
debug_log "开始查找项目根目录"
find_project_root
debug_log "项目根目录查找完成: $PROJECT_ROOT"

# 定义日志函数（需要在 PROJECT_ROOT 和 LOG_FILE 设置之后）
log_message() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")

    if [ "$ENABLE_LOGGING" = true ]; then
        # 去除颜色代码后写入日志
        local clean_message=$(echo -e "$message" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" 2>/dev/null || echo "$message")
        echo "[$timestamp] [$level] $clean_message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# 重写打印函数以支持日志记录
print_status() {
    local message="$1"
    echo -e "${BLUE}[INFO]${NC} $message" >&2
    [ "$ENABLE_LOGGING" = true ] && log_message "$message" "INFO"
    debug_log "STATUS: $message"
}

print_success() {
    local message="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $message" >&2
    [ "$ENABLE_LOGGING" = true ] && log_message "$message" "SUCCESS"
    debug_log "SUCCESS: $message"
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARNING]${NC} $message" >&2
    [ "$ENABLE_LOGGING" = true ] && log_message "$message" "WARNING"
    debug_log "WARNING: $message"
}

print_error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" >&2
    [ "$ENABLE_LOGGING" = true ] && log_message "$message" "ERROR"
    debug_log "ERROR: $message"
}

# 检查命令是否存在
check_command() {
    local cmd="$1"
    debug_log "检查命令: $cmd"
    if ! command -v "$cmd" &> /dev/null; then
        print_error "命令 '$cmd' 未找到，请确保已安装"
        debug_log "命令未找到: $cmd"
        return 1
    fi
    debug_log "命令找到: $cmd -> $(command -v "$cmd")"
    return 0
}

# 检查必要的依赖命令
check_dependencies() {
    print_status "检查系统依赖..."
    debug_log "开始检查依赖: ${REQUIRED_COMMANDS[*]}"

    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! check_command "$cmd"; then
            print_error "缺少依赖命令: $cmd"
            print_error "请确保在虚拟环境中安装了所有必要的工具"
            if [ "$cmd" = "pkgs" ]; then
                print_error "pkgs 命令通常由 env 脚本提供，请确保已正确设置 RT-Thread 环境"
            fi
            debug_log "依赖检查失败: $cmd"
            return 1
        fi
    done

    print_success "所有依赖命令检查通过"
    debug_log "所有依赖命令检查通过"
    return 0
}

# 优雅退出函数
graceful_exit() {
    local exit_code=$?
    local signal=$1

    echo
    if [[ -n "$signal" ]]; then
        print_warning "构建过程被用户中断"
        [ "$ENABLE_LOGGING" = true ] && log_message "构建被用户中断" "WARNING"
        debug_log "构建被用户中断: 信号=$signal, 退出码=$exit_code"
    else
        print_error "构建过程中发生错误 (退出码: $exit_code)"
        [ "$ENABLE_LOGGING" = true ] && log_message "构建失败，退出码: $exit_code" "ERROR"
        debug_log "构建失败: 退出码=$exit_code"

        # 提供恢复建议
        echo
        print_status "建议:"
        echo "  1. 检查虚拟环境: source venv/bin/activate"
        echo "  2. 手动执行失败的命令"
        echo "  3. 查看详细错误信息"

        if [ "$ENABLE_LOGGING" = true ]; then
            echo "  4. 查看日志文件: $LOG_FILE"
        fi

        if [ "$DEBUG_MODE" = true ]; then
            echo "  5. 查看调试日志: $DEBUG_LOG"
        fi
    fi

    exit ${exit_code:-0}
}

# 设置信号处理
trap 'graceful_exit SIGINT' INT
trap 'graceful_exit SIGTERM' TERM
trap 'graceful_exit' ERR

# 检测Python虚拟环境
check_python_venv() {
    debug_log "检查Python虚拟环境"
    if [[ -z "${VIRTUAL_ENV}" ]]; then
        print_error "未检测到Python虚拟环境！"
        echo
        echo "请先激活RT-Thread的Python虚拟环境，例如："
        echo "  source $PROJECT_ROOT/venv/bin/activate"
        echo "或者"
        echo "  source ~/rt-thread/venv/bin/activate"
        echo
        echo "如果你还没有创建虚拟环境，可以使用以下命令创建："
        echo "  python -m venv $PROJECT_ROOT/venv"
        echo "  source $PROJECT_ROOT/venv/bin/activate"
        echo "  pip install -r $PROJECT_ROOT/requirements.txt  # 安装所需依赖"
        echo
        debug_log "未检测到Python虚拟环境"
        return 1
    else
        print_success "检测到Python虚拟环境: ${VIRTUAL_ENV}"
        debug_log "检测到Python虚拟环境: ${VIRTUAL_ENV}"
        return 0
    fi
}

# 确认继续函数
confirm_continue() {
    local step_name="$1"
    local command_desc="$2"

    if [ "$AUTO_CONFIRM" = true ]; then
        print_status "自动模式：执行 $step_name"
        debug_log "自动模式执行: $step_name"
        return 0
    fi

    echo
    print_warning "下一步: $step_name"
    print_status "命令: $command_desc"
    debug_log "等待用户确认: $step_name"

    # 使用更友好的提示
    while true; do
        echo -n "是否继续执行? [Y/n] " >&2
        read -r response

        # 清理输入缓冲区
        if read -t 0; then
            read -t 0.1
        fi

        case "$response" in
            [Yy]|"")
                debug_log "用户确认继续: $step_name"
                return 0
                ;;
            [Nn])
                print_warning "用户取消执行 $step_name"
                echo "构建过程已取消。"
                debug_log "用户取消: $step_name"
                exit 0
                ;;
            *)
                echo "无效输入，请输入 Y/y 或 N/n" >&2
                ;;
        esac
    done
}

# 检查烧录脚本
check_flash_script() {
    print_status "检查烧录脚本..."
    debug_log "检查烧录脚本: $FLASH_SCRIPT_PATH"

    # 检查烧录脚本是否存在
    if [ ! -f "$FLASH_SCRIPT_PATH" ]; then
        print_error "烧录脚本不存在: $FLASH_SCRIPT_PATH"
        print_status "请检查烧录脚本路径是否正确，或者是否在正确的项目目录中"
        debug_log "烧录脚本不存在: $FLASH_SCRIPT_PATH"
        return 1
    fi

    # 检查烧录脚本是否可执行
    if [ ! -x "$FLASH_SCRIPT_PATH" ]; then
        print_warning "烧录脚本不可执行，尝试添加执行权限..."
        if chmod +x "$FLASH_SCRIPT_PATH"; then
            print_success "成功添加执行权限"
            debug_log "添加执行权限成功: $FLASH_SCRIPT_PATH"
        else
            print_error "无法添加执行权限"
            debug_log "添加执行权限失败: $FLASH_SCRIPT_PATH"
            return 1
        fi
    fi

    print_success "烧录脚本检查通过: $FLASH_SCRIPT_PATH"
    debug_log "烧录脚本检查通过: $FLASH_SCRIPT_PATH"
    return 0
}

# 只执行烧录的函数
flash_only() {
    print_status "进入只烧录模式..."
    debug_log "进入flash_only模式"

    # 检查烧录脚本
    if ! check_flash_script; then
        debug_log "烧录脚本检查失败"
        exit 1
    fi

    confirm_continue "烧录到MCU" "bash \"$FLASH_SCRIPT_PATH\""
    print_status "正在烧录到MCU..."
    debug_log "开始执行烧录脚本"

    if [ "$ENABLE_LOGGING" = true ]; then
        # 使用脚本记录日志
        {
            echo "========================================"
            echo "开始烧录: $(date)"
            echo "烧录脚本: $FLASH_SCRIPT_PATH"
            echo "========================================"
        } >> "$LOG_FILE" 2>/dev/null || true

        # 执行烧录脚本，将输出同时显示在终端和日志文件
        bash "$FLASH_SCRIPT_PATH" 2>&1 | tee -a "$LOG_FILE" || {
            local result=$?
            debug_log "烧录脚本执行失败: 退出码=$result"
            return $result
        }
    else
        bash "$FLASH_SCRIPT_PATH" || {
            local result=$?
            debug_log "烧录脚本执行失败: 退出码=$result"
            return $result
        }
    fi

    local result=$?
    if [ $result -eq 0 ]; then
        print_success "烧录完成"
        debug_log "烧录成功完成"
    else
        print_error "烧录失败，退出码: $result"
        debug_log "烧录失败: 退出码=$result"
        exit $result
    fi

    exit 0
}

# 安全执行命令
safe_execute() {
    local cmd="$1"
    local description="$2"

    print_status "执行: $description"
    print_status "命令: $cmd"
    debug_log "开始执行命令: $description"
    debug_log "命令: $cmd"

    if [ "$ENABLE_LOGGING" = true ]; then
        log_message "开始执行: $description" "INFO"
        log_message "命令: $cmd" "INFO"

        # 记录命令开始
        {
            echo ">>> 开始执行: $description"
            echo ">>> 命令: $cmd"
            echo ">>> 时间: $(date)"
            echo ">>> 输出:"
        } >> "$LOG_FILE" 2>/dev/null || true

        # 执行命令并记录输出
        if bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE"; then
            local result=0
        else
            local result=$?
        fi

        {
            echo ">>> 结束: 退出码=$result"
            echo ""
        } >> "$LOG_FILE" 2>/dev/null || true
    else
        bash -c "$cmd"
        local result=$?
    fi

    debug_log "命令执行完成: $description, 退出码=$result"

    if [ $result -ne 0 ]; then
        print_error "命令执行失败: $description (退出码: $result)"
        debug_log "命令执行失败: $description, 退出码=$result"
        exit $result
    fi

    return 0
}

# 检查构建输出文件
check_build_output_files() {
    local found_files=false
    local empty_files=0
    local valid_files=0

    for pattern in "${BUILD_OUTPUT_PATTERNS[@]}"; do
        for file in $pattern; do
            if [ -f "$file" ]; then
                found_files=true
                local file_size
                file_size=$(du -b "$file" 2>/dev/null | cut -f1)

                if [ -z "$file_size" ]; then
                    # 如果du失败，尝试使用stat
                    if command -v stat >/dev/null 2>&1; then
                        file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
                    fi
                fi

                if [ -z "$file_size" ] || [ "$file_size" -eq 0 ]; then
                    print_warning "  - $file (空文件或无法获取大小，可能构建异常)"
                    empty_files=$((empty_files + 1))
                elif [ "$file_size" -lt "$MIN_FILE_SIZE" ]; then
                    print_warning "  - $file ($(du -h "$file" | cut -f1)，文件过小，可能构建异常)"
                else
                    echo "  - $file ($(du -h "$file" | cut -f1)B)"
                    valid_files=$((valid_files + 1))
                fi
            fi
        done
    done

    if [ "$found_files" = false ]; then
        echo "  (未找到构建输出文件)"
    elif [ "$empty_files" -gt 0 ]; then
        print_warning "发现 $empty_files 个空文件，请检查构建过程"
    fi

    return $valid_files
}

# 显示构建摘要
show_summary() {
    echo
    echo "========================================"
    print_success "构建完成摘要"
    echo "========================================"
    print_status "构建时间: $(date)"
    print_status "工作目录: $(pwd)"
    print_status "项目根目录: $PROJECT_ROOT"
    print_status "虚拟环境: ${VIRTUAL_ENV:-未激活}"

    if [ "$ENABLE_LOGGING" = true ]; then
        print_status "日志文件: $LOG_FILE"
    fi

    echo
    print_status "执行的步骤:"
    [ "$SKIP_PKGS" = true ] && echo "  ❌ 软件包更新" || echo "  ✅ 软件包更新"
    [ "$CLEAN_BUILD" = true ] && echo "  ✅ 清理构建" || echo "  ❌ 清理构建"
    echo "  ✅ 项目编译"
    [ "$SKIP_FLASH" = true ] && echo "  ❌ 烧录到MCU" || echo "  ✅ 烧录到MCU"

    echo
    print_status "生成的构建文件:"
    check_build_output_files
    local valid_files=$?

    echo
    print_status "参数配置:"
    echo "  AUTO_CONFIRM: $AUTO_CONFIRM"
    echo "  SKIP_PKGS:    $SKIP_PKGS"
    echo "  SKIP_FLASH:   $SKIP_FLASH"
    echo "  CLEAN_BUILD:  $CLEAN_BUILD"
    echo "  FLASH_ONLY:   $FLASH_ONLY"
    echo "  ENABLE_LOG:   $ENABLE_LOGGING"
    echo "  LOG_RETENTION: ${LOG_RETENTION}天"
    echo "  DEBUG_MODE:   $DEBUG_MODE"

    if [ "$valid_files" -eq 0 ] && [ "$SKIP_FLASH" = false ]; then
        print_warning "警告: 未发现有效的构建输出文件，烧录可能失败"
    fi
}

# 主执行函数
main() {
    print_status "开始 RT-Thread 构建流程..."
    print_status "脚本目录: $SCRIPT_DIR"
    print_status "工作目录: $PWD"
    print_status "项目根目录: $PROJECT_ROOT"

    if [ "$ENABLE_LOGGING" = true ]; then
        print_status "日志记录已启用，输出保存到: $LOG_FILE"
        {
            echo "========================================"
            echo "RT-Thread 构建日志 - $(date)"
            echo "========================================"
            echo "脚本: $SCRIPT_NAME"
            echo "参数: $@"
            echo "工作目录: $PWD"
            echo "项目根目录: $PROJECT_ROOT"
            echo "Bash版本: $BASH_VERSION"
            echo "========================================"
        } >> "$LOG_FILE" 2>/dev/null || true
    fi

    if [ "$DEBUG_MODE" = true ]; then
        print_status "调试模式已启用，调试日志: $DEBUG_LOG"
        echo "=== 调试信息开始 ===" > "$DEBUG_LOG"
        echo "时间: $(date)" >> "$DEBUG_LOG"
        echo "脚本: $SCRIPT_NAME" >> "$DEBUG_LOG"
        echo "参数: $@" >> "$DEBUG_LOG"
        echo "工作目录: $PWD" >> "$DEBUG_LOG"
        echo "项目根目录: $PROJECT_ROOT" >> "$DEBUG_LOG"
        echo "Bash版本: $BASH_VERSION" >> "$DEBUG_LOG"
        echo "=== 调试信息结束 ===" >> "$DEBUG_LOG"
    fi

    # 显示当前选项状态
    if [ "$SKIP_PKGS" = true ]; then
        print_status "已启用跳过软件包更新模式"
    fi
    if [ "$SKIP_FLASH" = true ]; then
        print_status "已启用跳过烧录模式"
    fi
    if [ "$CLEAN_BUILD" = true ]; then
        print_status "已启用强制清理构建模式"
    fi
    if [ "$AUTO_CONFIRM" = true ]; then
        print_status "已启用自动确认模式"
    fi
    if [ "$FLASH_ONLY" = true ]; then
        print_status "已启用只烧录模式"
    fi
    if [ "$CLEAN_OLD_LOGS" = true ]; then
        print_status "已启用日志清理模式 (保留 ${LOG_RETENTION} 天)"
    fi

    # 第一阶段: 检查系统依赖
    print_status "检查系统依赖..."
    if ! check_dependencies; then
        print_error "依赖检查失败，脚本终止"
        debug_log "依赖检查失败，主流程终止"
        exit 1
    fi

    # 第二阶段: 检测Python虚拟环境
    print_status "检查Python虚拟环境状态..."
    if ! check_python_venv; then
        print_error "虚拟环境检查失败，脚本终止"
        debug_log "虚拟环境检查失败，主流程终止"
        exit 1
    fi

    # 显示当前Python信息
    print_status "Python信息:"
    safe_execute "python --version" "检查Python版本"
    safe_execute "pip --version" "检查pip版本"

    # 第三阶段: 更新软件包（可跳过）
    if [ "$SKIP_PKGS" = true ]; then
        print_status "跳过软件包更新步骤 (--no-pkgs)"
    else
        confirm_continue "更新软件包" "pkgs --update"
        safe_execute "pkgs --update" "更新软件包"
    fi

    # 第四阶段: 清理构建（根据参数决定）
    if [ "$CLEAN_BUILD" = true ]; then
        confirm_continue "清理构建" "scons -c"
        safe_execute "scons -c" "清理构建文件"
    else
        print_status "跳过构建清理步骤 (未使用 -c/--clean-build 参数)"
    fi

    # 第五阶段: 编译项目
    confirm_continue "编译项目" "scons"
    safe_execute "scons" "编译项目"

    # 第六阶段: 烧录到MCU（可跳过）
    if [ "$SKIP_FLASH" = true ]; then
        print_status "跳过烧录步骤 (--no-flash)"
    else
        # 检查烧录脚本
        if ! check_flash_script; then
            print_error "烧录脚本检查失败，脚本终止"
            debug_log "烧录脚本检查失败，主流程终止"
            exit 1
        fi

        confirm_continue "烧录到MCU" "bash \"$FLASH_SCRIPT_PATH\""
        safe_execute "bash \"$FLASH_SCRIPT_PATH\"" "烧录到MCU"
    fi

    # 显示构建摘要
    show_summary
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 显示开始信息
    echo "========================================"
    echo "  RT-Thread 自动化构建脚本（生产标准版 v4.0）"
    echo "========================================"
    echo
    echo "参数: $@"
    echo
    echo "Bash版本: $BASH_VERSION"
    echo

    # 检查是否只执行烧录
    if [ "$FLASH_ONLY" = true ]; then
        flash_only
    fi

    # 执行主函数
    main "$@"
fi
