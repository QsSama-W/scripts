#!/bin/bash

# ==========================================
# 一键挂载数据盘到 /www
# 兼容 sda/sdb/vda/vdb/nvme 等多种磁盘类型
# 强制格式化，无需手动交互
# ==========================================

MOUNT_POINT="/www"
FSTYPE="ext4"

if [ "$EUID" -ne 0 ]; then
  echo "错误: 请使用 root 权限运行"
  exit 1
fi

echo "=========================================="
echo "  一键挂载数据盘脚本"
echo "=========================================="
echo ""

# 1. 获取系统盘（根分区所在的磁盘）
ROOT_DEV=$(findmnt -nro SOURCE / | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
echo "系统盘: $ROOT_DEV"
echo ""

# 2. 列出所有块设备
echo "当前磁盘列表:"
echo "------------------------------------------"
lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v "loop"
echo "------------------------------------------"
echo ""

# 3. 自动检测数据盘（排除系统盘和光驱）
DISK=""
for dev in \
  /dev/vd[b-z] \
  /dev/sd[b-z] \
  /dev/xvd[b-z] \
  /dev/nvme[1-9]n1 \
  /dev/vd[a-z][a-z] \
  /dev/sd[a-z][a-z]; do

  [ -b "$dev" ] || continue

  # 跳过系统盘
  if [ "$dev" = "$ROOT_DEV" ]; then
    continue
  fi

  # 跳过已挂载的
  if findmnt -rno SOURCE "$dev" &>/dev/null; then
    continue
  fi

  DISK="$dev"
  break
done

# 4. 如果自动检测失败，再尝试检测有分区号的
if [ -z "$DISK" ]; then
  for dev in \
    /dev/vd[b-z]1 \
    /dev/sd[b-z]1 \
    /dev/xvd[b-z]1 \
    /dev/nvme[1-9]n1p1 \
    /dev/vd[a-z][a-z]1 \
    /dev/sd[a-z][a-z]1; do

    [ -b "$dev" ] || continue

    # 获取该分区所属的整盘
    PARENT=$(lsblk -nro PKNAME "$dev" 2>/dev/null)
    PARENT_DEV="/dev/$PARENT"

    # 跳过系统盘的分区
    if [ "$PARENT_DEV" = "$ROOT_DEV" ]; then
      continue
    fi

    # 跳过已挂载的
    if findmnt -rno SOURCE "$dev" &>/dev/null; then
      continue
    fi

    DISK="$dev"
    break
  done
fi

# 5. 最终判断
if [ -z "$DISK" ]; then
  echo "未检测到可用的数据盘。"
  echo ""
  echo "所有磁盘信息:"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
  echo ""
  echo "手动输入磁盘路径 (例如 /dev/sdb 或 /dev/vdb1):"
  read -r DISK
fi

if [ ! -b "$DISK" ]; then
  echo "错误: $DISK 不是一个有效的块设备"
  exit 1
fi

# 6. 再次确认不是系统盘
PARENT_DEV=$(echo "$DISK" | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
if [ "$PARENT_DEV" = "$ROOT_DEV" ]; then
  echo "错误: 检测到 $DISK 属于系统盘，拒绝操作!"
  exit 1
fi

echo "=========================================="
echo "目标磁盘: $DISK"
echo "挂载目录: $MOUNT_POINT"
echo "文件系统: $FSTYPE"
echo "=========================================="
echo ""

# 7. 如果已挂载在目标目录，先卸载
if findmnt -rno SOURCE "$MOUNT_POINT" &>/dev/null; then
  echo "检测到 $MOUNT_POINT 已有挂载，先卸载..."
  umount -l "$MOUNT_POINT" 2>/dev/null
  sleep 1
fi

# 8. 如果磁盘已挂载在其他位置，先卸载
if findmnt -rno SOURCE "$DISK" &>/dev/null; then
  OLD_MOUNT=$(findmnt -rno TARGET "$DISK")
  echo "检测到 $DISK 已挂载在 $OLD_MOUNT，先卸载..."
  umount -l "$DISK" 2>/dev/null
  sleep 1
fi

# 9. 创建挂载点
mkdir -p "$MOUNT_POINT"

# 10. 强制格式化
echo "正在格式化 $DISK 为 $FSTYPE ..."
mkfs.ext4 -F "$DISK"
if [ $? -ne 0 ]; then
  echo "错误: 格式化失败!"
  exit 1
fi
echo "格式化完成。"
echo ""

# 11. 挂载
echo "正在挂载 $DISK -> $MOUNT_POINT ..."
mount "$DISK" "$MOUNT_POINT"
if [ $? -ne 0 ]; then
  echo "错误: 挂载失败!"
  exit 1
fi

# 12. 验证挂载
if ! findmnt -rno SOURCE "$MOUNT_POINT" &>/dev/null; then
  echo "错误: 挂载验证失败!"
  exit 1
fi

# 13. 获取 UUID
UUID=$(blkid -s UUID -o value "$DISK")

# 14. 写入 fstab（先移除旧的 /www 条目）
sed -i "\|${MOUNT_POINT}|d" /etc/fstab
echo "UUID=$UUID $MOUNT_POINT $FSTYPE defaults 0 2" >> /etc/fstab

# 15. 输出结果
echo ""
echo "=========================================="
echo "  挂载完成!"
echo "=========================================="
echo "  磁盘:   $DISK"
echo "  UUID:   $UUID"
echo "  挂载点: $MOUNT_POINT"
echo "  文件系统: $FSTYPE"
echo "=========================================="
echo ""

# 16. 显示最终状态
df -h | grep -E "Filesystem|$MOUNT_POINT"
echo ""
echo "fstab 已更新，重启后自动挂载。"