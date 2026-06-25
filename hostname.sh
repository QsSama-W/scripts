#!/bin/sh

# root 权限检查
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须以 root 权限运行"
    exit 1
fi

# 输入新主机名
printf "请输入新主机名: "
read -r NEW_HOSTNAME

# 空值检查
if [ -z "$NEW_HOSTNAME" ]; then
    echo "错误：主机名不能为空"
    exit 1
fi

# 主机名合法性校验
case "$NEW_HOSTNAME" in
    *[!a-zA-Z0-9.-]*)
        echo "错误：主机名包含非法字符"
        exit 1
        ;;
    .* | *. | -* | *- | *..* )
        # 拦截：以点/横杠开头，以点/横杠结尾，或包含连续的点
        echo "错误：主机名格式非法"
        exit 1
        ;;
esac

# systemd 环境
if [ -d /run/systemd/system ] && command -v hostnamectl >/dev/null 2>&1; then

    hostnamectl set-hostname "$NEW_HOSTNAME"

    echo "[OK] 已通过 hostnamectl 修改"

else

    # OpenRC / Alpine / BusyBox / 容器
    if command -v hostname >/dev/null 2>&1; then
        hostname "$NEW_HOSTNAME" 2>/dev/null || \
            echo "提示：运行时主机名修改跳过（可能是容器无特权环境）"
    fi

    # 持久化
    echo "$NEW_HOSTNAME" > /etc/hostname

    echo "[OK] 已更新 /etc/hostname"

fi

# Debian / Ubuntu hosts 兼容
if [ -f /etc/debian_version ]; then

    if grep -q '^127\.0\.1\.1' /etc/hosts; then

        # 保留后续 alias，仅替换 hostname
        sed -i \
            "s/^127\.0\.1\.1[[:space:]]\+[^[:space:]]\+/127.0.1.1 $NEW_HOSTNAME/" \
            /etc/hosts

    else

        echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts

    fi

    echo "[OK] 已更新 Debian hosts 映射"

fi

echo "-----------------------------------"
echo "修改完成"
echo "当前主机名：$(hostname)"