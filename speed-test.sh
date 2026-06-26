#!/bin/sh
# ============================================================
#  多区域网络下载速度测试
#  档位: 10MB / 100MB / 1GB
#  节点: Cloudflare / Hetzner / DataPacket / Tele2 / OVH
#  兼容 Debian/Ubuntu & Alpine Linux
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

fmt_speed() {
    awk "BEGIN{ b=$1+0; if(b>=1073741824) printf \"%.2f GB/s\",b/1073741824; else if(b>=1048576) printf \"%.2f MB/s\",b/1048576; else if(b>=1024) printf \"%.2f KB/s\",b/1024; else printf \"%.0f B/s\",b }"
}
fmt_bytes() {
    awk "BEGIN{ b=$1+0; if(b>=1073741824) printf \"%.2f GB\",b/1073741824; else if(b>=1048576) printf \"%.2f MB\",b/1048576; else if(b>=1024) printf \"%.2f KB\",b/1024; else printf \"%.0f B\",b }"
}
fmt_mbps() {
    awk "BEGIN{ printf \"%.1f\",$1*8/1000000 }"
}

ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        echo -e "  ${GREEN}[√]${NC} curl $(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
        return
    fi
    echo -e "  ${YELLOW}[!]${NC} 未找到 curl，正在安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl >/dev/null 2>&1
    fi
    command -v curl >/dev/null 2>&1 && echo -e "  ${GREEN}[√]${NC} curl 已安装" || { echo -e "  ${RED}[×]${NC} 安装失败"; exit 1; }
}

dl_test() {
    local name="$1" url="$2"
    local r
    r=$(curl -o /dev/null -sS -w "%{time_total} %{size_download} %{speed_download}" \
        --connect-timeout 10 --max-time 600 -L -f "$url" 2>&1)
    if [ $? -ne 0 ] || [ -z "$r" ]; then
        printf "    ${BOLD}%-36s${NC} ${RED}失败${NC}\n" "$name"; return 1
    fi
    local t s v
    t=$(echo "$r"|awk '{print $1}'); s=$(echo "$r"|awk '{print $2}'); v=$(echo "$r"|awk '{print $3}')
    if [ -z "$t" ] || [ "$t" = "0" ] || [ "$t" = "0.000000" ] || [ -z "$v" ] || [ "$v" = "0" ]; then
        printf "    ${BOLD}%-36s${NC} ${RED}失败${NC}\n" "$name"; return 1
    fi
    printf "    ${BOLD}%-36s${NC} ${GREEN}%-12s${NC} %s  (%s / %ss)\n" \
        "$name" "$(fmt_speed "$v")" "$(fmt_mbps "$v") Mbps" "$(fmt_bytes "$s")" "$t"
}

run_round() {
    local mb="$1" cf_bytes="$2"
    local pass=0 fail=0

    echo ""
    echo -e "${CYAN}===[ ${BOLD}测试文件: ${mb} MB${NC}${CYAN} ]===${NC}"

    echo -e "\n  ${BOLD}基准${NC}"
    echo -e "  ${DIM}──────────────────────────────────${NC}"
    dl_test "Cloudflare (全球最近节点)" \
        "https://speed.cloudflare.com/__down?bytes=${cf_bytes}" \
        && pass=$((pass+1)) || fail=$((fail+1))

    echo -e "\n  ${BOLD}欧洲 (Europe)${NC}"
    echo -e "  ${DIM}──────────────────────────────────${NC}"
    dl_test "Hetzner 德国纽伦堡" \
        "http://speed.hetzner.de/${mb}MB.bin" \
        && pass=$((pass+1)) || fail=$((fail+1))
    dl_test "Tele2 瑞典 Stockholm" \
        "http://speedtest.tele2.net/${mb}MB.zip" \
        && pass=$((pass+1)) || fail=$((fail+1))
    dl_test "DataPacket 法国巴黎" \
        "http://par.download.datapacket.com/${mb}mb.bin" \
        && pass=$((pass+1)) || fail=$((fail+1))

    echo -e "\n  ${BOLD}北美 (North America)${NC}"
    echo -e "  ${DIM}──────────────────────────────────${NC}"
    dl_test "OVH 美西俄勒冈" \
        "https://proof.ovh.us/files/${mb}Mb.dat" \
        && pass=$((pass+1)) || fail=$((fail+1))
    dl_test "DataPacket 美西洛杉矶" \
        "http://lax.download.datapacket.com/${mb}mb.bin" \
        && pass=$((pass+1)) || fail=$((fail+1))
    dl_test "DataPacket 美东阿什本" \
        "http://ash.download.datapacket.com/${mb}mb.bin" \
        && pass=$((pass+1)) || fail=$((fail+1))

    echo -e "\n  ${BOLD}亚太 (Asia-Pacific)${NC}"
    echo -e "  ${DIM}──────────────────────────────────${NC}"
    dl_test "DataPacket 新加坡" \
        "http://sgp.download.datapacket.com/${mb}mb.bin" \
        && pass=$((pass+1)) || fail=$((fail+1))
    dl_test "DataPacket 日本东京" \
        "http://tyo.download.datapacket.com/${mb}mb.bin" \
        && pass=$((pass+1)) || fail=$((fail+1))
    dl_test "DataPacket 香港" \
        "http://hkg.download.datapacket.com/${mb}mb.bin" \
        && pass=$((pass+1)) || fail=$((fail+1))

    echo ""
    echo -e "  ${DIM}本轮: ${GREEN}${pass} 成功${NC}  ${DIM}${fail} 失败${NC}"
}

# ================================================================
#  主程序
# ================================================================

echo ""
echo -e "${BOLD}===== 多区域网络下载速度测试 =====${NC}"
echo -e "${DIM}节点: Cloudflare / Hetzner / DataPacket / Tele2 / OVH${NC}"
echo -e "${DIM}区域: 欧洲 · 北美 · 亚太    档位: 10 / 100 / 1000 MB${NC}"

echo -e "\n${BOLD}系统信息${NC}"
echo -e "${DIM}──────────────────────────────────────────${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "  系统 : ${PRETTY_NAME:-${NAME:-未知} ${VERSION_ID:-}}"
fi
echo -e "  内核 : $(uname -r)"
echo -ne "  IP   : "; curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "(获取失败)"
echo ""

echo -e "${BOLD}依赖检查${NC}"
echo -e "${DIM}──────────────────────────────────────────${NC}"
ensure_curl
echo ""

echo -e "${BOLD}选择测试档位${NC}"
echo -e "${DIM}──────────────────────────────────────────${NC}"
echo ""
echo -e "  ${BOLD}1${NC})  ${GREEN}10 MB${NC}     快速测试，几秒~几十秒完成"
echo -e "  ${BOLD}2${NC})  ${YELLOW}100 MB${NC}    标准测试，各节点均有文件"
echo -e "  ${BOLD}3${NC})  ${CYAN}1 GB${NC}      精确测试，最接近真实带宽"
echo -e "  ${BOLD}4${NC})  ${BOLD}全部测试${NC}   10M -> 100M -> 1G 依次测试"
echo ""
printf "  请输入选项 [1-4]: "
read -r choice

case "$choice" in
    1) ROUNDS="10" ;;
    2) ROUNDS="100" ;;
    3) ROUNDS="1000" ;;
    4) ROUNDS="10 100 1000" ;;
    *) echo -e "\n  ${YELLOW}无效选项，默认 100MB${NC}"; ROUNDS="100" ;;
esac

for mb in $ROUNDS; do
    case "$mb" in
        10)   run_round 10 10485760 ;;
        100)  run_round 100 104857600 ;;
        1000) run_round 1000 1073741824 ;;
    esac
done

echo ""
echo -e "${CYAN}=====================================${NC}"
echo -e "  ${BOLD}换算${NC}: 1 MB/s = 8 Mbps (例: 12.5 MB/s = 100 Mbps)"
echo -e "  ${BOLD}规律${NC}: 同方向多节点速度一致 -> 链路稳定"
echo -e "        欧洲快 / 亚太慢 -> 服务器在欧洲方向"
echo -e "        1GB 结果最接近真实带宽"
echo ""