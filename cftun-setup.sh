#!/bin/bash
set -e

# ============== Cloudflare Tunnel 一键安装 ==============
# 使用 cloudflared tunnel login 浏览器授权（无需绑卡）
# 支持多个子域名，可随时用 cftun add 添加
# 安装目录: /opt/cloudflared/

# ============== 可调整配置 ==============
INSTALL_DIR="/opt/cloudflared"          # 安装目录
CONFIG_DIR="${INSTALL_DIR}/config"      # 配置目录
CONFIG_FILE="${CONFIG_DIR}/config.yml"  # 隧道配置文件
PROXIED="true"                          # DNS 代理: true/false
# =======================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[ "$(id -u)" -ne 0 ] && error "请用 root 用户运行: sudo bash $0"

# 检查是否已安装
if command -v cloudflared &>/dev/null && [ -f "/etc/systemd/system/cloudflared.service" ] && [ -f "$CONFIG_FILE" ]; then
    warn "检测到已安装 Cloudflare Tunnel"
    echo ""
    echo "  1) 重新安装（覆盖配置）"
    echo "  2) 只添加子域名"
    echo "  3) 查看当前状态"
    echo "  0) 取消"
    echo ""
    read -p "  请选择 [0-3]: " CHOICE
    case "$CHOICE" in
        1)
            echo "  继续重新安装..."
            echo ""
            ;;
        2)
            read -p "  子域名: " SUB
            read -p "  端口: " PORT
            [ -z "$SUB" ] || [ -z "$PORT" ] && error "参数不能为空"
            cftun add "$SUB" "$PORT"
            exit 0
            ;;
        3)
            cftun list
            systemctl status cloudflared --no-pager
            exit 0
            ;;
        *)
            info "已取消"
            exit 0
            ;;
    esac
fi

# 1. 安装 cloudflared
if ! command -v cloudflared &>/dev/null; then
    info "正在安装 cloudflared..."
    ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH="amd64"; [ "$ARCH" = "aarch64" ] && ARCH="arm64"
    
    # 尝试多个下载源
    DOWNLOADED=false

    # 方法1: Cloudflare 官方 apt 仓库（最稳定）
    if ! $DOWNLOADED; then
        info "尝试 apt 安装..."
        if command -v apt-get &>/dev/null; then
            curl -fsSL --connect-timeout 10 https://pkg.cloudflare.com/cloudflare-main.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg 2>/dev/null
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflared.list
            apt-get update -qq 2>/dev/null && apt-get install -y -qq cloudflared 2>/dev/null && DOWNLOADED=true || true
        fi
    fi

    # 方法2: ghproxy 国内镜像
    if ! $DOWNLOADED; then
        info "尝试 ghproxy 镜像..."
        curl -fsSL --connect-timeout 10 "https://mirror.ghproxy.com/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o /usr/local/bin/cloudflared 2>/dev/null && DOWNLOADED=true || true
    fi

    # 方法3: ghp.ci 镜像
    if ! $DOWNLOADED; then
        info "尝试 ghp.ci 镜像..."
        curl -fsSL --connect-timeout 10 "https://ghp.ci/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o /usr/local/bin/cloudflared 2>/dev/null && DOWNLOADED=true || true
    fi

    # 方法4: GitHub 直连
    if ! $DOWNLOADED; then
        info "尝试 GitHub 直连..."
        curl -fsSL --connect-timeout 10 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o /usr/local/bin/cloudflared 2>/dev/null && DOWNLOADED=true || true
    fi
    
    $DOWNLOADED || { rm -f /usr/local/bin/cloudflared; error "所有下载源都失败了，请手动安装 cloudflared"; }
    
    chmod +x /usr/local/bin/cloudflared
    export PATH="/usr/local/bin:$PATH"
    hash -r 2>/dev/null || true
fi
command -v cloudflared &>/dev/null || error "cloudflared 未找到，请重新登录 shell 或手动添加 /usr/local/bin 到 PATH"
info "cloudflared: $(cloudflared --version 2>&1 | head -1)"

# 2. 创建安装目录
mkdir -p "$CONFIG_DIR"

# 3. 收集基础信息
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  CF 隧道安装向导（浏览器授权版）${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}[1/4] 浏览器授权登录${NC}"
echo "  接下来会生成一个授权链接"
echo "  请复制链接在本地浏览器打开，登录 Cloudflare 账号并授权"
echo "  选择要使用的域名（免费套餐选 Free 就行，不需要绑卡）"
echo "  授权完成后 cloudflared 会自动下载证书"
echo ""
echo "  按回车生成授权链接..."
read -p ""

# 浏览器授权 - 直接运行，URL 会显示在终端
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}复制下方链接在浏览器中打开，完成授权:${NC}"
echo ""
cloudflared tunnel login
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 检查证书
CERT_DIR=$(find /root /home -name "cert.pem" -path "*/.cloudflared/*" 2>/dev/null | head -1)
[ -z "$CERT_DIR" ] && error "授权失败，未找到 cert.pem，请确认已完成浏览器授权"
CRED_DIR=$(dirname "$CERT_DIR")
info "授权成功，证书路径: ${CERT_DIR}"

echo -e "\n${YELLOW}[2/4] 创建隧道${NC}"
read -p "  给隧道起个名字（如 my-tunnel）: " TUNNEL_NAME
[ -z "$TUNNEL_NAME" ] && error "隧道名称不能为空"

# 检查同名隧道是否已存在
EXISTS=$(cloudflared tunnel list 2>/dev/null | grep -w "$TUNNEL_NAME" || true)
if [ -n "$EXISTS" ]; then
    warn "隧道 '${TUNNEL_NAME}' 已存在，跳过创建"
else
    cloudflared tunnel create "$TUNNEL_NAME"
    info "隧道 '${TUNNEL_NAME}' 创建成功"
fi

# 获取隧道 UUID
TUNNEL_UUID=$(cloudflared tunnel list 2>/dev/null | grep -w "$TUNNEL_NAME" | grep -oP '[a-f0-9-]{36}' | head -1)
[ -z "$TUNNEL_UUID" ] && error "无法获取隧道 UUID"
TUNNEL_CNAME="${TUNNEL_UUID}.cfargotunnel.com"
info "隧道 UUID: ${TUNNEL_UUID}"

echo -e "\n${YELLOW}[3/4] 主域名${NC}"
echo "  请输入主域名（不要带子域名，如 example.com）"
read -p "  域名: " DOMAIN
[ -z "$DOMAIN" ] && error "域名不能为空"

# 可选：API Token（用于自动配置 DNS）
echo -e "\n${YELLOW}[3.5/4] API Token（可选，回车跳过）${NC}"
echo "  如果想自动配置 DNS 记录，请提供 API Token"
echo "  创建地址: https://dash.cloudflare.com/profile/api-tokens"
echo "  权限选择: Zone → DNS → Edit"
echo "  （跳过的话需要手动去 Dashboard 添加 CNAME 记录）"
read -p "  API Token（留空跳过）: " API_TOKEN

ZONE_ID=""
if [ -n "$API_TOKEN" ]; then
    VALIDATE=$(curl -s "https://api.cloudflare.com/client/v4/user/tokens/verify" -H "Authorization: Bearer ${API_TOKEN}" 2>/dev/null)
    if echo "$VALIDATE" | grep -q '"success":true'; then
        ZONE_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
            -H "Authorization: Bearer ${API_TOKEN}" 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')" 2>/dev/null)
        if [ -z "$ZONE_ID" ]; then
            warn "未找到域名 ${DOMAIN}，跳过自动 DNS 配置"
        else
            info "域名: ${DOMAIN}, Zone ID: ${ZONE_ID}"
        fi
    else
        warn "API Token 验证失败，跳过自动 DNS 配置"
        API_TOKEN=""
    fi
fi

echo -e "\n${YELLOW}[4/4] 子域名配置${NC}"
echo "  输入子域名前缀和对应的本地端口"
echo "  输入空行结束"
echo ""
echo "  示例: blog → 8080, wiki → 3000, api → 5000"
echo ""

declare -A SUBDOMAINS
IDX=1
while true; do
    read -p "  子域名 ${IDX} (留空结束): " SUB
    [ -z "$SUB" ] && break
    read -p "  端口: " PORT
    [ -z "$PORT" ] && error "端口不能为空"
    SUBDOMAINS["$SUB"]="$PORT"
    info "  ${SUB}.${DOMAIN} → localhost:${PORT}"
    ((IDX++))
done

[ ${#SUBDOMAINS[@]} -eq 0 ] && error "至少需要添加一个子域名"

# 4. 配置 DNS 记录（如果有 API Token）
if [ -n "$API_TOKEN" ] && [ -n "$ZONE_ID" ]; then
    echo ""
    info "正在配置 DNS 记录..."
    for SUB in "${!SUBDOMAINS[@]}"; do
        FULL="${SUB}.${DOMAIN}"

        EXISTING=$(curl -s "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${FULL}" \
            -H "Authorization: Bearer ${API_TOKEN}" 2>/dev/null)

        RECORD_COUNT=$(echo "$EXISTING" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null || echo "0")

        if [ "$RECORD_COUNT" -gt "0" ]; then
            RECORD_ID=$(echo "$EXISTING" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
            curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
                -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
                --data "{\"type\":\"CNAME\",\"name\":\"${SUB}\",\"content\":\"${TUNNEL_CNAME}\",\"proxied\":${PROXIED}}" >/dev/null 2>&1
        else
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
                --data "{\"type\":\"CNAME\",\"name\":\"${SUB}\",\"content\":\"${TUNNEL_CNAME}\",\"proxied\":${PROXIED}}" >/dev/null 2>&1
        fi
        PROXY_STATUS="代理已开启"
        [ "$PROXIED" = "false" ] && PROXY_STATUS="仅 DNS 解析"
        info "DNS: ${FULL} → ${TUNNEL_CNAME} (${PROXY_STATUS})"
    done
else
    echo ""
    warn "未配置 API Token，DNS 需要手动添加"
    warn "请到 Cloudflare Dashboard → DNS 添加以下 CNAME 记录:"
    for SUB in "${!SUBDOMAINS[@]}"; do
        echo "  ${SUB}.${DOMAIN}  CNAME  ${TUNNEL_CNAME}"
    done
fi

# 5. 生成配置文件
echo ""
info "正在生成配置文件..."

[ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"

cat > "$CONFIG_FILE" << EOF
# Cloudflare Tunnel 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

tunnel: ${TUNNEL_UUID}
credentials-file: ${CRED_DIR}/${TUNNEL_UUID}.json

ingress:
EOF

for SUB in "${!SUBDOMAINS[@]}"; do
    FULL="${SUB}.${DOMAIN}"
    PORT="${SUBDOMAINS[$SUB]}"
    cat >> "$CONFIG_FILE" << EOF
  - hostname: ${FULL}
    service: http://localhost:${PORT}
EOF
done

cat >> "$CONFIG_FILE" << EOF
  - service: http_status:404
EOF

info "配置文件: ${CONFIG_FILE}"

# 6. 绑定 DNS 并启动隧道
echo ""
info "正在绑定 DNS..."
for SUB in "${!SUBDOMAINS[@]}"; do
    cloudflared tunnel route dns "$TUNNEL_UUID" "${SUB}.${DOMAIN}" 2>/dev/null || true
done

# 创建 systemd 服务（开机自启）
info "正在配置 systemd 服务..."
cat > /etc/systemd/system/cloudflared.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config ${CONFIG_FILE} run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared 2>/dev/null
systemctl start cloudflared 2>/dev/null
sleep 3
systemctl is-active --quiet cloudflared && info "隧道服务已启动并设置开机自启" || warn "服务启动可能有问题，请手动检查"

# 7. 创建管理工具 cftun
cat > /usr/local/bin/cftun << 'TOOL'
#!/bin/bash
# Cloudflare Tunnel 管理工具
# 安装目录: /opt/cloudflared/

INSTALL_DIR="/opt/cloudflared"
CONFIG_DIR="${INSTALL_DIR}/config"
CONFIG_FILE="${CONFIG_DIR}/config.yml"
PROXIED="__PROXIED__"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

get_tunnel_uuid() {
    # 方法1: tunnel list
    UUID=$(cloudflared tunnel list 2>/dev/null | grep -oP '[a-f0-9-]{36}' | head -1)
    [ -n "$UUID" ] && echo "$UUID" && return

    # 方法2: config.yml
    [ -f "$CONFIG_FILE" ] && UUID=$(grep -oP 'tunnel:\s*\K[a-f0-9-]{36}' "$CONFIG_FILE" 2>/dev/null)
    [ -n "$UUID" ] && echo "$UUID" && return

    # 方法3: 凭证目录
    CERT_DIR=$(find /root /home -name "cert.pem" -path "*/.cloudflared/*" 2>/dev/null | head -1)
    [ -n "$CERT_DIR" ] && CRED_DIR=$(dirname "$CERT_DIR")
    for F in "$CRED_DIR"/*.json; do
        UUID=$(echo "$F" | grep -oP '[a-f0-9-]{36}')
        [ -n "$UUID" ] && echo "$UUID" && return
    done
}

check_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[✗]${NC} 配置文件不存在: ${CONFIG_FILE}"
        return 1
    fi
    UUID=$(get_tunnel_uuid)
    if [ -z "$UUID" ]; then
        echo -e "${RED}[✗]${NC} 未找到隧道 UUID"
        return 1
    fi
    return 0
}

add_sub() {
    [ -z "$1" ] || [ -z "$2" ] && echo "用法: cftun add <子域名> <端口>" && exit 1
    SUB="$1"; PORT="$2"
    UUID=$(get_tunnel_uuid); [ -z "$UUID" ] && echo "未找到隧道" && exit 1

    # 获取域名
    DOMAIN=$(grep "hostname:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*hostname: //' | sed 's/\/.*//' | cut -d. -f2-)
    [ -z "$DOMAIN" ] && read -p "域名: " DOMAIN
    FULL="${SUB}.${DOMAIN}"

    if grep -q "hostname: ${FULL}" "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${YELLOW}[!]${NC} ${FULL} 已存在，跳过添加"
        return 0
    fi

    # 绑定 DNS
    cloudflared tunnel route dns "$UUID" "$FULL" 2>/dev/null || true

    # 添加配置
    if [ -f "$CONFIG_FILE" ]; then
        sed -i "/service: http_status:404/i\\  - hostname: ${FULL}\\n    service: http://localhost:${PORT}" "$CONFIG_FILE" 2>/dev/null
        systemctl restart cloudflared 2>/dev/null
    fi
    echo -e "${GREEN}[✓]${NC} ${FULL} → localhost:${PORT}"
}

edit_sub() {
    [ -z "$1" ] && echo "用法: cftun edit <子域名> <新端口>" && exit 1
    SUB="$1"; NEW_PORT="$2"
    UUID=$(get_tunnel_uuid); [ -z "$UUID" ] && echo "未找到隧道" && exit 1

    DOMAIN=$(grep "hostname:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*hostname: //' | sed 's/\/.*//' | cut -d. -f2-)
    FULL="${SUB}.${DOMAIN}"

    if [ -z "$NEW_PORT" ]; then
        echo -e "${CYAN}编辑子域名: ${FULL}${NC}"
        read -p "  新端口: " NEW_PORT
        [ -z "$NEW_PORT" ] && echo "端口不能为空" && exit 1
    fi

    if ! grep -q "hostname: ${FULL}" "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}[✗]${NC} ${FULL} 不存在，请先用 cftun add 添加"
        exit 1
    fi

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
    sed -i "/hostname: ${FULL}/,/service: http:/{s|localhost:[0-9]*|localhost:${NEW_PORT}|}" "$CONFIG_FILE" 2>/dev/null

    systemctl restart cloudflared 2>/dev/null
    echo -e "${GREEN}[✓]${NC} ${FULL} → localhost:${NEW_PORT} (已更新)"
}

del_sub() {
    [ -z "$1" ] && echo "用法: cftun del <子域名>" && exit 1
    UUID=$(get_tunnel_uuid); [ -z "$UUID" ] && echo "未找到隧道" && exit 1

    DOMAIN=$(grep "hostname:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*hostname: //' | sed 's/\/.*//' | cut -d. -f2-)
    FULL="${1}.${DOMAIN}"

    # 备份配置
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"

    # 删除配置
    [ -f "$CONFIG_FILE" ] && sed -i "/hostname: ${FULL}/,/service: http:\/\//d" "$CONFIG_FILE" 2>/dev/null

    systemctl restart cloudflared 2>/dev/null
    echo -e "${GREEN}[✓]${NC} 已删除 ${FULL}"
}

show_list() {
    echo -e "${CYAN}=== 隧道列表 ===${NC}"
    cloudflared tunnel list 2>/dev/null | head -20 || echo "  (无)"

    echo ""
    echo -e "${CYAN}=== 当前配置 ===${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        LAST_HOST=""
        while IFS= read -r line; do
            HOST=$(echo "$line" | grep -oP 'hostname:\s*\K.*')
            SVC=$(echo "$line" | grep -oP 'service:\s*\K.*')
            if [ -n "$HOST" ]; then
                LAST_HOST="$HOST"
            fi
            if [ -n "$SVC" ] && [ -n "$LAST_HOST" ]; then
                echo "$SVC" | grep -q "http_status" && { LAST_HOST=""; continue; }
                PORT=$(echo "$SVC" | grep -oP ':\K[0-9]+$')
                echo -e "  ${YELLOW}${LAST_HOST}${NC} → localhost:${PORT}"
                LAST_HOST=""
            fi
        done < "$CONFIG_FILE"
    else
        echo "  (配置文件不存在)"
    fi

    echo ""
    echo -e "${CYAN}=== 服务状态 ===${NC}"
    systemctl is-active --quiet cloudflared 2>/dev/null && echo "  运行中 ✓" || echo "  未运行 ✗"
}

case "$1" in
  add|a)     add_sub "$2" "$3" ;;
  edit|e)    edit_sub "$2" "$3" ;;
  del|d|rm)  del_sub "$2" ;;
  list|ls|l) show_list ;;
  start)
    if check_config; then
        systemctl start cloudflared 2>/dev/null
        echo -e "${GREEN}[✓]${NC} 已启动"
    else
        echo -e "${RED}[✗]${NC} 配置检查失败"
        exit 1
    fi
    ;;
  stop)
    systemctl stop cloudflared 2>/dev/null
    echo -e "${GREEN}[✓]${NC} 已停止"
    ;;
  restart)
    if check_config; then
        systemctl restart cloudflared 2>/dev/null
        echo -e "${GREEN}[✓]${NC} 已重启"
    else
        echo -e "${RED}[✗]${NC} 配置检查失败，重启取消"
        exit 1
    fi
    ;;
  status)
    systemctl status cloudflared 2>/dev/null || echo "未运行"
    ;;
  logs)      journalctl -u cloudflared -f --no-pager ;;
  uuid)
    UUID=$(get_tunnel_uuid)
    [ -n "$UUID" ] && echo "隧道 UUID: ${UUID}" || echo "未找到隧道 UUID"
    ;;
  help|--help|-h)
    echo -e "${CYAN}Cloudflare Tunnel 管理工具${NC}"
    echo ""
    echo "子域名管理:"
    echo "  cftun add <子域名> <端口>       添加子域名"
    echo "  cftun edit <子域名> <端口>      修改子域名端口"
    echo "  cftun del <子域名>              删除子域名"
    echo "  cftun list                      查看所有"
    echo ""
    echo "服务控制:"
    echo "  cftun start                     启动服务"
    echo "  cftun stop                      停止服务"
    echo "  cftun restart                   重启服务（自动检查配置）"
    echo "  cftun status                    服务状态"
    echo "  cftun logs                      查看日志"
    echo ""
    echo "其他:"
    echo "  cftun uuid                      查看隧道 UUID"
    ;;
  *) echo "输入 'cftun help' 查看帮助" ;;
esac
TOOL

# 替换变量
sed -i "s|__PROXIED__|${PROXIED}|g" /usr/local/bin/cftun
chmod +x /usr/local/bin/cftun

# 8. 完成
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ 安装完成!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "安装目录: ${INSTALL_DIR}"
echo "配置文件: ${CONFIG_FILE}"
echo ""
echo "已配置的站点:"
for SUB in "${!SUBDOMAINS[@]}"; do
    PORT="${SUBDOMAINS[$SUB]}"
    echo "  ${YELLOW}https://${SUB}.${DOMAIN}${NC} → localhost:${PORT}"
done
echo ""
echo "快速命令:"
echo "  cftun add wiki 3000           添加新站点"
echo "  cftun edit wiki 3001          修改端口"
echo "  cftun del wiki                删除站点"
echo "  cftun list                    查看所有"
echo "  cftun restart                 重启隧道"
echo "  cftun logs                    查看日志"
echo ""
echo "管理隧道:"
echo "  cloudflared tunnel list                    列出所有隧道"
echo "  cloudflared tunnel delete <name>          删除隧道"
echo "  cloudflared tunnel info <name>            查看隧道详情"
echo ""
