#!/bin/sh

# ============================================================================
#  FRP 客户端一键安装脚本
#  运行一次后自动注册 frpc CLI 命令
#  支持: Debian / Ubuntu | systemd | 多服务器连接
#  日期: 2026-08-06
# ============================================================================

INSTALL_DIR="/opt/frpc"
FRPC_BIN="$INSTALL_DIR/frpc"
CONFIGS_DIR="$INSTALL_DIR/configs"
LOG_DIR="$INSTALL_DIR/logs"
SERVICE_PREFIX="frpc"
CLI_BIN="/usr/local/bin/frpc"

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

# ======================== 发行版检测 ========================

detect_distro() {
    [ -f /etc/os-release ] || { echo "unknown"; return; }
    # shellcheck disable=SC1091
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

    local init; init=$(detect_init)
    if [ "$init" = "systemd" ]; then ok "初始化系统: systemd"
    else fail "需要 systemd (当前: $init)"; err=$((err + 1)); fi

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
    if [ -z "$v" ] && command -v curl >/dev/null 2>&1; then
        v=$(curl -sI --connect-timeout 10 "https://github.com/fatedier/frp/releases/latest" 2>/dev/null \
            | grep -i "^location:" | tr -d '\r' | grep -o 'v[0-9][0-9.]*' | head -1 | sed 's/^v//')
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

    mkdir -p "$INSTALL_DIR" "$CONFIGS_DIR" "$LOG_DIR"
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
#  由安装脚本自动生成
# ============================================================================

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=C.UTF-8

INSTALL_DIR="/opt/frpc"
FRPC_BIN="$INSTALL_DIR/frpc"
CONFIGS_DIR="$INSTALL_DIR/configs"
LOG_DIR="$INSTALL_DIR/logs"
SERVICE_PREFIX="frpc"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ======================== 工具函数 ========================

# ====== 关键：定义 line 函数 ======
line() { printf "\033[0;36m────────────────────────────────────────────────────\033[0m\n"; }

# 列出所有连接名
find_connections() {
    [ -d "$CONFIGS_DIR" ] || return
    for f in "$CONFIGS_DIR"/*.toml; do
        [ -f "$f" ] || continue
        basename "$f" .toml
    done
}

# 从配置文件读取值
get_conf_val() {
    local file=$1 key=$2
    grep "^${key}" "$file" 2>/dev/null | head -1 | sed "s/^${key}[[:space:]]*=[[:space:]]*//;s/^\"//;s/\"$//"
}

# 获取服务器信息
get_server_info() {
    local conf=$1
    local addr port
    addr=$(get_conf_val "$conf" "serverAddr")
    port=$(get_conf_val "$conf" "serverPort")
    echo "${addr:-?}:${port:-7000}"
}

# 验证连接名
valid_name() {
    case "$1" in
        "") return 1 ;;
        *[!a-zA-Z0-9_]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 统计连接数
count_connections() {
    local n=0
    for _ in $(find_connections); do n=$((n + 1)); done
    echo "$n"
}

# 获取唯一连接名（仅一个时返回）
single_connection() {
    local cnt; cnt=$(count_connections)
    [ "$cnt" -eq 1 ] && find_connections
}

# ====== 打开编辑器的统一函数 ======
open_editor() {
    local file=$1
    stty sane 2>/dev/null
    TERM="${TERM:-xterm}"
    export TERM

    local editor=""
    command -v nano >/dev/null 2>&1 && editor="nano"
    command -v vim  >/dev/null 2>&1 && editor="vim"
    command -v vi   >/dev/null 2>&1 && [ -z "$editor" ] && editor="vi"

    if [ -z "$editor" ]; then
        printf "${R}[错误]${NC} 没有可用的文本编辑器\n"
        echo "  请安装: apt install nano"
        return 1
    fi

    printf "${B}[信息]${NC} 使用 ${BOLD}%s${NC} 编辑\n" "$editor"
    echo "  文件: $file"
    echo ""

    "$editor" "$file"
    stty sane 2>/dev/null
    return 0
}

# ======================== 帮助 ========================

cmd_help() {
    echo ""
    printf "  ${BOLD}frpc${NC} - FRP 客户端管理工具 (多服务器)\n"
    echo ""
    printf "  ${BOLD}用法:${NC}\n"
    echo "    frpc <命令> [选项]"
    echo ""
    printf "  ${BOLD}连接管理:${NC}\n"
    echo "    frpc add [name]            添加服务器连接"
    echo "    frpc remove <name>         删除连接"
    echo "    frpc list                  列出所有连接"
    echo ""
    printf "  ${BOLD}服务控制:${NC}\n"
    echo "    frpc start [name]          启动 (所有/指定)"
    echo "    frpc stop [name]           停止 (所有/指定)"
    echo "    frpc restart [name]        重启 (所有/指定)"
    echo ""
    printf "  ${BOLD}开机自启:${NC}\n"
    echo "    frpc enable [name]         设置开机自启"
    echo "    frpc disable [name]        取消开机自启"
    echo ""
    printf "  ${BOLD}状态查看:${NC}\n"
    echo "    frpc status [name]         查看运行状态"
    echo "    frpc version               查看版本"
    echo ""
    printf "  ${BOLD}日志管理:${NC}\n"
    echo "    frpc log <name>            实时日志"
    echo "    frpc log recent <name>     最近50行"
    echo "    frpc log clear <name>      清空日志"
    echo ""
    printf "  ${BOLD}配置管理:${NC}\n"
    echo "    frpc conf <name>           编辑配置"
    echo "    frpc conf show <name>      查看配置"
    echo ""
    printf "  ${BOLD}维护:${NC}\n"
    echo "    frpc reinstall             重新安装"
    echo "    frpc uninstall             卸载"
    echo "    frpc help                  显示此帮助"
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
    printf "${B}[信息]${NC} 启动 frpc_%s ...\n" "$name"
    systemctl start "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet "${SERVICE_PREFIX}_${name}" 2>/dev/null; then
        local pid; pid=$(systemctl show "${SERVICE_PREFIX}_${name}" --property=MainPID --value 2>/dev/null)
        printf "${G}[成功]${NC} frpc_%s 已启动 (PID: %s)\n" "$name" "$pid"
    else
        printf "${R}[失败]${NC} frpc_%s 启动失败 (frpc log recent %s 查看日志)\n" "$name" "$name"
    fi
}

# ======================== stop ========================

cmd_stop() {
    local name=$1
    if [ -n "$name" ]; then
        _stop_one "$name"
    else
        for n in $(find_connections); do _stop_one "$n"; done
    fi
}

_stop_one() {
    local name=$1 conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; fi
    systemctl stop "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
    printf "${G}[成功]${NC} frpc_%s 已停止\n" "$name"
}

# ======================== restart ========================

cmd_restart() {
    local name=$1
    if [ -n "$name" ]; then
        _restart_one "$name"
    else
        for n in $(find_connections); do _restart_one "$n"; done
    fi
}

_restart_one() {
    local name=$1 conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; fi
    printf "${B}[信息]${NC} 重启 frpc_%s ...\n" "$name"
    systemctl restart "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet "${SERVICE_PREFIX}_${name}" 2>/dev/null; then
        printf "${G}[成功]${NC} frpc_%s 已重启\n" "$name"
    else
        printf "${R}[失败]${NC} frpc_%s 重启失败\n" "$name"
    fi
}

# ======================== enable / disable ========================

cmd_enable() {
    local name=$1
    if [ -n "$name" ]; then
        [ ! -f "$CONFIGS_DIR/${name}.toml" ] && { printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; }
        systemctl enable "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
        printf "${G}[成功]${NC} frpc_%s 已设置开机自启\n" "$name"
    else
        for n in $(find_connections); do
            systemctl enable "${SERVICE_PREFIX}_${n}" >/dev/null 2>&1
            printf "${G}[成功]${NC} frpc_%s 已设置开机自启\n" "$n"
        done
    fi
}

cmd_disable() {
    local name=$1
    if [ -n "$name" ]; then
        [ ! -f "$CONFIGS_DIR/${name}.toml" ] && { printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; }
        systemctl disable "${SERVICE_PREFIX}_${name}" >/dev/null 2>&1
        printf "${G}[成功]${NC} frpc_%s 已取消开机自启\n" "$name"
    else
        for n in $(find_connections); do
            systemctl disable "${SERVICE_PREFIX}_${n}" >/dev/null 2>&1
            printf "${G}[成功]${NC} frpc_%s 已取消开机自启\n" "$n"
        done
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
        local server
        server=$(get_server_info "$conf")

        local st_d en_d
        if systemctl is-active --quiet "${SERVICE_PREFIX}_${name}" 2>/dev/null; then
            st_d="${G}● 运行中${NC}"
        else
            st_d="${R}● 已停止${NC}"
        fi
        if systemctl is-enabled --quiet "${SERVICE_PREFIX}_${name}" 2>/dev/null; then
            en_d="${G}● 已启用${NC}"
        else
            en_d="${R}○ 未启用${NC}"
        fi

        printf "  %-16s %-22b %-22b %s\n" "$name" "$st_d" "$en_d" "$server"
        cnt=$((cnt + 1))
    done

    echo ""
    printf "  共 %d 个连接\n" "$cnt"
    echo ""
}

# ======================== status ========================

cmd_status() {
    local name=$1

    if [ -n "$name" ]; then
        _status_one "$name"
    else
        local cnt; cnt=$(count_connections)
        if [ "$cnt" -eq 0 ]; then
            echo "  没有连接"; echo ""
            return
        fi
        cmd_list
    fi
}

_status_one() {
    local name=$1 conf="$CONFIGS_DIR/${name}.toml"
    if [ ! -f "$conf" ]; then printf "${R}[错误]${NC} 连接 '%s' 不存在\n" "$name"; return 1; fi

    local server
    server=$(get_server_info "$conf")
    local pid
    pid=$(systemctl show "${SERVICE_PREFIX}_${name}" --property=MainPID --value 2>/dev/null)

    echo ""
    if systemctl is-active --quiet "${SERVICE_PREFIX}_${name}" 2>/dev/null; then
        echo -e "  状态:   ${G}● 运行中${NC}"
    else
        echo -e "  状态:   ${R}● 已停止${NC}"
    fi

    if systemctl is-enabled --quiet "${SERVICE_PREFIX}_${name}" 2>/dev/null; then
        echo -e "  自启:   ${G}● 已启用${NC}"
    else
        echo -e "  自启:   ${Y}○ 未启用${NC}"
    fi

    echo "  服务器: $server"
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

    # 1. 连接名称
    local name=""
    while true; do
        printf "  连接名称 (英文/数字/下划线): "
        read -r name
        name=$(echo "$name" | tr -d ' ')
        if [ -z "$name" ]; then
            printf "${R}    名称不能为空${NC}\n"; continue
        fi
        if ! valid_name "$name"; then
            printf "${R}    名称只能包含英文、数字、下划线${NC}\n"; continue
        fi
        if [ -f "$CONFIGS_DIR/${name}.toml" ]; then
            printf "${R}    连接 '%s' 已存在${NC}\n" "$name"; continue
        fi
        break
    done

    # 2. 服务器地址
    local addr=""
    while true; do
        printf "  服务器地址 (IP或域名): "
        read -r addr
        [ -n "$addr" ] && break
        printf "${R}    地址不能为空${NC}\n"
    done

    # 3. 服务器端口
    local port="7000"
    printf "  服务器端口 [7000]: "
    read -r input
    [ -n "$input" ] && port="$input"

    # 4. 认证 Token
    local token=""
    while true; do
        printf "  认证Token: "
        read -r token
        [ -n "$token" ] && break
        printf "${R}    Token不能为空${NC}\n"
    done

    echo ""
    info "正在生成配置文件..."

    # 5. 生成配置
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
# 取消注释并修改你需要的代理规则
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

# --- HTTPS ---
#[[proxies]]
#name = "web-https"
#type = "https"
#localIP = "127.0.0.1"
#localPort = 443
#customDomains = ["your.domain.com"]
ENDCONF

    ok "配置文件: $conf"

    # 6. 打开编辑器
    echo ""
    info "即将打开编辑器，请配置 proxies 代理规则"
    if command -v nano >/dev/null 2>&1; then
        echo "  nano: 取消注释修改代理 → Ctrl+X → Y → 回车"
    else
        echo "  vi: 按 i 编辑 → ESC → :wq 保存退出"
    fi
    echo ""

    open_editor "$conf"

    # 7. 创建服务
    info "创建服务文件..."
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

    # 8. 启动
    echo ""
    printf "  输入 y 立即启动，其他键跳过: "
    read -r c
    case "$c" in
        y|Y)
            systemctl start "$svc_name" >/dev/null 2>&1
            sleep 1
            if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
                local pid; pid=$(systemctl show "$svc_name" --property=MainPID --value 2>/dev/null)
                printf "${G}[成功]${NC} frpc_%s 已启动 (PID: %s)\n" "$name" "$pid"
            else
                printf "${R}[失败]${NC} 启动失败，查看日志: frpc log recent %s\n" "$name"
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
    echo "  - 配置文件: $conf"
    echo "  - 日志文件: ${LOG_DIR}/${name}.log"
    echo "  - 服务文件: /etc/systemd/system/frpc_${name}.service"
    echo ""
    printf "  输入 YES 确认: "
    read -r c
    if [ "$c" != "YES" ]; then echo "  已取消"; return; fi

    systemctl stop "${SERVICE_PREFIX}_${name}" 2>/dev/null
    systemctl disable "${SERVICE_PREFIX}_${name}" 2>/dev/null
    rm -f "/etc/systemd/system/${SERVICE_PREFIX}_${name}.service"
    rm -f "$conf"
    rm -f "${LOG_DIR}/${name}.log"
    systemctl daemon-reload 2>/dev/null
    printf "${G}[成功]${NC} 连接 '%s' 已删除\n" "$name"
}

# ======================== conf ========================

cmd_conf() {
    local arg1=$1 arg2=$2
    local subcmd="edit" name=""

    # 解析参数:
    # frpc conf           → edit, auto-select single
    # frpc conf <name>    → edit <name>
    # frpc conf show      → show, auto-select single
    # frpc conf show <n>  → show <name>
    case "$arg1" in
        show|cat)
            subcmd="show"
            name="$arg2"
            ;;
        *)
            subcmd="edit"
            name="$arg1"
            ;;
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

            open_editor "$conf"

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
    local subcmd=$1 name=$2

    case "${subcmd:-live}" in
        recent|tail)
            [ -z "$name" ] && name=$(single_connection)
            if [ -z "$name" ]; then printf "${R}[错误]${NC} 请指定连接名: frpc log recent <名称>\n"; return 1; fi
            local lf="${LOG_DIR}/${name}.log"
            if [ -f "$lf" ] && [ -s "$lf" ]; then tail -n 50 "$lf"
            else journalctl -u "${SERVICE_PREFIX}_${name}" -n 50 --no-pager 2>/dev/null || printf "${R}[错误]${NC} 无日志\n"; fi
            ;;
        clear|clean)
            [ -z "$name" ] && name=$(single_connection)
            if [ -z "$name" ]; then printf "${R}[错误]${NC} 请指定连接名: frpc log clear <名称>\n"; return 1; fi
            local lf="${LOG_DIR}/${name}.log"
            printf "  确认清空 frpc_%s 日志? " "$name"
            read -r c
            case "$c" in y|Y|yes|YES) [ -f "$lf" ] && > "$lf"; printf "${G}[成功]${NC} 日志已清空\n" ;; *) echo "  已取消" ;; esac
            ;;
        live|""|-f)
            [ -z "$name" ] && name=$(single_connection)
            if [ -z "$name" ]; then printf "${R}[错误]${NC} 请指定连接名: frpc log <名称>\n"; return 1; fi
            local lf="${LOG_DIR}/${name}.log"
            if [ -f "$lf" ] && [ -s "$lf" ]; then tail -f "$lf"
            else journalctl -u "${SERVICE_PREFIX}_${name}" -f --no-pager 2>/dev/null || printf "${R}[错误]${NC} 无日志\n"; fi
            ;;
        *)
            echo "用法: frpc log [recent|clear] <名称>" ;;
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
    for n in $(find_connections); do systemctl stop "${SERVICE_PREFIX}_${n}" 2>/dev/null; done
    printf "${B}[信息]${NC} 重新安装...\n"
    sh "$INSTALL_DIR/install.sh"
}

# ======================== uninstall ========================

cmd_uninstall() {
    echo ""
    printf "${Y}[警告]${NC} 即将卸载 frpc，将删除:\n"
    echo "  - $INSTALL_DIR (二进制、配置、日志)"
    echo "  - 所有 frpc_* 服务文件"
    echo "  - $0 (CLI 命令)"
    echo ""
    printf "  输入 YES 确认卸载: "
    read -r c
    if [ "$c" != "YES" ]; then echo "  已取消"; return; fi

    for n in $(find_connections); do
        systemctl stop "${SERVICE_PREFIX}_${n}" 2>/dev/null
        systemctl disable "${SERVICE_PREFIX}_${n}" 2>/dev/null
        rm -f "/etc/systemd/system/${SERVICE_PREFIX}_${n}.service"
    done
    systemctl daemon-reload 2>/dev/null
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

    case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac

    line
    printf "  \033[0;32m安装完成！\033[0m\n"
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