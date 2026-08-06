#!/bin/sh

# ============================================================================
#  FRP 服务端一键安装脚本
#  运行一次后自动注册 frps CLI 命令
#  兼容: Debian / Ubuntu（仅限）
#  支持: systemd
#  日期: 2026-08-06
# ============================================================================

INSTALL_DIR="/opt/frps"
FRPS_BIN="$INSTALL_DIR/frps"
FRPS_CONF="$INSTALL_DIR/frps.toml"
SERVICE_NAME="frps"
LOG_DIR="$INSTALL_DIR/logs"
LOG_FILE="$LOG_DIR/frps.log"
CLI_BIN="/usr/local/bin/frps"

MIN_DISK_MB=50
MIN_RAM_MB=25

# ======================== 输出函数 ========================

ok()   { printf "\033[0;32m[  ok  ]\033[0m %s\n" "$1"; }
fail() { printf "\033[0;31m[ fail ]\033[0m %s\n" "$1"; }
info() { printf "\033[0;34m[  i   ]\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m[  !   ]\033[0m %s\n" "$1"; }
line() { printf "\033[0;36m────────────────────────────────────────────────────\033[0m\n"; }

die() {
    printf "\033[0;31m[错误] %s\033[0m\n" "$1" >&2
    exit 1
}

# ======================== 发行版检测（新增） ========================
# 仅允许 Debian / Ubuntu

detect_distro() {
    if [ ! -f /etc/os-release ]; then
        echo "unknown"
        return
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    local id="${ID:-}" id_like="${ID_LIKE:-}"
    case "$id" in
        debian|ubuntu)  echo "debian" ;;
        *)
            case "$id_like" in
                *debian*|*ubuntu*) echo "debian" ;;
                *) echo "unknown" ;;
            esac
            ;;
    esac
}

ensure_distro() {
    local distro
    distro=$(detect_distro)
    if [ "$distro" != "debian" ]; then
        printf "\033[0;31m[错误] 本脚本仅支持 Debian / Ubuntu 系统\033[0m\n" >&2
        if [ -f /etc/os-release ]; then
            # shellcheck disable=SC1091
            . /etc/os-release
            printf "\033[0;31m       当前系统: %s (%s)\033[0m\n" "${PRETTY_NAME:-unknown}" "${ID:-unknown}" >&2
        fi
        exit 1
    fi
    ok "系统兼容: $(. /etc/os-release && echo "${PRETTY_NAME:-$ID}")"
}

# ======================== 系统检测 ========================

detect_init() {
    if [ -d /run/systemd/system ] 2>/dev/null; then echo "systemd"
    elif [ -f /proc/1/comm ]; then
        case "$(cat /proc/1/comm 2>/dev/null)" in
            systemd) echo "systemd" ;;
            *) echo "unknown" ;;
        esac
    else echo "unknown"
    fi
}

detect_pkg() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    else echo "unknown"
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm" ;;
        *)       echo "unsupported" ;;
    esac
}

free_ram() {
    if [ -f /proc/meminfo ]; then
        local a
        a=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
        if [ -n "$a" ] && [ "$a" != "0" ]; then
            echo $((a / 1024))
        else
            awk '/MemFree:/{f=$2} /Buffers:/{b=$2} /Cached:/{c=$2} END{print int((f+b+c)/1024)}' /proc/meminfo
        fi
    else echo 0; fi
}

total_ram() {
    awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0
}

disk_free() {
    df -m / | awk 'NR==2{print $4}'
}

# ======================== 依赖安装 ========================

install_pkgs() {
    [ $# -eq 0 ] && return 0
    info "安装软件包: $*"
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq "$@" 2>/dev/null
}

ensure_deps() {
    line
    printf "  \033[1m检测依赖工具\033[0m\n"
    line
    echo ""

    local cmds="curl wget tar grep openssl iproute2"
    local need=""

    for cmd in $cmds; do
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$cmd"
        else
            fail "$cmd"
            need="$need $cmd"
        fi
    done

    echo ""

    if [ -n "$need" ]; then
        local unique=""
        for p in $need; do
            case " $unique " in
                *" $p "*) ;;
                *) unique="$unique $p" ;;
            esac
        done

        install_pkgs $unique || die "依赖安装失败，请手动安装后重试"
        echo ""

        for cmd in $cmds; do
            command -v "$cmd" >/dev/null 2>&1 || die "工具 $cmd 安装后仍不可用"
        done
        ok "所有依赖已安装并验证"
    else
        ok "所有依赖已就绪"
    fi

    case ":$PATH:" in
        *:/usr/local/bin:*) ;;
        *) export PATH="/usr/local/bin:$PATH" ;;
    esac

    echo ""
}

# ======================== 环境检测 ========================

full_check() {
    line
    printf "  \033[1mFRP 服务端 安装环境检测\033[0m\n"
    line
    echo ""

    local err=0

    # 发行版（最先检测）
    ensure_distro

    # root
    if [ "$(id -u)" -ne 0 ]; then
        fail "需要 root 权限，请用 sudo 运行"
        err=$((err + 1))
    else
        ok "root 权限"
    fi

    # 架构
    local arch
    arch=$(get_arch)
    if [ "$arch" = "unsupported" ]; then
        fail "不支持的架构: $(uname -m)"
        err=$((err + 1))
    else
        ok "CPU 架构: $(uname -m) -> $arch"
    fi

    # 内存
    local fr tr
    fr=$(free_ram)
    tr=$(total_ram)
    if [ "$tr" -eq 0 ]; then
        fail "无法读取内存"
        err=$((err + 1))
    elif [ "$fr" -lt "$MIN_RAM_MB" ]; then
        fail "内存不足: 可用 ${fr}MB，最低 ${MIN_RAM_MB}MB"
        err=$((err + 1))
    else
        ok "内存: 总 ${tr}MB / 可用 ${fr}MB"
    fi

    # 磁盘
    local dfree
    dfree=$(disk_free)
    if [ "$dfree" -lt "$MIN_DISK_MB" ]; then
        fail "磁盘不足: 可用 ${dfree}MB，最低 ${MIN_DISK_MB}MB"
        err=$((err + 1))
    else
        ok "磁盘: 可用 ${dfree}MB"
    fi

    # 网络
    if command -v curl >/dev/null 2>&1; then
        if curl -s --connect-timeout 5 --max-time 10 -o /dev/null https://github.com 2>/dev/null; then
            ok "GitHub 连通"
        else
            warn "GitHub 连通性检测失败，下载可能需要代理"
        fi
    else
        warn "无 curl，跳过网络检测"
    fi

    # 初始化系统
    local init
    init=$(detect_init)
    if [ "$init" = "systemd" ]; then
        ok "初始化系统: systemd"
    else
        fail "不支持的初始化系统: $init (需要 systemd)"
        err=$((err + 1))
    fi

    # 端口
    local port
    for port in 7000 7500; do
        local used=""
        if command -v ss >/dev/null 2>&1; then
            used=$(ss -tlnp 2>/dev/null | grep ":${port} ")
        fi
        if [ -z "$used" ] && command -v netstat >/dev/null 2>&1; then
            used=$(netstat -tlnp 2>/dev/null | grep ":${port} ")
        fi
        if [ -n "$used" ]; then
            warn "端口 $port 已被占用 (可在配置中修改)"
        else
            ok "端口 $port 可用"
        fi
    done

    echo ""
    line

    if [ $err -gt 0 ]; then
        printf "  \033[0;31m检测未通过，%d 个问题需要解决\033[0m\n" "$err"
        line
        return 1
    else
        printf "  \033[0;32m全部通过\033[0m\n"
        line
        return 0
    fi
}

# ======================== 下载安装 ========================

get_version() {
    local v=""
    if command -v curl >/dev/null 2>&1; then
        v=$(curl -s --connect-timeout 10 --max-time 15 \
            https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
            | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    fi
    if [ -z "$v" ] && command -v curl >/dev/null 2>&1; then
        v=$(curl -sI --connect-timeout 10 \
            "https://github.com/fatedier/frp/releases/latest" 2>/dev/null \
            | grep -i "^location:" | tr -d '\r' \
            | grep -o 'v[0-9][0-9.]*' | head -1 | sed 's/^v//')
    fi
    echo "$v"
}

download_and_install() {
    line
    printf "  \033[1m下载安装 FRP\033[0m\n"
    line
    echo ""

    local version
    version=$(get_version)
    [ -z "$version" ] && die "获取版本失败，请检查网络"

    local arch
    arch=$(get_arch)
    [ "$arch" = "unsupported" ] && die "不支持的架构"

    local file="frp_${version}_linux_${arch}.tar.gz"
    local url="https://github.com/fatedier/frp/releases/download/v${version}/${file}"

    info "版本: v${version} | 架构: $arch"
    info "地址: $url"
    echo ""

    local tmp
    tmp=$(mktemp -d)

    info "正在下载..."
    local dl_ok=0
    if command -v wget >/dev/null 2>&1; then
        if wget -q --show-progress --timeout=30 --tries=3 -O "$tmp/$file" "$url" 2>&1; then
            dl_ok=1
        fi
    elif command -v curl >/dev/null 2>&1; then
        if curl -# --connect-timeout 30 --retry 3 -L -o "$tmp/$file" "$url" 2>&1; then
            dl_ok=1
        fi
    fi

    if [ "$dl_ok" -eq 0 ] || [ ! -f "$tmp/$file" ]; then
        rm -rf "$tmp"
        die "下载失败，请检查网络"
    fi

    local fsize=0
    if command -v stat >/dev/null 2>&1; then
        fsize=$(stat -c%s "$tmp/$file" 2>/dev/null || echo 0)
    fi
    if [ "$fsize" -lt 1048576 ]; then
        rm -rf "$tmp"
        die "下载文件异常 (${fsize} 字节)，可能不是有效压缩包"
    fi
    ok "下载完成 ($(( fsize / 1048576 ))MB)"

    info "正在解压..."
    if ! tar -xzf "$tmp/$file" -C "$tmp" 2>&1; then
        rm -rf "$tmp"
        die "解压失败"
    fi

    local dir
    dir=$(ls -d "$tmp"/frp_${version}_linux_${arch} 2>/dev/null)
    if [ -z "$dir" ] || [ ! -f "$dir/frps" ]; then
        rm -rf "$tmp"
        die "解压后未找到 frps 可执行文件"
    fi

    if [ -d "$INSTALL_DIR" ]; then
        local bak="/opt/frps_backups/frps_$(date +%Y%m%d_%H%M%S)"
        mkdir -p /opt/frps_backups
        cp -r "$INSTALL_DIR" "$bak" 2>/dev/null
        info "旧版本已备份到: $bak"
    fi

    mkdir -p "$INSTALL_DIR" "$LOG_DIR"
    cp "$dir/frps" "$FRPS_BIN"
    chmod +x "$FRPS_BIN"

    if [ ! -f "$FRPS_CONF" ]; then
        gen_config
    fi

    if [ -f "$0" ] && [ "$0" != "/dev/stdin" ]; then
        cp "$0" "$INSTALL_DIR/install.sh" 2>/dev/null
    fi

    rm -rf "$tmp"

    [ -x "$FRPS_BIN" ] || die "安装验证失败"
    local ver
    ver=$("$FRPS_BIN" --version 2>&1 | head -1)
    ok "安装完成: $ver"
}

gen_config() {
    local token wp
    if command -v openssl >/dev/null 2>&1; then
        token=$(openssl rand -hex 16)
        wp=$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' | head -c 12)
    else
        token=$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 32)
        wp=$(dd if=/dev/urandom bs=1 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 12)
    fi
    [ -z "$token" ] && token="CHANGE_ME_$(date +%s)"
    [ -z "$wp" ] && wp="CHANGE_ME_$(date +%s)"

    cat > "$FRPS_CONF" <<ENDCONF
# FRP 服务端配置 - 自动生成
# 文档: https://gofrp.org/zh-cn/docs/

bindAddr = "0.0.0.0"
bindPort = 7000

auth.method = "token"
auth.token = "${token}"

# vhostHTTPPort = 8080
# vhostHTTPSPort = 8443

# webServer.addr = "0.0.0.0"
# webServer.port = 7500
# webServer.user = "admin"
# webServer.password = "${wp}"

log.to = "${LOG_FILE}"
log.level = "info"
log.maxDays = 7

transport.maxPoolCount = 10
transport.tcpMux = true
ENDCONF

    echo ""
    warn "自动生成的认证信息 (请牢记或修改):"
    printf "  \033[1mauth.token\033[0m    = \033[1;33m%s\033[0m\n" "$token"
    printf "  \033[1mdashboard密码\033[0m = \033[1;33m%s\033[0m\n" "$wp"
    echo ""
}

# ======================== 服务文件 ========================

setup_service() {
    info "创建 systemd 服务文件..."

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<ENDSVC
[Unit]
Description=FRP Server (frps)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${FRPS_BIN} -c ${FRPS_CONF}
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
WorkingDirectory=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
ENDSVC
    systemctl daemon-reload || die "daemon-reload 失败"
    ok "systemd 服务已创建"
}

# ======================== 注册 CLI ========================

register_cli() {
    info "注册 frps CLI 命令..."

    cat > "$CLI_BIN" <<'ENDCLI'
#!/bin/sh
# ============================================================================
#  frps CLI 管理工具
#  由安装脚本自动生成
# ============================================================================

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=C.UTF-8

INSTALL_DIR="/opt/frps"
FRPS_BIN="$INSTALL_DIR/frps"
FRPS_CONF="$INSTALL_DIR/frps.toml"
SERVICE_NAME="frps"
LOG_FILE="$INSTALL_DIR/logs/frps.log"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
C='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ======================== 初始化系统 ========================

init_sys() {
    if [ -d /run/systemd/system ] 2>/dev/null; then echo "systemd"
    elif [ -f /proc/1/comm ]; then
        case "$(cat /proc/1/comm 2>/dev/null)" in
            systemd) echo "systemd" ;;
            *) echo "unknown" ;;
        esac
    else echo "unknown"
    fi
}

# ======================== 服务操作 ========================

svc() {
    local act=$1
    case $act in
        start)   systemctl start $SERVICE_NAME ;;
        stop)    systemctl stop $SERVICE_NAME ;;
        restart) systemctl restart $SERVICE_NAME ;;
        enable)  systemctl enable $SERVICE_NAME ;;
        disable) systemctl disable $SERVICE_NAME ;;
        status)
            systemctl is-active --quiet $SERVICE_NAME 2>/dev/null && echo "active" || echo "inactive" ;;
        enabled)
            systemctl is-enabled --quiet $SERVICE_NAME 2>/dev/null && echo "enabled" || echo "disabled" ;;
        pid) systemctl show $SERVICE_NAME --property=MainPID --value 2>/dev/null ;;
        log) shift; journalctl -u $SERVICE_NAME "$@" ;;
    esac
}

# ======================== 编辑器检测 ========================

pick_editor() {
    local e
    for e in nano vim vi; do
        command -v "$e" >/dev/null 2>&1 && { echo "$e"; return; }
    done
    echo ""
}

# ======================== 帮助 ========================

cmd_help() {
    echo ""
    printf "  ${BOLD}frps${NC} - FRP 服务端管理工具\n"
    echo ""
    printf "  ${BOLD}用法:${NC}\n"
    echo "    frps <命令> [选项]"
    echo ""
    printf "  ${BOLD}服务控制:${NC}\n"
    echo "    frps start          启动服务"
    echo "    frps stop           停止服务"
    echo "    frps restart        重启服务"
    echo ""
    printf "  ${BOLD}开机自启:${NC}\n"
    echo "    frps enable         设置开机自启"
    echo "    frps disable        取消开机自启"
    echo ""
    printf "  ${BOLD}状态查看:${NC}\n"
    echo "    frps status         查看运行状态"
    echo "    frps info           查看安装信息"
    echo "    frps ports          查看端口监听"
    echo "    frps version        查看当前版本"
    echo ""
    printf "  ${BOLD}日志管理:${NC}\n"
    echo "    frps log            实时日志 (Ctrl+C 退出)"
    echo "    frps log recent     最近50行日志"
    echo "    frps log clear      清空日志"
    echo ""
    printf "  ${BOLD}配置管理:${NC}\n"
    echo "    frps conf           编辑配置文件"
    echo "    frps conf show      查看配置文件"
    echo ""
    printf "  ${BOLD}维护:${NC}\n"
    echo "    frps reinstall      重新安装"
    echo "    frps uninstall      卸载 frps"
    echo "    frps help           显示此帮助"
    echo ""
}

# ======================== start ========================

cmd_start() {
    if [ ! -x "$FRPS_BIN" ]; then
        printf "${R}[错误]${NC} frps 未安装，请先运行安装脚本\n"
        exit 1
    fi
    printf "${B}[信息]${NC} 启动 frps...\n"
    svc start >/dev/null 2>&1
    sleep 1
    if [ "$(svc status)" = "active" ]; then
        printf "${G}[成功]${NC} frps 已启动 (后台运行)\n"
        echo "  PID: $(svc pid)"
    else
        printf "${R}[失败]${NC} 启动失败，查看日志: frps log recent\n"
    fi
}

# ======================== stop ========================

cmd_stop() {
    printf "${B}[信息]${NC} 停止 frps...\n"
    svc stop >/dev/null 2>&1
    printf "${G}[成功]${NC} frps 已停止\n"
}

# ======================== restart ========================

cmd_restart() {
    if [ ! -x "$FRPS_BIN" ]; then
        printf "${R}[错误]${NC} frps 未安装\n"
        exit 1
    fi
    printf "${B}[信息]${NC} 重启 frps...\n"
    svc restart >/dev/null 2>&1
    sleep 1
    if [ "$(svc status)" = "active" ]; then
        printf "${G}[成功]${NC} frps 已重启 (后台运行)\n"
    else
        printf "${R}[失败]${NC} 重启失败，查看日志: frps log recent\n"
    fi
}

# ======================== enable / disable ========================

cmd_enable() {
    printf "${B}[信息]${NC} 设置开机自启...\n"
    svc enable >/dev/null 2>&1
    printf "${G}[成功]${NC} 已设置开机自启\n"
}

cmd_disable() {
    printf "${B}[信息]${NC} 取消开机自启...\n"
    svc disable >/dev/null 2>&1
    printf "${G}[成功]${NC} 已取消开机自启\n"
}

# ======================== status ========================

cmd_status() {
    echo ""
    if [ ! -x "$FRPS_BIN" ]; then
        printf "${R}[错误]${NC} frps 未安装\n"
        echo ""
        return
    fi

    local st en pid
    st=$(svc status)
    en=$(svc enabled)
    pid=$(svc pid)

    if [ "$st" = "active" ]; then
        echo -e "  状态:  ${G}● 运行中${NC}"
    else
        echo -e "  状态:  ${R}● 已停止${NC}"
    fi

    if [ "$en" = "enabled" ]; then
        echo -e "  自启:  ${G}● 已启用${NC}"
    else
        echo -e "  自启:  ${Y}● 未启用${NC}"
    fi

    echo "  版本:  $("$FRPS_BIN" --version 2>&1 | head -1)"
    echo "  PID:   ${pid:-无}"

    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/status" ]; then
        local mem
        mem=$(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/$pid/status 2>/dev/null)
        [ -n "$mem" ] && echo "  内存:  ${mem} MB"
    fi

    echo ""
    echo "  端口监听:"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep "frps" | sed 's/^/    /'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep "frps" | sed 's/^/    /'
    fi

    if [ -f "$FRPS_CONF" ]; then
        local bp wp
        bp=$(grep "^bindPort" "$FRPS_CONF" 2>/dev/null | awk '{print $3}')
        wp=$(grep "webServer.port" "$FRPS_CONF" 2>/dev/null | awk '{print $3}')
        echo ""
        echo "  配置端口: 服务=${bp:-7000}  面板=${wp:-7500}"
    fi
    echo ""
}

# ======================== info ========================

cmd_info() {
    echo ""
    if [ ! -x "$FRPS_BIN" ]; then
        printf "${R}[错误]${NC} frps 未安装\n"
        return
    fi

    echo "  安装信息:"
    echo "  版本:       $("$FRPS_BIN" --version 2>&1 | head -1)"
    echo "  二进制:     $FRPS_BIN"
    echo "  配置文件:   $FRPS_CONF"
    echo "  日志文件:   $LOG_FILE"
    echo "  CLI命令:    $0"
    echo "  初始化系统: $(init_sys)"
    echo ""
    echo "  系统信息:"
    echo "  架构:       $(uname -m)"
    echo "  内核:       $(uname -r)"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "  系统:       ${PRETTY_NAME:-$ID}"
    fi
    local tr fa
    tr=$(awk '/MemTotal:/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    fa=$(awk '/MemAvailable:/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    echo "  内存:       ${fa:-?}MB / ${tr:-?}MB"
    echo "  磁盘可用:   $(df -m / | awk 'NR==2{print $4}')MB"
    echo ""
}

# ======================== ports ========================

cmd_ports() {
    echo ""
    echo "  端口监听:"
    echo ""

    if [ -f "$FRPS_CONF" ]; then
        local bp wp
        bp=$(grep "^bindPort" "$FRPS_CONF" 2>/dev/null | awk '{print $3}')
        wp=$(grep "webServer.port" "$FRPS_CONF" 2>/dev/null | awk '{print $3}')
        echo "  配置端口:"
        echo "    服务端:   ${bp:-7000}"
        echo "    管理面板: ${wp:-7500}"
        echo ""
    fi

    echo "  实际监听:"
    local found=0
    if command -v ss >/dev/null 2>&1; then
        local lines
        lines=$(ss -tlnp 2>/dev/null | grep -E "frps|:7000|:7500")
        if [ -n "$lines" ]; then
            echo "$lines" | sed 's/^/    /'
            found=1
        fi
    fi
    if [ "$found" -eq 0 ] && command -v netstat >/dev/null 2>&1; then
        local lines
        lines=$(netstat -tlnp 2>/dev/null | grep -E "frps|:7000|:7500")
        if [ -n "$lines" ]; then
            echo "$lines" | sed 's/^/    /'
            found=1
        fi
    fi
    [ "$found" -eq 0 ] && echo "    ${Y}未检测到监听${NC}"

    local cc=0
    if command -v ss >/dev/null 2>&1; then
        cc=$(ss -tn 2>/dev/null | grep -c "frps" || echo 0)
    fi
    echo "  活跃连接: $cc"
    echo ""
}

# ======================== log ========================

cmd_log() {
    case "${1:-live}" in
        live|""|-f)
            if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
                tail -f "$LOG_FILE"
            elif [ "$(init_sys)" = "systemd" ]; then
                journalctl -u $SERVICE_NAME -f --no-pager
            else
                printf "${R}[错误]${NC} 日志文件不存在: $LOG_FILE\n"
            fi ;;
        recent|tail)
            if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
                tail -n 50 "$LOG_FILE"
            elif [ "$(init_sys)" = "systemd" ]; then
                journalctl -u $SERVICE_NAME -n 50 --no-pager 2>/dev/null
            else
                printf "${R}[错误]${NC} 无日志\n"
            fi ;;
        clear|clean)
            echo "  确认清空日志?"
            read -r c
            case "$c" in
                y|Y|yes|YES)
                    [ -f "$LOG_FILE" ] && > "$LOG_FILE"
                    printf "${G}[成功]${NC} 日志已清空\n" ;;
                *) echo "  已取消" ;;
            esac ;;
        *)
            echo "用法: frps log [live|recent|clear]"
            echo "  live    实时日志 (默认)"
            echo "  recent  最近50行"
            echo "  clear   清空日志" ;;
    esac
}

# ======================== conf ========================

cmd_conf() {
    case "${1:-edit}" in
        edit|"")
            if [ ! -f "$FRPS_CONF" ]; then
                printf "${R}[错误]${NC} 配置文件不存在: $FRPS_CONF\n"
                return 1
            fi
            local editor
            editor=$(pick_editor)
            if [ -z "$editor" ]; then
                printf "${R}[错误]${NC} 没有可用的文本编辑器\n"
                echo "  请手动修改: $FRPS_CONF"
                echo "  或安装编辑器: apt install nano"
                return 1
            fi
            printf "${B}[信息]${NC} 使用 ${BOLD}%s${NC} 编辑配置\n" "$editor"
            echo "  文件: $FRPS_CONF"
            echo ""

            # ===================== 关键修复 =====================
            # 原脚本 nano 使用了 --const（禁止修改）导致无法编辑
            # 已移除 --const 和 --linenumbers，直接以可写模式打开
            # ======================================================

            case "$editor" in
                nano)
                    LANG=C.UTF-8 LC_ALL=C.UTF-8 nano "$FRPS_CONF"
                    ;;
                vim)
                    LANG=C.UTF-8 LC_ALL=C.UTF-8 vim "$FRPS_CONF"
                    ;;
                vi)
                    LANG=C.UTF-8 LC_ALL=C.UTF-8 vi "$FRPS_CONF"
                    ;;
                *)
                    LANG=C.UTF-8 LC_ALL=C.UTF-8 "$editor" "$FRPS_CONF"
                    ;;
            esac

            echo ""
            printf "${B}[信息]${NC} 配置已修改\n"
            printf "${B}[信息]${NC} 输入 y 重启服务使配置生效，其他键跳过: "
            read -r c
            case "$c" in
                y|Y) cmd_restart ;;
            esac
            ;;
        show|cat)
            if [ ! -f "$FRPS_CONF" ]; then
                printf "${R}[错误]${NC} 配置文件不存在\n"
                return 1
            fi
            cat "$FRPS_CONF" ;;
        *)
            echo "用法: frps conf [edit|show]"
            echo "  edit   编辑配置 (默认)"
            echo "  show   查看配置" ;;
    esac
}

# ======================== version ========================

cmd_version() {
    if [ -x "$FRPS_BIN" ]; then
        "$FRPS_BIN" --version 2>&1 | head -1
    else
        printf "${R}[错误]${NC} frps 未安装\n"
    fi
}

# ======================== reinstall ========================

cmd_reinstall() {
    if [ ! -f "$INSTALL_DIR/install.sh" ]; then
        printf "${R}[错误]${NC} 安装脚本不存在，请重新下载\n"
        exit 1
    fi
    printf "${B}[信息]${NC} 停止当前服务...\n"
    svc stop 2>/dev/null
    svc disable 2>/dev/null
    printf "${B}[信息]${NC} 重新安装...\n"
    sh "$INSTALL_DIR/install.sh"
}

# ======================== uninstall ========================

cmd_uninstall() {
    echo ""
    printf "${Y}[警告]${NC} 即将卸载 frps，将删除:\n"
    echo "  - $INSTALL_DIR"
    echo "  - /etc/systemd/system/${SERVICE_NAME}.service"
    echo "  - $0"
    echo ""
    echo -n "  输入 YES 确认卸载: "
    read -r c
    if [ "$c" != "YES" ]; then
        echo "  已取消"
        return
    fi

    svc stop 2>/dev/null
    svc disable 2>/dev/null
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload 2>/dev/null
    rm -rf "$INSTALL_DIR"
    rm -f "$0"
    printf "${G}[成功]${NC} frps 已完全卸载\n"
}

# ======================== 主入口 ========================

if [ ! -x "$FRPS_BIN" ]; then
    case "${1:-help}" in
        help|-h|--help|"") cmd_help; exit 0 ;;
        *)
            echo ""
            printf "${R}[错误]${NC} frps 未安装\n"
            echo "  请先运行安装脚本进行安装"
            echo ""
            exit 1
            ;;
    esac
fi

case "${1:-help}" in
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    restart)     cmd_restart ;;
    enable)      cmd_enable ;;
    disable)     cmd_disable ;;
    status)      cmd_status ;;
    info)        cmd_info ;;
    ports)       cmd_ports ;;
    log)         cmd_log "$2" ;;
    conf)        cmd_conf "$2" ;;
    version|ver) cmd_version ;;
    reinstall)   cmd_reinstall ;;
    uninstall)   cmd_uninstall ;;
    help|-h|--help|"") cmd_help ;;
    *)
        echo ""
        printf "${R}[错误]${NC} 未知命令: %s\n" "$1"
        echo "  运行 frps help 查看所有命令"
        echo "" ;;
esac
ENDCLI

    chmod +x "$CLI_BIN"
    ok "CLI 命令已注册: $CLI_BIN"
}

# ======================== 安装流程 ========================

do_install() {
    echo ""
    printf "  \033[1mFRP 服务端 一键安装\033[0m\n"
    echo ""

    # 1. 环境检测（含发行版校验）
    full_check || die "环境检测未通过"
    echo ""

    # 2. 依赖
    ensure_deps

    # 3. 下载安装
    download_and_install
    echo ""

    # 4. 服务文件
    setup_service
    echo ""

    # 5. 注册 CLI
    register_cli
    echo ""

    case ":$PATH:" in
        *:/usr/local/bin:*) ;;
        *) export PATH="/usr/local/bin:$PATH" ;;
    esac

    line
    printf "  \033[0;32m安装完成！\033[0m\n"
    line
    echo ""
    echo "  安装目录:   $INSTALL_DIR"
    echo "  配置文件:   $FRPS_CONF"
    echo "  管理命令:   frps help"
    echo ""
    echo "  快速开始:"
    echo "    1) frps conf          编辑配置，修改密码"
    echo "    2) frps start         启动服务"
    echo "    3) frps enable        设置开机自启"
    echo "    4) frps status        查看状态"
    echo "    5) frps log           查看实时日志"
    echo "    6) 访问 http://服务器IP:7500  管理面板"
    echo ""
}

# ======================== 入口 ========================

case "${1:-}" in
    --update|--reinstall)
        download_and_install
        setup_service
        register_cli
        echo ""
        ok "操作完成，运行 frps start 启动服务"
        ;;
    *)
        do_install
        ;;
esac