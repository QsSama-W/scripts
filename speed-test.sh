#!/bin/sh
# ============================================================
#  多区域网络下载速度测试
#  节点覆盖: 欧洲 / 北美 / 亚太
#  兼容 Debian/Ubuntu & Alpine Linux
#  支持选择测试文件大小: 10MB / 50MB / 100MB / 全部
#  测完自动删除脚本自身
# ============================================================

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
    echo -e "  ${YELLOW}[!]${NC} 未找到 curl，正在安装..."
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

# --- 测完删除脚本自身 ---
cleanup() {
    local sp
    sp=$(readlink -f "$0" 2>/dev/null || echo "$0")
    [ -f "$sp" ] && rm -f "$sp" && echo -e "  ${DIM}测试脚本已自动删除${NC}"
}
trap cleanup EXIT

# --- 构建各节点的下载 URL ---
# $1 = 文件大小编号 (10/50/100)
build_urls() {
    local size="$1"
    # 输出格式: 节点名|主URL|备用URL  每行一个
    echo "Tele2 瑞典 (Stockholm)|http://speedtest.tele2.net/${size}MB.zip|https://speedtest.tele2.net/${size}MB.zip"
    echo "Hetzner 德国 (Falkenstein)|http://speed.hetzner.de/${size}MB.bin|https://speed.hetzner.de/${size}MB.bin"
    echo "OVH 美国 (Virginia)|http://proof.ovh.us/files/${size}Mb.dat|https://proof.ovh.us/files/${size}Mb.dat"
    echo "OVH 加拿大 (Beauharnois)|http://proof.ovh.ca/files/${size}Mb.dat|https://proof.ovh.ca/files/${size}Mb.dat"
    echo "OVH 新加坡 (Singapore)|http://proof.ovh.sg/files/${size}Mb.dat|https://proof.ovh.sg/files/${size}Mb.dat"
    echo "Clouvider 日本 (Tokyo)|http://nrt.speedtest.clouvider.net/${size}mb.bin|https://nrt.speedtest.clouvider.net/${size}mb.bin"
}

# --- 单次下载测试 ---
dl_test() {
    local name="$1" url="$2" alt="$3"

    for u in "$url" "$alt"; do
        [ -z "$u" ] && continue

        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 8 --max-time 12 -L -f "$u" 2>/dev/null)

        [ "$http_code" != "200" ] && continue

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

        printf "    ${BOLD}%-32s${NC} ${GREEN}%-12s${NC} %s  (%s / %ss)\n" \
            "$name" "$(fmt_speed "$v")" "$(fmt_mbps "$v") Mbps" \
            "$(fmt_bytes "$s")" "$t"
        return 0
    done

    printf "    ${BOLD}%-32s${NC} ${RED}%-12s${NC}\n" "$name" "失败"
    return 1
}

# --- 执行一轮测试 ---
# $1 = 文件大小编号
run_round() {
    local size="$1"
    local size_label
    case "$size" in
        10)  size_label="10 MB（快速测试）" ;;
        50)  size_label="50 MB（标准测试）" ;;
        100) size_label="100 MB（精确测试）" ;;
    esac

    local pass=0 fail_count=0

    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}          ${BOLD}多区域网络下载速度测试${NC}                         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${DIM}节点覆盖: 欧洲 / 北美 / 亚太${NC}                           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${DIM}测试文件: 每节点 ${size_label}${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"

    # ---- 欧洲 ----
    echo ""
    echo -e "${BOLD}━━━ 欧洲节点 (Europe) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    dl_test "Tele2 瑞典 (Stockholm)" \
        "http://speedtest.tele2.net/${size}MB.zip" \
        "https://speedtest.tele2.net/${size}MB.zip" \
        && pass=$((pass+1)) || fail_count=$((fail_count+1))

    dl_test "Hetzner 德国 (Falkenstein)" \
        "http://speed.hetzner.de/${size}MB.bin" \
        "https://speed.hetzner.de/${size}MB.bin" \
        && pass=$((pass+1)) || fail_count=$((fail_count+1))

    # ---- 北美 ----
    echo ""
    echo -e "${BOLD}━━━ 北美节点 (North America) ━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    dl_test "OVH 美国 (Virginia)" \
        "http://proof.ovh.us/files/${size}Mb.dat" \
        "https://proof.ovh.us/files/${size}Mb.dat" \
        && pass=$((pass+1)) || fail_count=$((fail_count+1))

    dl_test "OVH 加拿大 (Beauharnois)" \
        "http://proof.ovh.ca/files/${size}Mb.dat" \
        "https://proof.ovh.ca/files/${size}Mb.dat" \
        && pass=$((pass+1)) || fail_count=$((fail_count+1))

    # ---- 亚太 ----
    echo ""
    echo -e "${BOLD}━━━ 亚太节点 (Asia-Pacific) ━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    dl_test "OVH 新加坡 (Singapore)" \
        "http://proof.ovh.sg/files/${size}Mb.dat" \
        "https://proof.ovh.sg/files/${size}Mb.dat" \
        && pass=$((pass+1)) || fail_count=$((fail_count+1))

    dl_test "Clouvider 日本 (Tokyo)" \
        "http://nrt.speedtest.clouvider.net/${size}mb.bin" \
        "https://nrt.speedtest.clouvider.net/${size}mb.bin" \
        && pass=$((pass+1)) || fail_count=$((fail_count+1))

    echo ""
    echo -e "${DIM}──────────────────────────────────────────────${NC}"
    echo -e "  成功: ${GREEN}${pass}${NC}  |  失败: ${RED}${fail_count}${NC}"
    echo -e "${DIM}──────────────────────────────────────────────${NC}"

    # 返回值: 0=全部成功, 1=有失败
    [ "$fail_count" -gt 0 ] && return 1
    return 0
}

# ================================================================
#  主程序
# ================================================================

# ---- 标题 ----
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}          ${BOLD}多区域网络下载速度测试${NC}                         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     ${DIM}节点覆盖: 欧洲 / 北美 / 亚太${NC}                           ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     ${DIM}测试完成后自动删除脚本${NC}                                 ${CYAN}║${NC}"
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
curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "（获取失败）"
echo ""

# ---- 依赖 ----
echo ""
echo -e "${BOLD}依赖检查${NC}"
echo -e "${DIM}──────────────────────────────────────────────${NC}"
ensure_curl
echo ""

# ---- 选择测试文件大小 ----
echo -e "${BOLD}请选择测试文件大小${NC}"
echo -e "${DIM}──────────────────────────────────────────────${NC}"
echo ""
echo -e "  ${BOLD}1${NC}) ${GREEN}10 MB${NC}   — 快速测试，几十秒完成"
echo -e "  ${BOLD}2${NC}) ${YELLOW}50 MB${NC}   — 标准测试，结果较准确"
echo -e "  ${BOLD}3${NC}) ${CYAN}100 MB${NC}  — 精确测试，最接近真实带宽"
echo -e "  ${BOLD}4${NC}) ${BOLD}全部测试${NC} — 10M + 50M + 100M 依次测试"
echo ""

# 读取用户输入（兼容 sh）
printf "  请输入选项 [1-4]: "
read -r choice

case "$choice" in
    1) SIZES="10" ;;
    2) SIZES="50" ;;
    3) SIZES="100" ;;
    4) SIZES="10 50 100" ;;
    *)
        echo ""
        echo -e "  ${RED}无效选项，默认使用 100MB 测试${NC}"
        SIZES="100"
        ;;
esac

echo ""

# ---- 执行测试 ----
TOTAL_PASS=0; TOTAL_FAIL=0

for sz in $SIZES; do
    run_round "$sz"
    # 累计统计
    echo ""
done

# ---- 结果解读 ----
echo -e "${DIM}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}结果解读:${NC}"
echo -e "  ${DIM}1. 同区域多节点速度接近  → 该方向链路稳定${NC}"
echo -e "  ${DIM}2. 欧洲远快于其他区域    → 服务器在欧洲${NC}"
echo -e "  ${DIM}3. 亚太明显慢            → 跨欧亚链路延迟高${NC}"
echo -e "  ${DIM}4. 100M 测试结果最接近真实带宽${NC}"
echo ""
echo -e "  ${BOLD}节点失败说明:${NC}"
echo -e "  ${DIM}• 失败不代表网络有问题，可能是测试服务器本身不可达${NC}"
echo -e "  ${DIM}• 公共测速节点无 SLA 保证，偶尔不可用是正常的${NC}"
echo -e "  ${DIM}• 只要有任一节点成功，就能说明对应方向的链路情况${NC}"
echo ""
echo -e "  ${BOLD}测速提示:${NC}"
echo -e "  ${DIM}• 带宽换算: 1 MB/s = 8 Mbps（乘以 8）${NC}"
echo -e "  ${DIM}• 例如显示 12.50 MB/s → 实际带宽 100 Mbps${NC}"
echo ""