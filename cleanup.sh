#!/bin/bash

# ==========================================
# Debian / Alpine 系统垃圾清理脚本
# Author: QsSama
# ==========================================

# 定义日志文件位置
LOG_FILE="/var/log/system_cleanup.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "系统垃圾清理程序"
echo "开始时间: $(date)"
echo "=========================================="

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "错误: 请使用 root 权限运行此脚本"
  exit 1
fi

# 检测系统类型
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  echo "错误: 无法检测系统类型"
  exit 1
fi

echo "检测到系统: $PRETTY_NAME"

# 获取清理前磁盘使用情况
echo ""
echo "清理前磁盘使用情况:"
df -h / | tail -1

clean_debian() {
    echo ""
    echo "======== Debian/Ubuntu 清理 ========"

    echo "[1/6] 清理 apt 缓存..."
    apt clean
    apt autoclean

    echo "[2/6] 删除不再需要的软件包..."
    apt autoremove -y
    apt autoremove --purge -y

    echo "[3/6] 清理旧内核（保留当前和上一个）..."
    current_kernel=$(uname -r)
    dpkg --list 'linux-image*' | grep ^ii | awk '{print $2}' | while read kernel; do
        if [ "$kernel" != "linux-image-$current_kernel" ] && [ "$kernel" != "linux-image-generic" ]; then
            echo "  移除: $kernel"
            apt purge -y "$kernel" 2>/dev/null
        fi
    done

    echo "[4/6] 清理临时文件..."
    rm -rf /tmp/*
    rm -rf /var/tmp/*

    echo "[5/6] 清理旧日志（保留最近7天）..."
    find /var/log -type f -name "*.gz" -delete 2>/dev/null
    find /var/log -type f -name "*.old" -delete 2>/dev/null
    find /var/log -type f -name "*.1" -delete 2>/dev/null
    journalctl --vacuum-time=7d 2>/dev/null

    echo "[6/6] 清理用户缓存..."
    rm -rf /root/.cache/pip/http 2>/dev/null
    rm -rf /root/.npm/_cacache 2>/dev/null
    rm -rf /root/.yarn/cache 2>/dev/null

    echo "Debian 清理完成。"
}

clean_alpine() {
    echo ""
    echo "======== Alpine 清理 ========"

    echo "[1/4] 清理 apk 缓存..."
    apk cache clean

    echo "[2/4] 删除不再需要的软件包..."
    apk del $(apk list --installed --no-cache | grep -v -E "^(alpine|busybox|musl|ssl_client|wget|ca-certificates)" | awk -F/ '{print $1}') 2>/dev/null

    echo "[3/4] 清理临时文件..."
    rm -rf /tmp/*
    rm -rf /var/tmp/*

    echo "[4/4] 清理旧日志..."
    find /var/log -type f -name "*.gz" -delete 2>/dev/null
    find /var/log -type f -name "*.old" -delete 2>/dev/null
    find /var/log -type f -name "*.1" -delete 2>/dev/null

    echo "Alpine 清理完成。"
}

# 执行对应系统的清理
case $OS in
    debian|ubuntu|devuan|linuxmint|kali)
        clean_debian
        ;;
    alpine)
        clean_alpine
        ;;
    *)
        echo "错误: 不支持的系统类型: $OS"
        echo "本脚本支持 Debian/Ubuntu 系和 Alpine 系"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "清理完成！"
echo "结束时间: $(date)"
echo ""
echo "清理后磁盘使用情况:"
df -h / | tail -1
echo "=========================================="
