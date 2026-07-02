#!/bin/bash
# 一键脚本管理器 - 自动从仓库拉取最新脚本列表
# 用法: bash menu.sh

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

# 检查 bash
if ! command -v bash &>/dev/null; then
    echo -e "${RED}错误: 缺少 bash${NC}"
    exit 1
fi

# 确定下载工具：优先 curl，其次 wget
DOWNLOADER=""
if command -v curl &>/dev/null; then
    DOWNLOADER="curl"
elif command -v wget &>/dev/null; then
    DOWNLOADER="wget"
else
    echo -e "${RED}错误: 缺少下载工具，请安装 curl 或 wget${NC}"
    echo -e "Debian: apt install -y curl"
    echo -e "Alpine: apk add curl"
    exit 1
fi

# 创建临时目录
mkdir -p "$SCRIPTS_DIR"

echo -e "${CYAN}${BOLD}========================================${NC}"
echo -e "${CYAN}${BOLD}    脚本一键管理器 - 自动同步最新版本${NC}"
echo -e "${CYAN}${BOLD}========================================${NC}"
echo ""

# 拉取最新 README
echo -ne "${YELLOW}正在拉取最新脚本列表...${NC}"
if [ "$DOWNLOADER" = "curl" ]; then
    if ! curl -sL -o "${SCRIPTS_DIR}/README.md" "${README_URL}?t=${RANDOM}" 2>/dev/null; then
        echo -e "${RED} 失败！${NC}"
        echo -e "${RED}无法连接到 GitHub，请检查网络。${NC}"
        exit 1
    fi
else
    if ! wget -q -O "${SCRIPTS_DIR}/README.md" "${README_URL}?t=${RANDOM}" 2>/dev/null; then
        echo -e "${RED} 失败！${NC}"
        echo -e "${RED}无法连接到 GitHub，请检查网络。${NC}"
        exit 1
    fi
fi
echo -e "${GREEN} 完成！${NC}"
echo ""

# 解析 README 提取脚本名和描述
# 格式: | `script.sh` | 描述 |
declare -a SCRIPT_NAMES=()
declare -a SCRIPT_DESCS=()

while IFS= read -r line; do
    # 匹配表格行中的脚本行（以 | 开头，包含 `.sh` 且不在表头分隔行）
    if [[ "$line" =~ ^\|[[:space:]]*\`(.*\.sh)\`[[:space:]]*\|[[:space:]]*(.*)\|[[:space:]]*$ ]]; then
        script_name="${BASH_REMATCH[1]}"
        script_desc="${BASH_REMATCH[2]}"
        # 去除首尾空格
        script_name=$(echo "$script_name" | xargs)
        script_desc=$(echo "$script_desc" | xargs)
        SCRIPT_NAMES+=("$script_name")
        SCRIPT_DESCS+=("$script_desc")
    fi
done < "${SCRIPTS_DIR}/README.md"

# 如果没解析到脚本，可能格式变了
if [ ${#SCRIPT_NAMES[@]} -eq 0 ]; then
    echo -e "${RED}未能解析到脚本列表，README 格式可能已变更。${NC}"
    exit 1
fi

echo -e "${GREEN}共发现 ${#SCRIPT_NAMES[@]} 个脚本:${NC}"
echo ""

# 显示菜单
echo -e "${BOLD}========================================${NC}"
for i in "${!SCRIPT_NAMES[@]}"; do
    idx=$((i + 1))
    printf "  ${GREEN}%2d${NC}. %-35s ${YELLOW}%s${NC}\n" "$idx" "${SCRIPT_NAMES[$i]}" "${SCRIPT_DESCS[$i]}"
done
echo ""
echo -e "  ${RED} 0${NC}. 退出"
echo -e "${BOLD}========================================${NC}"
echo ""

# 用户选择
read -p "请输入编号 [0-${#SCRIPT_NAMES[@]}]: " choice

# 验证输入
if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}输入无效，请输入数字。${NC}"
    exit 1
fi

if [ "$choice" -eq 0 ]; then
    echo "已退出。"
    exit 0
fi

if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#SCRIPT_NAMES[@]} ]; then
    echo -e "${RED}编号超出范围，请重新运行。${NC}"
    exit 1
fi

# 获取选中的脚本
INDEX=$((choice - 1))
SELECTED="${SCRIPT_NAMES[$INDEX]}"
SCRIPT_URL="${REPO_RAW}/${SELECTED}?t=${RANDOM}"

echo ""
echo -e "${CYAN}正在下载 ${BOLD}${SELECTED}${NC}${CYAN} ...${NC}"

# 下载脚本
TARGET="${SCRIPTS_DIR}/${SELECTED}"
if [ "$DOWNLOADER" = "curl" ]; then
    if ! curl -sL -o "$TARGET" "$SCRIPT_URL" 2>/dev/null; then
        echo -e "${RED}下载失败！${NC}"
        exit 1
    fi
else
    if ! wget -q -O "$TARGET" "$SCRIPT_URL" 2>/dev/null; then
        echo -e "${RED}下载失败！${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}下载完成！${NC}"
echo -e "${CYAN}正在执行 ${BOLD}${SELECTED}${NC}${CYAN} ...${NC}"
echo ""

# 执行脚本
bash "$TARGET"

# 清理
rm -f "$TARGET"
