#!/bin/bash

TARGET_DIR="/opt/ddns-go"
REPO="jeessy2/ddns-go"
ARCH="linux_x86_64.tar.gz"

CURRENT_IP=$(curl -s ip.sb || curl -s ifconfig.me)
echo "------------------------------------------"
echo "当前公网 IP: $CURRENT_IP"
echo "存放目录: $TARGET_DIR"
echo "------------------------------------------"

if [ ! -d "$TARGET_DIR" ]; then
    echo "创建目录: $TARGET_DIR"
    sudo mkdir -p "$TARGET_DIR"
fi

echo "正在检查 GitHub 最新版本..."
LATEST_TAG=$(curl -s https://api.github.com/repos/$REPO/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    echo "错误：无法获取版本号，请检查网络。"
    exit 1
fi

VERSION=${LATEST_TAG#v}
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/ddns-go_${VERSION}_linux_x86_64.tar.gz"

echo "目标版本: $LATEST_TAG"

echo "正在下载..."
sudo wget -q --show-progress "$DOWNLOAD_URL" -O "$TARGET_DIR/ddns-go_new.tar.gz"

if [ $? -ne 0 ]; then
    echo "下载失败，请检查网络链接或 GitHub 访问。"
    exit 1
fi

echo "正在解压..."
sudo tar -zxf "$TARGET_DIR/ddns-go_new.tar.gz" -C "$TARGET_DIR"
sudo chmod +x "$TARGET_DIR/ddns-go"

if [ -f "$TARGET_DIR/ddns-go" ]; then
    echo "正在停止并卸载旧版服务..."
    sudo "$TARGET_DIR/ddns-go" -s uninstall 2>/dev/null
fi

echo "正在安装并启动新版本服务..."
sudo "$TARGET_DIR/ddns-go" -s install

sudo rm "$TARGET_DIR/ddns-go_new.tar.gz"
sudo rm -f "$TARGET_DIR/README.md" "$TARGET_DIR/LICENSE"

echo "------------------------------------------"
echo "升级成功！"
echo "当前运行版本："
"$TARGET_DIR/ddns-go" -v
echo "请访问 Web 界面 (默认端口 9876) 确认配置是否生效。"
echo "------------------------------------------"
