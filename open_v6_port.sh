#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 清屏增加仪式感
clear
echo -e "${GREEN}=======================================${NC}"
echo -e "${GREEN}      LXC/LXD IPv6 端口一键开启工具      ${NC}"
echo -e "${GREEN}=======================================${NC}"

# 1. 检查并安装必要依赖
echo -e "${YELLOW}[1/4] 正在检查系统组件...${NC}"

if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}未发现 curl，正在同步软件源并安装...${NC}"
    apt-get update
    apt-get install -y curl
else
    echo -e "${GREEN}√ curl 已存在${NC}"
fi

if ! command -v ip6tables &> /dev/null; then
    echo -e "${YELLOW}未发现 ip6tables，正在同步软件源并安装...${NC}"
    # 如果上面已经 update 过了，这里其实会很快
    apt-get update
    apt-get install -y iptables
else
    echo -e "${GREEN}√ ip6tables 已存在${NC}"
fi

# 2. 检测 IPv6
echo -e "${YELLOW}[2/4] 正在检测 IPv6 网络地址...${NC}"
# 这里的 curl 没加 -s，你会看到进度条
IPV6_ADDR=$(curl -6 --connect-timeout 15 ip.sb || curl -6 --connect-timeout 5 api64.ipify.org)

if [ -z "$IPV6_ADDR" ]; then
    echo -e "${RED}错误: 未检测到 IPv6 地址，请确认网络连接。${NC}"
    exit 1
fi
echo -e "${GREEN}√ 本机 IPv6: ${IPV6_ADDR}${NC}"

# 3. 交互输入
echo -e "${YELLOW}[3/4] 等待用户输入...${NC}"
echo -e "${YELLOW}请输入需要开放的端口号 (TCP & UDP):${NC} "
read PORT < /dev/tty

if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}输入错误，[${PORT}] 不是有效的数字端口！${NC}"
    exit 1
fi

# 4. 执行规则
echo -e "${YELLOW}[4/4] 正在下发 ip6tables 防火墙规则...${NC}"
echo -e "执行: ip6tables -I INPUT -p tcp --dport $PORT -j ACCEPT"
ip6tables -I INPUT -p tcp --dport "$PORT" -j ACCEPT

echo -e "执行: ip6tables -I INPUT -p udp --dport $PORT -j ACCEPT"
ip6tables -I INPUT -p udp --dport "$PORT" -j ACCEPT

# 5. 验证结果
if [ $? -eq 0 ]; then
    echo -e "${GREEN}---------------------------------------${NC}"
    echo -e "${GREEN}★ 成功！端口 ${PORT} 已实时放行${NC}"
    echo -e "${YELLOW}当前 IPv6 规则库快照：${NC}"
    ip6tables -L INPUT -vn --line-numbers | grep "$PORT"
    echo -e "${GREEN}---------------------------------------${NC}"
else
    echo -e "${RED}执行失败，请检查是否具有 Root 权限或宿主机内核支持。${NC}"
fi
