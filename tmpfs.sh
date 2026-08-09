#!/bin/bash

# 检查是否为 Debian 系
if ! grep -qi 'debian' /etc/os-release 2>/dev/null; then
    echo "错误: 此脚本仅适用于 Debian 系统。"
    exit 1
fi

# 记录修改前的 tmpfs 大小
before_size=$(findmnt -n /tmp -o OPTIONS | grep -oP 'size=\K[^,]+')

# 创建 drop-in 目录
mkdir -p /etc/systemd/system/tmp.mount.d

# 写入覆盖配置
cat > /etc/systemd/system/tmp.mount.d/override.conf << 'EOF'
[Mount]
Options=mode=1777,relatime,nosuid,nodev,size=2G
EOF

# 重新加载 systemd
systemctl daemon-reload

# 尝试重启 tmp.mount，失败也不影响（drop-in 重启后生效）
systemctl restart tmp.mount 2>/dev/null

# 记录修改后的 tmpfs 大小
after_size=$(findmnt -n /tmp -o OPTIONS | grep -oP 'size=\K[^,]+')

# 统一输出对比
echo "================================"
echo "  /tmp tmpfs 大小修改结果"
echo "================================"
echo ""
echo "  修改前: size=$before_size"
echo "  修改后: size=$after_size"
echo ""
echo "================================"