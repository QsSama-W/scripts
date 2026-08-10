#!/bin/bash
# ============================================
#  JC - 进程管理器 CLI
#  用法: jc [-t 超时秒数] [-n 显示数量] [help] [-h]
# ============================================

set -euo pipefail

JC_BIN="/usr/local/bin/jc"

# ==================== 自动注册 ====================
# 检测当前执行路径，如果不是全局命令路径，则自动复制并授权
if [[ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$JC_BIN" ]]; then
    echo -e "\033[1;36m检测到首次运行，正在自动注册全局命令 'jc'...\033[0m"
    cp "$0" "$JC_BIN"
    chmod +x "$JC_BIN"
    echo -e "\033[1;32m注册成功！以后可以在终端任意位置直接输入 jc 调起面板。\033[0m"
    sleep 1.5
    exec "$JC_BIN" "$@" # 替换当前进程，直接启动安装好的 CLI
fi

# ==================== 颜色 ====================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

IDLE_TIMEOUT=120
SHOW_COUNT=10

# ==================== 工具函数 ====================
clear_screen() { printf '\033[2J\033[H'; }

timed_read() {
    local prompt="$1"
    if (( IDLE_TIMEOUT == 0 )); then
        printf "${prompt}"
        read -r REPLY
        return 0
    fi
    printf "${prompt}"
    if read -r -t "$IDLE_TIMEOUT" REPLY; then
        return 0
    else
        return 1
    fi
}

interactive_read() {
    local prompt="$1"
    if ! timed_read "$prompt"; then
        auto_exit
    fi
}

auto_exit() {
    clear_screen
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "    ⏱  空闲 ${IDLE_TIMEOUT} 秒，jc 自动退出${RESET}"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    exit 0
}

header() {
    local title="$1"
    local width=58
    local clean_title
    clean_title=$(echo -e "$title" | sed 's/\x1b\[[0-9;]*m//g')
    local clean_len=${#clean_title}
    local pad=$(( (width - clean_len) / 2 ))
    local pad2=$(( width - clean_len - pad ))
    echo ""
    printf "${CYAN}┌"
    printf '─%.0s' $(seq 1 "$width")
    printf "┐${RESET}\n"
    printf "${CYAN}│${RESET}"
    printf '%*s' "$pad" ""
    printf "${BOLD}${WHITE}%s${RESET}" "$title"
    printf '%*s' "$pad2" ""
    printf "${CYAN}│${RESET}\n"
    printf "${CYAN}└"
    printf '─%.0s' $(seq 1 "$width")
    printf "┘${RESET}\n"
}

check_root_warn() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "  ${YELLOW}⚠  非 root 运行，只能终止自己的进程${RESET}"
        echo ""
    fi
}

# ==================== CPU 使用率采集 ====================
get_cpu_usage() {
    local -a vals1 vals2
    read -r -a vals1 <<< "$(grep '^cpu ' /proc/stat)"
    sleep 0.5
    read -r -a vals2 <<< "$(grep '^cpu ' /proc/stat)"

    local total1=$(( vals1[1] + vals1[2] + vals1[3] + vals1[4] + vals1[5] + vals1[6] + vals1[7] ))
    local total2=$(( vals2[1] + vals2[2] + vals2[3] + vals2[4] + vals2[5] + vals2[6] + vals2[7] ))
    local idle_d=$(( vals2[4] - vals1[4] ))
    local total_d=$(( total2 - total1 ))

    if (( total_d == 0 )); then
        echo 0
    else
        echo $(( (total_d - idle_d) * 100 / total_d ))
    fi
}

cpu_color() {
    local usage="$1"
    if (( usage < 50 )); then
        echo -e "${GREEN}${usage}%${RESET}"
    elif (( usage < 80 )); then
        echo -e "${YELLOW}${usage}%${RESET}"
    else
        echo -e "${RED}${usage}%${RESET}"
    fi
}

# ==================== 帮助页面 ====================
show_help() {
    clear_screen
    header " JC - 使用帮助 "
    echo ""

    echo -e "  ${BOLD}${WHITE}用法${RESET}"
    echo -e "  ${CYAN}jc${RESET} [选项] [命令]"
    echo ""

    echo -e "  ${BOLD}${WHITE}命令${RESET}"
    echo -e "    ${GREEN}无参数${RESET}       启动交互式进程管理器"
    echo -e "    ${GREEN}help${RESET}         显示本帮助信息"
    echo ""

    echo -e "  ${BOLD}${WHITE}选项${RESET}"
    echo -e "    ${GREEN}-t <秒>${RESET}     设置空闲超时时间 (默认: 120秒)"
    echo -e "                       ${DIM}设为 0 则禁用自动退出${RESET}"
    echo -e "    ${GREEN}-n <数量>${RESET}   设置显示的进程数量 (默认: 10)"
    echo -e "    ${GREEN}-h${RESET}           显示本帮助信息"
    echo ""

    echo -e "  ${BOLD}${WHITE}示例${RESET}"
    echo -e "    ${CYAN}jc${RESET}                  ${DIM}# 启动，默认120秒超时${RESET}"
    echo -e "    ${CYAN}jc -t 60${RESET}            ${DIM}# 60秒空闲后自动退出${RESET}"
    echo -e "    ${CYAN}jc -t 0${RESET}             ${DIM}# 禁用空闲自动退出${RESET}"
    echo -e "    ${CYAN}jc -n 20${RESET}            ${DIM}# 显示TOP 20进程${RESET}"
    echo -e "    ${CYAN}jc -t 60 -n 20${RESET}      ${DIM}# 组合使用${RESET}"
    echo -e "    ${CYAN}jc help${RESET}             ${DIM}# 查看帮助${RESET}"
    echo ""

    echo -e "  ${BOLD}${WHITE}交互快捷键${RESET}"
    echo -e "    ${GREEN}1${RESET}           查看内存占用 TOP 列表"
    echo -e "    ${GREEN}2${RESET}           查看CPU 占用 TOP 列表"
    echo -e "    ${GREEN}h${RESET}           查看帮助"
    echo -e "    ${GREEN}r${RESET}           刷新页面"
    echo -e "    ${GREEN}u${RESET}           卸载 jc"
    echo -e "    ${RED}q${RESET}           退出程序"
    echo ""

    echo -e "  ${BOLD}${WHITE}进程管理操作${RESET}"
    echo -e "    在列表页 ${GREEN}输入数字序号${RESET} 选中对应进程"
    echo -e "    选择终止方式:"
    echo -e "      ${GREEN}[1]${RESET} 普通终止 (SIGTERM) — 优雅退出，允许清理"
    echo -e "      ${RED}[2]${RESET} 强制终止 (SIGKILL) — 立即杀死，可能丢数据"
    echo -e "      ${DIM}[3]${RESET} 取消操作"
    echo -e "    输入 ${GREEN}b${RESET} 返回主菜单"
    echo ""

    echo -e "  ${BOLD}${WHITE}颜色含义${RESET}"
    echo -e "    ${GREEN}绿色${RESET}   占用正常"
    echo -e "    ${YELLOW}黄色${RESET}   占用偏高，需要关注"
    echo -e "    ${RED}红色${RESET}   占用过高，建议处理"
    echo ""

    echo -e "  ${BOLD}${WHITE}卸载${RESET}"
    echo -e "    方式一: 在主菜单输入 ${GREEN}u${RESET}"
    echo -e "    方式二: ${CYAN}sudo rm -f ${JC_BIN}${RESET}"
    echo ""

    echo -e "${YELLOW}$(printf '─%.0s' $(seq 1 58))${RESET}"
    echo ""
}

# ==================== 系统信息 ====================
sys_summary() {
    local used_mem total_mem uptime_str load mem_pct usage

    usage=$(get_cpu_usage)

    read -r total_mem used_mem _ <<< "$(free -m | awk '/Mem:/{print $2, $3}')"
    mem_pct=$(( used_mem * 100 / total_mem ))

    uptime_str=$(uptime -p 2>/dev/null || uptime | sed 's/.*up/up/' | sed 's/,.*//')
    load=$(awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "N/A")

    local timeout_info
    if (( IDLE_TIMEOUT > 0 )); then
        timeout_info="${IDLE_TIMEOUT}s"
    else
        timeout_info="禁用"
    fi

    echo -e "  ${DIM}运行时间:${RESET} ${uptime_str}"
    echo -e "  ${DIM}系统负载:${RESET} ${load}"
    echo -e "  ${DIM}CPU 使用:${RESET} $(cpu_color "$usage")"
    echo -e "  ${DIM}内存使用:${RESET} ${GREEN}${used_mem}M${RESET} / ${total_mem}M ${DIM}(${mem_pct}%)${RESET}"
    echo -e "  ${DIM}空闲超时:${RESET} ${timeout_info}"
    echo ""
}

# ==================== 进程列表 ====================
show_processes() {
    local mode="$1" count="$2"

    if [[ "$mode" == "mem" ]]; then
        echo -e "${YELLOW}$(printf '─%.0s' $(seq 1 62))${RESET}"
        printf "  ${BOLD}${YELLOW}%-5s  %-8s  %-7s  %-7s  %s${RESET}\n" \
            "序号" "PID" "%MEM" "%CPU" "进程名"
        echo -e "${YELLOW}$(printf '─%.0s' $(seq 1 62))${RESET}"

        ps -eo pid,pmem,pcpu,comm --sort=-%mem --no-headers 2>/dev/null \
            | head -n "$count" \
            | nl -w2 -s'	' \
            | while IFS=$'\t' read -r num rest; do
                local num_clean pid pmem pcpu comm color
                num_clean=$(echo "$num" | tr -d ' .')
                pid=$(echo "$rest" | awk '{print $1}')
                pmem=$(echo "$rest" | awk '{print $2}')
                pcpu=$(echo "$rest" | awk '{print $3}')
                comm=$(echo "$rest" | awk '{print $4}')
                color="$GREEN"
                if command -v bc &>/dev/null; then
                    (( $(echo "$pmem > 10" | bc -l 2>/dev/null || echo 0) )) && color="$YELLOW"
                    (( $(echo "$pmem > 50" | bc -l 2>/dev/null || echo 0) )) && color="$RED"
                fi
                printf "  ${WHITE}%2s${RESET}   ${CYAN}%-8s${RESET}  ${color}%-7s${RESET}  %-7s  %s\n" \
                    "$num_clean" "$pid" "${pmem}%" "${pcpu}%" "$comm"
            done

    else
        echo -e "${YELLOW}$(printf '─%.0s' $(seq 1 62))${RESET}"
        printf "  ${BOLD}${YELLOW}%-5s  %-8s  %-7s  %-7s  %s${RESET}\n" \
            "序号" "PID" "%CPU" "%MEM" "进程名"
        echo -e "${YELLOW}$(printf '─%.0s' $(seq 1 62))${RESET}"

        ps -eo pid,pcpu,pmem,comm --sort=-%cpu --no-headers 2>/dev/null \
            | head -n "$count" \
            | nl -w2 -s'	' \
            | while IFS=$'\t' read -r num rest; do
                local num_clean pid pcpu pmem comm color
                num_clean=$(echo "$num" | tr -d ' .')
                pid=$(echo "$rest" | awk '{print $1}')
                pcpu=$(echo "$rest" | awk '{print $2}')
                pmem=$(echo "$rest" | awk '{print $3}')
                comm=$(echo "$rest" | awk '{print $4}')
                color="$GREEN"
                if command -v bc &>/dev/null; then
                    (( $(echo "$pcpu > 50" | bc -l 2>/dev/null || echo 0) )) && color="$YELLOW"
                    (( $(echo "$pcpu > 100" | bc -l 2>/dev/null || echo 0) )) && color="$RED"
                fi
                printf "  ${WHITE}%2s${RESET}   ${CYAN}%-8s${RESET}  ${color}%-7s${RESET}  %-7s  %s\n" \
                    "$num_clean" "$pid" "${pcpu}%" "${pmem}%" "$comm"
            done
    fi
    echo -e "${YELLOW}$(printf '─%.0s' $(seq 1 62))${RESET}"
}

get_pid_by_number() {
    local mode="$1" num="$2"
    if [[ "$mode" == "mem" ]]; then
        ps -eo pid --sort=-%mem --no-headers 2>/dev/null | head -n "$num" | tail -n 1 | tr -d ' '
    else
        ps -eo pid --sort=-%cpu --no-headers 2>/dev/null | head -n "$num" | tail -n 1 | tr -d ' '
    fi
}

# ==================== 终止进程 ====================
kill_process() {
    local pid="$1"

    local info
    info=$(ps -p "$pid" -o pid,pcpu,pmem,comm --no-headers 2>/dev/null)
    if [[ -z "$info" ]]; then
        echo -e "\n  ${RED}进程 ${pid} 不存在或已退出${RESET}"
        return 1
    fi

    local comm pcpu pmem
    comm=$(echo "$info" | awk '{print $4}')
    pcpu=$(echo "$info" | awk '{print $2}')
    pmem=$(echo "$info" | awk '{print $3}')

    echo ""
    echo -e "  ${DIM}已选择:${RESET} ${BOLD}${WHITE}${comm}${RESET}  ${DIM}PID:${RESET} ${CYAN}${pid}${RESET}  ${DIM}CPU:${RESET} ${pcpu}%  ${DIM}MEM:${RESET} ${pmem}%"
    echo ""
    echo -e "  ${YELLOW}终止方式:${RESET}"
    echo -e "    ${GREEN}[1]${RESET} 普通终止 (SIGTERM)"
    echo -e "    ${RED}[2]${RESET} 强制终止 (SIGKILL)"
    echo -e "    ${DIM}[3]${RESET} 取消"
    echo ""
    interactive_read "  选择 ${GREEN}[1/2/3]${RESET}: "

    case "$REPLY" in
        1)
            if kill "$pid" 2>/dev/null; then
                sleep 0.5
                if kill -0 "$pid" 2>/dev/null; then
                    echo -e "\n  ${YELLOW}进程仍在运行，强制终止？ [y/N]:${RESET} "
                    interactive_read ""
                    if [[ "$REPLY" =~ ^[Yy] ]]; then
                        kill -9 "$pid" 2>/dev/null && \
                            echo -e "  ${RED}已强制终止 ${pid} (${comm})${RESET}" || \
                            echo -e "  ${RED}终止失败，权限不足？${RESET}"
                    else
                        echo -e "  ${DIM}进程保持运行${RESET}"
                    fi
                else
                    echo -e "  ${GREEN}已终止 ${pid} (${comm})${RESET}"
                fi
            else
                echo -e "  ${RED}发送信号失败，权限不足？${RESET}"
            fi
            ;;
        2)
            echo -e "  ${RED}⚠  强制终止可能导致数据丢失${RESET}"
            interactive_read "  确认 [y/N]: "
            if [[ "$REPLY" =~ ^[Yy] ]]; then
                kill -9 "$pid" 2>/dev/null && \
                    echo -e "  ${RED}已强制终止 ${pid} (${comm})${RESET}" || \
                    echo -e "  ${RED}终止失败${RESET}"
            else
                echo -e "  ${DIM}已取消${RESET}"
            fi
            ;;
        *)
            echo -e "  ${DIM}已取消${RESET}"
            ;;
    esac
}

# ==================== 卸载 ====================
do_uninstall() {
    clear_screen
    header " 卸载 jc "
    echo ""

    echo -e "  ${DIM}安装路径:${RESET} ${CYAN}${JC_BIN}${RESET}"
    if [[ -f "$JC_BIN" ]]; then
        echo -e "  ${DIM}文件大小:${RESET} $(du -h "$JC_BIN" | awk '{print $1}')"
        echo -e "  ${DIM}安装时间:${RESET} $(stat -c '%y' "$JC_BIN" 2>/dev/null | cut -d. -f1 || echo '未知')"
    fi
    echo ""

    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${RED}  ⚠  卸载将删除 ${JC_BIN}${RESET}"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    interactive_read "  确认卸载 [y/N]: "

    if [[ ! "$REPLY" =~ ^[Yy] ]]; then
        echo -e "\n  ${DIM}已取消卸载${RESET}"
        interactive_read "  按回车返回..."
        return
    fi

    if [[ $EUID -ne 0 ]]; then
        echo -e "  ${DIM}需要 root 权限，尝试 sudo...${RESET}"
        if command -v sudo &>/dev/null; then
            if sudo rm -f "$JC_BIN" 2>/dev/null; then
                uninstall_success
            else
                echo -e "\n  ${RED}卸载失败：无法删除 ${JC_BIN}${RESET}"
                echo -e "  ${DIM}请手动执行: sudo rm -f ${JC_BIN}${RESET}"
                interactive_read "  按回车返回..."
            fi
        else
            echo -e "\n  ${RED}卸载失败：需要 root 权限且未安装 sudo${RESET}"
            interactive_read "  按回车返回..."
        fi
    else
        if rm -f "$JC_BIN" 2>/dev/null; then
            uninstall_success
        else
            echo -e "\n  ${RED}卸载失败${RESET}"
            interactive_read "  按回车返回..."
        fi
    fi
}

uninstall_success() {
    echo ""
    echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${GREEN}  ✓  jc 已成功卸载${RESET}"
    echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    exit 0
}

# ==================== 视图 ====================
view_mem() {
    while true; do
        clear_screen
        header " 内存占用 TOP ${SHOW_COUNT} "
        echo ""
        check_root_warn
        sys_summary
        show_processes "mem" "$SHOW_COUNT"
        echo ""
        echo -e "  输入序号终止进程 | ${DIM}b=返回 | q=退出${RESET}"
        interactive_read "  ${GREEN}> ${RESET}"

        case "$REPLY" in
            b|B) return ;;
            q|Q) clear_screen; echo -e "\n  ${GREEN}再见！${RESET}\n"; exit 0 ;;
        esac

        if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= SHOW_COUNT )); then
            local pid
            pid=$(get_pid_by_number "mem" "$REPLY")
            if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
                kill_process "$pid"
                echo ""
                interactive_read "  按回车继续..."
            else
                echo -e "  ${RED}无法获取进程信息${RESET}"
                sleep 0.5
            fi
        else
            echo -e "  ${RED}无效输入${RESET}"
            sleep 0.5
        fi
    done
}

view_cpu() {
    while true; do
        clear_screen
        header " CPU占用 TOP ${SHOW_COUNT} "
        echo ""
        check_root_warn
        sys_summary
        show_processes "cpu" "$SHOW_COUNT"
        echo ""
        echo -e "  输入序号终止进程 | ${DIM}b=返回 | q=退出${RESET}"
        interactive_read "  ${GREEN}> ${RESET}"

        case "$REPLY" in
            b|B) return ;;
            q|Q) clear_screen; echo -e "\n  ${GREEN}再见！${RESET}\n"; exit 0 ;;
        esac

        if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= SHOW_COUNT )); then
            local pid
            pid=$(get_pid_by_number "cpu" "$REPLY")
            if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
                kill_process "$pid"
                echo ""
                interactive_read "  按回车继续..."
            else
                echo -e "  ${RED}无法获取进程信息${RESET}"
                sleep 0.5
            fi
        else
            echo -e "  ${RED}无效输入${RESET}"
            sleep 0.5
        fi
    done
}

# ==================== 主循环 ====================
main_loop() {
    while true; do
        clear_screen
        header " JC - 进程管理器 "
        echo ""
        check_root_warn
        sys_summary

        echo -e "  ${BOLD}选择操作:${RESET}"
        echo ""
        echo -e "    ${GREEN}[1]${RESET} 内存占用 TOP ${SHOW_COUNT}"
        echo -e "    ${CYAN}[2]${RESET} CPU  占用 TOP ${SHOW_COUNT}"
        echo -e "    ${WHITE}[h]${RESET} 帮助"
        echo -e "    ${DIM}[r]${RESET} 刷新"
        echo -e "    ${YELLOW}[u]${RESET} 卸载 jc"
        echo -e "    ${RED}[q]${RESET} 退出"
        echo ""
        if (( IDLE_TIMEOUT > 0 )); then
            echo -e "  ${DIM}💡 空闲 ${IDLE_TIMEOUT}s 后自动退出${RESET}"
            echo ""
        fi
        interactive_read "  选择 ${GREEN}[1/2/h/r/u/q]${RESET}: "

        case "$REPLY" in
            1) view_mem ;;
            2) view_cpu ;;
            h|H) show_help; interactive_read "  按回车返回主页..."; continue ;;
            r|R) continue ;;
            u|U) do_uninstall ;;
            q|Q) clear_screen; echo -e "\n  ${GREEN}再见！${RESET}\n"; exit 0 ;;
            *) echo -e "  ${RED}无效选择${RESET}"; sleep 0.5 ;;
        esac
    done
}

# ==================== 清理 ====================
cleanup() {
    printf '\033[?25h'
    printf '\033[0m'
    stty echo 2>/dev/null || true
}
trap cleanup EXIT

# ==================== 入口 ====================
FIRST_ARG="${1:-}"
if [[ "$FIRST_ARG" == "help" || "$FIRST_ARG" == "--help" || "$FIRST_ARG" == "-h" ]]; then
    if [[ "$FIRST_ARG" != "-h" ]]; then
        shift
        while getopts "t:n:" opt "${@}" 2>/dev/null; do
            case "$opt" in
                t) IDLE_TIMEOUT="$OPTARG" ;;
                n) SHOW_COUNT="$OPTARG" ;;
            esac
        done
    fi
    show_help
    exit 0
fi

while getopts "t:n:h" opt; do
    case "$opt" in
        t) IDLE_TIMEOUT="$OPTARG" ;;
        n) SHOW_COUNT="$OPTARG" ;;
        h) show_help; exit 0 ;;
        *) usage() { echo "用法: jc [-t 秒] [-n 数量] [help] [-h]"; exit 1; }; usage ;;
    esac
done

if ! [[ "$IDLE_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "错误: -t 参数必须为非负整数" >&2; exit 1
fi
if ! [[ "$SHOW_COUNT" =~ ^[0-9]+$ ]] || (( SHOW_COUNT < 1 )); then
    echo "错误: -n 参数必须为正整数" >&2; exit 1
fi

printf '\033[?25l'
main_loop