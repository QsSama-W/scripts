#!/bin/sh
# 一键脚本管理器 - 自动从仓库拉取最新脚本列表
# 用法: sh menu.sh

# 清屏
clear 2>/dev/null || printf '\033[2J\033[H'

# 清理函数
cleanup() {
    rm -f /tmp/menu.sh
    rm -f "${SCRIPTS_DIR}/README.md" "${SCRIPTS_DIR}/names.txt" "${SCRIPTS_DIR}/descs.txt"
    rm -f "${SCRIPTS_DIR}/${SELECTED}" 2>/dev/null
}
trap cleanup EXIT

REPO_RAW="https://raw.githubusercontent.com/QsSama-W/scripts/main"
README_URL="${REPO_RAW}/README.md"
SCRIPTS_DIR="/tmp/qs-scripts"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 创建临时目录
mkdir -p "$SCRIPTS_DIR"

echo -e "${CYAN}${BOLD}========================================${NC}"
echo -e "${CYAN}${BOLD}    脚本一键管理器 - 自动同步最新版本${NC}"
echo -e "${CYAN}${BOLD}========================================${NC}"
echo ""

# 拉取最新 README
echo -ne "${YELLOW}正在拉取最新脚本列表...${NC}"
if ! wget -q -O "${SCRIPTS_DIR}/README.md" "${README_URL}?t=${RANDOM}" 2>/dev/null; then
    echo -e "${RED} 失败！${NC}"
    echo -e "${RED}无法连接到 GitHub，请检查网络。${NC}"
    exit 1
fi
echo -e "${GREEN} 完成！${NC}"
echo ""

# 解析 README 提取脚本名和描述
> "${SCRIPTS_DIR}/names.txt"
> "${SCRIPTS_DIR}/descs.txt"

# 用 awk 一次性完成过滤和解析
awk -F'|' '/\| `.*\.sh` \|/ && !/---/ {
    gsub(/^[ \t]+|[ \t]+$/, "", $2)
    gsub(/`/, "", $2)
    gsub(/^[ \t]+|[ \t]+$/, "", $3)
    if ($2 != "") {
        print $2 > "'${SCRIPTS_DIR}/names.txt'"
        print $3 > "'${SCRIPTS_DIR}/descs.txt'"
    }
}' "${SCRIPTS_DIR}/README.md"

COUNT=$(wc -l < "${SCRIPTS_DIR}/names.txt" | tr -d ' ')

# 如果没解析到脚本，可能格式变了
if [ "$COUNT" -eq 0 ]; then
    echo -e "${RED}未能解析到脚本列表，README 格式可能已变更。${NC}"
    exit 1
fi

echo -e "${GREEN}共发现 ${COUNT} 个脚本:${NC}"
echo ""

# 显示菜单
echo -e "${BOLD}========================================${NC}"
IDX=1
while IFS= read -r name; do
    desc=$(sed -n "${IDX}p" "${SCRIPTS_DIR}/descs.txt")
    printf "  ${GREEN}%2d${NC}. %-35s ${YELLOW}%s${NC}\n" "$IDX" "$name" "$desc"
    IDX=$((IDX + 1))
done < "${SCRIPTS_DIR}/names.txt"
echo ""
echo -e "  ${RED} 0${NC}. 退出"
echo -e "${BOLD}========================================${NC}"
echo ""

# 用户选择
printf "请输入编号 [0-%d]: " "$COUNT"
read choice

# 验证输入
case "$choice" in
    ''|*[!0-9]*)
        echo -e "${RED}输入无效，请输入数字。${NC}"
        exit 1
        ;;
esac

if [ "$choice" -eq 0 ]; then
    echo "已退出。"
    exit 0
fi

if [ "$choice" -lt 1 ] || [ "$choice" -gt "$COUNT" ]; then
    echo -e "${RED}编号超出范围，请重新运行。${NC}"
    exit 1
fi

# 获取选中的脚本
SELECTED=$(sed -n "${choice}p" "${SCRIPTS_DIR}/names.txt")
SCRIPT_URL="${REPO_RAW}/${SELECTED}?t=${RANDOM}"

echo ""
echo -e "${CYAN}正在下载 ${BOLD}${SELECTED}${NC}${CYAN} ...${NC}"

# 下载脚本
TARGET="${SCRIPTS_DIR}/${SELECTED}"
if ! wget -q -O "$TARGET" "$SCRIPT_URL" 2>/dev/null; then
    echo -e "${RED}下载失败！${NC}"
    exit 1
fi

echo -e "${GREEN}下载完成！${NC}"
echo -e "${CYAN}正在执行 ${BOLD}${SELECTED}${NC}${CYAN} ...${NC}"
echo ""

# 执行脚本
sh "$TARGET"
