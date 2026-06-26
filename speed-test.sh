#!/bin/sh
# ============================================
# Network Download Speed Test
# Compatible with Debian/Ubuntu & Alpine Linux
# ============================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Helpers ---
info()  { echo -e "  ${CYAN}[i]${NC} $1"; }
ok()    { echo -e "  ${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "  ${YELLOW}[!]${NC} $1"; }
fail()  { echo -e "  ${RED}[✗]${NC} $1"; }

# --- Format bytes/s -> human readable ---
format_speed() {
    awk "BEGIN {
        bps = $1 + 0
        if (bps >= 1073741824) printf \"%.2f GB/s\", bps / 1073741824
        else if (bps >= 1048576) printf \"%.2f MB/s\", bps / 1048576
        else if (bps >= 1024) printf \"%.2f KB/s\", bps / 1024
        else printf \"%.0f B/s\", bps
    }"
}

# --- Format bytes -> human readable ---
format_bytes() {
    awk "BEGIN {
        b = $1 + 0
        if (b >= 1073741824) printf \"%.2f GB\", b / 1073741824
        else if (b >= 1048576) printf \"%.2f MB\", b / 1048576
        else if (b >= 1024) printf \"%.2f KB\", b / 1024
        else printf \"%.0f B\", b
    }"
}

# --- Install curl if missing ---
ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        local ver
        ver=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')
        ok "curl ${ver} found"
        return 0
    fi

    warn "curl not found, attempting to install..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl >/dev/null 2>&1
    else
        fail "Cannot detect package manager (apt/apk). Please install curl manually."
        exit 1
    fi

    if command -v curl >/dev/null 2>&1; then
        ok "curl installed successfully"
    else
        fail "Failed to install curl"
        exit 1
    fi
}

# --- Single download test ---
# $1 = label, $2 = primary url, $3 = fallback url
test_download() {
    local label="$1"
    local url="$2"
    local fallback="$3"

    echo ""
    echo -e "  ${BOLD}▸ Test: ${label}${NC}"

    # Try primary URL first, fallback if it fails
    for mirror in "$url" "$fallback"; do
        [ -z "$mirror" ] && continue

        echo -e "    ${DIM}Source: ${mirror}${NC}"
        echo -ne "    Downloading... "

        local result
        result=$(curl -o /dev/null -s -S \
            -w "%{time_total} %{size_download} %{speed_download}" \
            --connect-timeout 10 \
            --max-time 180 \
            -L -f "$mirror" 2>&1)

        local curl_exit=$?

        if [ $curl_exit -ne 0 ] || [ -z "$result" ]; then
            echo -e "${RED}FAILED${NC}"
            warn "Mirror unreachable, trying next..."
            continue
        fi

        local time_total size_bytes speed_bps
        time_total=$(echo "$result" | awk '{print $1}')
        size_bytes=$(echo "$result" | awk '{print $2}')
        speed_bps=$(echo "$result"  | awk '{print $3}')

        # Validate
        if [ -z "$time_total" ] || [ "$time_total" = "0" ] || [ "$time_total" = "0.000000" ]; then
            echo -e "${RED}FAILED${NC}"
            warn "Invalid timing data, trying next mirror..."
            continue
        fi

        if [ -z "$speed_bps" ] || [ "$speed_bps" = "0" ]; then
            echo -e "${RED}FAILED${NC}"
            warn "No data received, trying next mirror..."
            continue
        fi

        local size_display speed_display
        size_display=$(format_bytes "$size_bytes")
        speed_display=$(format_speed "$speed_bps")

        echo -e "${GREEN}Done${NC}"
        echo -e "    Downloaded : ${BOLD}${size_display}${NC} in ${BOLD}${time_total}s${NC}"
        echo -e "    Speed      : ${GREEN}${BOLD}${speed_display}${NC}"
        return 0
    done

    fail "All mirrors failed for ${label}"
    return 1
}

# ============================================================
#  Main
# ============================================================
echo ""
echo -e "${CYAN}┌──────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│${NC}          ${BOLD}Network Download Speed Test${NC}              ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}        ${DIM}Debian / Alpine Compatible${NC}                  ${CYAN}│${NC}"
echo -e "${CYAN}└──────────────────────────────────────────────┘${NC}"
echo ""

# ---- System Info ----
echo -e "${BOLD}System Information${NC}"
echo -e "${DIM}──────────────────────────────────────────────${NC}"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo -e "  OS     : ${PRETTY_NAME:-${NAME:-Unknown} ${VERSION_ID:-}}"
else
    echo -e "  OS     : $(uname -srm)"
fi
echo -e "  Kernel : $(uname -r)"
echo -e "  Host   : $(hostname 2>/dev/null || echo 'unknown')"

echo -ne "  Public : "
curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "(unable to retrieve)"

echo ""
echo ""

# ---- Dependencies ----
echo -e "${BOLD}Dependencies${NC}"
echo -e "${DIM}──────────────────────────────────────────────${NC}"
ensure_curl

echo ""
echo ""

# ---- Speed Tests ----
echo -e "${BOLD}Download Speed Tests${NC}"
echo -e "${DIM}──────────────────────────────────────────────${NC}"

# 10 MB test
test_download "10 MB" \
    "http://speedtest.tele2.net/10MB.zip" \
    "https://speed.hetzner.de/10MB.bin"

# 50 MB test
test_download "50 MB" \
    "http://speedtest.tele2.net/50MB.zip" \
    "https://speed.hetzner.de/50MB.bin"

echo ""
echo -e "${DIM}──────────────────────────────────────────────${NC}"
echo -e "${DIM}Note: Actual speed depends on network path, server load,${NC}"
echo -e "${DIM}and time of day. Results show download throughput only.${NC}"
echo ""