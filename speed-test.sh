#!/bin/sh
# ============================================================
#  多区域网络下载速度测试
#  测试节点覆盖: 欧洲 / 北美 / 亚太
#  兼容 Debian/Ubuntu & Alpine Linux
# ============================================================

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[√]${NC} $1"; }
fail() { echo -e "  ${RED}[×]${NC} $1"; }

fmt_speed() {
    awk "BEGIN{
        b=$1+0
        if(b>=1073741824) printf \"%.2f GB/s\", b/1073741824
        else if(b>=1048576) printf \"%.2f MB/s\", b/1048576
        else if(b>=1024) printf \"%.2f KB/s\", b/1024
        else printf \"%.0f B/s\", b
    }"
}

fmt_bytes() {
    awk "BEGIN{
        b=$1+0
        if(b>=1073741824) printf \"%.2f GB\", b/1073741824
        else if(b>=1048576) printf \"%.2f MB\", b/1048576
        else if(b>=1024) printf \"%.2f KB\", b/1024
        else printf \"%.0f B\", b
    }"
}

fmt_mbps() {
    awk "BEGIN{ printf \"%.1f\", $1 * 8 / 1000000 }"
}

# --- 安装 curl ---
ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        ok "已检测到 curl $(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
        return 0
    fi
    echo -e "  ${YELLOW}[!]${NC} 未找到 curl，正在自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl >/dev/null 2>&1
    else
        fail "无法识别包管理器，请手动安装 curl"
        exit 1
    fi
    command -v curl >/dev/null 2>&1 && ok "curl 安装成功" || { fail "curl 安装失败"; exit 1; }
}

# --- 单次下载测试 ---
# 参数: $1=名称 $2=主地址 $3=备用地址
dl_test() {
    local name="$1" url="$2" alt="$3"

    for u in "$url" "$alt"; do
        [ -z "$u" ] && continue

        local r
        r=$(curl -o /dev/null -sS \
            -w "%{time_total} %{size_download} %{speed_download}" \
            --connect-timeout 10 --max-time 300 -L -f "$u" 2>&1)

        [ $? -ne 0 ] || [ -z "$r" ] && continue

        local t s v
        t=$(echo "$r" | awk '{print $1}')
        s=$(echo "$r" | awk '{print $2}')
        v=$(echo "$r" | awk '{print $3}')

        [ -z "$t" ] || [ "$t" = "0" ] || [ "$t" = "0.000000" ] && continue
        [ -z "$v" ] || [ "$v" = "0" ] && continue

        printf "    ${BOLD}%-34s${NC} ${GREEN}%-12s${NC} %s  (%s / %ss)\n" \
            "$name" "$(fmt_speed "$v")" "$(fmt_mbps "$v") Mbps" \
            "$(fmt_bytes "$s")" "$t"
        return 0
    done

    printf "    ${BOLD}%-34s${NC} ${RED}%-12s${NC}\n" "$name" "失败"
    return 1
}

# ================================================================
#  主程序
# ================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}          ${BOLD}多区域网络下载速度测试${NC}                         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     ${DIM}测试节点覆盖: 欧洲 / 北美 / 亚太${NC}                     ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     ${DIM}每个节点下载 100MB 文件${NC}                             ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# ---- 系统信息 ----
echo -e "${BOLD}系统信息${NC}"
echo -e "${DIM}──────────────────────────────────────────────${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "  操作系统 : ${PRETTY_NAME:-${NAME:-未知} ${VERSION_ID:-}}"
else
    echo -e "  操作系统 : $(uname -srm)"
fi
echo -e "  内核版本 : $(uname -r)"
echo -ne "  公网 IP  : "
MYIP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
echo "${MYIP:-（获取失败）}"
echo ""

# ---- 依赖 ----
echo -e "${BOLD}依赖检查${NC}"
echo -e "${DIM}──────────────────────────────────────────────${NC}"
ensure_curl
echo ""

PASS=0; FAIL=0

# ======================== 欧洲 (2/4) ========================
echo -e "${BOLD}━━━ 欧洲节点 (Europe) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${DIM}节点位于欧洲，测试到欧洲方向的带宽${NC}"
echo ""

dl_test "Hetzner 德国 (Falkenstein)" \
    "https://speed.hetzner.de/100MB.bin" \
    "http://speed.hetzner.de/100MB.bin" \
    && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

dl_test "Tele2 欧洲 (Anycast 多地)" \
    "http://speedtest.tele2.net/100MB.zip" \
    "https://speedtest.tele2.net/100MB.zip" \
    && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ""

# ======================== 北美 (3/4) ========================
echo -e "${BOLD}━━━ 北美节点 (North America) ━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${DIM}节点位于加拿大魁北克，测试跨大西洋链路${NC}"
echo ""

dl_test "OVH 加拿大 (Beauharnois, QC)" \
    "http://proof.ovh.ca/files/100Mb.dat" \
    "https://proof.ovh.ca/files/100Mb.dat" \
    && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ""

# ======================== 亚太 (4/4) ========================
echo -e "${BOLD}━━━ 亚太节点 (Asia-Pacific) ━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${DIM}节点位于新加坡，测试到亚太方向的链路${NC}"
echo ""

dl_test "OVH 新加坡 (Singapore)" \
    "http://proof.ovh.sg/files/100Mb.dat" \
    "https://proof.ovh.sg/files/100Mb.dat" \
    && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ""

# ======================== 汇总 ========================
echo -e "${DIM}──────────────────────────────────────────────${NC}"
echo -e "  完成: ${GREEN}${PASS}${NC} 个成功  |  失败: ${RED}${FAIL}${NC} 个"
echo -e "${DIM}──────────────────────────────────────────────${NC}"
echo -e ""
echo -e "  ${BOLD}结果解读:${NC}"
echo -e "  ${DIM}1. 同区域多节点速度接近 → 该方向链路稳定${NC}"
echo -e "  ${DIM}2. 欧洲速度远快于其他区域 → 服务器位于欧洲${NC}"
echo -e "  ${DIM}3. 北美/亚太速度差异大 → 国际出口带宽有限${NC}"
echo -e "  ${DIM}4. 所有区域速度接近 → 优质国际线路${NC}"
echo -e ""
echo -e "  ${DIM}注: 测试为 服务器→远程节点 方向下载，反映双向链路质量${NC}"
echo -e "  ${DIM}注: 100MB 文件可让 TCP 窗口充分打开，结果最接近真实带宽${NC}"
echo -e "  ${DIM}注: 亚太节点如失败不影响其他区域，可改用 iperf3 补充测试${NC}"
echo ""