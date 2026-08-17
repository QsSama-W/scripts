#!/bin/sh

# ============================================================================
#  FRP 客户端一键安装脚本（支持 systemd + 无 systemd 环境）
#  支持: Debian / Ubuntu | 多服务器连接 | Firecracker 等无 systemd 环境
#  日期: 2026-08-06
# ============================================================================

INSTALL_DIR="/opt/frpc"
FRPC_BIN="$INSTALL_DIR/frpc"
CONFIGS_DIR="$INSTALL_DIR/configs"
LOG_DIR="$INSTALL_DIR/logs"
PIDS_DIR="$INSTALL_DIR/pids"
ENABLED_DIR="$INSTALL_DIR/enabled"
STARTUP_SCRIPT="$INSTALL_DIR/startup.sh"
SERVICE_PREFIX="frpc"
CLI_BIN="/usr/local/bin/frpc"

MIN_DISK_MB=50
MIN_RAM_MB=25

# 后端类型: systemd 或 pidfile
BACKEND="unknown"

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

# ======================== 发行版检测 ========================

detect_distro() {
    [ -f /etc/os-release ] || { echo "unknown"; return; }
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) echo "debian" ;;
        *) case "${ID_LIKE:-}" in *debian*|*ubuntu*) echo "debian" ;; *) echo "unknown" ;; esac ;;
    esac
}

ensure_distro() {
    local d; d=$(detect_distro)
    if [ "$d" != "debian" ]; then
        printf "\033[0;31m[错误] 本脚本仅支持 Debian / Ubuntu 系统\033[0m\n" >&2
        [ -f /etc/os-release ] && . /etc/os-release && printf "\033[0;31m       当前: %s (%s)\033[0m\n" "${PRETTY_NAME:-unknown}" "${ID:-unknown}" >&2
        exit 1
    fi
    ok "系统兼容: $(. /etc/os-release && echo "${PRETTY_NAME:-$ID}")"
}

# ======================== 系统检测 ========================

detect_init() {
    if [ -d /run/systemd/system ] 2>/dev/null; then echo "systemd"
    elif [ -f /proc/1/comm ]; then case "$(cat /proc/1/comm 2>/dev/null)" in systemd) echo "systemd" ;; *) echo "unknown" ;; esac
    else echo "unknown"
    fi
}

get_arch() {
    case "$(uname -m)" in x86_64) echo "amd64" ;; aarch64) echo "arm64" ;; armv7l) echo "arm" ;; *) echo "unsupported" ;; esac
}

free_ram() {
    if [ -f /proc/meminfo ]; then
        local a; a=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
        [ -n "$a" ] && [ "$a" != "0" ] && { echo $((a / 1024)); return; }
        awk '/MemFree:/{f=$2} /Buffers:/{b=$2} /Cached:/{c=$2} END{print int((f+b+c)/1024)}' /proc/meminfo
    else echo 0; fi
}

total_ram() { awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0; }
disk_free() { df -m / | awk 'NR==2{print $4}'; }

# ======================== 后端检测 ========================

init_backend() {
    if [ "$(detect_init)" = "systemd" ]; then
        BACKEND="systemd"
    else
        BACKEND="pidfile"
    fi
}

# ======================== 进程管理（抽象层） ========================

_pid_file() { echo "$PIDS_DIR/${1}.pid"; }

# 判断进程是否存活
pid_is_running() {
    local name=$1 pf
    pf=$(_pid_file "$name")
    if [ -f "$pf" ]; then
        local pid
        pid=$(cat "$pf" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$pf"
    fi
    return 1
}

# 通过 PID 文件启动
pid_start() {
    local name=$1 conf="$2"
    mkdir -p "$PIDS_DIR"
    nohup "$FRPC_BIN" -c "$conf" >> "$LOG_DIR/${name}.log" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null
    echo "$pid" > "$(_pid_file "$name")"
    ok "frpc_${name} 已启动 (PID: $pid)"
}

# 通过 PID 文件停止
pid_stop() {
    local name=$1 pf
    pf=$(_pid_file "$name")
    if [ -f "$pf" ]; then
        local pid
        pid=$(cat "$pf" 2>/dev/null)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null
            # 等待 3 秒，若未退出则强制
            local i=0
            while [ $i -lt 3 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 1
                i=$((i + 1))
            done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$pf"
    fi
    ok "frpc_${name} 已停止"
}

# ---- 统一接口 ----

_is_active() {
    local name=$1
    if [ "$BACKEND" = "systemd" ]; then
        systemctl is-active --quiet "${SERVICE_PREFIX}_${name}" 2>/dev/null
    else
        pid_is_running "$name"
    fi
}

_is_enabled() {
    local name=$1
    if [ "$BACKEND" = "systemd" ]; then
        systemctl is-enabled --quiet "${SERVICE_PREFIX}_${name}" 2>/dev/null
    else
        [ -f "$ENABLED_DIR/${name}.enabled" ]
    fi
}

_get_pid() {
    local name=$1
    if [ "$BACKEND" = "systemd" ]; then
        systemctl show "${SERVICE_PREFIX}_${name}" --property=MainPID --value 2>/dev/null
    else
        local pf; pf=$(_pid_file "$name")
        if [ -f "$pf" ]; then cat "$pf" 2>/dev/null; fi
    fi
}

_get_mem() {
    local pid=$1
    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/status" ]; then
        awk '/VmRSS/{printf "%.1f", $2/1024}' "/proc/$pid/status" 2>/dev/null
    fi
}

_do_start() {
    local name=$1 conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then
        printf "\033[0;31m[错误]\033[0m 连接 '%s' 不存在\n" "$name"; return 1
    fi
    if [ "$BACKEND" = "systemd" ]; then
        systemctl start "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
        sleep 1
        if _is_active "$name"; then
            local pid; pid=$(_get_pid "$name")
            ok "frpc_${name} 已启动 (PID: $pid)"
        else
            printf "\033[0;31m[失败]\033[0m frpc_%s 启动失败\n" "$name"
        fi
    else
        if pid_is_running "$name"; then
            warn "frpc_${name} 已在运行 (PID: $(_get_pid "$name"))"
            return 0
        fi
        pid_start "$name" "$conf"
    fi
}

_do_stop() {
    local name=$1 conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then
        printf "\033[0;31m[错误]\033[0m 连接 '%s' 不存在\n" "$name"; return 1
    fi
    if [ "$BACKEND" = "systemd" ]; then
        systemctl stop "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
        ok "frpc_${name} 已停止"
    else
        if ! pid_is_running "$name"; then
            warn "frpc_${name} 未运行"
            rm -f "$(_pid_file "$name")"
            return 0
        fi
        pid_stop "$name"
    fi
}

_do_restart() {
    local name=$1
    printf "\033[0;34m[  i   ]\033[0m 重启 frpc_%s ...\n" "$name"
    _do_stop "$name" 2>/dev/null
    sleep 1
    _do_start "$name"
}

_do_enable() {
    local name=$1 conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then
        printf "\033[0;31m[错误]\033[0m 连接 '%s' 不存在\n" "$name"; return 1
    fi
    if [ "$BACKEND" = "systemd" ]; then
        systemctl enable "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
    else
        mkdir -p "$ENABLED_DIR"
        touch "$ENABLED_DIR/${name}.enabled"
        _rebuild_startup_script
    fi
    ok "frpc_${name} 已设置开机自启"
}

_do_disable() {
    local name=$1
    if [ "$BACKEND" = "systemd" ]; then
        systemctl disable "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
    else
        rm -f "$ENABLED_DIR/${name}.enabled"
        _rebuild_startup_script
    fi
    ok "frpc_${name} 已取消开机自启"
}

# ======================== startup.sh（非 systemd 自启） ========================

_rebuild_startup_script() {
    mkdir -p "$ENABLED_DIR"
    cat > "$STARTUP_SCRIPT" <<'STARTEOF'
#!/bin/sh
# FRP Client 自动启动脚本 - 由安装脚本自动生成
INSTALL_DIR="/opt/frpc"
FRPC_BIN="$INSTALL_DIR/frpc"
CONFIGS_DIR="$INSTALL_DIR/configs"
LOG_DIR="$INSTALL_DIR/logs"
PIDS_DIR="$INSTALL_DIR/pids"
ENABLED_DIR="$INSTALL_DIR/enabled"

mkdir -p "$PIDS_DIR"

for f in "$ENABLED_DIR"/*.enabled; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .enabled)
    conf="$CONFIGS_DIR/${name}.toml"
    [ -f "$conf" ] || continue
    pid_file="$PIDS_DIR/${name}.pid"
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file" 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && continue
    fi
    nohup "$FRPC_BIN" -c "$conf" >> "$LOG_DIR/${name}.log" 2>&1 &
    disown
    echo $! > "$pid_file"
done
STARTEOF
    chmod +x "$STARTUP_SCRIPT"

    # 写入 crontab
    _setup_crontab
}

_setup_crontab() {
    local marker="# frpc-autostart"
    local entry="$marker"
    if command -v crontab >/dev/null 2>&1; then
        # 移除旧条目
        crontab -l 2>/dev/null | grep -v "$marker" > /tmp/_frpc_cron_tmp
        # 添加新条目
        echo "@reboot $STARTUP_SCRIPT $entry" >> /tmp/_frpc_cron_tmp
        crontab /tmp/_frpc_cron_tmp
        rm -f /tmp/_frpc_cron_tmp
    fi
}

_remove_crontab() {
    local marker="# frpc-autostart"
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "$marker" > /tmp/_frpc_cron_tmp
        crontab /tmp/_frpc_cron_tmp
        rm -f /tmp/_frpc_cron_tmp
    fi
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

    local cmds="curl tar grep" need="" ss_pkg="iproute2"

    if command -v nano >/dev/null 2>&1; then ok "nano (编辑器)"
    else fail "nano (编辑器)"; need="$need nano"; fi

    for cmd in $cmds; do
        if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd"
        else fail "$cmd"; need="$need $cmd"; fi
    done

    if command -v ss >/dev/null 2>&1; then ok "ss"
    else fail "ss"; need="$need $ss_pkg"; fi

    echo ""

    if [ -n "$need" ]; then
        local unique=""
        for p in $need; do case " $unique " in *" $p "*) ;; *) unique="$unique $p" ;; esac; done
        install_pkgs $unique || die "依赖安装失败"
        echo ""
        for cmd in $cmds; do command -v "$cmd" >/dev/null 2>&1 || die "$cmd 安装后仍不可用"; done
        command -v ss >/dev/null 2>&1 || die "ss 安装后仍不可用"
        command -v nano >/dev/null 2>&1 || die "nano 安装后仍不可用"
        ok "所有依赖已就绪"
    else
        ok "所有依赖已就绪"
    fi

    case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac
    echo ""
}

# ======================== 环境检测 ========================

full_check() {
    line
    printf "  \033[1mFRP 客户端 安装环境检测\033[0m\n"
    line
    echo ""
    local err=0

    ensure_distro

    if [ "$(id -u)" -ne 0 ]; then fail "需要 root 权限"; err=$((err + 1)); else ok "root 权限"; fi

    local arch; arch=$(get_arch)
    if [ "$arch" = "unsupported" ]; then fail "不支持的架构: $(uname -m)"; err=$((err + 1)); else ok "CPU 架构: $(uname -m) -> $arch"; fi

    local fr tr; fr=$(free_ram); tr=$(total_ram)
    if [ "$tr" -eq 0 ]; then fail "无法读取内存"; err=$((err + 1))
    elif [ "$fr" -lt "$MIN_RAM_MB" ]; then fail "内存不足: ${fr}MB / 最低 ${MIN_RAM_MB}MB"; err=$((err + 1))
    else ok "内存: 总 ${tr}MB / 可用 ${fr}MB"; fi

    local dfree; dfree=$(disk_free)
    if [ "$dfree" -lt "$MIN_DISK_MB" ]; then fail "磁盘不足: ${dfree}MB / 最低 ${MIN_DISK_MB}MB"; err=$((err + 1))
    else ok "磁盘: 可用 ${dfree}MB"; fi

    if command -v curl >/dev/null 2>&1; then
        curl -s --connect-timeout 5 --max-time 10 -o /dev/null https://github.com 2>/dev/null && ok "GitHub 连通" || warn "GitHub 连通失败，可能需要代理"
    else warn "无 curl，跳过网络检测"; fi

    init_backend

    if [ "$BACKEND" = "systemd" ]; then
        ok "初始化系统: systemd"
    else
        ok "初始化系统: 无 systemd (使用 PID 文件管理模式)"
        # 检查 crontab 是否可用（自启依赖）
        if command -v crontab >/dev/null 2>&1; then
            ok "crontab 可用 (支持开机自启)"
        else
            warn "crontab 不可用，开机自启将不可用 (可安装: apt install cron)"
        fi
    fi

    echo ""
    line
    if [ $err -gt 0 ]; then printf "  \033[0;31m检测未通过，%d 个问题\033[0m\n" "$err"; line; return 1
    else printf "  \033[0;32m全部通过\033[0m\n"; line; return 0; fi
}

# ======================== 下载安装 ========================

get_version() {
    local v=""
    if command -v curl >/dev/null 2>&1; then
        v=$(curl -s --connect-timeout 10 --max-time 15 \
            https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
            | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    fi
    echo "$v"
}

download_and_install() {
    line
    printf "  \033[1m下载安装 FRP Client\033[0m\n"
    line
    echo ""

    local version; version=$(get_version)
    [ -z "$version" ] && die "获取版本失败，请检查网络"

    local arch; arch=$(get_arch)
    [ "$arch" = "unsupported" ] && die "不支持的架构"

    local file="frp_${version}_linux_${arch}.tar.gz"
    local url="https://github.com/fatedier/frp/releases/download/v${version}/${file}"
    info "版本: v${version} | 架构: $arch"
    info "地址: $url"
    echo ""

    local tmp; tmp=$(mktemp -d)

    info "正在下载..."
    local dl_ok=0
    curl -# --connect-timeout 30 --retry 3 -L -o "$tmp/$file" "$url" 2>&1 && dl_ok=1

    if [ "$dl_ok" -eq 0 ] || [ ! -f "$tmp/$file" ]; then rm -rf "$tmp"; die "下载失败"; fi

    local fsize=0
    command -v stat >/dev/null 2>&1 && fsize=$(stat -c%s "$tmp/$file" 2>/dev/null || echo 0)
    [ "$fsize" -lt 1048576 ] && { rm -rf "$tmp"; die "文件异常 (${fsize}B)"; }
    ok "下载完成 ($(( fsize / 1048576 ))MB)"

    info "正在解压..."
    tar -xzf "$tmp/$file" -C "$tmp" 2>&1 || { rm -rf "$tmp"; die "解压失败"; }

    local dir; dir=$(ls -d "$tmp"/frp_${version}_linux_${arch} 2>/dev/null)
    [ -z "$dir" ] || [ ! -f "$dir/frpc" ] && { rm -rf "$tmp"; die "未找到 frpc 可执行文件"; }

    if [ -d "$INSTALL_DIR" ]; then
        local bak="/opt/frpc_backups/frpc_$(date +%Y%m%d_%H%M%S)"
        mkdir -p /opt/frpc_backups
        cp -r "$INSTALL_DIR" "$bak" 2>/dev/null
        info "旧版本已备份到: $bak"
    fi

    mkdir -p "$INSTALL_DIR" "$CONFIGS_DIR" "$LOG_DIR" "$PIDS_DIR" "$ENABLED_DIR"
    cp "$dir/frpc" "$FRPC_BIN"
    chmod +x "$FRPC_BIN"

    if [ -f "$0" ] && [ "$0" != "/dev/stdin" ]; then
        cp "$0" "$INSTALL_DIR/install.sh" 2>/dev/null
    fi

    rm -rf "$tmp"
    [ -x "$FRPC_BIN" ] || die "安装验证失败"
    ok "安装完成: $("$FRPC_BIN" --version 2>&1 | head -1)"
}

# ======================== 注册 CLI ========================

register_cli() {
    info "注册 frpc CLI 命令..."

    cat > "$CLI_BIN" <<'ENDCLI'
#!/bin/sh
# ============================================================================
#  frpc CLI 管理工具 - 支持多服务器连接
#  支持 systemd 和非 systemd（PID 文件管理）
#  由安装脚本自动生成
# ============================================================================

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=C.UTF-8

INSTALL_DIR="/opt/frpc"
FRPC_BIN="$INSTALL_DIR/frpc"
CONFIGS_DIR="$INSTALL_DIR/configs"
LOG_DIR="$INSTALL_DIR/logs"
PIDS_DIR="$INSTALL_DIR/pids"
ENABLED_DIR="$INSTALL_DIR/enabled"
STARTUP_SCRIPT="$INSTALL_DIR/startup.sh"
SERVICE_PREFIX="frpc"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ======================== 后端检测 ========================

detect_init() {
    if [ -d /run/systemd/system ] 2>/dev/null; then echo "systemd"
    elif [ -f /proc/1/comm ]; then case "$(cat /proc/1/comm 2>/dev/null)" in systemd) echo "systemd" ;; *) echo "unknown" ;; esac
    else echo "unknown"
    fi
}

_init_backend() {
    if [ "$(detect_init)" = "systemd" ]; then echo "systemd"
    else echo "pidfile"
    fi
}

BACKEND=$(_init_backend)

# ======================== 工具函数 ========================

line() { printf "\033[0;36m────────────────────────────────────────────────────\033[0m\n"; }

find_connections() {
    [ -d "$CONFIGS_DIR" ] || return
    for f in "$CONFIGS_DIR"/*.toml; do
        [ -f "$f" ] || continue
        basename "$f" .toml
    done
}

get_conf_val() {
    local file=$1 key=$2
    grep "^${key}" "$file" 2>/dev/null | head -1 | sed "s/^${key}[[:space:]]*=[[:space:]]*//;s/^\"//;s/\"$//"
}

get_server_info() {
    local conf=$1
    local addr port
    addr=$(get_conf_val "$conf" "serverAddr")
    port=$(get_conf_val "$conf" "serverPort")
    echo "${addr:-?}:${port:-7000}"
}

valid_name() {
    case "$1" in
        "") return 1 ;;
        *[!a-zA-Z0-9_]*) return 1 ;;
        *) return 0 ;;
    esac
}

count_connections() {
    local n=0
    for _ in $(find_connections); do n=$((n + 1)); done
    echo "$n"
}

single_connection() {
    local cnt; cnt=$(count_connections)
    [ "$cnt" -eq 1 ] && find_connections
}

is_subcmd() {
    case "$1" in
        recent|tail|clear|clean|live|""|-f) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_yes() {
    case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in
        YES) return 0 ;;
        *) return 1 ;;
    esac
}

_pid_file() { echo "$PIDS_DIR/${1}.pid"; }

pid_is_running() {
    local name=$1 pf
    pf=$(_pid_file "$name")
    if [ -f "$pf" ]; then
        local pid; pid=$(cat "$pf" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$pf"
    fi
    return 1
}

_is_active() {
    local name=$1
    if [ "$BACKEND" = "systemd" ]; then
        systemctl is-active --quiet "${SERVICE_PREFIX}_${name}" 2>/dev/null
    else
        pid_is_running "$name"
    fi
}

_is_enabled() {
    local name=$1
    if [ "$BACKEND" = "systemd" ]; then
        systemctl is-enabled --quiet "${SERVICE_PREFIX}_${name}" 2>/dev/null
    else
        [ -f "$ENABLED_DIR/${name}.enabled" ]
    fi
}

_get_pid() {
    local name=$1
    if [ "$BACKEND" = "systemd" ]; then
        systemctl show "${SERVICE_PREFIX}_${name}" --property=MainPID --value 2>/dev/null
    else
        local pf; pf=$(_pid_file "$name")
        [ -f "$pf" ] && cat "$pf" 2>/dev/null
    fi
}

# ======================== 帮助 ========================

cmd_help() {
    echo ""
    printf "  ${BOLD}frpc${NC} - FRP 客户端管理工具 (多服务器 | 后端: %s)\n" "$BACKEND"
    echo ""
    printf "  ${BOLD}用法:${NC}\n"
    echo "    frpc <命令> [选项]"
    echo ""
    printf "  ${BOLD}连接管理:${NC}\n"
    echo "    frpc add                  添加服务器连接"
    echo "    frpc remove <name>        删除连接"
    echo "    frpc list                 列出所有连接"
    echo ""
    printf "  ${BOLD}服务控制:${NC}\n"
    echo "    frpc start [name]         启动 (全部/指定)"
    echo "    frpc stop [name]          停止 (全部/指定)"
    echo "    frpc restart [name]       重启 (全部/指定)"
    echo ""
    printf "  ${BOLD}开机自启:${NC}\n"
    echo "    frpc enable [name]        设置开机自启"
    echo "    frpc disable [name]       取消开机自启"
    echo ""
    printf "  ${BOLD}状态查看:${NC}\n"
    echo "    frpc status [name]        查看运行状态"
    echo "    frpc version              查看版本"
    echo ""
    printf "  ${BOLD}日志管理:${NC}\n"
    echo "    frpc log <name>           实时日志"
    echo "    frpc log recent <name>    最近50行"
    echo "    frpc log clear <name>     清空日志"
    echo ""
    printf "  ${BOLD}配置管理:${NC}\n"
    echo "    frpc conf <name>          编辑配置"
    echo "    frpc conf show <name>     查看配置"
    echo ""
    printf "  ${BOLD}维护:${NC}\n"
    echo "    frpc reinstall            重新安装"
    echo "    frpc uninstall            卸载"
    echo "    frpc help                 显示此帮助"
    echo ""
}

# ======================== start ========================

cmd_start() {
    local name=$1
    if [ -n "$name" ]; then
        _start_one "$name"
    else
        local cnt; cnt=$(count_connections)
        if [ "$cnt" -eq 0 ]; then
            printf "${Y}[提示]${NC} 没有连接，请先运行 frpc add\n"
            return 1
        fi
        for n in $(find_connections); do _start_one "$n"; done
    fi
}

_start_one() {
    local name=$1 conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; fi

    if [ "$BACKEND" = "systemd" ]; then
        printf "${B}[信息]${NC} 启动 frpc_%s ...\n" "$name"
        systemctl start "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
        sleep 1
        if _is_active "$name"; then
            local pid; pid=$(_get_pid "$name")
            printf "${G}[成功]${NC} frpc_%s 已启动 (PID: %s)\n" "$name" "$pid"
        else
            printf "${R}[失败]${NC} frpc_%s 启动失败\n" "$name"
        fi
    else
        if pid_is_running "$name"; then
            printf "${Y}[提示]${NC} frpc_%s 已在运行 (PID: %s)\n" "$name" "$(_get_pid "$name")"
            return 0
        fi
        printf "${B}[信息]${NC} 启动 frpc_%s ...\n" "$name"
        mkdir -p "$PIDS_DIR"
        nohup "$FRPC_BIN" -c "$conf" >> "$LOG_DIR/${name}.log" 2>&1 &
        local pid=$!
        disown "$pid" 2>/dev/null
        echo "$pid" > "$(_pid_file "$name")"
        sleep 1
        if _is_active "$name"; then
            printf "${G}[成功]${NC} frpc_%s 已启动 (PID: %s)\n" "$name" "$pid"
        else
            printf "${R}[失败]${NC} frpc_%s 启动失败\n" "$name"
            rm -f "$(_pid_file "$name")"
        fi
    fi
}

# ======================== stop ========================

cmd_stop() {
    local name=$1
    if [ -n "$name" ]; then _stop_one "$name"
    else for n in $(find_connections); do _stop_one "$n"; done; fi
}

_stop_one() {
    local name=$1 conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; fi

    if [ "$BACKEND" = "systemd" ]; then
        systemctl stop "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
        printf "${G}[成功]${NC} frpc_%s 已停止\n" "$name"
    else
        if ! pid_is_running "$name"; then
            printf "${Y}[提示]${NC} frpc_%s 未运行\n" "$name"
            rm -f "$(_pid_file "$name")"
            return 0
        fi
        local pid; pid=$(_get_pid "$name")
        kill "$pid" 2>/dev/null
        local i=0
        while [ $i -lt 3 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        rm -f "$(_pid_file "$name")"
        printf "${G}[成功]${NC} frpc_%s 已停止\n" "$name"
    fi
}

# ======================== restart ========================

cmd_restart() {
    local name=$1
    if [ -n "$name" ]; then _restart_one "$name"
    else for n in $(find_connections); do _restart_one "$n"; done; fi
}

_restart_one() {
    local name=$1 conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; fi
    printf "${B}[信息]${NC} 重启 frpc_%s ...\n" "$name"
    _stop_one "$name" 2>/dev/null
    sleep 1
    _start_one "$name"
}

# ======================== enable / disable ========================

cmd_enable() {
    local name=$1
    if [ -n "$name" ]; then
        [ ! -f "$CONFIGS_DIR/${name}.toml" ] && { printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; }
        if [ "$BACKEND" = "systemd" ]; then
            systemctl enable "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
        else
            mkdir -p "$ENABLED_DIR"
            touch "$ENABLED_DIR/${name}.enabled"
            _rebuild_startup
        fi
        printf "${G}[成功]${NC} frpc_%s 已设置开机自启\n" "$name"
    else
        for n in $(find_connections); do
            if [ "$BACKEND" = "systemd" ]; then
                systemctl enable "${SERVICE_PREFIX}_${n}" >/dev/null 2>&1
            else
                mkdir -p "$ENABLED_DIR"
                touch "$ENABLED_DIR/${n}.enabled"
            fi
            printf "${G}[成功]${NC} frpc_%s 已设置开机自启\n" "$n"
        done
        [ "$BACKEND" != "systemd" ] && _rebuild_startup
    fi
}

cmd_disable() {
    local name=$1
    if [ -n "$name" ]; then
        [ ! -f "$CONFIGS_DIR/${name}.toml" ] && { printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; }
        if [ "$BACKEND" = "systemd" ]; then
            systemctl disable "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
        else
            rm -f "$ENABLED_DIR/${name}.enabled"
            _rebuild_startup
        fi
        printf "${G}[成功]${NC} frpc_%s 已取消开机自启\n" "$name"
    else
        for n in $(find_connections); do
            if [ "$BACKEND" = "systemd" ]; then
                systemctl disable "${SERVICE_PREFIX}_${n}" >/dev/null 2>&1
            else
                rm -f "$ENABLED_DIR/${n}.enabled"
            fi
            printf "${G}[成功]${NC} frpc_%s 已取消开机自启\n" "$n"
        done
        [ "$BACKEND" != "systemd" ] && _rebuild_startup
    fi
}

# 非 systemd：重建 startup.sh + crontab
_rebuild_startup() {
    mkdir -p "$ENABLED_DIR" "$PIDS_DIR"
    cat > "$STARTUP_SCRIPT" <<'STARTEOF'
#!/bin/sh
# FRP Client 自动启动脚本 - 自动生成
INSTALL_DIR="/opt/frpc"
FRPC_BIN="$INSTALL_DIR/frpc"
CONFIGS_DIR="$INSTALL_DIR/configs"
LOG_DIR="$INSTALL_DIR/logs"
PIDS_DIR="$INSTALL_DIR/pids"
ENABLED_DIR="$INSTALL_DIR/enabled"
mkdir -p "$PIDS_DIR"
for f in "$ENABLED_DIR"/*.enabled; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .enabled)
    conf="$CONFIGS_DIR/${name}.toml"
    [ -f "$conf" ] || continue
    pf="$PIDS_DIR/${name}.pid"
    if [ -f "$pf" ]; then
        pid=$(cat "$pf" 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && continue
    fi
    nohup "$FRPC_BIN" -c "$conf" >> "$LOG_DIR/${name}.log" 2>&1 &
    disown
    echo $! > "$pf"
done
STARTEOF
    chmod +x "$STARTUP_SCRIPT"
    # 更新 crontab
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "frpc-autostart" > /tmp/_frpc_cron
        echo "@reboot $STARTUP_SCRIPT # frpc-autostart" >> /tmp/_frpc_cron
        crontab /tmp/_frpc_cron
        rm -f /tmp/_frpc_cron
    fi
}

# ======================== list ========================

cmd_list() {
    echo ""
    local configs; configs=$(find_connections)
    if [ -z "$configs" ]; then
        echo "  没有连接，请运行 frpc add 添加服务器"
        echo ""
        return
    fi

    printf "  ${BOLD}%-16s %-12s %-12s %s${NC}\n" "名称" "状态" "自启" "服务器"
    line

    local cnt=0
    for name in $configs; do
        local conf="$CONFIGS_DIR/${name}.toml"
        local server; server=$(get_server_info "$conf")

        local st_d en_d
        if _is_active "$name"; then
            st_d="${G}● 运行中${NC}"
        else
            st_d="${R}● 已停止${NC}"
        fi
        if _is_enabled "$name"; then
            en_d="${G}● 已启用${NC}"
        else
            en_d="${R}○ 未启用${NC}"
        fi

        printf "  %-16s %-22b %-22b %s\n" "$name" "$st_d" "$en_d" "$server"
        cnt=$((cnt + 1))
    done

    echo ""
    printf "  共 %d 个连接\n" "$cnt"
    printf "  运行后端: %s\n" "$BACKEND"
    echo ""
}

# ======================== status ========================

cmd_status() {
    local name=$1
    if [ -n "$name" ]; then
        _status_one "$name"
    else
        local cnt; cnt=$(count_connections)
        if [ "$cnt" -eq 0 ]; then echo "  没有连接"; echo ""; return; fi
        cmd_list
    fi
}

_status_one() {
    local name=$1 conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; fi

    local server; server=$(get_server_info "$conf")
    local pid; pid=$(_get_pid "$name")

    echo ""
    if _is_active "$name"; then
        echo -e "  状态:   ${G}● 运行中${NC}"
    else
        echo -e "  状态:   ${R}● 已停止${NC}"
    fi

    if _is_enabled "$name"; then
        echo -e "  自启:   ${G}● 已启用${NC}"
    else
        echo -e "  自启:   ${Y}○ 未启用${NC}"
    fi

    echo "  服务器: $server"
    echo "  后端:   $BACKEND"
    echo "  版本:   $("$FRPC_BIN" --version 2>&1 | head -1)"
    echo "  PID:    ${pid:-无}"

    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/status" ]; then
        local mem; mem=$(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/$pid/status 2>/dev/null)
        [ -n "$mem" ] && echo "  内存:   ${mem} MB"
    fi
    echo ""
}

# ======================== add ========================

cmd_add() {
    echo ""
    line
    printf "  \033[1m添加 FRP 服务器连接\033[0m\n"
    line
    echo ""

    local name=""
    while true; do
        printf "  连接名称 (英文/数字/下划线): "
        read -r name
        name=$(echo "$name" | tr -d ' ')
        if [ -z "$name" ]; then printf "${R}    名称不能为空${NC}\n"; continue; fi
        if ! valid_name "$name"; then printf "${R}    名称只能包含英文、数字、下划线${NC}\n"; continue; fi
        if [ -f "$CONFIGS_DIR/${name}.toml" ]; then printf "${R}    连接 '%s' 已存在${NC}\n" "$name"; continue; fi
        break
    done

    local addr=""
    while true; do
        printf "  服务器地址 (IP或域名): "
        read -r addr
        [ -n "$addr" ] && break
        printf "${R}    地址不能为空${NC}\n"
    done

    local port="7000"
    printf "  服务器端口 [7000]: "
    read -r input
    [ -n "$input" ] && port="$input"

    local token=""
    while true; do
        printf "  认证Token: "
        read -r token
        [ -n "$token" ] && break
        printf "${R}    Token不能为空${NC}\n"
    done

    echo ""
    info "正在生成配置文件..."

    local conf="$CONFIGS_DIR/${name}.toml"
    cat > "$conf" <<ENDCONF
# FRP Client Config - ${name}
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

serverAddr = "${addr}"
serverPort = ${port}

auth.method = "token"
auth.token = "${token}"

log.to = "${LOG_DIR}/${name}.log"
log.level = "info"
log.maxDays = 7

transport.poolCount = 5
transport.tcpMux = true

# ==================== 代理配置 ====================
# 更多类型参见: https://gofrp.org/zh-cn/docs/

# --- SSH ---
#[[proxies]]
#name = "ssh"
#type = "tcp"
#localIP = "127.0.0.1"
#localPort = 22
#remotePort = 6000

# --- Web ---
#[[proxies]]
#name = "web"
#type = "http"
#localIP = "127.0.0.1"
#localPort = 80
#customDomains = ["your.domain.com"]
ENDCONF

    ok "配置文件: $conf"

    echo ""
    info "即将打开编辑器，请配置 proxies 代理规则"

    local editor=""
    if command -v nano >/dev/null 2>&1; then
        editor="nano"
    elif command -v vim >/dev/null 2>&1; then
        editor="vim"
    elif command -v vi >/dev/null 2>&1; then
        editor="vi"
    fi

    if [ -n "$editor" ]; then
        printf "${B}[信息]${NC} 使用 ${BOLD}%s${NC} 编辑配置\n" "$editor"
        echo "  文件: $conf"
        echo ""
        stty sane 2>/dev/null
        TERM="${TERM:-xterm}"
        export TERM
        case "$editor" in
            nano) LANG=C.UTF-8 LC_ALL=C.UTF-8 nano "$conf" ;;
            vim)  LANG=C.UTF-8 LC_ALL=C.UTF-8 vim "$conf" ;;
            vi)   LANG=C.UTF-8 LC_ALL=C.UTF-8 vi "$conf" ;;
        esac
        stty sane 2>/dev/null
    else
        warn "无编辑器，请手动修改: $conf"
    fi

    # 根据后端创建服务
    if [ "$BACKEND" = "systemd" ]; then
        info "创建 systemd 服务文件..."
        local svc_name="${SERVICE_PREFIX}_${name}"
        cat > "/etc/systemd/system/${svc_name}.service" <<ENDSVC
[Unit]
Description=FRP Client (${name})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${FRPC_BIN} -c ${conf}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
ENDSVC
        systemctl daemon-reload 2>/dev/null
        ok "服务 frpc_${name} 已创建"
    else
        ok "后端: PID 文件管理 (无需 systemd 服务文件)"
    fi

    echo ""
    printf "  输入 y 立即启动，其他键跳过: "
    read -r c
    case "$c" in
        y|Y)
            if [ "$BACKEND" = "systemd" ]; then
                systemctl start "$svc_name" >/dev/null 2>&1
                sleep 1
                if _is_active "$name"; then
                    local pid; pid=$(_get_pid "$name")
                    printf "${G}[成功]${NC} frpc_%s 已启动 (PID: %s)\n" "$name" "$pid"
                else
                    printf "${R}[失败]${NC} 启动失败，查看日志: frpc log recent %s\n" "$name"
                fi
            else
                mkdir -p "$PIDS_DIR"
                nohup "$FRPC_BIN" -c "$conf" >> "$LOG_DIR/${name}.log" 2>&1 &
                local pid=$!
                disown "$pid" 2>/dev/null
                echo "$pid" > "$(_pid_file "$name")"
                sleep 1
                if _is_active "$name"; then
                    printf "${G}[成功]${NC} frpc_%s 已启动 (PID: %s)\n" "$name" "$pid"
                else
                    printf "${R}[失败]${NC} 启动失败，查看日志: frpc log recent %s\n" "$name"
                fi
            fi
            ;;
    esac
    echo ""
}

# ======================== remove ========================

cmd_remove() {
    local name=$1
    if [ -z "$name" ]; then
        printf "${R}[错误]${NC} 用法: frpc remove <连接名>\n"
        printf "  运行 frpc list 查看所有连接\n"
        return 1
    fi

    local conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then
        printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"
        return 1
    fi

    echo ""
    printf "${Y}[警告]${NC} 即将删除连接 '%s'，将移除:\n" "$name"
    echo "  - 配置: $conf"
    echo "  - 日志: ${LOG_DIR}/${name}.log"
    echo "  - PID:  $(_pid_file "$name")"
    if [ "$BACKEND" = "systemd" ]; then
        echo "  - 服务: /etc/systemd/system/frpc_${name}.service"
    else
        echo "  - 自启: ${ENABLED_DIR}/${name}.enabled"
    fi
    echo ""
    printf "  输入 YES 确认: "
    read -r c
    if ! confirm_yes "$c"; then echo "  已取消"; return; fi

    # 停止
    if [ "$BACKEND" = "systemd" ]; then
        systemctl stop "${SERVICE_PREFIX}_${name}" 2>/dev/null
        systemctl disable "${SERVICE_PREFIX}_${name}" 2>/dev/null
        rm -f "/etc/systemd/system/${SERVICE_PREFIX}_${name}.service"
        systemctl daemon-reload 2>/dev/null
    else
        if pid_is_running "$name"; then
            local pid; pid=$(_get_pid "$name")
            kill "$pid" 2>/dev/null
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$(_pid_file "$name")"
        rm -f "$ENABLED_DIR/${name}.enabled"
    fi
    rm -f "$conf"
    rm -f "${LOG_DIR}/${name}.log"

    if [ "$BACKEND" != "systemd" ]; then
        # 如果没有更多启用的连接，清理 crontab
        local has_enabled=0
        for f in "$ENABLED_DIR"/*.enabled; do [ -f "$f" ] && has_enabled=1 && break; done
        if [ "$has_enabled" -eq 0 ] && command -v crontab >/dev/null 2>&1; then
            crontab -l 2>/dev/null | grep -v "frpc-autostart" > /tmp/_frpc_cron
            crontab /tmp/_frpc_cron 2>/dev/null
            rm -f /tmp/_frpc_cron
            rm -f "$STARTUP_SCRIPT"
        fi
    fi

    printf "${G}[成功]${NC} 连接 '%s' 已删除\n" "$name"
}

# ======================== conf ========================

cmd_conf() {
    local arg1=$1 arg2=$2
    local subcmd="edit" name=""

    case "$arg1" in
        show|cat) subcmd="show"; name="$arg2" ;;
        *) subcmd="edit"; name="$arg1" ;;
    esac

    case "$subcmd" in
        edit)
            [ -z "$name" ] && name=$(single_connection)
            if [ -z "$name" ]; then
                printf "${R}[错误]${NC} 请指定连接名: frpc conf <名称>\n"
                printf "  运行 frpc list 查看所有连接\n"
                return 1
            fi
            local conf="$CONFIGS_DIR/${name}.toml"
            if [ ! -f "$conf" ]; then printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; fi

            printf "${B}[信息]${NC} 编辑 frpc_%s 配置\n" "$name"
            echo "  文件: $conf"
            echo ""
            stty sane 2>/dev/null
            TERM="${TERM:-xterm}"
            export TERM
            if command -v nano >/dev/null 2>&1; then
                LANG=C.UTF-8 LC_ALL=C.UTF-8 nano "$conf"
            elif command -v vim >/dev/null 2>&1; then
                LANG=C.UTF-8 LC_ALL=C.UTF-8 vim "$conf"
            elif command -v vi >/dev/null 2>&1; then
                LANG=C.UTF-8 LC_ALL=C.UTF-8 vi "$conf"
            else
                printf "${R}[错误]${NC} 没有可用的文本编辑器\n"
                echo "  请安装: apt install nano"
                return 1
            fi
            stty sane 2>/dev/null
            echo ""
            printf "${B}[信息]${NC} 输入 y 重启连接使配置生效，其他键跳过: "
            read -r c
            case "$c" in y|Y) _restart_one "$name" ;; esac
            ;;
        show)
            [ -z "$name" ] && name=$(single_connection)
            if [ -z "$name" ]; then
                printf "${R}[错误]${NC} 请指定连接名: frpc conf show <名称>\n"
                return 1
            fi
            local conf="$CONFIGS_DIR/${name}.toml"
            if [ ! -f "$conf" ]; then printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; fi
            cat "$conf"
            ;;
    esac
}

# ======================== log ========================

cmd_log() {
    local arg1=$1 arg2=$2
    local subcmd="live" name=""

    if [ -z "$arg1" ]; then
        subcmd="live"
        name=""
    elif is_subcmd "$arg1"; then
        subcmd="$arg1"
        name="$arg2"
    else
        subcmd="live"
        name="$arg1"
    fi

    case "$subcmd" in
        recent|tail)
            [ -z "$name" ] && name=$(single_connection)
            if [ -z "$name" ]; then printf "${R}[错误]${NC} 请指定连接名: frpc log recent <名称>\n"; return 1; fi
            local lf="${LOG_DIR}/${name}.log"
            if [ -f "$lf" ] && [ -s "$lf" ]; then tail -n 50 "$lf"
            elif [ "$BACKEND" = "systemd" ]; then
                journalctl -u "${SERVICE_PREFIX}_${name}" -n 50 --no-pager 2>/dev/null || printf "${R}[错误]${NC} 无日志\n"
            else
                printf "${R}[错误]${NC} 无日志\n"
            fi
            ;;
        clear|clean)
            [ -z "$name" ] && name=$(single_connection)
            if [ -z "$name" ]; then printf "${R}[错误]${NC} 请指定连接名: frpc log clear <名称>\n"; return 1; fi
            local lf="${LOG_DIR}/${name}.log"
            printf "  确认清空 frpc_%s 日志? " "$name"
            read -r c
            if ! confirm_yes "$c"; then echo "  已取消"; return; fi
            [ -f "$lf" ] && > "$lf"
            printf "${G}[成功]${NC} 日志已清空\n"
            ;;
        live|""|-f)
            [ -z "$name" ] && name=$(single_connection)
            if [ -z "$name" ]; then printf "${R}[错误]${NC} 请指定连接名: frpc log <名称>\n"; return 1; fi
            local lf="${LOG_DIR}/${name}.log"
            if [ -f "$lf" ] && [ -s "$lf" ]; then tail -f "$lf"
            elif [ "$BACKEND" = "systemd" ]; then
                journalctl -u "${SERVICE_PREFIX}_${name}" -f --no-pager 2>/dev/null || printf "${R}[错误]${NC} 无日志\n"
            else
                printf "${R}[错误]${NC} 无日志 (进程可能未运行)\n"
            fi
            ;;
        *) echo "用法: frpc log [recent|clear] <名称>" ;;
    esac
}

# ======================== version ========================

cmd_version() {
    if [ -x "$FRPC_BIN" ]; then "$FRPC_BIN" --version 2>&1 | head -1
    else printf "${R}[错误]${NC} frpc 未安装\n"; fi
}

# ======================== reinstall ========================

cmd_reinstall() {
    if [ ! -f "$INSTALL_DIR/install.sh" ]; then
        printf "${R}[错误]${NC} 安装脚本不存在，请重新下载\n"; exit 1
    fi
    printf "${B}[信息]${NC} 停止所有连接...\n"
    for n in $(find_connections); do
        if [ "$BACKEND" = "systemd" ]; then
            systemctl stop "${SERVICE_PREFIX}_${n}" 2>/dev/null
        else
            if pid_is_running "$n"; then
                local pid; pid=$(_get_pid "$n")
                kill "$pid" 2>/dev/null
                rm -f "$(_pid_file "$n")"
            fi
        fi
    done
    printf "${B}[信息]${NC} 重新安装...\n"
    sh "$INSTALL_DIR/install.sh"
}

# ======================== uninstall ========================

cmd_uninstall() {
    echo ""
    printf "${Y}[警告]${NC} 即即卸载 frpc，将删除:\n"
    echo "  - $INSTALL_DIR"
    if [ "$BACKEND" = "systemd" ]; then
        echo "  - 所有 frpc_* 服务文件"
    else
        echo "  - 所有 PID 文件和自启配置"
        echo "  - crontab 中的 frpc-autostart"
    fi
    echo "  - $0"
    echo ""
    printf "  输入 YES 确认卸载: "
    read -r c
    if ! confirm_yes "$c"; then echo "  已取消"; return; fi

    for n in $(find_connections); do
        if [ "$BACKEND" = "systemd" ]; then
            systemctl stop "${SERVICE_PREFIX}_${n}" 2>/dev/null
            systemctl disable "${SERVICE_PREFIX}_${n}" 2>/dev/null
            rm -f "/etc/systemd/system/${SERVICE_PREFIX}_${n}.service"
        else
            if pid_is_running "$n"; then
                local pid; pid=$(_get_pid "$n")
                kill "$pid" 2>/dev/null
            fi
            rm -f "$(_pid_file "$n")"
            rm -f "$ENABLED_DIR/${n}.enabled"
        fi
    done

    if [ "$BACKEND" = "systemd" ]; then
        systemctl daemon-reload 2>/dev/null
    else
        if command -v crontab >/dev/null 2>&1; then
            crontab -l 2>/dev/null | grep -v "frpc-autostart" > /tmp/_frpc_cron
            crontab /tmp/_frpc_cron 2>/dev/null
            rm -f /tmp/_frpc_cron
        fi
    fi

    rm -rf "$INSTALL_DIR"
    rm -f "$0"
    printf "${G}[成功]${NC} frpc 已完全卸载\n"
}

# ======================== 主入口 ========================

if [ ! -x "$FRPC_BIN" ]; then
    case "${1:-help}" in
        help|-h|--help|"") cmd_help; exit 0 ;;
        *) printf "${R}[错误]${NC} frpc 未安装，请先运行安装脚本\n"; exit 1 ;;
    esac
fi

case "${1:-help}" in
    start)       cmd_start "$2" ;;
    stop)        cmd_stop "$2" ;;
    restart)     cmd_restart "$2" ;;
    enable)      cmd_enable "$2" ;;
    disable)     cmd_disable "$2" ;;
    list|ls)     cmd_list ;;
    status|st)   cmd_status "$2" ;;
    add)         cmd_add ;;
    remove|rm)   cmd_remove "$2" ;;
    conf)        cmd_conf "$2" "$3" ;;
    log)         cmd_log "$2" "$3" ;;
    version|ver) cmd_version ;;
    reinstall)   cmd_reinstall ;;
    uninstall)   cmd_uninstall ;;
    help|-h|--help|"") cmd_help ;;
    *) echo ""; printf "${R}[错误]${NC} 未知命令: %s\n" "$1"; echo "  运行 frpc help 查看所有命令"; echo "" ;;
esac
ENDCLI

    chmod +x "$CLI_BIN"
    ok "CLI 命令已注册: $CLI_BIN"
}

# ======================== 安装流程 ========================

do_install() {
    echo ""
    printf "  \033[1mFRP 客户端 一键安装\033[0m\n"
    echo ""

    full_check || die "环境检测未通过"
    echo ""
    ensure_deps
    download_and_install
    echo ""
    register_cli
    echo ""

    # 非 systemd 环境：初始化目录
    if [ "$BACKEND" = "pidfile" ]; then
        mkdir -p "$PIDS_DIR" "$ENABLED_DIR"
        ok "PID 文件目录: $PIDS_DIR"
    fi

    case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac

    line
    printf "  \033[0;32m安装完成！\033[0m\n"
    printf "  运行后端: %s\n" "$BACKEND"
    line
    echo ""
    echo "  安装目录:   $INSTALL_DIR"
    echo "  配置目录:   $CONFIGS_DIR"
    echo "  管理命令:   frpc help"
    echo ""
    echo "  快速开始:"
    echo "    frpc add          添加服务器连接"
    echo "    frpc start        启动所有连接"
    echo "    frpc list         查看所有连接"
    echo "    frpc status       查看运行状态"
    echo "    frpc help         查看所有命令"
    echo ""
}

# ======================== 入口 ========================

case "${1:-}" in
    --update|--reinstall)
        download_and_install
        register_cli
        echo ""
        ok "操作完成，运行 frpc start 启动连接"
        ;;
    *)
        do_install
        ;;
esac