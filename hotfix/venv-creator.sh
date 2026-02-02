#!/bin/bash
# RT-Thread Python虚拟环境创建与配置脚本
# 版本: 1.6.0
# 描述: 自动创建Python虚拟环境并安装RT-Thread开发依赖
# 修复: 修复show_completion_info函数中颜色显示问题

set -euo pipefail  # 更严格的安全设置

# 颜色和样式定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # 重置颜色

# 配置变量
readonly SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly DEFAULT_VENV_NAME="rt-thread-venv"
readonly DEFAULT_REQUIREMENTS="requirements.txt"

# RT-Thread环境路径（非readonly，因为可能在configure_rtthread中修改）
RT_THREAD_ENV_PATH="$HOME/.env/env.sh"

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} $1" >&2; }

# 显示使用帮助
show_usage() {
    cat << EOF
${BOLD}RT-Thread虚拟环境配置工具${NC}
版本: 1.6.0

${BOLD}使用方法:${NC}
  $SCRIPT_NAME [选项] [虚拟环境名称]

${BOLD}选项:${NC}
  -h, --help            显示此帮助信息
  -y, --yes             自动确认所有提示
  -n, --name NAME       指定虚拟环境名称
  -r, --requirements FILE 指定requirements.txt文件路径
  --no-rt-thread        不配置RT-Thread环境
  --debug               启用调试模式
  --force               强制删除已存在的目录
  --skip-deps-check     跳过系统依赖检查
  --skip-pip-upgrade    跳过pip升级
  --mirror URL          指定PyPI镜像源URL
  --no-mirror           不使用镜像源

${BOLD}示例:${NC}
  $SCRIPT_NAME                     # 交互式创建虚拟环境
  $SCRIPT_NAME -y                  # 自动确认所有提示
  $SCRIPT_NAME --name my-env       # 指定环境名称为my-env
  $SCRIPT_NAME --force --yes       # 强制模式，自动确认
  $SCRIPT_NAME --mirror https://pypi.tuna.tsinghua.edu.cn/simple/  # 使用清华源

${BOLD}环境变量:${NC}
  RTTHREAD_VENV_NAME    默认虚拟环境名称
  RTTHREAD_REQ_FILE     默认requirements.txt路径
  RTTHREAD_PYPI_MIRROR  PyPI镜像源URL
  RTTHREAD_NO_MIRROR    设置为1时禁用镜像源
EOF
}

# 安全的确认函数
confirm() {
    local prompt="$1"
    local default="${2:-n}"

    # 如果设置了自动确认，直接返回是
    if [[ "${AUTO_CONFIRM:-false}" == "true" ]]; then
        log_info "自动确认: $prompt"
        return 0
    fi

    # 显示提示
    echo -en "${YELLOW}❓${NC} $prompt "
    if [[ "$default" == "y" ]]; then
        echo -en "[${GREEN}Y${NC}/${RED}n${NC}] "
    else
        echo -en "[${GREEN}y${NC}/${RED}N${NC}] "
    fi

    # 读取输入
    local response
    read -r response

    # 处理响应
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        [nN]|[nN][oO]) return 1 ;;
        "")
            if [[ "$default" == "y" ]]; then
                return 0
            else
                return 1
            fi
            ;;
        *)
            log_warn "无效输入，请回答 yes 或 no"
            confirm "$prompt" "$default"
            ;;
    esac
}

# 检查系统依赖
check_system_deps() {
    log_info "检查系统依赖..."

    local missing_deps=()

    # 检查Python3
    if ! command -v python3 &> /dev/null; then
        missing_deps+=("python3")
    else
        # 检查Python版本
        local python_version
        python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "unknown")
        log_info "检测到Python版本: $python_version"

        # 建议Python 3.8+
        if [[ $(python3 -c "import sys; print(1 if sys.version_info >= (3, 8) else 0)" 2>/dev/null) -eq 0 ]]; then
            log_warn "建议使用Python 3.8或更高版本以获得最佳体验"
        fi
    fi

    # 检查venv模块
    if ! python3 -c "import venv" 2>/dev/null; then
        missing_deps+=("python3-venv")
    fi

    # 检查其他可能需要的工具
    if ! command -v pip3 &> /dev/null; then
        log_warn "未找到pip3，将在虚拟环境中安装"
    fi

    # 如果有缺失的依赖
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "缺少必要的系统依赖: ${missing_deps[*]}"
        echo "请使用以下命令安装:"
        echo "  Ubuntu/Debian: sudo apt-get update && sudo apt-get install ${missing_deps[*]}"
        echo "  CentOS/RHEL/Fedora: sudo dnf install ${missing_deps[*]}"
        echo "  macOS: brew install ${missing_deps[*]}"
        return 1
    fi

    log_success "系统依赖检查通过"
    return 0
}

# 验证虚拟环境名称
validate_venv_name() {
    local name="$1"

    # 检查是否为空
    if [[ -z "$name" ]]; then
        log_error "虚拟环境名称不能为空"
        return 1
    fi

    # 检查长度限制
    if [[ ${#name} -gt 50 ]]; then
        log_warn "虚拟环境名称过长（${#name}字符），建议使用较短的名称（≤50字符）"
        if ! confirm "确定要使用这个名称吗?" "n"; then
            return 1
        fi
    fi

    # 检查命名规范
    if [[ ! "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]; then
        log_error "无效的虚拟环境名称: $name"
        echo "名称必须以字母或下划线开头，只能包含字母、数字、下划线、点和连字符"
        return 1
    fi

    # 避免使用敏感名称
    local sensitive_names=("python" "python3" "system" "root" "bin" "usr" "etc")
    for sensitive in "${sensitive_names[@]}"; do
        if [[ "$name" == "$sensitive" ]]; then
            log_warn "不建议使用名称: $name，这可能会与系统目录冲突"
            if ! confirm "确定要使用这个名称吗?" "n"; then
                return 1
            fi
        fi
    done

    return 0
}

# 检查requirements文件（修复：只返回文件路径，不包含其他信息）
check_requirements_file() {
    local req_file="$1"

    if [[ ! -f "$req_file" ]]; then
        log_error "未找到requirements文件: $req_file"

        # 尝试在常用位置查找
        local possible_locations=(
            "$SCRIPT_DIR/requirements.txt"
            "$SCRIPT_DIR/../requirements.txt"
            "./requirements.txt"
        )

        for location in "${possible_locations[@]}"; do
            if [[ -f "$location" ]]; then
                log_info "找到可能的requirements文件: $location"
                if confirm "是否使用此文件?" "y"; then
                    # 只返回文件路径
                    echo "$location"
                    return 0
                fi
            fi
        done

        # 创建默认的requirements.txt
        if confirm "是否创建默认的requirements.txt文件?" "y"; then
            cat > "$req_file" << 'EOF'
# 核心构建工具 - 固定版本
kconfiglib==14.1.0
PyYAML==6.0.3
SCons==4.10.1

# 其他包 - 允许自动更新
certifi>=2025.11.12
charset-normalizer>=3.4.4
idna>=3.11
requests>=2.32.5
tqdm>=4.67.1
urllib3>=2.6.0
EOF
            log_success "已创建默认requirements.txt文件"
            # 只返回文件路径
            echo "$req_file"
            return 0
        else
            return 1
        fi
    fi

    # 检查文件是否可读
    if [[ ! -r "$req_file" ]]; then
        log_error "无法读取requirements文件: $req_file"
        return 1
    fi

    # 检查文件内容
    local line_count
    line_count=$(grep -v "^#" "$req_file" | grep -v "^$" | wc -l)

    if [[ "$line_count" -eq 0 ]]; then
        log_warn "requirements.txt文件为空或只包含注释"
        if ! confirm "继续安装?" "y"; then
            return 1
        fi
    fi

    # 显示依赖列表（输出到stderr，不干扰函数返回值）
    echo "" >&2
    echo "=========================================" >&2
    echo "检测到的依赖包 ($line_count 个):" >&2
    echo "=========================================" >&2
    grep -v "^#" "$req_file" | grep -v "^$" | head -30 >&2
    if [[ "$line_count" -gt 30 ]]; then
        echo "... 还有 $(($line_count - 30)) 个依赖包" >&2
    fi
    echo "=========================================" >&2

    # 只返回文件路径
    echo "$req_file"
    return 0
}

# 清理输入缓冲区（优化版，修复竞争条件）
clear_input_buffer() {
    # 读取并丢弃所有可用的输入，使用更健壮的方法
    while IFS= read -r -t 0.001 -n 1; do
        : # 丢弃所有可用的字符
    done
}

# 显示系统信息
show_system_info() {
    log_info "系统信息:"
    echo "  - 脚本目录: $SCRIPT_DIR"
    echo "  - 操作系统: $(uname -s) $(uname -r)"
    echo "  - 架构: $(uname -m)"
    echo "  - Python3: $(command -v python3 2>/dev/null || echo '未找到')"
    echo "  - 当前用户: $(whoami)"
    echo "  - 主机名: $(hostname)"
}

# 创建虚拟环境
create_virtualenv() {
    local venv_name="$1"
    local venv_path="$2"

    log_info "正在创建虚拟环境: $venv_name"
    log_info "虚拟环境路径: $venv_path"

    # 创建虚拟环境
    if ! python3 -m venv "$venv_path"; then
        log_error "虚拟环境创建失败"
        return 1
    fi

    # 验证虚拟环境
    if [[ ! -f "$venv_path/bin/activate" ]]; then
        log_error "虚拟环境创建不完整，缺少激活脚本"
        return 1
    fi

    log_success "虚拟环境创建成功"
    return 0
}

# 提取镜像源的主机名（修复端口号问题）
extract_mirror_hostname() {
    local mirror_url="$1"
    local hostname=""

    # 使用更精确的正则表达式提取主机名（排除端口号）
    if [[ "$mirror_url" =~ ^https?://([^:/]+) ]]; then
        hostname="${BASH_REMATCH[1]}"
    else
        # 如果无法解析，尝试使用sed作为备选
        hostname=$(echo "$mirror_url" | sed -E 's|^https?://([^:/]+).*$|\1|' 2>/dev/null || echo "")
    fi

    # 验证主机名
    if [[ -n "$hostname" ]] && [[ "$hostname" =~ :[0-9]+$ ]]; then
        # 如果仍然包含端口号，再次清理
        hostname=$(echo "$hostname" | cut -d: -f1)
    fi

    # 极端无效镜像源的兜底
    if [[ -z "$hostname" ]]; then
        hostname="pypi.org"
        log_warn "镜像源格式无效，使用默认可信主机名: $hostname"
    fi

    echo "$hostname"
}

# 获取pip安装参数（使用数组避免eval风险）
get_pip_args_array() {
    local -n args_array="$1"  # 通过引用传递数组

    # 基本参数
    args_array=("--timeout" "$PIP_TIMEOUT" "--retries" "$PIP_RETRIES")

    # 检查是否禁用镜像源
    if [[ "${NO_MIRROR:-false}" == "true" ]] || [[ "${RTTHREAD_NO_MIRROR:-}" == "1" ]]; then
        log_info "已禁用PyPI镜像源，使用官方源"
        return
    fi

    # 使用环境变量或默认镜像源
    local mirror="${RTTHREAD_PYPI_MIRROR:-$PYPI_MIRROR}"

    # 检查镜像源可用性
    if [[ -n "$mirror" ]]; then
        log_info "使用PyPI镜像源: $mirror"

        # 提取主机名（修复端口号问题）
        local hostname
        hostname=$(extract_mirror_hostname "$mirror")

        if [[ -n "$hostname" ]]; then
            args_array+=("-i" "$mirror" "--trusted-host" "$hostname")
            log_debug "提取的镜像主机名: $hostname"
        else
            log_warn "无法提取镜像主机名，将不使用--trusted-host参数"
            args_array+=("-i" "$mirror")
        fi
    fi
}

# 安装依赖
install_dependencies() {
    local venv_path="$1"
    local req_file="$2"

    local pip_path="$venv_path/bin/pip"

    if [[ ! -f "$pip_path" ]]; then
        log_error "虚拟环境中未找到pip"
        return 1
    fi

    # 获取pip安装参数数组
    local pip_args_array
    get_pip_args_array pip_args_array

    # 升级pip
    if [[ "${SKIP_PIP_UPGRADE:-false}" != "true" ]]; then
        log_info "升级pip..."

        # 使用数组传递参数，避免eval风险
        if "$pip_path" install --upgrade pip "${pip_args_array[@]}" --quiet; then
            log_success "pip升级成功"
        else
            log_warn "pip升级失败，尝试不指定镜像源重新升级..."
            if "$pip_path" install --upgrade pip --timeout "$PIP_TIMEOUT" --retries "$PIP_RETRIES" --quiet; then
                log_success "pip升级成功（不使用镜像源）"
            else
                log_warn "pip升级失败，继续尝试安装依赖"
            fi
        fi
    fi

    # 安装依赖
    log_info "正在安装依赖包..."
    echo ""

    # 使用数组传递参数，避免eval风险
    if "$pip_path" install -r "$req_file" "${pip_args_array[@]}"; then
        log_success "依赖安装完成"

        # 显示已安装的包
        if [[ "${DEBUG:-false}" == "true" ]]; then
            echo ""
            log_info "已安装的包:"
            "$pip_path" list --format=columns
        fi

        return 0
    else
        log_error "依赖安装失败，尝试不使用镜像源重新安装..."

        # 重试时不使用镜像源
        if "$pip_path" install -r "$req_file" --timeout "$PIP_TIMEOUT" --retries "$PIP_RETRIES"; then
            log_success "依赖安装完成（不使用镜像源）"
            return 0
        else
            log_error "依赖安装失败，请检查网络连接或requirements.txt文件"
            return 1
        fi
    fi
}

# 配置RT-Thread环境
configure_rtthread() {
    local venv_path="$1"

    if [[ "${NO_RTTHREAD:-false}" == "true" ]]; then
        log_info "跳过RT-Thread环境配置"
        return 0
    fi

    # 注意：RT_THREAD_ENV_PATH 不再是 readonly，可以重新赋值
    if [[ ! -f "$RT_THREAD_ENV_PATH" ]]; then
        log_warn "未找到RT-Thread env工具: $RT_THREAD_ENV_PATH"

        # 尝试其他常见位置
        local possible_paths=(
            "$HOME/env/env.sh"
            "/opt/rt-thread/env/env.sh"
            "/usr/local/rt-thread/env/env.sh"
        )

        for rt_path in "${possible_paths[@]}"; do
            if [[ -f "$rt_path" ]]; then
                log_info "在备用位置找到RT-Thread env工具: $rt_path"
                RT_THREAD_ENV_PATH="$rt_path"  # 这里可以安全赋值
                break
            fi
        done

        if [[ ! -f "$RT_THREAD_ENV_PATH" ]]; then
            log_warn "RT-Thread环境未安装或不在标准位置"
            if confirm "是否跳过RT-Thread环境配置?" "y"; then
                return 0
            fi
        fi
    fi

    if [[ -f "$RT_THREAD_ENV_PATH" ]]; then
        log_info "配置RT-Thread环境..."

        local activate_path="$venv_path/bin/activate"

        # 备份原始activate文件
        if [[ ! -f "${activate_path}.bak" ]]; then
            cp "$activate_path" "${activate_path}.bak"
        fi

        # 添加RT-Thread环境配置
        if ! grep -q "RT-Thread环境配置" "$activate_path"; then
            cat >> "$activate_path" << 'EOF'

# =========================================
# RT-Thread环境配置
# =========================================
if [[ -f "$HOME/.env/env.sh" ]]; then
    source "$HOME/.env/env.sh" >/dev/null 2>&1
    echo "[RT-Thread] 环境已加载"
elif [[ -f "/opt/rt-thread/env/env.sh" ]]; then
    source "/opt/rt-thread/env/env.sh" >/dev/null 2>&1
    echo "[RT-Thread] 环境已加载"
fi

# 检查RT-Thread工具
check_rtthread_tools() {
    if command -v scons &> /dev/null; then
        echo "[RT-Thread] SCons: $(scons --version 2>/dev/null | head -1)"
    else
        echo "[RT-Thread] 警告: SCons未找到，请确保RT-Thread环境正确安装"
    fi
}

# 在虚拟环境激活时检查工具
check_rtthread_tools
EOF
            log_success "已配置自动加载RT-Thread环境"
        else
            log_warn "RT-Thread环境已配置，跳过"
        fi
    fi

    return 0
}

# 显示完成信息（修复：使用echo -e正确显示颜色）
show_completion_info() {
    local venv_name="$1"
    local venv_path="$2"
    local req_file="$3"

    clear
    echo ""
    echo -e "╔════════════════════════════════════════════════════════════╗"
    echo -e "║              RT-Thread虚拟环境配置完成                    ║"
    echo -e "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo -e "${GREEN}✓${NC} 虚拟环境名称: ${BOLD}$venv_name${NC}"
    echo -e "${GREEN}✓${NC} 环境路径: ${BOLD}$venv_path${NC}"
    echo -e "${GREEN}✓${NC} 依赖文件: ${BOLD}$req_file${NC}"
    echo ""
    echo -e "${BOLD}使用方法:${NC}"
    echo ""
    echo -e "1. ${CYAN}激活环境:${NC}"
    echo -e "   ${BOLD}source \"$venv_path/bin/activate\"${NC}"
    echo ""
    echo -e "2. ${CYAN}退出环境:${NC}"
    echo -e "   ${BOLD}deactivate${NC}"
    echo ""
    echo -e "3. ${CYAN}常用命令:${NC}"
    echo -e "   scons --help                查看SCons帮助"
    echo -e "   scons --menuconfig          配置RT-Thread项目"
    echo -e "   scons -j4                   使用4个线程编译"
    echo -e "   python --version            查看Python版本"
    echo -e "   pip list                    查看已安装的包"
    echo ""
    echo -e "4. ${CYAN}快速测试:${NC}"
    echo -e "   ${BOLD}source \"$venv_path/bin/activate\" && python -c \"import sys; print(f'Python {sys.version}')\"${NC}"
    echo ""
    echo -e "${YELLOW}注意:${NC}"
    echo -e "  • 每次打开新终端都需要重新激活虚拟环境"
    echo -e "  • 要永久激活，可将激活命令添加到 ~/.bashrc 或 ~/.zshrc"
    echo -e "  • 如需卸载，直接删除目录: ${BOLD}rm -rf \"$venv_path\"${NC}"
    echo ""
    echo -e "${BOLD}开始你的RT-Thread开发之旅吧！${NC}"
    echo ""
}

# 清理函数（错误时调用）- 优化版
cleanup() {
    local exit_code=$?

    # 仅在异常退出时执行清理逻辑
    if [[ $exit_code -eq 0 ]]; then
        exit 0
    fi

    log_error "脚本执行失败 (退出码: $exit_code)"

    # 如果虚拟环境目录存在但创建失败，询问是否清理
    if [[ -n "${VENV_PATH:-}" ]] && [[ -d "$VENV_PATH" ]]; then
        if confirm "检测到可能不完整的虚拟环境目录 '$VENV_PATH'，是否删除?" "y"; then
            log_info "清理虚拟环境目录..."
            rm -rf "$VENV_PATH"
        fi
    fi

    exit $exit_code
}

# 设置退出时清理
trap cleanup EXIT

# 主函数
main() {
    # PyPI镜像源配置（在main函数开始处声明，确保优先级正确）
    local PYPI_MIRROR="${RTTHREAD_PYPI_MIRROR:-https://mirrors.aliyun.com/pypi/simple/}"
    local PIP_TIMEOUT=30
    local PIP_RETRIES=3

    # 解析命令行参数
    local venv_name=""
    local req_file="$SCRIPT_DIR/$DEFAULT_REQUIREMENTS"
    local AUTO_CONFIRM=false
    local NO_RTTHREAD=false
    local DEBUG=false
    local SKIP_DEPS_CHECK=false
    local SKIP_PIP_UPGRADE=false
    local FORCE=false
    local NO_MIRROR=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -y|--yes)
                AUTO_CONFIRM=true
                shift
                ;;
            -n|--name)
                if [[ -n "${2:-}" ]]; then
                    venv_name="$2"
                    shift 2
                else
                    log_error "选项 --name 需要一个参数"
                    exit 1
                fi
                ;;
            -r|--requirements)
                if [[ -n "${2:-}" ]]; then
                    req_file="$2"
                    shift 2
                else
                    log_error "选项 --requirements 需要一个参数"
                    exit 1
                fi
                ;;
            --no-rt-thread)
                NO_RTTHREAD=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --skip-deps-check)
                SKIP_DEPS_CHECK=true
                shift
                ;;
            --skip-pip-upgrade)
                SKIP_PIP_UPGRADE=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --mirror)
                if [[ -n "${2:-}" ]]; then
                    PYPI_MIRROR="$2"
                    shift 2
                else
                    log_error "选项 --mirror 需要一个参数"
                    exit 1
                fi
                ;;
            --no-mirror)
                NO_MIRROR=true
                shift
                ;;
            -*)
                log_error "未知选项: $1"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "$venv_name" ]]; then
                    venv_name="$1"
                else
                    log_warn "忽略额外参数: $1"
                fi
                shift
                ;;
        esac
    done

    # 显示标题
    clear
    echo ""
    echo -e "╔════════════════════════════════════════════════════════════╗"
    echo -e "║         RT-Thread开发环境配置工具 v1.6.0                   ║"
    echo -e "║         https://www.rt-thread.org/                         ║"
    echo -e "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # 显示系统信息
    show_system_info
    echo ""

    # 检查系统依赖
    if [[ "$SKIP_DEPS_CHECK" != "true" ]]; then
        check_system_deps || exit 1
    fi

    # 获取虚拟环境名称
    if [[ -z "$venv_name" ]]; then
        # 检查环境变量
        if [[ -n "${RTTHREAD_VENV_NAME:-}" ]]; then
            venv_name="$RTTHREAD_VENV_NAME"
            log_info "使用环境变量中的虚拟环境名称: $venv_name"
        else
            clear_input_buffer
            echo -en "${CYAN}请输入虚拟环境名称${NC} [${GREEN}$DEFAULT_VENV_NAME${NC}]: "
            read -r user_input

            if [[ -n "$user_input" ]]; then
                venv_name="$user_input"
            else
                venv_name="$DEFAULT_VENV_NAME"
            fi
        fi
    fi

    # 验证名称
    validate_venv_name "$venv_name" || exit 1

    # 检查requirements文件
    if [[ -n "${RTTHREAD_REQ_FILE:-}" ]]; then
        req_file="$RTTHREAD_REQ_FILE"
        log_info "使用环境变量中的requirements文件: $req_file"
    fi

    req_file=$(check_requirements_file "$req_file") || exit 1

    # 确认安装
    if [[ "$AUTO_CONFIRM" != "true" ]]; then
        echo ""
        echo "========================================="
        echo "配置摘要:"
        echo "========================================="
        echo "  虚拟环境名称: $venv_name"
        echo "  虚拟环境路径: $SCRIPT_DIR/$venv_name"
        echo "  依赖文件: $req_file"
        echo "  自动确认: $AUTO_CONFIRM"
        echo "  配置RT-Thread: $([[ "$NO_RTTHREAD" == "true" ]] && echo "否" || echo "是")"
        echo "  PyPI镜像源: $([[ "$NO_MIRROR" == "true" ]] && echo "禁用" || echo "$PYPI_MIRROR")"
        echo "========================================="
        echo ""

        if ! confirm "确认以上配置?" "y"; then
            log_info "用户取消操作"
            exit 0
        fi
    fi

    # 设置虚拟环境路径
    local venv_path="$SCRIPT_DIR/$venv_name"
    export VENV_PATH="$venv_path"  # 用于清理函数

    # 检查目录是否存在
    if [[ -d "$venv_path" ]]; then
        if [[ "$FORCE" == "true" ]]; then
            log_info "强制模式: 删除已存在的虚拟环境目录..."
            rm -rf "$venv_path"
        else
            log_warn "虚拟环境目录已存在: $venv_path"

            if confirm "是否删除并重新创建?" "n"; then
                log_info "删除旧虚拟环境..."
                rm -rf "$venv_path"
            else
                if confirm "是否使用现有虚拟环境?" "n"; then
                    log_info "使用现有虚拟环境"
                else
                    exit 0
                fi
            fi
        fi
    fi

    # 创建虚拟环境
    if [[ ! -d "$venv_path" ]]; then
        create_virtualenv "$venv_name" "$venv_path" || exit 1
    fi

    # 安装依赖
    install_dependencies "$venv_path" "$req_file" || exit 1

    # 配置RT-Thread环境
    configure_rtthread "$venv_path"

    # 显示完成信息
    show_completion_info "$venv_name" "$venv_path" "$req_file"

    return 0
}

# 如果是直接执行，则运行主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
