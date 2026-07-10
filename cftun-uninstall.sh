#!/bin/bash

# ============== Cloudflare Tunnel 卸载脚本 ==============
# 查找并清理所有 CF Tunnel 安装记录
# 恢复到未安装状态

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[ "$(id -u)" -ne 0 ] && error "请用 root 用户运行: sudo bash $0"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Cloudflare Tunnel 卸载脚本${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 1. 扫描安装记录
echo -e "${YELLOW}正在扫描安装记录...${NC}"
echo ""

FOUND_ITEMS=0

# 扫描函数
scan_item() {
    local path="$1"
    local desc="$2"
    if [ -e "$path" ]; then
        echo "  发现: ${desc}"
        echo "        ${path}"
        FOUND_ITEMS=$((FOUND_ITEMS + 1))
    fi
}

echo -e "${CYAN}[服务]${NC}"
scan_item "/etc/systemd/system/cloudflared.service" "systemd 服务"
scan_item "/etc/systemd/system/cloudflared@.service" "systemd 模板服务"

echo ""
echo -e "${CYAN}[配置文件]${NC}"
scan_item "/etc/cloudflared" "系统默认配置目录"
scan_item "/opt/cloudflared" "自定义安装目录"
scan_item "/root/.cloudflared" "root 用户配置"
scan_item "/home/*/.cloudflared" "用户配置目录"

echo ""
echo -e "${CYAN}[可执行文件]${NC}"
scan_item "/usr/local/bin/cloudflared" "二进制文件"
scan_item "/usr/local/bin/cftun" "管理工具"
scan_item "/usr/bin/cloudflared" "包管理器安装"

echo ""
echo -e "${CYAN}[apt 源]${NC}"
scan_item "/etc/apt/sources.list.d/cloudflared.list" "apt 源配置"
scan_item "/usr/share/keyrings/cloudflare-main.gpg" "GPG 签名密钥"

echo ""
echo -e "${CYAN}[日志]${NC}"
scan_item "/var/log/cloudflared" "日志目录"
scan_item "/var/lib/cloudflared" "数据目录"

# 扫描其他可能的配置位置
echo ""
echo -e "${CYAN}[其他位置]${NC}"
for HOME_DIR in /home/*; do
    [ -d "${HOME_DIR}/.cloudflared" ] && scan_item "${HOME_DIR}/.cloudflared" "用户配置: $(basename $HOME_DIR)"
done

# 2. 确认卸载
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "扫描到 ${YELLOW}${FOUND_ITEMS}${NC} 个相关项目"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ "$FOUND_ITEMS" -eq 0 ]; then
    info "未发现 Cloudflare Tunnel 安装记录"
    echo ""
    # 还是检查一下是否有残留
    echo -e "${YELLOW}是否进行深度扫描? [y/N]: ${NC}"
    read -p "" DEEP_SCAN
    if [ "$DEEP_SCAN" = "y" ] || [ "$DEEP_SCAN" = "Y" ]; then
        echo ""
        echo -e "${CYAN}[深度扫描]${NC}"
        # 搜索可能的残留
        find /etc -name "*cloudflare*" -o -name "*cloudflared" 2>/dev/null | while read f; do
            scan_item "$f" "残留文件"
        done
        find /usr -name "*cloudflare*" -o -name "*cloudflared" 2>/dev/null | while read f; do
            scan_item "$f" "残留文件"
        done
        find /opt -name "*cloudflare*" -o -name "*cloudflared" 2>/dev/null | while read f; do
            scan_item "$f" "残留文件"
        done
    fi
fi

echo ""
echo -e "${YELLOW}确认卸载? 这将删除以上所有项目 [y/N]: ${NC}"
read -p "" CONFIRM
[ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ] && info "已取消卸载" && exit 0

echo ""

# 3. 停止服务
echo -e "${YELLOW}[1/6] 停止服务...${NC}"
# 停止 systemd 服务
if systemctl is-active --quiet cloudflared 2>/dev/null; then
    systemctl stop cloudflared 2>/dev/null
    info "已停止 cloudflared 服务"
else
    info "cloudflared 服务未运行"
fi
# 也杀掉可能残留的后台进程
pkill -f "cloudflared tunnel" 2>/dev/null || true

# 4. 禁用服务
echo -e "${YELLOW}[2/6] 禁用服务...${NC}"
systemctl disable cloudflared 2>/dev/null && info "已禁用 cloudflared 服务" || true
systemctl daemon-reload 2>/dev/null && info "已重载 systemd" || true

# 5. 删除配置和数据
echo -e "${YELLOW}[3/6] 清理配置文件...${NC}"

# 备份提示
echo -e "${YELLOW}  是否备份配置文件? [y/N]: ${NC}"
read -p "" BACKUP
if [ "$BACKUP" = "y" ] || [ "$BACKUP" = "Y" ]; then
    BACKUP_DIR="/root/cftun-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    [ -d "/opt/cloudflared" ] && cp -r /opt/cloudflared "$BACKUP_DIR/" 2>/dev/null
    [ -d "/etc/cloudflared" ] && cp -r /etc/cloudflared "$BACKUP_DIR/" 2>/dev/null
    [ -d "/root/.cloudflared" ] && cp -r /root/.cloudflared "$BACKUP_DIR/" 2>/dev/null
    
    for HOME_DIR in /home/*; do
        [ -d "${HOME_DIR}/.cloudflared" ] && cp -r "${HOME_DIR}/.cloudflared" "$BACKUP_DIR/" 2>/dev/null
    done
    
    info "配置已备份到: ${BACKUP_DIR}"
fi

# 删除配置目录
DIRS_TO_DELETE=(
    "/opt/cloudflared"
    "/etc/cloudflared"
    "/root/.cloudflared"
    "/var/log/cloudflared"
    "/var/lib/cloudflared"
)

for DIR in "${DIRS_TO_DELETE[@]}"; do
    [ -d "$DIR" ] && rm -rf "$DIR" && info "已删除: ${DIR}"
done

# 删除用户配置
for HOME_DIR in /home/*; do
    [ -d "${HOME_DIR}/.cloudflared" ] && rm -rf "${HOME_DIR}/.cloudflared" && info "已删除: ${HOME_DIR}/.cloudflared"
done

# 6. 删除可执行文件
echo -e "${YELLOW}[4/6] 清理可执行文件...${NC}"

FILES_TO_DELETE=(
    "/usr/local/bin/cloudflared"
    "/usr/local/bin/cftun"
    "/usr/bin/cloudflared"
)

for FILE in "${FILES_TO_DELETE[@]}"; do
    [ -f "$FILE" ] && rm -f "$FILE" && info "已删除: ${FILE}"
done

# 7. 删除 systemd 服务文件
echo -e "${YELLOW}[5/6] 清理 systemd 服务...${NC}"

SERVICE_FILES=(
    "/etc/systemd/system/cloudflared.service"
    "/etc/systemd/system/cloudflared@.service"
)

for FILE in "${SERVICE_FILES[@]}"; do
    [ -f "$FILE" ] && rm -f "$FILE" && info "已删除: ${FILE}"
done

systemctl daemon-reload 2>/dev/null

# 8. 清理 apt 源（安装脚本添加的）
echo -e "${YELLOW}[6/6] 清理 apt 源...${NC}"
rm -f /etc/apt/sources.list.d/cloudflared.list && info "已删除 apt 源: cloudflared.list"
rm -f /usr/share/keyrings/cloudflare-main.gpg && info "已删除 GPG key: cloudflare-main.gpg"
apt-get update -qq 2>/dev/null || true

# 8. 完成
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ 卸载完成!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "已清理的内容:"
echo "  - cloudflared 进程和服务"
echo "  - /opt/cloudflared/ 目录"
echo "  - /etc/cloudflared/ 目录"
echo "  - 所有 .cloudflared 配置"
echo "  - cftun 管理工具"
echo "  - systemd 服务文件"
echo "  - apt 源和 GPG key"
echo ""

if [ "$BACKUP" = "y" ] || [ "$BACKUP" = "Y" ]; then
    echo "配置备份位置: ${BACKUP_DIR}"
    echo ""
fi

echo "如需重新安装，请运行: sudo bash cftun-setup.sh"
echo ""
