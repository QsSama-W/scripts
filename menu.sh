#!/bin/sh
# 一键脚本管理器 - 自动从仓库拉取最新脚本列表
# 用法: sh menu.sh

clear 2>/dev/null || printf '\033[2J\033[H'

cleanup() {
    rm -f /tmp/menu.sh
    rm -f "${SCRIPTS_DIR}/README.md" "${SCRIPTS_DIR}/names.txt" "${SCRIPTS_DIR}/descs.txt" "${SCRIPTS_DIR}/cmds.txt"
    rm -f "${SCRIPTS_DIR}/${SELECTED}" 2>/dev/null
}
trap cleanup EXIT

REPO_RAW="https://raw.githubusercontent.com/QsSama-W/scripts/main"
README_URL="${REPO_RAW}/README.md"
SCRIPTS_DIR="/tmp/qs-scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "$SCRIPTS_DIR"

printf "%b\n" "${CYAN}${BOLD}========================================${NC}"
printf "%b\n" "${CYAN}${BOLD}    脚本一键管理器 - 自动同步最新版本${NC}"
printf "%b\n" "${CYAN}${BOLD}========================================${NC}"
echo ""

printf "%b" "${YELLOW}正在拉取最新脚本列表...${NC}"
if ! wget -q -O "${SCRIPTS_DIR}/README.md" "${README_URL}?t=${RANDOM}" 2>/dev/null; then
    printf "%b\n" "${RED} 失败！${NC}"
    printf "%b\n" "${RED}无法连接到 GitHub，请检查网络。${NC}"
    exit 1
fi
printf "%b\n" "${GREEN} 完成！${NC}"
echo ""

# 解析脚本列表
> "${SCRIPTS_DIR}/names.txt"
> "${SCRIPTS_DIR}/descs.txt"

awk -F'|' '/\| `.*\.sh` \|/ && !/---/ {
    gsub(/^[ \t]+|[ \t]+$/, "", $2)
    gsub(/`/, "", $2)
    gsub(/^[ \t]+|[ \t]+$/, "", $3)
    if ($2 != "") {
        print $2 > "'${SCRIPTS_DIR}/names.txt'"
        print $3 > "'${SCRIPTS_DIR}/descs.txt'"
    }
}' "${SCRIPTS_DIR}/README.md"

# 解析一键命令：支持从注释中强制读取文件名 Key
awk '
/```bash/ { in_code=1; explicit_name=""; next }
/```/ && in_code {
    in_code=0
    if (cmd != "") {
        if (explicit_name != "") {
            cmds[explicit_name] = cmd
        } else {
            n = split(cmd, parts, " ")
            for (i = 1; i <= n; i++) {
                if (parts[i] ~ /\.sh(\?|$)/) {
                    gsub(/\?.*/, "", parts[i])
                    gsub(/.*\//, "", parts[i])
                    cmds[parts[i]] = cmd
                    break
                }
            }
        }
        cmd = ""
    }
    next
}
in_code && NF > 0 {
    # 如果是注释行，尝试提取强绑定的脚本名称
    if ($0 ~ /^[ \t]*#/) {
        if ($0 ~ /\.sh/) {
            tmp = $0
            gsub(/.*#|[ \t]+/, "", tmp)
            if (tmp ~ /\.sh$/) explicit_name = tmp
        }
    } else {
        if (cmd == "") cmd = $0; else cmd = cmd " && " $0
    }
}
END {
    while ((getline name < "'"${SCRIPTS_DIR}/names.txt"'") > 0) {
        if (name in cmds) print cmds[name]
        else print ""
    }
}' "${SCRIPTS_DIR}/README.md" > "${SCRIPTS_DIR}/cmds.txt"

COUNT=$(wc -l < "${SCRIPTS_DIR}/names.txt" | tr -d ' ')

if [ "$COUNT" -eq 0 ]; then
    printf "%b\n" "${RED}未能解析到脚本列表，README 格式可能已变更。${NC}"
    exit 1
fi

printf "%b\n" "${GREEN}共发现 ${COUNT} 个脚本:${NC}"
echo ""

printf "%b\n" "${BOLD}========================================${NC}"
IDX=1
while IFS= read -r name; do
    desc=$(sed -n "${IDX}p" "${SCRIPTS_DIR}/descs.txt")
    printf "  ${GREEN}%2d${NC}. %-35s ${YELLOW}%s${NC}\n" "$IDX" "$name" "$desc"
    IDX=$((IDX + 1))
done < "${SCRIPTS_DIR}/names.txt"
echo ""
printf "%b\n" "  ${RED} 0${NC}. 退出"
printf "%b\n" "${BOLD}========================================${NC}"
echo ""

printf "请输入编号 [0-%d]: " "$COUNT"
read choice

case "$choice" in
    ''|*[!0-9]*)
        printf "%b\n" "${RED}输入无效，请输入数字。${NC}"
        exit 1
        ;;
esac

if [ "$choice" -eq 0 ]; then
    echo "已退出。"
    exit 0
fi

if [ "$choice" -lt 1 ] || [ "$choice" -gt "$COUNT" ]; then
    printf "%b\n" "${RED}编号超出范围，请重新运行。${NC}"
    exit 1
fi

SELECTED=$(sed -n "${choice}p" "${SCRIPTS_DIR}/names.txt")
CMD=$(sed -n "${choice}p" "${SCRIPTS_DIR}/cmds.txt")

if [ -z "$CMD" ]; then
    printf "%b\n" "${RED}未找到 ${SELECTED} 的一键命令，请手动执行。${NC}"
    exit 1
fi

echo ""
printf "%b\n" "${CYAN}${BOLD}一键执行命令:${NC}"
printf "%b\n" "  ${CMD}"
echo ""

CMD=$(echo "$CMD" | tr -d '\r')
eval "$CMD"