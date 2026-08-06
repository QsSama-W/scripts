#!/bin/bash

# ============================================================================
#  FRP 服务器 (frps) 一键部署与管理脚本
#  功能：自动下载最新版FRP，部署到/opt/frps，提供完整中文交互式管理菜单
#  日期：2026-08-06
# ============================================================================

# ======================== 全局变量 ========================
INSTALL_DIR="/opt/frps"
FRPS_BIN="$INSTALL_DIR/frps"
FRPS_CONF="$INSTALL_DIR/frps.toml"
FRPS_SERVICE="/etc/systemd/system/frps.service"
SERVICE_NAME="frps"
LOG_DIR="$INSTALL_DIR/logs"
LOG_FILE="$LOG_DIR/frps.log"
BACKUP_DIR="/opt/frps_backups"
SCRIPT_NAME="frps"

# 最低资源要求
MIN_DISK_MB=50      # 最低磁盘空间 50MB
MIN_RAM_MB=30       # 最低可用内存 30MB

# ======================== 颜色定义 ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ======================== 工具函数 ========================

# 带颜色的分隔线
print_line() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 信息提示
info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

# 成功提示
success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

# 警告提示
warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

# 错误提示
error() {
    echo -e "${RED}[错误]${NC} $1"
}

# 等待用户按键
wait_key() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo ""
}

# ======================== 系统检测 ========================

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "此脚本需要以 root 权限运行"
        echo "  请执行: sudo bash $0"
        exit 1
    fi
}

# 获取系统架构
get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)     echo "amd64" ;;
        aarch64)    echo "arm64" ;;
        armv7l)     echo "arm" ;;
        *)
            error "不支持的CPU架构: $arch"
            exit 1
            ;;
    esac
}

# 获取系统信息概览
get_system_info() {
    local arch=$(uname -m)
    local os_name=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)
    local kernel=$(uname -r)
    local total_ram=$(free -m | awk '/Mem:/{print $2}')
    local free_ram=$(free -m | awk '/Mem:/{print $7}')
    local disk_total=$(df -m / | awk 'NR==2{print $2}')
    local disk_free=$(df -m / | awk 'NR==2{print $4}')

    echo -e "  ${BOLD}操作系统${NC}     : ${os_name:-未知}"
    echo -e "  ${BOLD}内核版本${NC}     : ${kernel}"
    echo -e "  ${BOLD}CPU架构${NC}      : ${arch}"
    echo -e "  ${BOLD}总内存${NC}       : ${total_ram} MB"
    echo -e "  ${BOLD}可用内存${NC}     : ${free_ram} MB"
    echo -e "  ${BOLD}磁盘总空间${NC}   : ${disk_total} MB"
    echo -e "  ${BOLD}磁盘可用空间${NC} : ${disk_free} MB"
}

# 检测安装前的资源空间（磁盘 + 内存）
check_resources() {
    print_line
    echo -e "${BOLD}  📋 安装前资源检测${NC}"
    print_line
    echo ""

    # 检测可用内存
    local free_ram=$(free -m | awk '/Mem:/{print $7}')
    local total_ram=$(free -m | awk '/Mem:/{print $2}')

    echo -e "  ${BOLD}内存检测:${NC}"
    echo -e "    总内存:     ${total_ram} MB"
    echo -e "    可用内存:   ${free_ram} MB"
    echo -e "    最低要求:   ${MIN_RAM_MB} MB"
    echo ""

    if [ "$free_ram" -lt "$MIN_RAM_MB" ]; then
        error "可用内存不足！当前可用 ${free_ram} MB，最低需要 ${MIN_RAM_MB} MB"
        echo "    FRPS 服务运行时大约需要 ${MIN_RAM_MB} MB 内存"
        echo "    建议关闭不必要的程序后重试"
        return 1
    else
        success "内存检测通过"
    fi

    echo ""

    # 检测可用磁盘空间
    local disk_free=$(df -m / | awk 'NR==2{print $4}')
    local disk_total=$(df -m / | awk 'NR==2{print $2}')

    echo -e "  ${BOLD}磁盘检测:${NC}"
    echo -e "    磁盘总空间:   ${disk_total} MB"
    echo -e "    可用空间:     ${disk_free} MB"
    echo -e "    最低要求:     ${MIN_DISK_MB} MB"
    echo ""

    if [ "$disk_free" -lt "$MIN_DISK_MB" ]; then
        error "磁盘空间不足！当前可用 ${disk_free} MB，最低需要 ${MIN_DISK_MB} MB"
        echo "    解压安装包约需 30 MB，运行日志预留 20 MB"
        return 1
    else
        success "磁盘检测通过"
    fi

    echo ""
    print_line
    success "资源检测全部通过，可以继续安装"
    print_line

    return 0
}

# ======================== 安装依赖 ========================

install_dependencies() {
    info "正在检查并安装必要依赖..."

    local deps_needed=()

    if ! command -v wget &>/dev/null; then
        deps_needed+=("wget")
    fi
    if ! command -v curl &>/dev/null; then
        deps_needed+=("curl")
    fi
    if ! command -v tar &>/dev/null; then
        deps_needed+=("tar")
    fi

    if [ ${#deps_needed[@]} -eq 0 ]; then
        success "所有依赖已就绪"
        return 0
    fi

    info "需要安装: ${deps_needed[*]}"

    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "${deps_needed[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y -q "${deps_needed[@]}"
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "${deps_needed[@]}"
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm "${deps_needed[@]}"
    else
        error "无法自动安装依赖，请手动安装: ${deps_needed[*]}"
        return 1
    fi

    success "依赖安装完成"
    return 0
}

# ======================== 下载与安装 ========================

# 获取FRP最新版本号
get_latest_version() {
    local version=""
    # 尝试从 GitHub API 获取
    version=$(curl -s --connect-timeout 10 https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
        | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')

    if [ -z "$version" ]; then
        # 备用：从GitHub页面解析
        version=$(curl -sL --connect-timeout 10 "https://github.com/fatedier/frp/releases/latest" 2>/dev/null \
            | grep -oP 'tag/v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi

    echo "$version"
}

# 下载最新版frps
download_frps() {
    print_line
    echo -e "${BOLD}  📥 下载 FRP 服务端${NC}"
    print_line
    echo ""

    # 获取最新版本
    info "正在从 GitHub 获取 FRP 最新版本..."
    local version=$(get_latest_version)

    if [ -z "$version" ]; then
        warn "无法从 GitHub 获取最新版本，将使用备用版本 0.61.1"
        version="0.61.1"
    fi

    local arch=$(get_arch)
    local filename="frp_${version}_linux_${arch}.tar.gz"
    local download_url="https://github.com/fatedier/frp/releases/download/v${version}/${filename}"

    info "版本号:   v${version}"
    info "架构:     ${arch}"
    info "文件名:   ${filename}"
    info "下载地址: ${download_url}"
    echo ""

    # 创建临时目录
    local tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT

    info "正在下载，请稍候..."
    if ! wget -q --show-progress -O "$tmp_dir/$filename" "$download_url" 2>&1; then
        error "下载失败！请检查网络连接"
        echo "  如果在中国大陆，可能需要代理或使用镜像源"
        rm -rf "$tmp_dir"
        return 1
    fi

    success "下载完成"

    # 解压
    info "正在解压安装包..."
    cd "$tmp_dir" || return 1
    if ! tar -xzf "$filename" 2>&1; then
        error "解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi

    local extracted_dir=$(ls -d frp_${version}_linux_${arch} 2>/dev/null)
    if [ -z "$extracted_dir" ] || [ ! -d "$extracted_dir" ]; then
        error "解压后未找到预期目录"
        rm -rf "$tmp_dir"
        return 1
    fi

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$LOG_DIR"

    # 复制文件
    cp "$tmp_dir/$extracted_dir/frps" "$FRPS_BIN"
    chmod +x "$FRPS_BIN"

    # 生成配置文件（如果不存在）
    if [ ! -f "$FRPS_CONF" ]; then
        generate_default_config
    fi

    # 清理临时文件
    rm -rf "$tmp_dir"
    trap - EXIT

    success "frps 二进制文件已安装到 $FRPS_BIN"
    return 0
}

# 生成默认配置文件
generate_default_config() {
    local token=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    local web_password=$(openssl rand -base64 8 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

    cat > "$FRPS_CONF" <<EOF
# ===========================================
# FRP 服务端配置文件 (frps.toml)
# 由部署脚本自动生成
# 文档: https://gofrp.org/zh-cn/docs/
# ===========================================

# --- 基础设置 ---
# 服务端监听地址
bindAddr = "0.0.0.0"
# 服务端监听端口（客户端连接此端口）
bindPort = 7000

# --- 认证设置 ---
auth.method = "token"
auth.token = "${token}"

# --- HTTP/HTTPS 虚拟主机 ---
# 如需通过域名暴露HTTP服务，取消注释以下行
# vhostHTTPPort = 8080
# vhostHTTPSPort = 8443
# vhostHTTPTimeout = 60

# --- Dashboard 管理面板 ---
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "${web_password}"

# --- 日志设置 ---
log.to = "${LOG_FILE}"
log.level = "info"
log.maxDays = 7

# --- 连接池设置 ---
transport.maxPoolCount = 10
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 30

# --- 端口限制（可选）---
# 限制客户端可映射的端口范围
# allowPorts = [
#   { start = 2000, end = 30000 }
# ]

# --- 其他设置 ---
# 客户端最大连接数限制
# maxPortsPerClient = 0
# 如果端口被占用是否自动关闭
# tcpNatdTimeout = 90
EOF

    echo ""
    warn "已生成默认配置文件: $FRPS_CONF"
    warn "随机生成的认证令牌: ${token}"
    warn "随机生成的面板密码: ${web_password}"
    warn "请务必在部署完成后修改以上密码！"
}

# ======================== systemd 服务管理 ========================

# 创建 systemd 服务文件
setup_systemd() {
    info "正在配置 systemd 服务..."

    cat > "$FRPS_SERVICE" <<EOF
[Unit]
Description=FRP Server (frps)
Documentation=https://gofrp.org/zh-cn/docs/
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${FRPS_BIN} -c ${FRPS_CONF}
Restart=always
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3

# 进程限制
LimitNOFILE=1048576
LimitNPROC=512

# 安全加固
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}

# 环境
WorkingDirectory=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    success "systemd 服务文件已创建: $FRPS_SERVICE"
}

# ======================== 核心安装流程 ========================

deploy_frps() {
    print_line
    echo -e "${BOLD}  🚀 开始部署 FRP 服务端${NC}"
    print_line
    echo ""

    # 第一步：资源检测
    info "步骤 1/5: 系统资源检测"
    if ! check_resources; then
        error "资源检测未通过，安装终止"
        wait_key
        return
    fi
    echo ""

    # 第二步：安装依赖
    info "步骤 2/5: 检查系统依赖"
    if ! install_dependencies; then
        error "依赖安装失败"
        wait_key
        return
    fi
    echo ""

    # 第三步：备份已有安装
    if [ -d "$INSTALL_DIR" ]; then
        info "步骤 3/5: 备份已有安装"
        local backup_name="${BACKUP_DIR}/frps_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp -r "$INSTALL_DIR" "$backup_name"
        success "已备份到: $backup_name"
    else
        info "步骤 3/5: 首次安装，无需备份"
    fi
    echo ""

    # 第四步：下载并解压
    info "步骤 4/5: 下载并解压 FRP"
    if ! download_frps; then
        error "下载安装失败"
        wait_key
        return
    fi
    echo ""

    # 第五步：配置 systemd
    info "步骤 5/5: 配置系统服务"
    setup_systemd
    echo ""

    # 完成
    print_line
    echo -e "${GREEN}  ✅ FRP 服务端部署成功！${NC}"
    print_line
    echo ""
    echo -e "  ${BOLD}安装目录${NC}     : $INSTALL_DIR"
    echo -e "  ${BOLD}可执行文件${NC}   : $FRPS_BIN"
    echo -e "  ${BOLD}配置文件${NC}     : $FRPS_CONF"
    echo -e "  ${BOLD}日志目录${NC}     : $LOG_DIR"
    echo -e "  ${BOLD}服务文件${NC}     : $FRPS_SERVICE"
    echo ""
    print_line
    warn "接下来请执行以下操作："
    echo "  1. 编辑配置文件修改密码: ${BOLD}nano $FRPS_CONF${NC}"
    echo "  2. 启动服务:             ${BOLD}systemctl start frps${NC}"
    echo "  3. 设置开机自启:         ${BOLD}systemctl enable frps${NC}"
    echo "  4. 查看运行状态:         ${BOLD}systemctl status frps${NC}"
    print_line

    wait_key
}

# ======================== 服务管理 ========================

start_service() {
    info "正在启动 frps 服务..."
    systemctl start "$SERVICE_NAME" 2>/dev/null
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        success "frps 服务已成功启动（后台运行中）"
        local pid=$(systemctl show $SERVICE_NAME --property=MainPID --value 2>/dev/null)
        local port=$(ss -tlnp | grep "frps" | awk '{print $4}' | head -3)
        echo ""
        echo -e "  ${BOLD}进程PID${NC}  : $pid"
        echo -e "  ${BOLD}监听端口${NC} : $port"
    else
        error "启动失败，请查看日志: journalctl -u $SERVICE_NAME -n 20"
    fi
    wait_key
}

stop_service() {
    info "正在停止 frps 服务..."
    if systemctl stop "$SERVICE_NAME" 2>/dev/null; then
        success "frps 服务已停止"
    else
        error "停止失败"
    fi
    wait_key
}

restart_service() {
    info "正在重启 frps 服务..."
    systemctl restart "$SERVICE_NAME" 2>/dev/null
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        success "frps 服务已成功重启（后台运行中）"
    else
        error "重启失败，请查看日志"
    fi
    wait_key
}

enable_service() {
    info "正在设置 frps 开机自启..."
    if systemctl enable "$SERVICE_NAME" 2>/dev/null; then
        success "frps 服务已设置为开机自启"
        info "服务将在系统启动时自动在后台运行"
    else
        error "设置失败"
    fi
    wait_key
}

disable_service() {
    info "正在取消 frps 开机自启..."
    if systemctl disable "$SERVICE_NAME" 2>/dev/null; then
        success "已取消 frps 开机自启"
    else
        error "取消失败"
    fi
    wait_key
}

check_status() {
    print_line
    echo -e "${BOLD}  📊 frps 服务运行状态${NC}"
    print_line
    echo ""

    # 服务基本状态
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "  ${BOLD}服务状态${NC}  : ${GREEN}● 运行中${NC}"
    else
        echo -e "  ${BOLD}服务状态${NC}  : ${RED}● 已停止${NC}"
    fi

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "  ${BOLD}开机自启${NC}  : ${GREEN}● 已启用${NC}"
    else
        echo -e "  ${BOLD}开机自启${NC}  : ${YELLOW}● 未启用${NC}"
    fi

    # 进程信息
    local pid=$(systemctl show $SERVICE_NAME --property=MainPID --value 2>/dev/null)
    echo -e "  ${BOLD}主进程PID${NC} : ${pid:-无}"

    # 内存占用
    if [ "$pid" != "0" ] && [ -n "$pid" ]; then
        local mem=$(ps -o rss= -p "$pid" 2>/dev/null)
        if [ -n "$mem" ]; then
            echo -e "  ${BOLD}内存占用${NC}  : $((mem/1024)) MB"
        fi
        local uptime=$(ps -o etime= -p "$pid" 2>/dev/null | xargs)
        echo -e "  ${BOLD}运行时长${NC}  : $uptime"
    fi

    # 监听端口
    echo ""
    echo -e "  ${BOLD}监听端口:${NC}"
    ss -tlnp 2>/dev/null | grep "frps" | awk '{print "    " $4 " (" $6 ")"}'

    # 配置信息摘要
    if [ -f "$FRPS_CONF" ]; then
        echo ""
        echo -e "  ${BOLD}配置摘要:${NC}"
        local bind_port=$(grep -E "^bindPort" "$FRPS_CONF" | awk '{print $3}')
        local web_port=$(grep -E "webServer\.port" "$FRPS_CONF" | awk '{print $3}')
        echo -e "    服务端口:     ${bind_port:-7000}"
        echo -e "    管理面板端口: ${web_port:-7500}"
    fi

    echo ""
    print_line
    wait_key
}

# ======================== 日志管理 ========================

view_live_log() {
    print_line
    echo -e "${BOLD}  📜 frps 实时日志${NC}"
    echo -e "  ${YELLOW}按 Ctrl+C 退出日志查看${NC}"
    print_line
    echo ""

    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        info "日志文件不存在，使用 journalctl 查看..."
        journalctl -u "$SERVICE_NAME" -f --no-pager
    fi
}

view_recent_log() {
    print_line
    echo -e "${BOLD}  📜 frps 最近日志（最近50行）${NC}"
    print_line
    echo ""

    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        tail -n 50 "$LOG_FILE"
    else
        journalctl -u "$SERVICE_NAME" -n 50 --no-pager 2>/dev/null
    fi

    wait_key
}

clear_log() {
    warn "即将清空 frps 日志文件"
    read -p "确认清空？(y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$LOG_FILE" ]; then
            > "$LOG_FILE"
            success "日志已清空"
        fi
        journalctl --rotate --vacuum-time=1s -u "$SERVICE_NAME" 2>/dev/null
    else
        info "已取消"
    fi
    wait_key
}

# ======================== 配置管理 ========================

edit_config() {
    print_line
    echo -e "${BOLD}  ⚙️  编辑 frps 配置文件${NC}"
    print_line
    echo ""
    echo -e "  配置文件路径: ${BOLD}$FRPS_CONF${NC}"
    echo ""
    echo "  请选择编辑方式:"
    echo "    1) nano  (推荐新手，简单易用)"
    echo "    2) vim   (功能强大)"
    echo "    3) 返回主菜单"
    echo ""
    read -p "  请输入选择 [1-3]: " editor_choice

    case $editor_choice in
        1) nano "$FRPS_CONF" ;;
        2) vim "$FRPS_CONF" ;;
        3) return ;;
        *) warn "无效选择" ;;
    esac

    echo ""
    warn "配置文件已修改，如需生效请重启服务"
    read -p "  是否立即重启 frps 服务使配置生效？(y/N): " restart_confirm
    if [ "$restart_confirm" = "y" ] || [ "$restart_confirm" = "Y" ]; then
        restart_service
    fi
}

view_config() {
    print_line
    echo -e "${BOLD}  📄 当前 frps 配置文件内容${NC}"
    print_line
    echo ""

    if [ -f "$FRPS_CONF" ]; then
        cat "$FRPS_CONF"
    else
        error "配置文件不存在: $FRPS_CONF"
    fi

    echo ""
    print_line
    wait_key
}

# ======================== 网络检测 ========================

check_ports() {
    print_line
    echo -e "${BOLD}  🌐 端口监听检查${NC}"
    print_line
    echo ""

    if [ -f "$FRPS_CONF" ]; then
        local bind_port=$(grep -E "^bindPort" "$FRPS_CONF" | awk '{print $3}')
        local web_port=$(grep -E "webServer\.port" "$FRPS_CONF" | awk '{print $3}')
        local vhost_port=$(grep -E "vhostHTTPPort" "$FRPS_CONF" | grep -v "^#" | awk '{print $3}')

        echo -e "  ${BOLD}配置中定义的端口:${NC}"
        echo -e "    服务端口:     ${bind_port:-7000}"
        echo -e "    管理面板:     ${web_port:-7500}"
        [ -n "$vhost_port" ] && echo -e "    HTTP虚拟主机: $vhost_port"
        echo ""
    fi

    echo -e "  ${BOLD}实际监听情况:${NC}"
    local ports_info=$(ss -tlnp 2>/dev/null | grep "frps")
    if [ -n "$ports_info" ]; then
        echo "$ports_info" | while read line; do
            echo -e "    ${GREEN}$line${NC}"
        done
    else
        echo -e "    ${YELLOW}未检测到 frps 监听端口（服务可能未启动）${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}frps 相关所有连接:${NC}"
    ss -tnp 2>/dev/null | grep "frps" | head -10 || echo -e "    ${YELLOW}无活跃连接${NC}"

    echo ""
    print_line
    wait_key
}

# ======================== 快捷命令 ========================

create_shortcut() {
    info "正在创建全局管理快捷命令..."

    local shortcut_file="/usr/local/bin/frps"
    cat > "$shortcut_file" <<'SHORTCUT_EOF'
#!/bin/bash
# =========================================
# frps 管理快捷命令
# 用法: frps {start|stop|restart|status|log|conf|deploy}
# =========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

case "$1" in
    start)
        echo -e "${YELLOW}启动 frps 服务...${NC}"
        sudo systemctl start frps
        sleep 1
        if systemctl is-active --quiet frps; then
            echo -e "${GREEN}frps 已启动（后台运行中）${NC}"
        else
            echo -e "${RED}启动失败${NC}"
        fi
        ;;
    stop)
        echo -e "${YELLOW}停止 frps 服务...${NC}"
        sudo systemctl stop frps
        echo -e "${GREEN}frps 已停止${NC}"
        ;;
    restart)
        echo -e "${YELLOW}重启 frps 服务...${NC}"
        sudo systemctl restart frps
        sleep 1
        if systemctl is-active --quiet frps; then
            echo -e "${GREEN}frps 已重启（后台运行中）${NC}"
        else
            echo -e "${RED}重启失败${NC}"
        fi
        ;;
    status)
        sudo systemctl status frps
        ;;
    log)
        if [ -f /opt/frps/logs/frps.log ]; then
            tail -f /opt/frps/logs/frps.log
        else
            sudo journalctl -u frps -f
        fi
        ;;
    conf)
        sudo nano /opt/frps/frps.toml
        echo -e "${YELLOW}修改后请执行: frps restart${NC}"
        ;;
    deploy)
        sudo bash /opt/frps/frps_manager.sh
        ;;
    enable)
        sudo systemctl enable frps
        echo -e "${GREEN}已设置开机自启${NC}"
        ;;
    disable)
        sudo systemctl disable frps
        echo -e "${GREEN}已取消开机自启${NC}"
        ;;
    *)
        echo -e "frps 管理工具"
        echo ""
        echo "用法: frps <命令>"
        echo ""
        echo "命令列表:"
        echo "  start     启动服务"
        echo "  stop      停止服务"
        echo "  restart   重启服务"
        echo "  status    查看状态"
        echo "  log       查看实时日志"
        echo "  conf      编辑配置文件"
        echo "  enable    设置开机自启"
        echo "  disable   取消开机自启"
        echo "  deploy    打开管理面板"
        ;;
esac
SHORTCUT_EOF

    chmod +x "$shortcut_file"
    success "全局快捷命令已创建: $shortcut_file"
    echo ""
    echo -e "  ${BOLD}使用方法:${NC}"
    echo "    frps start     - 启动服务"
    echo "    frps stop      - 停止服务"
    echo "    frps restart   - 重启服务"
    echo "    frps status    - 查看状态"
    echo "    frps log       - 实时日志"
    echo "    frps conf      - 编辑配置"
    echo "    frps enable    - 设置开机自启"
    echo "    frps disable   - 取消开机自启"
    echo "    frps deploy    - 打开管理面板"

    wait_key
}

# ======================== 卸载 ========================

uninstall_frps() {
    print_line
    echo -e "${BOLD}  🗑️  卸载 frps${NC}"
    print_line
    echo ""
    warn "此操作将执行以下步骤："
    echo "  1. 停止 frps 服务"
    echo "  2. 禁用开机自启"
    echo "  3. 删除服务文件"
    echo "  4. 删除安装目录: $INSTALL_DIR"
    echo ""
    read -p "  确认卸载？输入 YES 确认: " confirm

    if [ "$confirm" != "YES" ]; then
        info "已取消卸载"
        wait_key
        return
    fi

    info "停止服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null

    info "禁用开机自启..."
    systemctl disable "$SERVICE_NAME" 2>/dev/null

    info "删除服务文件..."
    rm -f "$FRPS_SERVICE"
    systemctl daemon-reload

    info "删除安装目录..."
    rm -rf "$INSTALL_DIR"

    info "删除快捷命令..."
    rm -f "/usr/local/bin/frps"

    success "frps 已完全卸载"
    wait_key
}

# ======================== 更新脚本自身 ========================

update_script() {
    info "正在检查脚本更新..."
    warn "如需更新，请从原始来源重新下载此脚本"
    info "当前脚本路径: $0"
    wait_key
}

# ======================== 主菜单 ========================

show_menu() {
    clear

    # 状态栏
    local status_text="${RED}● 未安装${NC}"
    local enable_text="${YELLOW}未设置${NC}"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        status_text="${GREEN}● 运行中${NC}"
    elif [ -f "$FRPS_BIN" ]; then
        status_text="${RED}● 已停止${NC}"
    fi
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        enable_text="${GREEN}已启用${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}║          FRP 服务端 管理面板                      ║${NC}"
    echo -e "  ${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}服务状态${NC}  : $status_text"
    echo -e "  ${BOLD}开机自启${NC}  : $enable_text"
    echo -e "  ${BOLD}安装目录${NC}  : $INSTALL_DIR"
    echo ""
    echo -e "  ${CYAN}─── 部署管理 ──────────────────────────────────${NC}"
    echo -e "  ${BOLD}1${NC})  部署 / 更新 frps"
    echo -e "  ${BOLD}2${NC})  卸载 frps"
    echo -e "  ${BOLD}3${NC})  系统环境检测"
    echo ""
    echo -e "  ${CYAN}─── 服务控制 ──────────────────────────────────${NC}"
    echo -e "  ${BOLD}4${NC})  启动服务"
    echo -e "  ${BOLD}5${NC})  停止服务"
    echo -e "  ${BOLD}6${NC})  重启服务"
    echo ""
    echo -e "  ${CYAN}─── 开机自启 ──────────────────────────────────${NC}"
    echo -e "  ${BOLD}7${NC})  设置开机自启"
    echo -e "  ${BOLD}8${NC})  取消开机自启"
    echo ""
    echo -e "  ${CYAN}─── 状态与日志 ────────────────────────────────${NC}"
    echo -e "  ${BOLD}9${NC})  查看运行状态"
    echo -e "  ${BOLD}10${NC}) 实时日志 (Ctrl+C 退出)"
    echo -e "  ${BOLD}11${NC}) 最近日志 (最近50行)"
    echo -e "  ${BOLD}12${NC}) 清空日志"
    echo ""
    echo -e "  ${CYAN}─── 配置管理 ──────────────────────────────────${NC}"
    echo -e "  ${BOLD}13${NC}) 编辑配置文件"
    echo -e "  ${BOLD}14${NC}) 查看配置文件"
    echo ""
    echo -e "  ${CYAN}─── 网络工具 ──────────────────────────────────${NC}"
    echo -e "  ${BOLD}15${NC}) 端口监听检查"
    echo ""
    echo -e "  ${CYAN}─── 其他 ──────────────────────────────────────${NC}"
    echo -e "  ${BOLD}16${NC}) 创建全局快捷命令 (frps)"
    echo ""
    echo -e "  ${BOLD}0${NC})  退出脚本"
    echo ""
    echo -e "  ${CYAN}──────────────────────────────────────────────────${NC}"
}

# ======================== 主程序 ========================

main() {
    check_root

    while true; do
        show_menu
        read -p "  请输入选项 [0-16]: " choice
        case $choice in
            1)  deploy_frps ;;
            2)  uninstall_frps ;;
            3)
                clear
                print_line
                echo -e "${BOLD}  🖥️  系统环境检测${NC}"
                print_line
                echo ""
                get_system_info
                echo ""
                check_resources
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
            0)
                clear
                echo ""
                echo -e "  ${GREEN}感谢使用 FRP 管理面板，再见！${NC}"
                echo ""
                exit 0
                ;;
            *)
                error "无效选项，请输入 0-16 之间的数字"
                sleep 1
                ;;
        esac
    done
}

# 启动
main "$@"