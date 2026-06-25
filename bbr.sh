#!/bin/sh
# ============================================
# BBR 启用脚本 —— 通用，兼容 Alpine / Debian
# 容器安全，内存友好
# ============================================

set -e

# ---------- 判断发行版 ----------
if [ -f /etc/alpine-release ]; then
    DISTRO="alpine"
elif [ -f /etc/debian_version ]; then
    DISTRO="debian"
else
    DISTRO="unknown"
fi

# ---------- 1. 内核版本检查 ----------
KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)
if [ "$KERNEL_MAJOR" -lt 4 ] || { [ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -lt 9 ]; }; then
    echo "错误: 内核 $(uname -r) 版本过低，BBR 需要 ≥ 4.9"
    exit 1
fi
echo "[1/7] 内核版本 $(uname -r) ✓"

# ---------- 2. 加载 BBR 模块 ----------
if modprobe tcp_bbr 2>/dev/null; then
    echo "[2/7] tcp_bbr 模块已加载"
elif [ -d /sys/module/tcp_bbr ]; then
    echo "[2/7] tcp_bbr 已内置在内核中"
else
    echo "[2/7] 跳过 tcp_bbr 加载（容器环境或模块不可用）"
fi

# ---------- 3. 检测可用的队列调度器 ----------
QDISC=""
if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
    QDISC="fq"
    echo "[3/7] 队列调度器: fq"
elif sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1; then
    QDISC="fq_codel"
    echo "[3/7] 队列调度器: fq_codel（fq 不可用，已降级）"
else
    echo "[3/7] default_qdisc 不可用（容器限制），跳过"
fi

# ---------- 4. 检测 BBR 是否可用 ----------
if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    echo "[4/7] 错误: 无法设置 tcp_congestion_control=bbr"
    exit 1
fi
echo "[4/7] tcp_congestion_control 已设为 bbr"

# ---------- 5. 开机自动加载模块 ----------
case "$DISTRO" in
    alpine)
        MODULE_FILE="/etc/conf.d/modules"
        if [ -f "$MODULE_FILE" ]; then
            if ! grep -q "tcp_bbr" "$MODULE_FILE"; then
                if grep -q "^modules=" "$MODULE_FILE"; then
                    sed -i 's/^modules="$$.*$$"/modules="tcp_bbr \1"/' "$MODULE_FILE"
                else
                    echo 'modules="tcp_bbr"' >> "$MODULE_FILE"
                fi
            fi
        else
            echo 'modules="tcp_bbr"' > "$MODULE_FILE"
        fi
        echo "[5/7] 写入 $MODULE_FILE"
        ;;
    debian)
        mkdir -p /etc/modules-load.d
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        echo "[5/7] 写入 /etc/modules-load.d/bbr.conf"
        ;;
    *)
        echo "[5/7] 未知系统，跳过模块自加载配置"
        ;;
esac

# ---------- 6. 写入 sysctl（持久化） ----------
safe_delete() {
    local escaped_key
    escaped_key=$(echo "$1" | sed 's/\./\\./g')
    sed -i "/^#*${escaped_key}[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null || true
}

if [ -n "$QDISC" ]; then
    safe_delete "net.core.default_qdisc"
    echo "net.core.default_qdisc = $QDISC" >> /etc/sysctl.conf
fi
safe_delete "net.ipv4.tcp_congestion_control"
echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
echo "[6/7] 写入 /etc/sysctl.conf"

# ---------- 7. 验证 ----------
CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control)

echo "[7/7] 验证:"
echo "  拥塞算法 = $CC"
if [ -n "$QDISC" ]; then
    QD=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "不可用")
    echo "  队列调度 = $QD"
fi

if [ "$CC" = "bbr" ]; then
    echo "✓ BBR 已成功启用"
else
    echo "✗ BBR 未生效"
    exit 1
fi
