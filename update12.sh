#!/bin/bash

# ==========================================
# Debian 11 to Debian 12 (Bookworm) Upgrade Script (Unattended)
# apt update && apt install -y wget && wget -O update12.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/update12.sh?t=$RANDOM" && bash update12.sh
# ==========================================

LOG_FILE="/var/log/debian12_upgrade.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "开始执行 Debian 11 -> Debian 12 自动化升级程序"
echo "开始时间: $(date)"
echo "日志文件: $LOG_FILE"
echo "=========================================="

# 1. 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "错误: 请使用 root 权限运行此脚本 (例如: sudo bash update12.sh)"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# 2. 先将源替换为中科大 Bullseye 源，确保能正常拉包
echo "[Step 1/6] 将源替换为 USTC (Bullseye)..."
cat > /etc/apt/sources.list <<EOF
deb https://mirrors.ustc.edu.cn/debian/ bullseye main contrib non-free
# deb-src https://mirrors.ustc.edu.cn/debian/ bullseye main contrib non-free

deb https://mirrors.ustc.edu.cn/debian/ bullseye-updates main contrib non-free
# deb-src https://mirrors.ustc.edu.cn/debian/ bullseye-updates main contrib non-free

deb https://mirrors.ustc.edu.cn/debian-security bullseye-security main contrib non-free
# deb-src https://mirrors.ustc.edu.cn/debian-security bullseye-security main contrib non-free
EOF

echo "源替换完成。"

# 3. 更新当前系统到最新状态
echo "[Step 2/6] 更新当前系统软件包..."
apt update
apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

# 4. 将源替换为中科大 Bookworm 源
echo "[Step 3/6] 正在将源替换为 USTC (Bookworm)..."
cat > /etc/apt/sources.list <<EOF
# 默认注释了源码镜像以提高 apt update 速度，如有需要可自行取消注释
deb https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware
# deb-src https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware

deb https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware
# deb-src https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware

deb https://mirrors.ustc.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
# deb-src https://mirrors.ustc.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

echo "源替换完成。"

# 5. 更新软件源索引
echo "[Step 4/6] 更新软件源索引..."
apt update

# 6. 执行系统升级
echo "[Step 5/6] 开始执行版本升级 (全自动模式，这可能需要一段时间)..."
apt upgrade --without-new-pkgs -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

# 7. 清理残留
echo "[Step 6/6] 清理不再需要的旧软件包..."
apt autoremove -y
apt clean

echo "=========================================="
echo "升级操作已完成！"
echo "结束时间: $(date)"
echo "请检查上方是否有错误信息。"
echo "建议立即重启系统以应用更改: reboot"
echo "=========================================="
