#!/bin/bash

# ============================================================================
#  FRP 服务器一键安装脚本
#  运行一次后自动注册 frps CLI 命令
#  支持: Debian / Ubuntu / CentOS / Fedora / Alpine / Arch
#  支持: systemd / OpenRC
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ======================== 错误处理 ========================

die() {
    echo -e "${RED}[错误]${NC} $1" >&2
    exit 1
}

try() {
    local desc="$1"; shift
    local output
    output=$("$@" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${RED}[失败]${NC} $desc"
        [ -n "$output" ] && echo -e "${DIM}  $output${NC}"
        return 1
    fi
    return 0
}

ok()   { echo -e "${GREEN}[  ✓  ]${NC} $1"; }
fail() { echo -e "${RED}[  ✗  ]${NC} $1"; }
info() { echo -e "${BLUE}[  i  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[  !  ]${NC} $1"; }
line() { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }

# ======================== 系统检测 ========================

detect_init() {
    if [ -d /run/systemd/system ] 2>/dev/null; then echo "systemd"
    elif [ -f /sbin/openrc ] 2>/dev/null; then echo "openrc"
    elif [ -f /proc/1/comm ]; then
        case "$(cat /proc/1/comm 2>/dev/null)" in
            systemd) echo "systemd" ;;
            openrc-init) echo "openrc" ;;
            *) echo "unknown" ;;
        esac
    else echo "unknown"
    fi
}

detect_pkg() {
    if command -v apk &>/dev/null; then echo "apk"
    elif command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v pacman &>/dev/null; then echo "pacman"
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
        local a=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
        if [ -n "$a" ] && [ "$a" != "0" ]; then echo $((a/1024))
        else
            awk '/MemFree:/{f=$2} /Buffers:/{b=$2} /Cached:/{c=$2} END{print int((f+b+c)/1024)}' /proc/meminfo
        fi
    else echo 0; fi
}

total_ram() { awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0; }
disk_free() { df -m / | awk 'NR==2{print $4}'; }

# ======================== 依赖安装 ========================

install_pkgs() {
    local pkgs=("$@")
    [ ${#pkgs[@]} -eq 0 ] && return 0

    local pkg=$(detect_pkg)
    info "安装软件包: ${pkgs[*]}"

    case $pkg in
        apk)     apk update -q 2>/dev/null; apk add --no-cache "${pkgs[@]}" 2>/dev/null ;;
        apt)     apt-get update -qq 2>/dev/null; apt-get install -y -qq "${pkgs[@]}" 2>/dev/null ;;
        dnf)     dnf install -y -q "${pkgs[@]}" 2>/dev/null ;;
        yum)     yum install -y -q "${pkgs[@]}" 2>/dev/null ;;
        pacman)  pacman -S --noconfirm --needed "${pkgs[@]}" 2>/dev/null ;;
        *)       die "无法自动安装，请手动安装: ${pkgs[*]}" ;;
    esac
}

ensure_deps() {
    line
    echo -e "${BOLD}  检测依赖工具${NC}"
    line
    echo ""

    # 命令 -> 各发行版包名: debian/alpine/centos/arch
    local map=(
        "curl:curl:curl:curl:curl"
        "wget:wget:wget:wget:wget"
        "tar:tar:tar:tar:tar"
        "grep:grep:grep:grep:grep"
        "openssl:openssl:libressl:openssl:openssl"
    )

    local pkg=$(detect_pkg)

    # Alpine 专用
    [ "$pkg" = "apk" ] && map+=("bash:bash:bash:bash:bash" "ss:iproute2:iproute2:iproute:iproute2")

    # ss 命令
    [ "$pkg" != "apk" ] && map+=("ss:iproute2:iproute2:iproute:iproute2")

    local need_install=()

    for entry in "${map[@]}"; do
        IFS=':' read -r cmd deb alp cen arc <<< "$entry"
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd"
        else
            fail "$cmd"
            case $pkg in
                apk)           need_install+=("$alp") ;;
                apt)           need_install+=("$deb") ;;
                yum|dnf)       need_install+=("$cen") ;;
                pacman)        need_install+=("$arc") ;;
            esac
        fi
    done

    echo ""

    if [ ${#need_install[@]} -gt 0 ]; then
        local unique=($(printf '%s\n' "${need_install[@]}" | sort -u))
        install_pkgs "${unique[@]}" || die "依赖安装失败，请手动安装后重试"
        echo ""

        # 二次验证
        for entry in "${map[@]}"; do
            IFS=':' read -r cmd _ _ _ _ <<< "$entry"
            command -v "$cmd" &>/dev/null || die "工具 $cmd 安装后仍不可用"
        done
        ok "所有依赖已安装并验证"
    else
        ok "所有依赖已就绪"
    fi
    echo ""
}

# ======================== 环境检测 ========================

full_check() {
    line
    echo -e "${BOLD}  FRP 服务端 安装环境检测${NC}"
    line
    echo ""

    local err=0

    # root
    if [ "$(id -u)" -ne 0 ]; then
        fail "需要 root 权限，请用 sudo 运行"
        ((err++))
    else
        ok "root 权限"
    fi

    # 架构
    local arch=$(get_arch)
    if [ "$arch" = "unsupported" ]; then
        fail "不支持的架构: $(uname -m)"
        ((err++))
    else
        ok "CPU 架构: $(uname -m) -> $arch"
    fi

    # 内存
    local fr=$(free_ram)
    local tr=$(total_ram)
    if [ "$tr" -eq 0 ]; then
        fail "无法读取内存"
        ((err++))
    elif [ "$fr" -lt "$MIN_RAM_MB" ]; then
        fail "内存不足: 可用 ${fr}MB，最低 ${MIN_RAM_MB}MB"
        ((err++))
    else
        ok "内存: 总 ${tr}MB / 可用 ${fr}MB (最低 ${MIN_RAM_MB}MB)"
    fi

    # 磁盘
    local dfree=$(disk_free)
    if [ "$dfree" -lt "$MIN_DISK_MB" ]; then
        fail "磁盘不足: 可用 ${dfree}MB，最低 ${MIN_DISK_MB}MB"
        ((err++))
    else
        ok "磁盘: 可用 ${dfree}MB (最低 ${MIN_DISK_MB}MB)"
    fi

    # 网络
    if curl -s --connect-timeout 5 --max-time 10 -o /dev/null https://github.com 2>/dev/null; then
        ok "GitHub 连通"
    elif wget --spider --timeout=5 -q https://github.com 2>/dev/null; then
        ok "GitHub 连通"
    else
        warn "GitHub 连通性检测失败，下载可能需要代理"
    fi

    # 初始化系统
    local init=$(detect_init)
    case $init in
        systemd|openrc) ok "初始化系统: $init" ;;
        *) fail "不支持的初始化系统: $init (需要 systemd 或 OpenRC)"; ((err++)) ;;
    esac

    # 端口
    for port in 7000 7500; do
        local used=""
        command -v ss &>/dev/null && used=$(ss -tlnp 2>/dev/null | grep ":${port} ")
        [ -z "$used" ] && command -v netstat &>/dev/null && used=$(netstat -tlnp 2>/dev/null | grep ":${port} ")
        if [ -n "$used" ]; then
            warn "端口 $port 已被占用 (可在配置文件中修改)"
        else
            ok "端口 $port 可用"
        fi
    done

    echo ""
    line

    if [ $err -gt 0 ]; then
        echo -e "${RED}  检测未通过，${err} 个问题需要解决${NC}"
        line
        return 1
    else
        echo -e "${GREEN}  全部通过，可以安装${NC}"
        line
        return 0
    fi
}

# ======================== 下载安装 ========================

get_version() {
    local v=""
    v=$(curl -s --connect-timeout 10 --max-time 15 https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
        | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [ -z "$v" ]; then
        v=$(curl -sI --connect-timeout 10 "https://github.com/fatedier/frp/releases/latest" 2>/dev/null \
            | grep -i "^location:" | tr -d '\r' | grep -o 'v[0-9][0-9.]*' | head -1 | sed 's/^v//')
    fi
    echo "$v"
}

download_and_install() {
    line
    echo -e "${BOLD}  下载安装 FRP${NC}"
    line
    echo ""

    local version=$(get_version)
    [ -z "$version" ] && die "获取版本失败，请检查网络"
    local arch=$(get_arch)
    [ "$arch" = "unsupported" ] && die "不支持的架构"

    local file="frp_${version}_linux_${arch}.tar.gz"
    local url="https://github.com/fatedier/frp/releases/download/v${version}/${file}"

    info "版本: v${version} | 架构: $arch"
    info "下载: $url"
    echo ""

    local tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" EXIT

    # 下载
    info "正在下载..."
    if command -v wget &>/dev/null; then
        wget -q --show-progress --timeout=30 --tries=3 -O "$tmp/$file" "$url" 2>&1 || { rm -rf "$tmp"; trap - EXIT; die "下载失败"; }
    elif command -v curl &>/dev/null; then
        curl -# --connect-timeout 30 --retry 3 -L -o "$tmp/$file" "$url" 2>&1 || { rm -rf "$tmp"; trap - EXIT; die "下载失败"; }
    else
        rm -rf "$tmp"; trap - EXIT; die "wget 和 curl 均不可用"
    fi

    # 验证文件大小
    local fsize=$(stat -c%s "$tmp/$file" 2>/dev/null || stat -f%z "$tmp/$file" 2>/dev/null)
    [ -z "$fsize" ] || [ "$fsize" -lt 1048576 ] && { rm -rf "$tmp"; trap - EXIT; die "下载文件异常 (${fsize} 字节)，可能不是有效压缩包"; }
    ok "下载完成 ($(( fsize / 1048576 ))MB)"

    # 解压
    info "正在解压..."
    tar -xzf "$tmp/$file" -C "$tmp" 2>&1 || { rm -rf "$tmp"; trap - EXIT; die "解压失败"; }

    local dir=$(ls -d "$tmp"/frp_${version}_linux_${arch} 2>/dev/null)
    [ -z "$dir" ] || [ ! -f "$dir/frps" ] && { rm -rf "$tmp"; trap - EXIT; die "解压后未找到 frps"; }

    # 备份
    if [ -d "$INSTALL_DIR" ]; then
        local bak="/opt/frps_backups/frps_$(date +%Y%m%d_%H%M%S)"
        mkdir -p /opt/frps_backups
        cp -r "$INSTALL_DIR" "$bak" 2>/dev/null
        info "旧版本已备份到: $bak"
    fi

    # 安装
    mkdir -p "$INSTALL_DIR" "$LOG_DIR"
    cp "$dir/frps" "$FRPS_BIN"
    chmod +x "$FRPS_BIN"

    # 生成配置
    if [ ! -f "$FRPS_CONF" ]; then
        gen_config
    fi

    # 保存安装脚本
    [ -f "$0" ] && [ "$0" != "/dev/stdin" ] && cp "$0" "$INSTALL_DIR/install.sh" 2>/dev/null

    rm -rf "$tmp"
    trap - EXIT

    # 验证
    [ -x "$FRPS_BIN" ] || die "安装验证失败"
    local ver=$("$FRPS_BIN" --version 2>&1 | head -1)
    ok "安装完成: $ver"
}

gen_config() {
    local token wp
    if command -v openssl &>/dev/null; then
        token=$(openssl rand -hex 16)
        wp=$(openssl rand -base64 12 | tr -d '/+=' | head -c 12)
    else
        token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)
        wp=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 12)
    fi

    cat > "$FRPS_CONF" <<EOF
# FRP 服务端配置 - 自动生成
# 文档: https://gofrp.org/zh-cn/docs/

bindAddr = "0.0.0.0"
bindPort = 7000

auth.method = "token"
auth.token = "${token}"

# vhostHTTPPort = 8080
# vhostHTTPSPort = 8443

webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "${wp}"

log.to = "${LOG_FILE}"
log.level = "info"
log.maxDays = 7

transport.maxPoolCount = 10
transport.tcpMux = true
EOF

    echo ""
    warn "自动生成的认证信息 (请牢记或修改):"
    echo -e "  ${BOLD}auth.token${NC}      = ${YELLOW}${token}${NC}"
    echo -e "  ${BOLD}dashboard密码${NC}   = ${YELLOW}${wp}${NC}"
    echo ""
}

# ======================== 服务文件 ========================

setup_service() {
    local init=$(detect_init)
    info "创建服务文件 (init: $init)..."

    case $init in
        systemd)
            cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
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
EOF
            systemctl daemon-reload || die "daemon-reload 失败"
            ok "systemd 服务已创建"
            ;;

        openrc)
            cat > "/etc/init.d/${SERVICE_NAME}" <<'EOF'
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
depend() { need net; after firewall; }
start_pre() { mkdir -p /opt/frps/logs; touch /opt/frps/logs/frps.log; }
EOF
            chmod +x "/etc/init.d/${SERVICE_NAME}"
            ok "OpenRC 服务已创建"
            ;;

        *) die "不支持的初始化系统: $init" ;;
    esac
}

# ======================== 注册 CLI ========================

register_cli() {
    info "注册 frps CLI 命令..."

    cat > "$CLI_BIN" <<'CLI_SCRIPT'
#!/bin/bash
# frps CLI 管理工具 - 由安装脚本自动生成

INSTALL_DIR="/opt/frps"
FRPS_BIN="$INSTALL_DIR/frps"
FRPS_CONF="$INSTALL_DIR/frps.toml"
SERVICE_NAME="frps"
LOG_FILE="$INSTALL_DIR/logs/frps.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 辅助函数 ──

init_system() {
    if [ -d /run/systemd/system ] 2>/dev/null; then echo "systemd"
    elif [ -f /sbin/openrc ] 2>/dev/null; then echo "openrc"
    else
        case "$(cat /proc/1/comm 2>/dev/null)" in
            systemd) echo "systemd" ;;
            openrc-init) echo "openrc" ;;
            *) echo "unknown" ;;
        esac
    fi
}

svc() {
    local act=$1
    local init=$(init_system)
    case $init in
        systemd)
            case $act in
                start)   systemctl start $SERVICE_NAME ;;
                stop)    systemctl stop $SERVICE_NAME ;;
                restart) systemctl restart $SERVICE_NAME ;;
                enable)  systemctl enable $SERVICE_NAME ;;
                disable) systemctl disable $SERVICE_NAME ;;
                status)
                    systemctl is-active --quiet $SERVICE_NAME 2>/dev/null && echo "active" || echo "inactive"
                    ;;
                enabled)
                    systemctl is-enabled --quiet $SERVICE_NAME 2>/dev/null && echo "enabled" || echo "disabled"
                    ;;
                pid)     systemctl show $SERVICE_NAME --property=MainPID --value 2>/dev/null ;;
                log)     shift; journalctl -u $SERVICE_NAME "$@" ;;
            esac
            ;;
        openrc)
            case $act in
                start)   rc-service $SERVICE_NAME start ;;
                stop)    rc-service $SERVICE_NAME stop ;;
                restart) rc-service $SERVICE_NAME restart ;;
                enable)  rc-update add $SERVICE_NAME default ;;
                disable) rc-update del $SERVICE_NAME default ;;
                status)
                    rc-service $SERVICE_NAME status &>/dev/null && echo "active" || echo "inactive"
                    ;;
                enabled)
                    rc-update show 2>/dev/null | grep -q $SERVICE_NAME && echo "enabled" || echo "disabled"
                    ;;
                pid)     pgrep -x "frps" 2>/dev/null ;;
                log)     [ -f "$LOG_FILE" ] && tail -f "$LOG_FILE" ;;
            esac
            ;;
        *)
            echo "不支持的初始化系统"; return 1 ;;
    esac
}

die()  { echo -e "${RED}[错误]${NC} $1"; exit 1; }
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

# ── 帮助 ──

show_help() {
    echo ""
    echo -e "  ${BOLD}frps${NC} - FRP 服务端管理工具"
    echo ""
    echo -e "  ${BOLD}用法:${NC}"
    echo "    frps <命令> [选项]"
    echo ""
    echo -e "  ${BOLD}服务控制:${NC}"
    echo "    frps start        启动服务"
    echo "    frps stop         停止服务"
    echo "    frps restart      重启服务"
    echo ""
    echo -e "  ${BOLD}开机自启:${NC}"
    echo "    frps enable       设置开机自启"
    echo "    frps disable      取消开机自启"
    echo ""
    echo -e "  ${BOLD}状态查看:${NC}"
    echo "    frps status       查看运行状态"
    echo "    frps info         查看安装信息"
    echo "    frps ports        查看端口监听"
    echo ""
    echo -e "  ${BOLD}日志管理:${NC}"
    echo "    frps log          实时日志 (Ctrl+C 退出)"
    echo "    frps log recent   最近50行日志"
    echo "    frps log clear    清空日志"
    echo ""
    echo -e "  ${BOLD}配置管理:${NC}"
    echo "    frps conf         编辑配置文件"
    echo "    frps conf show    查看配置文件"
    echo ""
    echo -e "  ${BOLD}维护:${NC}"
    echo "    frps update       更新 frps 到最新版"
    echo "    frps uninstall    卸载 frps"
    echo "    frps reinstall    重新安装"
    echo "    frps version      查看当前版本"
    echo "    frps help         显示此帮助"
    echo ""
}

# ── 子命令实现 ──

cmd_start() {
    [ ! -x "$FRPS_BIN" ] && die "frps 未安装，请先运行安装脚本"
    info "启动 frps..."
    svc start
    sleep 1
    if [ "$(svc status)" = "active" ]; then
        ok "frps 已启动 (后台运行)"
        echo -e "  PID: $(svc pid)"
    else
        fail "启动失败，查看日志: frps log recent"
    fi
}

cmd_stop() {
    info "停止 frps..."
    svc stop
    ok "frps 已停止"
}

cmd_restart() {
    [ ! -x "$FRPS_BIN" ] && die "frps 未安装"
    info "重启 frps..."
    svc restart
    sleep 1
    if [ "$(svc status)" = "active" ]; then
        ok "frps 已重启 (后台运行)"
    else
        fail "重启失败，查看日志: frps log recent"
    fi
}

cmd_enable() {
    info "设置开机自启..."
    svc enable
    ok "已设置开机自启"
}

cmd_disable() {
    info "取消开机自启..."
    svc disable
    ok "已取消开机自启"
}

cmd_status() {
    echo ""
    if [ ! -x "$FRPS_BIN" ]; then
        fail "frps 未安装"
        echo ""
        return
    fi

    local st=$(svc status)
    local en=$(svc enabled)
    local pid=$(svc pid)

    if [ "$st" = "active" ]; then
        echo -e "  状态:  ${GREEN}● 运行中${NC}"
    else
        echo -e "  状态:  ${RED}● 已停止${NC}"
    fi

    if [ "$en" = "enabled" ]; then
        echo -e "  自启:  ${GREEN}● 已启用${NC}"
    else
        echo -e "  自启:  ${YELLOW}● 未启用${NC}"
    fi

    echo -e "  版本:  $("$FRPS_BIN" --version 2>&1 | head -1)"
    echo -e "  PID:   ${pid:-无}"

    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/status" ]; then
        local mem=$(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/$pid/status 2>/dev/null)
        [ -n "$mem" ] && echo -e "  内存:  ${mem} MB"
    fi

    echo ""
    echo -e "  ${BOLD}端口监听:${NC}"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep "frps" | sed 's/^/    /'
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep "frps" | sed 's/^/    /'
    fi

    if [ -f "$FRPS_CONF" ]; then
        local bp=$(grep "^bindPort" "$FRPS_CONF" 2>/dev/null | awk '{print $3}')
        local wp=$(grep "webServer.port" "$FRPS_CONF" 2>/dev/null | awk '{print $3}')
        echo ""
        echo -e "  ${BOLD}配置端口:${NC} 服务=${bp:-7000}  面板=${wp:-7500}"
    fi

    echo ""
}

cmd_info() {
    echo ""
    if [ ! -x "$FRPS_BIN" ]; then
        fail "frps 未安装"
        return
    fi

    echo -e "  ${BOLD}安装信息:${NC}"
    echo -e "  版本:       $("$FRPS_BIN" --version 2>&1 | head -1)"
    echo -e "  二进制:     $FRPS_BIN"
    echo -e "  配置文件:   $FRPS_CONF"
    echo -e "  日志文件:   $LOG_FILE"
    echo -e "  CLI命令:    $0"
    echo -e "  初始化系统: $(init_system)"
    echo ""
    echo -e "  ${BOLD}系统信息:${NC}"
    echo -e "  架构:       $(uname -m)"
    echo -e "  内核:       $(uname -r)"
    [ -f /etc/os-release ] && echo -e "  系统:       $(. /etc/os-release; echo "${PRETTY_NAME:-$ID}")"
    echo -e "  内存:       $(awk '/MemAvailable:/{printf "%.0fMB / %.0fMB", $2/1024, 0}' /proc/meminfo 2>/dev/null | sed "s|/ .*|/ $(awk '/MemTotal:/{printf "%.0fMB", $2/1024}' /proc/meminfo)|")"
    echo -e "  磁盘可用:   $(df -m / | awk 'NR==2{print $4}')MB"
    echo ""
}

cmd_ports() {
    echo ""
    echo -e "  ${BOLD}端口监听:${NC}"
    echo ""

    if [ -f "$FRPS_CONF" ]; then
        local bp=$(grep "^bindPort" "$FRPS_CONF" 2>/dev/null | awk '{print $3}')
        local wp=$(grep "webServer.port" "$FRPS_CONF" 2>/dev/null | awk '{print $3}')
        echo -e "  配置端口:"
        echo -e "    服务端:  ${bp:-7000}"
        echo -e "    管理面板: ${wp:-7500}"
        echo ""
    fi

    echo -e "  实际监听:"
    local found=0
    if command -v ss &>/dev/null; then
        local lines=$(ss -tlnp 2>/dev/null | grep -E "frps|:7000|:7500")
        if [ -n "$lines" ]; then echo "$lines" | sed 's/^/    /'; found=1; fi
    fi
    if [ "$found" -eq 0 ] && command -v netstat &>/dev/null; then
        local lines=$(netstat -tlnp 2>/dev/null | grep -E "frps|:7000|:7500")
        if [ -n "$lines" ]; then echo "$lines" | sed 's/^/    /'; found=1; fi
    fi
    [ "$found" -eq 0 ] && echo -e "    ${YELLOW}未检测到监听${NC}"

    local cc=0
    command -v ss &>/dev/null && cc=$(ss -tn 2>/dev/null | grep -c "frps" || echo 0)
    echo -e "  活跃连接: $cc"
    echo ""
}

cmd_log() {
    local sub="${1:-live}"

    case $sub in
        live|""|-f)
            if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
                tail -f "$LOG_FILE"
            elif [ "$(init_system)" = "systemd" ]; then
                journalctl -u $SERVICE_NAME -f --no-pager
            else
                fail "日志文件不存在: $LOG_FILE"
            fi
            ;;
        recent|tail)
            if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
                tail -n 50 "$LOG_FILE"
            elif [ "$(init_system)" = "systemd" ]; then
                journalctl -u $SERVICE_NAME -n 50 --no-pager 2>/dev/null
            else
                fail "无日志"
            fi
            ;;
        clear|clean)
            read -p "确认清空日志？(y/N): " c
            if [ "$c" = "y" ] || [ "$c" = "Y" ]; then
                [ -f "$LOG_FILE" ] && > "$LOG_FILE"
                ok "日志已清空"
            fi
            ;;
        *)
            echo "用法: frps log [live|recent|clear]"
            echo "  live    实时日志 (默认)"
            echo "  recent  最近50行"
            echo "  clear   清空日志"
            ;;
    esac
}

cmd_conf() {
    local sub="${1:-edit}"

    case $sub in
        edit|"")
            if [ ! -f "$FRPS_CONF" ]; then
                fail "配置文件不存在: $FRPS_CONF"
                return
            fi
            ${EDITOR:-nano} "$FRPS_CONF"
            echo ""
            read -p "重启服务使配置生效？(y/N): " c
            if [ "$c" = "y" ] || [ "$c" = "Y" ]; then
                cmd_restart
            fi
            ;;
        show|cat)
            if [ ! -f "$FRPS_CONF" ]; then
                fail "配置文件不存在"
                return
            fi
            cat "$FRPS_CONF"
            ;;
        *)
            echo "用法: frps conf [edit|show]"
            echo "  edit   编辑配置 (默认)"
            echo "  show   查看配置"
            ;;
    esac
}

cmd_version() {
    if [ -x "$FRPS_BIN" ]; then
        "$FRPS_BIN" --version 2>&1 | head -1
    else
        fail "frps 未安装"
    fi
}

cmd_update() {
    [ ! -x "$FRPS_BIN" ] && die "frps 未安装，请先运行安装脚本"
    [ ! -f "$INSTALL_DIR/install.sh" ] && die "安装脚本不存在，请重新下载"

    info "停止当前服务..."
    svc stop 2>/dev/null

    info "执行更新..."
    bash "$INSTALL_DIR/install.sh" --update
}

cmd_reinstall() {
    [ ! -f "$INSTALL_DIR/install.sh" ] && die "安装脚本不存在，请重新下载"

    info "停止当前服务..."
    svc stop 2>/dev/null
    svc disable 2>/dev/null

    info "重新安装..."
    bash "$INSTALL_DIR/install.sh" --reinstall
}

cmd_uninstall() {
    echo ""
    warn "即将卸载 frps，此操作将删除:"
    echo "  - $INSTALL_DIR"
    echo "  - /etc/systemd/system/${SERVICE_NAME}.service (或 /etc/init.d/${SERVICE_NAME})"
    echo "  - $0"
    echo ""
    read -p "输入 YES 确认卸载: " c
    if [ "$c" != "YES" ]; then
        info "已取消"
        return
    fi

    svc stop 2>/dev/null
    svc disable 2>/dev/null

    local init=$(init_system)
    if [ "$init" = "systemd" ]; then
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload 2>/dev/null
    elif [ "$init" = "openrc" ]; then
        rm -f "/etc/init.d/${SERVICE_NAME}"
    fi

    rm -rf "$INSTALL_DIR"
    rm -f "$0"

    echo ""
    ok "frps 已完全卸载"
}

# ── 入口 ──

[ ! -x "$FRPS_BIN" ] && [ "$1" != "help" ] && [ -z "$1" ] && {
    echo ""
    fail "frps 未安装"
    echo "  请先运行安装脚本进行安装"
    echo ""
    exit 1
}

case "${1:-help}" in
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    restart)     cmd_restart ;;
    enable)      cmd_enable ;;
    disable)     cmd_disable ;;
    status)      cmd_status ;;
    info)        cmd_info ;;
    ports)       cmd_ports ;;
    log)         cmd_log "${2:-live}" ;;
    conf)        cmd_conf "${2:-edit}" ;;
    version|ver) cmd_version ;;
    update)      cmd_update ;;
    reinstall)   cmd_reinstall ;;
    uninstall)   cmd_uninstall ;;
    help|-h|--help) show_help ;;
    *)
        echo ""
        fail "未知命令: $1"
        echo "  运行 frps help 查看所有命令"
        echo ""
        ;;
esac
CLI_SCRIPT

    chmod +x "$CLI_BIN"
    ok "CLI 命令已注册: $CLI_BIN"
}

# ======================== 安装流程 ========================

do_install() {
    echo ""
    echo -e "${BOLD}  FRP 服务端 一键安装${NC}"
    echo ""

    # 1. 环境检测
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

    # 完成
    line
    echo -e "${GREEN}  安装完成！${NC}"
    line
    echo ""
    echo -e "  ${BOLD}安装目录${NC}:   $INSTALL_DIR"
    echo -e "  ${BOLD}配置文件${NC}:   $FRPS_CONF"
    echo -e "  ${BOLD}管理命令${NC}:   frps help"
    echo ""
    echo -e "  ${BOLD}快速开始:${NC}"
    echo -e "    1) ${BOLD}frps conf${NC}         # 编辑配置，修改密码"
    echo -e "    2) ${BOLD}frps start${NC}         # 启动服务"
    echo -e "    3) ${BOLD}frps enable${NC}        # 设置开机自启"
    echo -e "    4) ${BOLD}frps status${NC}        # 查看状态"
    echo -e "    5) ${BOLD}frps log${NC}           # 查看实时日志"
    echo -e "    6) 访问 http://服务器IP:7500  # 管理面板"
    echo ""
}

# ======================== 入口 ========================

case "${1:-}" in
    --update)
        # 被 CLI 的 update 命令调用
        download_and_install
        setup_service
        register_cli
        echo ""
        ok "更新完成，运行 frps start 启动服务"
        ;;
    --reinstall)
        # 被 CLI 的 reinstall 命令调用
        download_and_install
        setup_service
        register_cli
        echo ""
        ok "重装完成，运行 frps start 启动服务"
        ;;
    *)
        # 正常安装
        do_install
        ;;
esac