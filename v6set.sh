#!/bin/bash
# v6 — IPv6 Address Manager
set -euo pipefail

R='\033[38;2;235;130;60m'
G='\033[38;2;80;200;120m'
B='\033[38;2;120;165;255m'
Y='\033[38;2;255;210;60m'
C='\033[38;2;100;210;210m'
M='\033[38;2;190;140;255m'
W='\033[38;2;235;230;220m'
D='\033[38;2;120;115;108m'
BD='\033[1m'
DIM='\033[2m'
RST='\033[0m'

CONF="/etc/v6mgr.conf"
IFACES_FILE="/etc/network/interfaces"
CMD_NAME="v6"

die()  { echo -e "\n  ${R}${BD}✖${RST} $1\n" >&2; exit 1; }
ok()   { echo -e "  ${G}${BD}✔${RST} $1"; }
warn() { echo -e "  ${Y}${BD}⚠${RST} $1"; }
step() { echo -e "  ${B}▸${RST} $1"; }
hr()   { echo -e "  ${DIM}$(printf '─%.0s' {1..48})${RST}"; }
pause() { echo ""; read -rp "  按 Enter 继续..."; }

check_root() { [[ $EUID -eq 0 ]] || die "需要 root 权限"; }

detect_iface() {
    IFACE=$(ip -o link show up | awk -F': ' '/lo/{next} {print $2; exit}')
    [[ -n "$IFACE" ]] || die "未检测到活动网卡"
}

# ═══════════ 首次设置 ═══════════
setup_wizard() {
    clear
    echo ""
    echo -e "  ${BD}${B}初 始 设 置${RST}"
    echo ""
    hr
    echo ""
    detect_iface
    echo -e "  ${DIM}检测到网卡${RST}  ${W}${BD}${IFACE}${RST}"
    echo ""

    local hint=""
    local detected
    detected=$(ip -6 addr show scope global | grep -oP 'inet6 \K[0-9a-f:]+' | head -1)
    if [[ -n "$detected" ]]; then
        hint=$(echo "$detected" | cut -d: -f1-4)
        echo -e "  ${DIM}已有地址${RST}  ${W}${detected}${RST}"
        echo -e "  ${DIM}推测前缀${RST}  ${W}${hint}::/64${RST}"
        echo ""
    fi

    local input
    while true; do
        if [[ -n "$hint" ]]; then
            read -rp "  输入 /64 前缀 [${hint}::/64]: " input
            input=${input:-"${hint}::/64"}
        else
            read -rp "  输入 /64 前缀（如 2602:ffc8:2:b045::/64）: " input
        fi
        echo "$input" | grep -qP '^[0-9a-fA-F:]+/64$' && break
        warn "格式不对，示例: 2602:ffc8:2:b045::/64"
    done

    PREFIX=$(echo "$input" | sed 's|/64||' | sed 's|:*$||')
    PREFIX="${PREFIX}::"


    cat > "$CONF" <<EOF
IFACE=$IFACE
PREFIX=$PREFIX
EOF

    echo ""
    ok "配置已保存 ${W}${CONF}${RST}"
    echo -e "  ${DIM}前缀${RST}  ${W}${PREFIX}/64${RST}"
    echo -e "  ${DIM}网卡${RST}  ${W}${IFACE}${RST}"
    echo ""
    read -rp "  按 Enter 进入面板..."
}

load_config() {
    if [[ ! -f "$CONF" ]]; then
        setup_wizard
    else
        source "$CONF"
        [[ -n "${IFACE:-}" && -n "${PREFIX:-}" ]] || setup_wizard
        if ! ip link show "$IFACE" &>/dev/null; then
            warn "网卡 ${IFACE} 不存在，重新检测"
            detect_iface
            sed -i "s/^IFACE=.*/IFACE=$IFACE/" "$CONF"
        fi
    fi
}

# ═══════════ 地址读取 ═══════════
declare -a A_ADDR=() A_PFX=() A_IFACE=()
declare -a O_ADDR=() O_PFX=()
total_all=0 total_own=0

load_addresses() {
    A_ADDR=(); A_PFX=(); A_IFACE=()
    O_ADDR=(); O_PFX=()
    total_all=0; total_own=0

    while IFS= read -r line; do
        local ifn=$(echo "$line" | awk '{print $2}')
        local addr=$(echo "$line" | grep -oP 'inet6 \K[0-9a-f:]+')
        local pfx=$(echo "$line" | grep -oP 'inet6 [0-9a-f:]+/\K\d+')
        [[ "$addr" == fe80:* ]] && continue
        A_ADDR+=("$addr"); A_PFX+=("$pfx"); A_IFACE+=("$ifn"); ((total_all++)) || true
        if [[ "${addr}:" == "${PREFIX}"* || "${addr}" == "${PREFIX%::}"* ]]; then
            O_ADDR+=("$addr"); O_PFX+=("$pfx"); ((total_own++)) || true
        fi
    done < <(ip -6 addr show | grep "inet6.*scope global")
}

# ═══════════ 随机生成 ═══════════
gen_rand() {
    local base="${PREFIX%::}"
    printf '%s:%04x:%04x:%04x:%04x' "$base" \
        $((RANDOM%65535)) $((RANDOM%65535)) $((RANDOM%65535)) $((RANDOM%65535))
}

is_dup() {
    local c="$1"
    for a in "${A_ADDR[@]}"; do [[ "$a" == "$c" ]] && return 0; done
    return 1
}

density_bar() {
    local c=$1 m=${2:-20} color="$G"
    ((c > 10)) && color="$Y"; ((c > 30)) && color="$R"; ((c == 0)) && color="$D"
    local f=$((c > m ? m : c)) bar=""
    for ((i = 0; i < f; i++)); do bar+="█"; done
    for ((i = f; i < m; i++)); do bar+="░"; done
    echo -e "${color}${bar}${RST} ${W}${c}${RST}"
}

# ═══════════ 界面 ═══════════
show_header() {
    clear
    echo ""
    echo -e "  ${B}${BD}┌──────────────────────────────────────────────┐${RST}"
    echo -e "  ${B}${BD}│${RST}                                              ${B}${BD}│${RST}"
    echo -e "  ${B}${BD}│${RST}    ${BD}${W}V 6${RST}   ${DIM}Address Manager${RST}                   ${B}${BD}│${RST}"
    echo -e "  ${B}${BD}│${RST}                                              ${B}${BD}│${RST}"
    echo -e "  ${B}${BD}└──────────────────────────────────────────────┘${RST}"
    echo ""
    echo -e "  ${DIM}前缀${RST}   ${W}${B}${PREFIX}/64${RST}"
    echo -e "  ${DIM}网卡${RST}   ${W}${IFACE}${RST}"
    echo -e "  ${DIM}地址${RST}   $(density_bar "$total_own") ${DIM}个属于此前缀${RST}"
    echo -e "  ${DIM}全部${RST}   ${W}${total_all}${RST} ${DIM}个全球单播${RST}"
    echo ""
}

show_list() {
    hr
    printf "  ${BD}${D}#  ${RST}  ${BD}${B}%-40s${RST} ${BD}${B}%-12s${RST} ${BD}${B}%s${RST}\n" "地址" "前缀" "网卡"
    hr
    if [[ $total_all -eq 0 ]]; then
        echo -e "  ${D}暂无地址${RST}"
    else
        local n=1
        for i in "${!A_ADDR[@]}"; do
            local mark tag pfx_fmt
            if [[ "${A_ADDR[$i]}:" == "${PREFIX}"* || "${A_ADDR[$i]}" == "${PREFIX%::}"* ]]; then
                mark="${G}*${RST}"; tag=""
            else
                mark="${D} ${RST}"; tag=" ${DIM}other${RST}"
            fi
            case "${A_PFX[$i]}" in
                128) pfx_fmt="${R}/128${RST} ${DIM}单${RST}" ;;
                64)  pfx_fmt="${G}/64${RST}  ${DIM}子网${RST}" ;;
                *)   pfx_fmt="${Y}/${A_PFX[$i]}${RST}" ;;
            esac
            printf "  ${D}%02d${RST} %b  ${W}%-40s${RST} %-22b ${DIM}%s${RST}%b\n" \
                "$n" "$mark" "${A_ADDR[$i]}" "$pfx_fmt" "${A_IFACE[$i]}" "$tag"
            ((n++))
        done
    fi
    echo ""
}

show_menu() {
    hr
    echo -e "  ${BD}${W}操 作${RST}"
    echo ""
    echo -e "  ${G}${BD}1${RST}  ${G}▸${RST} 添加地址"
    echo -e "  ${G}${BD}2${RST}  ${G}▸${RST} 自动生成随机 /128"
    echo -e "  ${R}${BD}3${RST}  ${R}▸${RST} 删除地址"
    echo -e "  ${Y}${BD}4${RST}  ${Y}▸${RST} 修改地址"
    echo -e "  ${C}${BD}5${RST}  ${C}▸${RST} 批量生成"
    echo -e "  ${B}${BD}6${RST}  ${B}▸${RST} 连通测试"
    echo ""
    echo -e "  ${Y}${BD}7${RST}  ${Y}▸${RST} 持久化到 interfaces"
    echo -e "  ${Y}${BD}8${RST}  ${Y}▸${RST} 应用持久化配置"
    echo ""
    echo -e "  ${M}${BD}9${RST}  ${M}▸${RST} 安装 v6 命令"
    echo -e "  ${B}${BD}s${RST}  ${B}▸${RST} 重新设置前缀"
    echo -e "  ${R}${BD}0${RST}  ${R}▸${RST} 退出"
    echo ""
    hr
    echo ""
}

# ═══════════ 操作实现 ═══════════
do_add() {
    echo -e "\n  ${BD}${G}添加地址${RST}  ${DIM}前缀 ${W}${PREFIX}${RST}\n"

    local addr
    read -rp "  输入地址（留空自动生成）: " addr

    if [[ -z "$addr" ]]; then
        addr=$(gen_rand)
        while is_dup "$addr"; do addr=$(gen_rand); done
        step "生成: ${W}${addr}${RST}"
    else
        # 补全前缀
        if [[ "$addr" != *:* ]]; then
            addr="${PREFIX%::}:${addr}"
        elif [[ "$addr" != "${PREFIX}"* && "$addr" != "${PREFIX%::}"* ]]; then
            # 输入的是后半段如 a:b:c:d
            local colons
            colons=$(echo "$addr" | tr -cd ':' | wc -c)
            if ((colons <= 3)); then
                addr="${PREFIX%::}:${addr}"
            fi
        fi
    fi

    echo ""
    echo -e "    ${R}1${RST} ${R}▸ /128${RST} ${DIM}单地址(默认)${RST}    ${G}2${RST} ${G}▸ /64${RST} ${DIM}子网${RST}"
    read -rp "  [1]: " p; p=${p:-1}
    local plen=128; [[ "$p" == "2" ]] && plen=64

    local full="${addr}/${plen}"
    is_dup "$addr" && { warn "地址已存在"; return; }

    step "添加 ${W}${full}${RST} ..."
    if ip -6 addr add "$full" dev "$IFACE" 2>/dev/null; then
        ok "已添加 ${BD}${full}${RST}"
    else
        warn "添加失败"
    fi
}

do_auto() {
    echo -e "\n  ${BD}${G}自动生成随机 /128${RST}\n"
    read -rp "  数量 [1]: " cnt; cnt=${cnt:-1}
    ((cnt < 1 || cnt > 100)) && { warn "1-100"; return; }

    echo ""
    local added=0
    for ((i = 0; i < cnt; i++)); do
        local addr=$(gen_rand)
        local t=0
        while is_dup "$addr" && ((t < 50)); do addr=$(gen_rand); ((t++)); done
        if ip -6 addr add "${addr}/128" dev "$IFACE" 2>/dev/null; then
            ok "${BD}${addr}/128${RST}"
            ((added++))
        fi
    done
    echo ""; ok "共 ${BD}${added}${RST} 个"
}

do_delete() {
    echo -e "\n  ${BD}${R}删除地址${RST}\n"
    [[ $total_all -eq 0 ]] && { warn "暂无地址"; return; }

    local n=1
    for i in "${!A_ADDR[@]}"; do
        printf "    ${R}%02d${RST}  ${R}▸${RST} ${W}%s/%s${RST} ${DIM}[%s]${RST}\n" \
            "$n" "${A_ADDR[$i]}" "${A_PFX[$i]}" "${A_IFACE[$i]}"
        ((n++))
    done

    echo ""
    read -rp "  序号（0取消 / all清空此前缀）: " sel
    [[ "$sel" == "0" || -z "$sel" ]] && { warn "已取消"; return; }

    if [[ "$sel" == "all" ]]; then
        read -rp "  ${R}确认删除此前缀全部？(y/N)${RST}: " c
        [[ "$c" != "y" ]] && { warn "已取消"; return; }
        local d=0
        for i in "${!A_ADDR[@]}"; do
            if [[ "${A_ADDR[$i]}:" == "${PREFIX}"* || "${A_ADDR[$i]}" == "${PREFIX%::}"* ]]; then
                ip -6 addr del "${A_ADDR[$i]}/${A_PFX[$i]}" dev "${A_IFACE[$i]}" 2>/dev/null && ((d++))
            fi
        done
        ok "已删除 ${BD}${d}${RST} 个"
        return
    fi

    ((sel < 1 || sel > total_all)) && { warn "无效"; return; }
    local idx=$((sel - 1))
    step "删除 ${W}${A_ADDR[$idx]}/${A_PFX[$idx]}${RST} ..."
    if ip -6 addr del "${A_ADDR[$idx]}/${A_PFX[$idx]}" dev "${A_IFACE[$idx]}" 2>/dev/null; then
        ok "已删除"
    else
        warn "删除失败"
    fi
}

do_edit() {
    echo -e "\n  ${BD}${Y}修改地址${RST}\n"
    [[ $total_all -eq 0 ]] && { warn "暂无"; return; }

    local n=1
    for i in "${!A_ADDR[@]}"; do
        printf "    ${Y}%02d${RST}  ${Y}▸${RST} ${W}%s/%s${RST}\n" \
            "$n" "${A_ADDR[$i]}" "${A_PFX[$i]}"
        ((n++))
    done

    echo ""
    read -rp "  序号（0取消）: " sel
    [[ "$sel" == "0" || -z "$sel" ]] && { warn "已取消"; return; }
    ((sel < 1 || sel > total_all)) && { warn "无效"; return; }

    local idx=$((sel - 1))
    local old="${A_ADDR[$idx]}" opfx="${A_PFX[$idx]}" oif="${A_IFACE[$idx]}"

    echo -e "\n  ${DIM}当前${RST}  ${W}${old}/${opfx}${RST}\n"
    echo -e "    ${Y}1${RST} ${Y}▸${RST} 替换地址"
    echo -e "    ${Y}2${RST} ${Y}▸${RST} 自动生成新地址替换"
    echo -e "    ${Y}3${RST} ${Y}▸${RST} 改前缀长度"
    read -rp "  选择: " op

    case "$op" in
        1)
            read -rp "  新地址: " nv; [[ -z "$nv" ]] && { warn "已取消"; return; }
            ip -6 addr del "${old}/${opfx}" dev "$oif" 2>/dev/null
            if ip -6 addr add "${nv}/${opfx}" dev "$oif" 2>/dev/null; then
                ok "替换: ${BD}${nv}/${opfx}${RST}"
            else
                warn "失败，回滚"; ip -6 addr add "${old}/${opfx}" dev "$oif" 2>/dev/null
            fi ;;
        2)
            local na=$(gen_rand)
            while is_dup "$na"; do na=$(gen_rand); done
            ip -6 addr del "${old}/${opfx}" dev "$oif" 2>/dev/null
            if ip -6 addr add "${na}/${opfx}" dev "$oif" 2>/dev/null; then
                ok "替换: ${BD}${old}${RST} → ${BD}${na}/${opfx}${RST}"
            else
                warn "失败，回滚"; ip -6 addr add "${old}/${opfx}" dev "$oif" 2>/dev/null
            fi ;;
        3)
            echo -e "    ${R}1${RST} ${R}▸ /128${RST}    ${G}2${RST} ${G}▸ /64${RST}"
            read -rp "  选择: " pc
            local np=128; [[ "$pc" == "2" ]] && np=64
            [[ "$np" == "$opfx" ]] && { ok "未变化"; return; }
            ip -6 addr del "${old}/${opfx}" dev "$oif" 2>/dev/null
            if ip -6 addr add "${old}/${np}" dev "$oif" 2>/dev/null; then
                ok "前缀: ${BD}/${opfx}${RST} → ${BD}/${np}${RST}"
            else
                warn "失败，回滚"; ip -6 addr add "${old}/${opfx}" dev "$oif" 2>/dev/null
            fi ;;
        *) warn "已取消" ;;
    esac
}

do_bulk() {
    echo -e "\n  ${BD}${C}批量生成${RST}\n"
    read -rp "  数量 [10]: " cnt; cnt=${cnt:-10}
    ((cnt < 1 || cnt > 500)) && { warn "1-500"; return; }
    echo -e "    ${R}1${RST} ${R}▸ /128${RST} ${DIM}(默认)${RST}    ${G}2${RST} ${G}▸ /64${RST}"
    read -rp "  [1]: " pc; pc=${pc:-1}
    local plen=128; [[ "$pc" == "2" ]] && plen=64

    echo ""
    local added=0
    for ((i = 0; i < cnt; i++)); do
        local addr=$(gen_rand)
        local t=0
        while is_dup "$addr" && ((t < 100)); do addr=$(gen_rand); ((t++)); done
        if ip -6 addr add "${addr}/${plen}" dev "$IFACE" 2>/dev/null; then
            ok "${BD}${addr}/${plen}${RST}"
            ((added++))
        fi
    done
    echo ""; ok "共 ${BD}${added}${RST} 个"
}

do_test() {
    echo -e "\n  ${BD}${B}连通测试${RST}\n"
    [[ $total_own -eq 0 ]] && { warn "此前缀暂无地址"; return; }
    local ok_c=0 fail_c=0
    for i in "${!O_ADDR[@]}"; do
        printf "  %-42s " "${O_ADDR[$i]}"
        if curl -6 -s --max-time 5 --interface "${O_ADDR[$i]}" -o /dev/null ifconfig.co 2>/dev/null; then
            echo -e "${G}${BD}online${RST}"; ((ok_c++))
        else
            echo -e "${R}offline${RST}"; ((fail_c++))
        fi
    done
    echo ""; ok "结果: ${G}${ok_c}${RST} 在线 / ${R}${fail_c}${RST} 离线"
}

do_persist() {
    echo -e "\n  ${BD}${Y}持久化到 interfaces${RST}\n"
    [[ $total_own -eq 0 ]] && { warn "暂无"; return; }

    echo -e "  ${DIM}写入${RST} ${W}${IFACES_FILE}${RST}\n"
    local n=1
    for i in "${!O_ADDR[@]}"; do
        printf "    ${G}%02d${RST} ${G}▸${RST} ${W}%s/%s${RST}\n" "$n" "${O_ADDR[$i]}" "${O_PFX[$i]}"
        ((n++))
    done
    echo ""
    echo -e "    ${BD}a${RST} ${G}▸${RST} 全部写入    ${BD}q${RST} ${R}▸${RST} 取消"
    read -rp "  选择: " sel
    [[ "$sel" == "q" || -z "$sel" ]] && { warn "已取消"; return; }

    if [[ ! -f "$IFACES_FILE" ]]; then
        cat > "$IFACES_FILE" <<EOF
auto lo
iface lo inet loopback

auto $IFACE
iface $IFACE inet dhcp
EOF
    fi

    cp "$IFACES_FILE" "${IFACES_FILE}.bak.v6mgr"
    step "已备份 ${W}${IFACES_FILE}.bak.v6mgr${RST}"

    local written=0
    write_entry() {
        local i=$1
        if grep -qF "${O_ADDR[$i]}" "$IFACES_FILE" 2>/dev/null; then
            warn "已存在: ${O_ADDR[$i]}/${O_PFX[$i]}"; return
        fi
        cat >> "$IFACES_FILE" <<EOF

iface $IFACE inet6 static
    address ${O_ADDR[$i]}/${O_PFX[$i]}
EOF
        ok "写入: ${BD}${O_ADDR[$i]}/${O_PFX[$i]}${RST}"
        ((written++))
    }

    if [[ "$sel" == "a" || "$sel" == "A" ]]; then
        for i in "${!O_ADDR[@]}"; do write_entry "$i"; done
    else
        ((sel < 1 || sel > total_own)) && { warn "无效"; return; }
        write_entry "$((sel - 1))"
    fi
    echo ""; ok "共 ${BD}${written}${RST} 个"
    echo -e "  ${DIM}执行 sudo systemctl restart networking 生效${RST}"
}

do_apply() {
    echo -e "\n  ${BD}${G}应用持久化${RST}\n"
    [[ ! -f "$IFACES_FILE" ]] && { warn "未找到 ${IFACES_FILE}"; return; }
    local cnt
    cnt=$(grep -c "inet6 static" "$IFACES_FILE" 2>/dev/null) || cnt=0
    echo -e "  ${DIM}文件${RST} ${W}${IFACES_FILE}${RST}  ${DIM}条目${RST} ${W}${cnt}${RST}\n"
    read -rp "  确认重启 networking？(y/N): " c
    [[ "$c" != "y" ]] && { warn "已取消"; return; }
    step "重启中 ..."
    systemctl restart networking 2>/dev/null && ok "已生效" || warn "失败，请检查配置"
}

do_install() {
    echo -e "\n  ${BD}${M}安装 v6 命令${RST}\n"
    local self=$(readlink -f "$0")
    local target="/usr/local/bin/${CMD_NAME}"
    [[ "$self" == "$target" ]] && { ok "已是最新"; return; }
    cp "$self" "$target" && chmod +x "$target"
    ok "已安装到 ${BD}${target}${RST}"
    echo -e "  ${DIM}现在任意位置运行 ${W}v6${DIM} 即可${RST}"
}

do_reset() {
    echo -e "\n  ${BD}${B}重新设置前缀${RST}\n"
    read -rp "  确认？(y/N): " c
    [[ "$c" != "y" ]] && { warn "已取消"; return; }
    rm -f "$CONF"
    setup_wizard
}

# ═══════════ 主循环 ═══════════
main() {
    check_root
    load_config

    trap 'echo -e "\n  ${G}✔${RST} 已退出\n"' EXIT INT

    while true; do
        load_addresses
        show_header
        show_list
        show_menu
        read -rp "  [0-9/s]: " ch
        echo ""
        case "${ch:-}" in
            1) do_add ;;
            2) do_auto ;;
            3) do_delete ;;
            4) do_edit ;;
            5) do_bulk ;;
            6) do_test ;;
            7) do_persist ;;
            8) do_apply ;;
            9) do_install ;;
            s|S) do_reset ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
        pause
    done
}

main "$@"
