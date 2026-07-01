#!/bin/bash

# ==========================================
# Debian 13 (Trixie) 系统更新脚本
# 检查内存和磁盘，执行系统更新
# Author: QsSama
# ==========================================

LOG_FILE="/var/log/debian13_update.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Debian 13 系统更新程序"
echo "开始时间: $(date)"
echo "=========================================="

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "错误: 请使用 root 权限运行此脚本"
  exit 1
fi

# 2. 检查系统版本（必须是 Debian 13）
if [ ! -f /etc/os-release ]; then
  echo "错误: 无法检测系统版本"
  exit 1
fi

. /etc/os-release

if [ "$VERSION_CODENAME" != "trixie" ]; then
  echo "错误: 本脚本仅支持 Debian 13 (Trixie)"
  echo "当前版本: $PRETTY_NAME"
  exit 1
fi
echo "系统版本: $PRETTY_NAME ✓"

# 3. 检查内存（最小要求 950M）
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
echo "内存大小: ${TOTAL_MEM}MB"

if [ "$TOTAL_MEM" -lt 950 ]; then
  echo ""
  echo "错误: 内存不足，更新最低要求 1GB"
  echo "当前内存: ${TOTAL_MEM}MB"
  exit 1
fi
echo "内存检查通过 ✓"

# 4. 检查磁盘空间（最小要求 9G）
DISK_AVAIL=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
echo "可用磁盘: ${DISK_AVAIL}G"

if [ "$DISK_AVAIL" -lt 9 ]; then
  echo ""
  echo "错误: 磁盘空间不足，更新最低要求 10GB"
  echo "当前可用: ${DISK_AVAIL}GB"
  exit 1
fi
echo "磁盘检查通过 ✓"

# 5. 设置非交互模式
export DEBIAN_FRONTEND=noninteractive

# 6. 执行升级
echo ""
echo "[Step 1/3] 更新软件源..."
apt update

echo ""
echo "[Step 2/3] 升级软件包..."
apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

echo ""
echo "[Step 3/3] 清理..."
apt autoremove -y
apt clean

echo ""
echo "=========================================="
echo "更新完成！"
echo "结束时间: $(date)"
echo "当前版本: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
echo "建议立即重启: reboot"
echo "=========================================="
