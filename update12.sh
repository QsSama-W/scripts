#!/bin/bash

# ==========================================
# Debian 11 (Bullseye) to Debian 12 (Bookworm) Upgrade Script (Unattended)
# Author: QsSama
# apt update && apt install -y wget && wget -O update12.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/update12.sh?t=$RANDOM" && bash update12.sh
# 注意：archive.debian.org 在部分地区无法访问，脚本内已替换为阿里云归档镜像
# ==========================================

# 定义日志文件位置
LOG_FILE="/var/log/debian12_upgrade.log"

# 将标准输出 (1) 和标准错误 (2) 都重定向到日志文件，同时也显示在屏幕上
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

# 2. 检查当前是否为 Debian 11 (Bullseye)
CURRENT_VERSION=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
if [ "$CURRENT_VERSION" != "bullseye" ]; then
  echo "错误: 当前系统不是 Debian 11 (Bullseye)，当前版本为 $CURRENT_VERSION"
  echo "此脚本仅适用于 Bullseye -> Bookworm 升级"
  exit 1
fi
echo "检测到当前系统: Debian 11 (Bullseye) ✓"

# ==========================================
# 核心修改点：设置非交互环境变量，防止弹出任何蓝底灰字的配置界面
export DEBIAN_FRONTEND=noninteractive
# ==========================================

# 3. 修复 Bullseye 归档源（已 LTS 过期，需要指向 archive.debian.org）
echo "[Step 1/6] 修复 Bullseye 归档源..."

cat > /etc/apt/sources.list <<'EOF'
# Bullseye 已归档，指向阿里云归档镜像（archive.debian.org 在部分地区无法访问）
deb https://mirrors.aliyun.com/debian-archive/debian/ bullseye main contrib non-free
deb https://mirrors.aliyun.com/debian-archive/debian/ bullseye-updates main contrib non-free
EOF

echo "源已切换为归档地址。"

# 4. 更新当前系统 (Bullseye) 到最新状态，确保环境干净
echo "[Step 2/6] 更新当前系统软件包..."
# 归档源的 Release 文件可能过期，添加参数跳过有效期检查
apt update -o Acquire::Check-Valid-Until=false
# 添加 Dpkg 选项：如果有默认选项就选默认，否则保留旧的配置文件(--force-confold)
apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Acquire::Check-Valid-Until=false
apt full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Acquire::Check-Valid-Until=false

# 5. 替换源为 USTC Bookworm 源
# 注意：Bookworm 起 non-free-firmware 独立为一个组件，需额外添加
echo "[Step 3/6] 正在将源替换为 USTC (Bookworm)..."

cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
# deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
# deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware

deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
# deb-src http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

echo "源替换完成。"

# 6. 更新软件源索引
echo "[Step 4/6] 更新软件源索引..."
apt update

# 7. 执行系统升级
echo "[Step 5/6] 开始执行版本升级 (全自动模式，这可能需要一段时间)..."

# 先进行最小化升级以避免依赖冲突
apt upgrade --without-new-pkgs -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

# 执行完整的发行版升级
apt full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

# 8. 清理残留
echo "[Step 6/6] 清理不再需要的旧软件包..."
apt autoremove -y
apt clean

echo "=========================================="
echo "升级操作已完成！"
echo "结束时间: $(date)"
echo "当前版本: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
echo "请检查上方是否有错误信息。"
echo "建议立即重启系统以应用更改: reboot"
echo "=========================================="