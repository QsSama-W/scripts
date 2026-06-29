#!/bin/bash

# ==========================================
# 一键挂载数据盘到 /www
# ==========================================

if [ "$EUID" -ne 0 ]; then
  echo "错误: 请使用 root 权限运行"
  exit 1
fi

# 1. 列出所有磁盘，让用户确认
echo "当前磁盘列表:"
lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT
echo ""
echo "=========================================="
echo "默认将挂载第一个未挂载的数据盘到 /www"
echo "=========================================="

# 2. 自动检测未挂载的数据盘（排除系统盘）
DISK=""
for dev in /dev/sd[b-z] /dev/vd[b-z] /dev/nvme[1-9]n[1-9]p[1-9]; do
  [ -b "$dev" ] || continue
  # 跳过已挂载的
  if ! findmnt -rno SOURCE "$dev" &>/dev/null; then
    DISK="$dev"
    break
  fi
done

if [ -z "$DISK" ]; then
  echo "未检测到未挂载的磁盘。"
  echo "手动输入磁盘路径 (例如 /dev/sdb1):"
  read -r DISK
fi

if [ ! -b "$DISK" ]; then
  echo "错误: $DISK 不存在"
  exit 1
fi

echo "将挂载: $DISK -> /www"

# 3. 检查是否已挂载
if findmnt -rno SOURCE "$DISK" &>/dev/null; then
  echo "警告: $DISK 已经挂载在 $(findmnt -rno TARGET "$DISK")"
  echo "是否继续？(y/N)"
  read -r CONFIRM
  [ "$CONFIRM" != "y" ] && exit 0
fi

# 4. 创建挂载点
mkdir -p /www

# 5. 获取文件系统类型
FSTYPE=$(blkid -o value -s TYPE "$DISK" 2>/dev/null)
if [ -z "$FSTYPE" ]; then
  echo "未检测到文件系统，是否格式化为 ext4？(y/N)"
  read -r CONFIRM
  [ "$CONFIRM" != "y" ] && exit 0
  mkfs.ext4 -F "$DISK"
  FSTYPE="ext4"
fi

echo "文件系统类型: $FSTYPE"

# 6. 挂载
mount "$DISK" /www
echo "挂载成功。"

# 7. 获取 UUID
UUID=$(blkid -s UUID -o value "$DISK")

# 8. 写入 fstab（先移除旧的 /www 挂载条目）
sed -i '\|/www|d' /etc/fstab
echo "UUID=$UUID /www $FSTYPE defaults 0 2" >> /etc/fstab

echo "=========================================="
echo "挂载完成!"
echo "磁盘: $DISK"
echo "挂载点: /www"
echo "fstab 已更新，重启后自动挂载"
echo "=========================================="
