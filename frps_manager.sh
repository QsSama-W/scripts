#!/bin/bash

# ============================================================================
#  FRP 服务器 (frps) 一键部署与管理脚本 v3
#  兼容：Debian / Ubuntu / CentOS / Fedora / Alpine / Arch
#  支持：systemd / OpenRC
#  优化：LXC 最小化安装环境
#  日期：2026-08-06
# ============================================================================

# ======================== 配置常量 ========================
INSTALL_DIR="/opt/frps"
FRPS_BIN="$INSTALL_DIR/frps"
FRPS_CONF="$INSTALL_DIR/frps.toml"
SERVICE_NAME="frps"
LOG_DIR="$INSTALL_DIR/logs"
LOG_FILE="$LOG_DIR/frps.log"
BACKUP_DIR="/opt/frps_backups"
SCRIPT_PATH="$INSTALL_DIR/frps_manager.sh"

MIN_DISK_MB=50
MIN_RAM_MB=25

# ======================== 颜色 ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ======================== 错误处理 ========================

# 全局错误捕获：任何未捕获的错误立即停止
trap 'handle_unexpected_error $? $LINENO' ERR

handle_unexpected_error() {
    local code=$1
    local line=$2
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  脚本在第 ${line} 行发生未知错误，退出码: ${code}${NC}"
    echo -e "${RED}  请将以上信息反馈以便排查问题${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit "$code"
}

# 带错误检查的命令执行包装器
# 用法: run_cmd "步骤描述" 命令 参数...
# 返回: 命令的输出，失败则立即终止
run_cmd() {
    local desc="$1"
    shift

    local output
    local exit_code

    output=$("$@" 2>&1)
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}[失败]${NC} $desc"
        echo -e "${DIM}  命令: $*${NC}"
        echo -e "${DIM}  输出: $output${NC}"
        echo ""
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}  安装中止。请根据上方错误信息排查问题。${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        exit 1
    fi

    echo -e "${GREEN}[完成]${NC} $desc"
    return 0
}

# 不终止的命令执行（用于非关键操作）
try_cmd() {
    local desc="$1"
    shift

    local output
    output=$("$@" 2>&1)

    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}[跳过]${NC} $desc"
        return 1
    fi

    echo "$output"
    return 0
}

# ======================== 工具函数 ========================

print_line() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

info()    { echo -e "${BLUE}[信息]${NC} $1"; }
success() { echo -e "${GREEN}[通过]${NC} $1"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $1"; }
fail()    { echo -e "${RED}[失败]${NC} $1"; }

wait_key() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo ""
}

# ======================== 系统检测 ========================

detect_init_system() {
    if [ -d /run/systemd/system ] 2>/dev/null; then
        echo "systemd"
    elif [ -f /sbin/openrc ] 2>/dev/null; then
        echo "openrc"
    elif [ -f /proc/1/comm ]; then
        local init_cmd=$(cat /proc/1/comm 2>/dev/null)
        case "$init_cmd" in
            systemd)     echo "systemd" ;;
            openrc-init) echo "openrc" ;;
            *)           echo "sysvinit" ;;
        esac
    else
        echo "unknown"
    fi
}

detect_pkg_manager() {
    if command -v apk &>/dev/null; then echo "apk"
    elif command -v apt-get &>/dev/null; then echo "apt"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v pacman &>/dev/null; then echo "pacman"
    else echo "unknown"
    fi
}

get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm" ;;
        *)       echo "unsupported" ;;
    esac
}

get_free_ram_mb() {
    if [ -f /proc/meminfo ]; then
        local avail=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
        if [ -n "$avail" ] && [ "$avail" != "0" ]; then
            echo $((avail / 1024))
        else
            local free=$(awk '/MemFree:/{print $2}' /proc/meminfo)
            local buf=$(awk '/Buffers:/{print $2}' /proc/meminfo)
            local cached=$(awk '/Cached:/{print $2}' /proc/meminfo)
            echo $(( (free + buf + cached) / 1024 ))
        fi
    else
        echo "0"
    fi
}

get_total_ram_mb() {
    awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "0"
}

get_disk_free_mb() {
    df -m / | awk 'NR==2{print $4}'
}

# ======================== 安装依赖 ========================

# 安装包管理器中的软件包
install_pkgs() {
    local pkg_mgr=$(detect_pkg_manager)
    local pkgs=("$@")

    if [ ${#pkgs[@]} -eq 0 ]; then
        return 0
    fi

    info "正在安装: ${pkgs[*]}"

    case $pkg_mgr in
        apk)
            apk update -q >/dev/null 2>&1 || true
            if ! apk add --no-cache "${pkgs[@]}" >/dev/null 2>&1; then
                fail "通过 apk 安装 ${pkgs[*]} 失败"
                return 1
            fi
            ;;
        apt)
            if ! apt-get update -qq >/dev/null 2>&1; then
                fail "apt-get update 失败"
                return 1
            fi
            if ! apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1; then
                fail "通过 apt 安装 ${pkgs[*]} 失败"
                return 1
            fi
            ;;
        yum)
            if ! yum install -y -q "${pkgs[@]}" >/dev/null 2>&1; then
                fail "通过 yum 安装 ${pkgs[*]} 失败"
                return 1
            fi
            ;;
        dnf)
            if ! dnf install -y -q "${pkgs[@]}" >/dev/null 2>&1; then
                fail "通过 dnf 安装 ${pkgs[*]} 失败"
                return 1
            fi
            ;;
        pacman)
            if ! pacman -S --noconfirm --needed "${pkgs[@]}" >/dev/null 2>&1; then
                fail "通过 pacman 安装 ${pkgs[*]} 失败"
                return 1
            fi
            ;;
        *)
            fail "未识别的包管理器，无法自动安装，请手动安装: ${pkgs[*]}"
            return 1
            ;;
    esac

    return 0
}

# 检测并补全所有必要工具
ensure_dependencies() {
    print_line
    echo -e "${BOLD}  📦 检测系统依赖工具${NC}"
    print_line
    echo ""

    local pkg_mgr=$(detect_pkg_manager)
    info "包管理器: $pkg_mgr"

    # 定义需要的工具和对应的包名映射
    # 格式: "命令名:debian包名:alpine包名:centos包名:arch包名"
    local tool_map=(
        "wget:wget:wget:wget:wget"
        "curl:curl:curl:curl:curl"
        "tar:tar:tar:tar:tar"
        "grep:grep:grep:grep:grep"
        "openssl:openssl:libressl:openssl:openssl"
    )

    # Alpine 额外需要的
    if [ "$pkg_mgr" = "apk" ]; then
        tool_map+=(
            "bash:bash:bash:bash:bash"
            "ss:iproute2:iproute2:iproute:iproute2"
        )
    else
        # Debian/CentOS 系可能需要 iproute2 提供 ss
        tool_map+=(
            "ss:iproute2:iproute2:iproute:iproute2"
        )
    fi

    local missing_tools=()
    local missing_pkgs=()
    local installed_count=0
    local total_count=${#tool_map[@]}

    for entry in "${tool_map[@]}"; do
        IFS=':' read -r cmd_name debian_pkg alpine_pkg centos_pkg arch_pkg <<< "$entry"

        if command -v "$cmd_name" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $cmd_name"
            ((installed_count++))
        else
            echo -e "  ${RED}✗${NC} $cmd_name ${DIM}(${cmd_name} 未安装)${NC}"
            missing_tools+=("$cmd_name")

            case $pkg_mgr in
                apk)  missing_pkgs+=("$alpine_pkg") ;;
                apt)  missing_pkgs+=("$debian_pkg") ;;
                yum|dnf) missing_pkgs+=("$centos_pkg") ;;
                pacman)  missing_pkgs+=("$arch_pkg") ;;
            esac
        fi
    done

    echo ""
    echo -e "  ${BOLD}检测结果:${NC} $installed_count/$total_count 个工具已就绪"

    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo ""
        warn "缺少 ${#missing_tools[@]} 个必要工具: ${missing_tools[*]}"
        info "正在自动安装..."
        echo ""

        # 去重
        local unique_pkgs=($(printf '%s\n' "${missing_pkgs[@]}" | sort -u))

        if ! install_pkgs "${unique_pkgs[@]}"; then
            fail "依赖安装失败，无法继续"
            fail "请手动安装以下工具后重试: ${missing_tools[*]}"
            return 1
        fi

        echo ""

        # 二次验证：确认所有工具现在都存在了
        local still_missing=()
        for entry in "${tool_map[@]}"; do
            IFS=':' read -r cmd_name _ _ _ _ <<< "$entry"
            if ! command -v "$cmd_name" &>/dev/null; then
                still_missing+=("$cmd_name")
            fi
        done

        if [ ${#still_missing[@]} -gt 0 ]; then
            fail "以下工具安装后仍然无法使用: ${still_missing[*]}"
            fail "请手动安装后重试"
            return 1
        fi

        success "所有缺失工具已自动安装并验证通过"
    else
        success "所有依赖工具已就绪"
    fi

    return 0
}

# ======================== 全面环境检测 ========================

# 这是核心：启动时做一次完整的系统环境扫描
full_system_check() {
    local errors=0

    print_line
    echo -e "${BOLD}  🔍 系统环境全面检测${NC}"
    print_line
    echo ""

    # ── 检测1: root 权限 ──
    echo -e "${BOLD}  [1/8] 权限检测${NC}"
    if [ "$(id -u)" -ne 0 ]; then
        fail "当前不是 root 用户"
        echo -e "  请使用: ${BOLD}sudo bash $0${NC}"
        ((errors++))
    else
        success "root 权限确认"
    fi
    echo ""

    # ── 检测2: 操作系统 ──
    echo -e "${BOLD}  [2/8] 操作系统${NC}"
    local distro="unknown"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        distro="${PRETTY_NAME:-$ID}"
    fi
    local kernel=$(uname -r)
    info "系统: $distro"
    info "内核: $kernel"
    success "操作系统识别完成"
    echo ""

    # ── 检测3: CPU 架构 ──
    echo -e "${BOLD}  [3/8] CPU 架构${NC}"
    local arch=$(get_arch)
    if [ "$arch" = "unsupported" ]; then
        fail "不支持的CPU架构: $(uname -m)"
        echo "  FRP 仅支持 x86_64 / aarch64 / armv7l"
        ((errors++))
    else
        success "架构: $(uname -m) -> $arch"
    fi
    echo ""

    # ── 检测4: 内存 ──
    echo -e "${BOLD}  [4/8] 内存检测${NC}"
    local total_ram=$(get_total_ram_mb)
    local free_ram=$(get_free_ram_mb)
    info "总内存: ${total_ram} MB | 可用: ${free_ram} MB | 最低要求: ${MIN_RAM_MB} MB"

    if [ "$total_ram" -eq 0 ]; then
        fail "无法读取内存信息"
        ((errors++))
    elif [ "$free_ram" -lt "$MIN_RAM_MB" ]; then
        fail "可用内存不足 (当前 ${free_ram} MB，需要 ${MIN_RAM_MB} MB)"
        ((errors++))
    else
        success "内存充足"
    fi
    echo ""

    # ── 检测5: 磁盘 ──
    echo -e "${BOLD}  [5/8] 磁盘检测${NC}"
    local disk_free=$(get_disk_free_mb)
    local disk_total=$(df -m / | awk 'NR==2{print $2}')
    info "总空间: ${disk_total} MB | 可用: ${disk_free} MB | 最低要求: ${MIN_DISK_MB} MB"

    if [ "$disk_free" -lt "$MIN_DISK_MB" ]; then
        fail "磁盘空间不足 (当前 ${disk_free} MB，需要 ${MIN_DISK_MB} MB)"
        ((errors++))
    else
        success "磁盘空间充足"
    fi
    echo ""

    # ── 检测6: 网络 ──
    echo -e "${BOLD}  [6/8] 网络连接${NC}"
    local net_ok=0

    # 检测 DNS
    if host github.com &>/dev/null 2>&1 || nslookup github.com &>/dev/null 2>&1; then
        success "DNS 解析正常"
        ((net_ok++))
    else
        # 有些 LXC 没有 host/nslookup，尝试 ping
        if ping -c 1 -W 3 github.com &>/dev/null 2>&1; then
            success "DNS 解析正常"
            ((net_ok++))
        else
            fail "DNS 解析失败，无法访问 github.com"
            ((errors++))
        fi
    fi

    # 检测 HTTPS 连通性
    if curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" https://api.github.com 2>/dev/null | grep -qE "^(200|301|302|304)$"; then
        success "GitHub API 可达"
        ((net_ok++))
    elif wget --spider --timeout=5 -q https://github.com 2>/dev/null; then
        success "GitHub 可达"
        ((net_ok++))
    else
        warn "GitHub 连接超时，下载可能失败"
        warn "如果你在中国大陆，可能需要代理"
    fi
    echo ""

    # ── 检测7: 初始化系统 ──
    echo -e "${BOLD}  [7/8] 初始化系统${NC}"
    local init=$(detect_init_system)
    case $init in
        systemd)
            success "检测到 systemd"
            # 验证 systemctl 是否可用
            if ! command -v systemctl &>/dev/null; then
                fail "systemd 已检测但 systemctl 命令不可用"
                ((errors++))
            fi
            ;;
        openrc)
            success "检测到 OpenRC"
            if ! command -v rc-service &>/dev/null; then
                fail "OpenRC 已检测但 rc-service 命令不可用"
                ((errors++))
            fi
            ;;
        *)
            fail "未识别的初始化系统 (进程1: $(cat /proc/1/comm 2>/dev/null))"
            echo "  本脚本仅支持 systemd 和 OpenRC"
            ((errors++))
            ;;
    esac
    echo ""

    # ── 检测8: 端口冲突 ──
    echo -e "${BOLD}  [8/8] 端口检测${NC}"
    local ports_to_check=(7000 7500)
    local port_conflict=0

    for port in "${ports_to_check[@]}"; do
        local port_in_use=""
        if command -v ss &>/dev/null; then
            port_in_use=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1)
        elif command -v netstat &>/dev/null; then
            port_in_use=$(netstat -tlnp 2>/dev/null | grep ":${port} " | head -1)
        elif command -v lsof &>/dev/null; then
            port_in_use=$(lsof -i :"$port" -sTCP:LISTEN 2>/dev/null | head -1)
        fi

        if [ -n "$port_in_use" ]; then
            warn "端口 $port 已被占用"
            echo -e "    ${DIM}$port_in_use${NC}"
            ((port_conflict++))
        else
            success "端口 $port 可用"
        fi
    done

    if [ "$port_conflict" -gt 0 ]; then
        warn "端口被占用不会阻止安装，但可能导致服务启动失败"
        warn "你可以在配置文件中修改端口"
    fi
    echo ""

    # ── 汇总 ──
    print_line
    if [ $errors -gt 0 ]; then
        echo -e "${RED}  ✗ 检测未通过，发现 ${errors} 个问题${NC}"
        echo -e "${RED}  请先解决上述问题后重新运行脚本${NC}"
        print_line
        return 1
    else
        echo -e "${GREEN}  ✓ 全部检测通过，系统环境满足安装要求${NC}"
        print_line
        return 0
    fi
}

# ======================== 下载安装 ========================

get_latest_version() {
    local version=""

    # 方法1: GitHub API
    version=$(curl -s --connect-timeout 10 --max-time 15 \
        https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
        | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')

    # 方法2: 跟随重定向解析
    if [ -z "$version" ]; then
        local redirect_url=$(curl -sI --connect-timeout 10 --max-time 15 \
            "https://github.com/fatedier/frp/releases/latest" 2>/dev/null \
            | grep -i "^location:" | tr -d '\r')

        if [ -n "$redirect_url" ]; then
            version=$(echo "$redirect_url" | grep -o 'v[0-9][0-9.]*' | head -1 | sed 's/^v//')
        fi
    fi

    # 方法3: wget 解析
    if [ -z "$version" ] && command -v wget &>/dev/null; then
        local page=$(wget -qO- --timeout=15 "https://github.com/fatedier/frp/releases/latest" 2>/dev/null)
        version=$(echo "$page" | grep -o 'tag/v[0-9][0-9.]*' | head -1 | sed 's/tag\/v//')
    fi

    echo "$version"
}

download_frps() {
    print_line
    echo -e "${BOLD}  📥 下载 FRP 服务端${NC}"
    print_line
    echo ""

    # 获取版本
    info "正在查询最新版本..."
    local version=$(get_latest_version)

    if [ -z "$version" ]; then
        fail "无法获取最新版本信息"
        echo -e "  请检查网络连接，或确认可以访问 github.com"
        return 1
    fi

    local arch=$(get_arch)
    if [ "$arch" = "unsupported" ]; then
        fail "不支持的架构: $(uname -m)"
        return 1
    fi

    local filename="frp_${version}_linux_${arch}.tar.gz"
    local download_url="https://github.com/fatedier/frp/releases/download/v${version}/${filename}"

    echo -e "  ${BOLD}版本${NC}    : v${version}"
    echo -e "  ${BOLD}架构${NC}    : ${arch}"
    echo -e "  ${BOLD}文件${NC}    : ${filename}"
    echo ""

    # 创建临时目录
    local tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" EXIT

    # 下载
    info "正在下载..."
    local dl_success=0

    if command -v wget &>/dev/null; then
        if wget -q --show-progress --timeout=30 --tries=3 \
            -O "$tmp_dir/$filename" "$download_url" 2>&1; then
            dl_success=1
        fi
    elif command -v curl &>/dev/null; then
        if curl -# --connect-timeout 30 --retry 3 \
            -L -o "$tmp_dir/$filename" "$download_url" 2>&1; then
            dl_success=1
        fi
    fi

    if [ "$dl_success" -eq 0 ] || [ ! -f "$tmp_dir/$filename" ]; then
        fail "下载失败"
        echo -e "  URL: $download_url"
        echo -e "  请检查网络连接或使用代理"
        rm -rf "$tmp_dir"
        trap - EXIT
        return 1
    fi

    # 验证文件大小（至少1MB，防止下载到错误页面）
    local file_size=$(stat -c%s "$tmp_dir/$filename" 2>/dev/null || stat -f%z "$tmp_dir/$filename" 2>/dev/null)
    if [ -n "$file_size" ] && [ "$file_size" -lt 1048576 ]; then
        fail "下载的文件异常（仅 ${file_size} 字节），可能不是有效的压缩包"
        echo -e "  可能原因：网络错误、代理未配置、GitHub 访问受限"
        rm -rf "$tmp_dir"
        trap - EXIT
        return 1
    fi

    success "下载完成 (${file_size} 字节)"

    # 解压
    info "正在解压..."
    if ! tar -xzf "$tmp_dir/$filename" -C "$tmp_dir" 2>&1; then
        fail "解压失败，文件可能已损坏"
        rm -rf "$tmp_dir"
        trap - EXIT
        return 1
    fi

    local extracted_dir=$(ls -d "$tmp_dir"/frp_${version}_linux_${arch} 2>/dev/null)
    if [ -z "$extracted_dir" ] || [ ! -d "$extracted_dir" ]; then
        fail "解压后未找到预期目录结构"
        ls -la "$tmp_dir"/ 2>/dev/null
        rm -rf "$tmp_dir"
        trap - EXIT
        return 1
    fi

    if [ ! -f "$extracted_dir/frps" ]; then
        fail "解压后未找到 frps 可执行文件"
        ls -la "$extracted_dir"/ 2>/dev/null
        rm -rf "$tmp_dir"
        trap - EXIT
        return 1
    fi

    # 备份已有安装
    if [ -d "$INSTALL_DIR" ]; then
        local backup_name="${BACKUP_DIR}/frps_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp -r "$INSTALL_DIR" "$backup_name" 2>/dev/null
        info "已备份旧版本到: $backup_name"
    fi

    # 安装
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$LOG_DIR"

    cp "$extracted_dir/frps" "$FRPS_BIN"
    if ! chmod +x "$FRPS_BIN"; then
        fail "设置执行权限失败"
        rm -rf "$tmp_dir"
        trap - EXIT
        return 1
    fi

    # 生成配置文件
    if [ ! -f "$FRPS_CONF" ]; then
        generate_default_config
    fi

    # 保存脚本自身到安装目录
    if [ -f "$0" ] && [ "$0" != "/dev/stdin" ]; then
        cp "$0" "$SCRIPT_PATH" 2>/dev/null && chmod +x "$SCRIPT_PATH" 2>/dev/null
    fi

    # 清理
    rm -rf "$tmp_dir"
    trap - EXIT

    # 最终验证
    if [ ! -x "$FRPS_BIN" ]; then
        fail "安装验证失败: frps 不可执行"
        return 1
    fi

    local installed_version=$("$FRPS_BIN" --version 2>&1 | head -1)
    success "安装完成，版本: $installed_version"

    return 0
}

generate_default_config() {
    local token=""
    local web_password=""

    if command -v openssl &>/dev/null; then
        token=$(openssl rand -hex 16)
        web_password=$(openssl rand -base64 8 | tr -d '/+=' | head -c 12)
    else
        token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)
        web_password=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 12)
    fi

    cat > "$FRPS_CONF" <<EOF
# ===========================================
# FRP 服务端配置文件 (frps.toml)
# 由部署脚本自动生成
# 文档: https://gofrp.org/zh-cn/docs/
# ===========================================

# --- 基础设置 ---
bindAddr = "0.0.0.0"
bindPort = 7000

# --- 认证 ---
auth.method = "token"
auth.token = "${token}"

# --- HTTP/HTTPS 虚拟主机 ---
# vhostHTTPPort = 8080
# vhostHTTPSPort = 8443

# --- 管理面板 ---
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "${web_password}"

# --- 日志 ---
log.to = "${LOG_FILE}"
log.level = "info"
log.maxDays = 7

# --- 传输 ---
transport.maxPoolCount = 10
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 30
EOF

    echo ""
    echo -e "  ${BOLD}自动生成的认证信息:${NC}"
    echo -e "    ${YELLOW}auth.token      = ${token}${NC}"
    echo -e "    ${YELLOW}dashboard密码   = ${web_password}${NC}"
    echo -e ""
    warn "请记住以上密码，或在配置文件中修改！"
}

# ======================== 服务文件 ========================

setup_service() {
    local init=$(detect_init_system)
    info "正在创建服务文件 (初始化系统: $init)..."

    case $init in
        systemd)
            cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=FRP Server (frps)
Documentation=https://gofrp.org/zh-cn/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${FRPS_BIN} -c ${FRPS_CONF}
Restart=always
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
WorkingDirectory=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF
            if ! systemctl daemon-reload 2>&1; then
                fail "systemctl daemon-reload 失败"
                return 1
            fi
            success "systemd 服务文件已创建"
            ;;

        openrc)
            cat > "/etc/init.d/${SERVICE_NAME}" <<'OPENRC_EOF'
#!/sbin/openrc-run

name="frps"
description="FRP Server"

command="/opt/frps/frps"
command_args="-c /opt/frps/frps.toml"
command_user="root"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/opt/frps/logs/frps.log"
error_log="/opt/frps/logs/frps.log"

respawn_delay=5
respawn_max=10

depend() {
    need net
    after firewall
}

start_pre() {
    mkdir -p /opt/frps/logs
    touch /opt/frps/logs/frps.log
}
OPENRC_EOF
            chmod +x "/etc/init.d/${SERVICE_NAME}"
            success "OpenRC 服务文件已创建"
            ;;

        *)
            fail "不支持的初始化系统: $init"
            return 1
            ;;
    esac

    return 0
}

# ======================== 服务操作 ========================

service_action() {
    local action=$1
    local init=$(detect_init_system)

    case $init in
        systemd)
            case $action in
                start)    systemctl start "$SERVICE_NAME" 2>&1 ;;
                stop)     systemctl stop "$SERVICE_NAME" 2>&1 ;;
                restart)  systemctl restart "$SERVICE_NAME" 2>&1 ;;
                enable)   systemctl enable "$SERVICE_NAME" 2>&1 ;;
                disable)  systemctl disable "$SERVICE_NAME" 2>&1 ;;
                status)
                    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
                        echo "active"
                    else
                        echo "inactive"
                    fi
                    ;;
                enabled)
                    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
                        echo "enabled"
                    else
                        echo "disabled"
                    fi
                    ;;
                pid)  systemctl show "$SERVICE_NAME" --property=MainPID --value 2>/dev/null ;;
                log)  journalctl -u "$SERVICE_NAME" "${@:2}" 2>&1 ;;
            esac
            ;;
        openrc)
            case $action in
                start)    rc-service "$SERVICE_NAME" start 2>&1 ;;
                stop)     rc-service "$SERVICE_NAME" stop 2>&1 ;;
                restart)  rc-service "$SERVICE_NAME" restart 2>&1 ;;
                enable)   rc-update add "$SERVICE_NAME" default 2>&1 ;;
                disable)  rc-update del "$SERVICE_NAME" default 2>&1 ;;
                status)
                    if rc-service "$SERVICE_NAME" status &>/dev/null; then
                        echo "active"
                    else
                        echo "inactive"
                    fi
                    ;;
                enabled)
                    if rc-update show 2>/dev/null | grep -q "$SERVICE_NAME"; then
                        echo "enabled"
                    else
                        echo "disabled"
                    fi
                    ;;
                pid)  pgrep -x "frps" 2>/dev/null ;;
                log)  [ -f "$LOG_FILE" ] && cat "$LOG_FILE" 2>/dev/null ;;
            esac
            ;;
    esac
}

# ======================== 核心部署流程 ========================

deploy_frps() {
    print_line
    echo -e "${BOLD}  🚀 开始部署 FRP 服务端${NC}"
    print_line
    echo ""

    # 步骤1: 安装依赖工具
    echo -e "${BOLD}  ── 步骤 1/4: 安装依赖工具 ──${NC}"
    if ! ensure_dependencies; then
        fail "依赖工具安装失败，无法继续"
        wait_key
        return 1
    fi
    echo ""

    # 步骤2: 下载安装
    echo -e "${BOLD}  ── 步骤 2/4: 下载并安装 frps ──${NC}"
    if ! download_frps; then
        fail "下载安装失败，无法继续"
        wait_key
        return 1
    fi
    echo ""

    # 步骤3: 创建服务文件
    echo -e "${BOLD}  ── 步骤 3/4: 配置系统服务 ──${NC}"
    if ! setup_service; then
        fail "服务配置失败，无法继续"
        wait_key
        return 1
    fi
    echo ""

    # 步骤4: 验证
    echo -e "${BOLD}  ── 步骤 4/4: 安装验证 ──${NC}"
    if [ ! -x "$FRPS_BIN" ]; then
        fail "验证失败: frps 不可执行"
        wait_key
        return 1
    fi
    if [ ! -f "$FRPS_CONF" ]; then
        fail "验证失败: 配置文件不存在"
        wait_key
        return 1
    fi
    if [ ! -d "$LOG_DIR" ]; then
        fail "验证失败: 日志目录不存在"
        wait_key
        return 1
    fi

    local bin_version=$("$FRPS_BIN" --version 2>&1 | head -1)
    success "二进制文件: $bin_version"
    success "配置文件: $FRPS_CONF"
    success "日志目录: $LOG_DIR"
    echo ""

    # 完成
    print_line
    echo -e "${GREEN}  ✅ FRP 服务端部署成功！${NC}"
    print_line
    echo ""
    echo -e "  ${BOLD}安装目录${NC}  : $INSTALL_DIR"
    echo -e "  ${BOLD}可执行文件${NC}: $FRPS_BIN"
    echo -e "  ${BOLD}配置文件${NC}  : $FRPS_CONF"
    echo ""
    echo -e "  ${BOLD}下一步操作:${NC}"
    echo -e "    1. 编辑配置修改密码:  ${BOLD}nano $FRPS_CONF${NC}"
    echo -e "    2. 启动服务:          ${BOLD}systemctl start frps${NC}"
    echo -e "    3. 设置开机自启:      ${BOLD}systemctl enable frps${NC}"
    echo -e "    4. 查看状态:          ${BOLD}systemctl status frps${NC}"
    echo -e "    5. Dashboard访问:     ${BOLD}http://服务器IP:7500${NC}"
    print_line

    wait_key
    return 0
}

# ======================== 菜单功能 ========================

start_service() {
    info "正在启动 frps..."
    local output=$(service_action start)
    local st=$(service_action status)

    sleep 1
    if [ "$st" = "active" ]; then
        success "frps 已启动（后台运行中）"
        local pid=$(service_action pid)
        echo -e "  PID: $pid"
    else
        fail "启动失败"
        [ -n "$output" ] && echo -e "  ${DIM}$output${NC}"
    fi
    wait_key
}

stop_service() {
    info "正在停止 frps..."
    service_action stop
    sleep 1
    success "frps 已停止"
    wait_key
}

restart_service() {
    info "正在重启 frps..."
    service_action restart
    sleep 1
    if [ "$(service_action status)" = "active" ]; then
        success "frps 已重启（后台运行中）"
    else
        fail "重启失败"
    fi
    wait_key
}

enable_service() {
    info "正在设置开机自启..."
    service_action enable
    success "已设置开机自启"
    wait_key
}

disable_service() {
    info "正在取消开机自启..."
    service_action disable
    success "已取消开机自启"
    wait_key
}

check_status() {
    print_line
    echo -e "${BOLD}  📊 frps 运行状态${NC}"
    print_line
    echo ""

    local st=$(service_action status)
    if [ "$st" = "active" ]; then
        echo -e "  状态: ${GREEN}● 运行中${NC}"
    else
        echo -e "  状态: ${RED}● 已停止${NC}"
    fi

    local en=$(service_action enabled)
    if [ "$en" = "enabled" ]; then
        echo -e "  自启: ${GREEN}● 已启用${NC}"
    else
        echo -e "  自启: ${YELLOW}● 未启用${NC}"
    fi

    local pid=$(service_action pid)
    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/status" ]; then
        local mem_kb=$(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null)
        local uptime_s=$(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);printf "%dd %dh %dm",d,h,m}' /proc/$pid/stat 2>/dev/null)
        echo -e "  PID : $pid"
        [ -n "$mem_kb" ] && echo -e "  内存: $((mem_kb/1024)) MB"
    fi

    echo ""
    echo -e "  ${BOLD}端口监听:${NC}"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep "frps" | while read line; do
            echo -e "    $line"
        done
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep "frps" | while read line; do
            echo -e "    $line"
        done
    fi

    local conn_count=0
    if command -v ss &>/dev/null; then
        conn_count=$(ss -tn 2>/dev/null | grep -c "frps" || echo 0)
    fi
    echo -e "  活跃连接: $conn_count"

    echo ""
    print_line
    wait_key
}

view_live_log() {
    print_line
    echo -e "${BOLD}  📜 实时日志${NC}"
    echo -e "  ${YELLOW}Ctrl+C 退出${NC}"
    print_line
    echo ""

    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    elif [ "$(detect_init_system)" = "systemd" ] && command -v journalctl &>/dev/null; then
        journalctl -u "$SERVICE_NAME" -f --no-pager
    else
        fail "日志文件不存在: $LOG_FILE"
        sleep 2
    fi
}

view_recent_log() {
    print_line
    echo -e "${BOLD}  📜 最近日志（50行）${NC}"
    print_line
    echo ""

    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        tail -n 50 "$LOG_FILE"
    elif [ "$(detect_init_system)" = "systemd" ]; then
        journalctl -u "$SERVICE_NAME" -n 50 --no-pager 2>/dev/null
    else
        fail "无日志可显示"
    fi

    wait_key
}

clear_log() {
    warn "即将清空日志"
    read -p "确认？(y/N): " c
    if [ "$c" = "y" ] || [ "$c" = "Y" ]; then
        [ -f "$LOG_FILE" ] && > "$LOG_FILE"
        success "日志已清空"
    fi
    wait_key
}

edit_config() {
    echo -e ""
    echo -e "  配置文件: ${BOLD}$FRPS_CONF${NC}"
    echo -e "  编辑器:   1=nano  2=vim  3=返回"
    echo ""
    read -p "  选择: " c
    case $c in
        1) nano "$FRPS_CONF" ;;
        2) vim "$FRPS_CONF" ;;
        *) return ;;
    esac
    read -p "  是否重启服务？(y/N): " rc
    [ "$rc" = "y" ] && restart_service
}

view_config() {
    print_line
    echo -e "${BOLD}  📄 当前配置${NC}"
    print_line
    echo ""
    if [ -f "$FRPS_CONF" ]; then
        cat "$FRPS_CONF"
    else
        fail "配置文件不存在"
    fi
    echo ""
    print_line
    wait_key
}

check_ports() {
    print_line
    echo -e "${BOLD}  🌐 端口检查${NC}"
    print_line
    echo ""

    if [ -f "$FRPS_CONF" ]; then
        local bind_port=$(grep "^bindPort" "$FRPS_CONF" | awk '{print $3}')
        local web_port=$(grep "webServer.port" "$FRPS_CONF" | awk '{print $3}')
        echo -e "  ${BOLD}配置端口:${NC}"
        echo -e "    服务端: ${bind_port:-7000}"
        echo -e "    面板:   ${web_port:-7500}"
        echo ""
    fi

    echo -e "  ${BOLD}实际监听:${NC}"
    local found=0
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -E "frps|:7000|:7500" | while read line; do
            echo -e "    $line"
            found=1
        done
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -E "frps|:7000|:7500" | while read line; do
            echo -e "    $line"
            found=1
        done
    fi

    echo ""
    print_line
    wait_key
}

create_shortcut() {
    local shortcut="/usr/local/bin/frps"

    cat > "$shortcut" <<'SHORTCUT'
#!/bin/bash
if [ -d /run/systemd/system ] 2>/dev/null || [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]; then
    INIT="systemd"
else
    INIT="openrc"
fi

case "$1" in
    start)
        [ "$INIT" = "systemd" ] && sudo systemctl start frps || sudo rc-service frps start
        sleep 1
        echo "frps 已启动"
        ;;
    stop)
        [ "$INIT" = "systemd" ] && sudo systemctl stop frps || sudo rc-service frps stop
        echo "frps 已停止"
        ;;
    restart)
        [ "$INIT" = "systemd" ] && sudo systemctl restart frps || sudo rc-service frps restart
        sleep 1
        echo "frps 已重启"
        ;;
    status)
        [ "$INIT" = "systemd" ] && sudo systemctl status frps || sudo rc-service frps status
        ;;
    enable)
        [ "$INIT" = "systemd" ] && sudo systemctl enable frps || sudo rc-update add frps default
        echo "已设置开机自启"
        ;;
    disable)
        [ "$INIT" = "systemd" ] && sudo systemctl disable frps || sudo rc-update del frps default
        echo "已取消开机自启"
        ;;
    log)
        [ -f /opt/frps/logs/frps.log ] && tail -f /opt/frps/logs/frps.log || echo "日志不存在"
        ;;
    conf)
        sudo nano /opt/frps/frps.toml
        echo "修改后执行: frps restart"
        ;;
    manage|panel|dashboard)
        sudo bash /opt/frps/frps_manager.sh
        ;;
    *)
        echo "用法: frps {start|stop|restart|status|enable|disable|log|conf|manage}"
        ;;
esac
SHORTCUT

    chmod +x "$shortcut"
    success "快捷命令已创建: $shortcut"
    wait_key
}

uninstall_frps() {
    print_line
    echo -e "${BOLD}  🗑️  卸载 frps${NC}"
    print_line
    echo ""
    read -p "  输入 YES 确认卸载: " c
    if [ "$c" != "YES" ]; then
        info "已取消"
        wait_key
        return
    fi

    service_action stop 2>/dev/null
    service_action disable 2>/dev/null

    local init=$(detect_init_system)
    [ "$init" = "systemd" ] && rm -f "/etc/systemd/system/${SERVICE_NAME}.service" && systemctl daemon-reload 2>/dev/null
    [ "$init" = "openrc" ] && rm -f "/etc/init.d/${SERVICE_NAME}"

    rm -rf "$INSTALL_DIR"
    rm -f "/usr/local/bin/frps"

    success "frps 已卸载"
    wait_key
}

# ======================== 主菜单 ========================

show_menu() {
    clear

    local st="inactive"
    local en="disabled"
    if [ -f "$FRPS_BIN" ]; then
        st=$(service_action status 2>/dev/null || echo "inactive")
        en=$(service_action enabled 2>/dev/null || echo "disabled")
    fi

    local init=$(detect_init_system)

    local st_text="${RED}● 未安装${NC}"
    [ -f "$FRPS_BIN" ] && {
        [ "$st" = "active" ] && st_text="${GREEN}● 运行中${NC}" || st_text="${RED}● 已停止${NC}"
    }
    local en_text="${YELLOW}未启用${NC}"
    [ "$en" = "enabled" ] && en_text="${GREEN}已启用${NC}"

    echo ""
    echo -e "  ${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}║         FRP 服务端 管理面板 v3                   ║${NC}"
    echo -e "  ${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  状态: $st_text  |  自启: $en_text  |  系统: $init"
    echo -e "  目录: $INSTALL_DIR"
    echo ""
    echo -e "  ${CYAN}── 部署 ──────────────────────────────────────${NC}"
    echo -e "  ${BOLD}1${NC})  部署 / 更新"
    echo -e "  ${BOLD}2${NC})  卸载"
    echo -e "  ${BOLD}3${NC})  环境检测"
    echo ""
    echo -e "  ${CYAN}── 服务 ──────────────────────────────────────${NC}"
    echo -e "  ${BOLD}4${NC})  启动        ${BOLD}5${NC})  停止        ${BOLD}6${NC})  重启"
    echo -e "  ${BOLD}7${NC})  开机自启    ${BOLD}8${NC})  取消自启"
    echo ""
    echo -e "  ${CYAN}── 监控 ──────────────────────────────────────${NC}"
    echo -e "  ${BOLD}9${NC})  运行状态    ${BOLD}10${NC}) 实时日志    ${BOLD}11${NC}) 最近日志"
    echo -e "  ${BOLD}12${NC}) 清空日志"
    echo ""
    echo -e "  ${CYAN}── 配置 ──────────────────────────────────────${NC}"
    echo -e "  ${BOLD}13${NC}) 编辑配置    ${BOLD}14${NC}) 查看配置"
    echo ""
    echo -e "  ${CYAN}── 工具 ──────────────────────────────────────${NC}"
    echo -e "  ${BOLD}15${NC}) 端口检查    ${BOLD}16${NC}) 创建快捷命令"
    echo ""
    echo -e "  ${BOLD}0${NC})  退出"
    echo ""
}

# ======================== 启动入口 ========================

main() {
    # 启动时立即做全面检测
    if ! full_system_check; then
        echo ""
        read -n 1 -s -r -p "按任意键退出..."
        exit 1
    fi

    # 检测通过后进入菜单
    while true; do
        show_menu
        read -p "  选项 [0-16]: " choice
        case $choice in
            1)  deploy_frps ;;
            2)  uninstall_frps ;;
            3)
                clear
                full_system_check
                wait_key
                ;;
            4)  start_service ;;
            5)  stop_service ;;
            6)  restart_service ;;
            7)  enable_service ;;
            8)  disable_service ;;
            9)  check_status ;;
            10) view_live_log ;;
            11) view_recent_log ;;
            12) clear_log ;;
            13) edit_config ;;
            14) view_config ;;
            15) check_ports ;;
            16) create_shortcut ;;
            0)  clear; echo -e "\n  再见！\n"; exit 0 ;;
            *)  echo -e "${RED}无效选项${NC}"; sleep 0.8 ;;
        esac
    done
}

main "$@"