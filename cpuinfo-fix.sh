#!/bin/bash

# ==========================================
# CPU 信息伪装脚本（一键部署版）
# 用法: curl -sL URL/cpuinfo-fix.sh | bash
# ==========================================

BAK_FILE="/tmp/cpuinfo.bak"
SCRIPT_PATH="/usr/local/bin/cpuinfo-fix.sh"
SERVICE_FILE="/etc/systemd/system/cpuinfo-fix.service"

if [ "$EUID" -ne 0 ]; then
  echo "错误: 请使用 root 权限运行"
  exit 1
fi

# 1. 自动获取当前 CPU 型号
CURRENT_CPU=$(lscpu | grep "Model name" | sed 's/Model name:\s*//')

if [ -z "$CURRENT_CPU" ]; then
  echo "错误: 无法获取当前 CPU 信息"
  exit 1
fi

echo "当前 CPU 显示: $CURRENT_CPU"
echo "=========================================="
echo "请选择要伪装的 CPU 型号:"
echo ""
echo "  [1] Intel(R) Xeon(R) Gold 6248R @ 3.00GHz"
echo "  [2] Intel(R) Xeon(R) Platinum 8375C @ 2.90GHz"
echo "  [3] Intel(R) Xeon(R) E5-2696 v4 @ 2.50GHz"
echo "  [4] Intel(R) Core(TM) i9-13900K @ 3.00GHz"
echo "  [5] AMD EPYC 7763 64-Core Processor"
echo "  [0] 自定义输入"
echo ""
read -r -p "请输入选项 [0-5]: " CHOICE

case "$CHOICE" in
  1) REAL_CPU="Intel(R) Xeon(R) Gold 6248R @ 3.00GHz" ;;
  2) REAL_CPU="Intel(R) Xeon(R) Platinum 8375C @ 2.90GHz" ;;
  3) REAL_CPU="Intel(R) Xeon(R) E5-2696 v4 @ 2.50GHz" ;;
  4) REAL_CPU="Intel(R) Core(TM) i9-13900K @ 3.00GHz" ;;
  5) REAL_CPU="AMD EPYC 7763 64-Core Processor" ;;
  0)
    read -r -p "请输入自定义 CPU 型号: " REAL_CPU
    if [ -z "$REAL_CPU" ]; then
      echo "错误: CPU 型号不能为空"
      exit 1
    fi
    ;;
  *)
    echo "错误: 无效选项"
    exit 1
    ;;
esac

echo ""
echo "目标 CPU: $REAL_CPU"
echo "=========================================="

# 2. 创建伪装脚本
cat > "$SCRIPT_PATH" << 'SCRIPT'
#!/bin/bash
REAL_CPU="__REAL_CPU__"
CURRENT_CPU=$(lscpu | grep "Model name" | sed 's/Model name:\s*//')
if [ "$CURRENT_CPU" = "$REAL_CPU" ]; then
  exit 0
fi
BAK_FILE="/tmp/cpuinfo.bak"
cp /proc/cpuinfo "$BAK_FILE"
sed -i "s/${CURRENT_CPU}/${REAL_CPU}/g" "$BAK_FILE"
mount --bind "$BAK_FILE" /proc/cpuinfo
SCRIPT

# 替换占位符
sed -i "s|__REAL_CPU__|${REAL_CPU}|g" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"

# 3. 立即执行
"$SCRIPT_PATH"

# 4. 创建 systemd 服务实现开机自启
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=CPU info display fix
After=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cpuinfo-fix.service
systemctl start cpuinfo-fix.service

# 5. 验证
echo ""
echo "=========================================="
echo "  部署完成!"
echo "=========================================="
echo ""
echo "  当前显示:"
lscpu | grep "Model name"
echo ""
echo "  脚本路径: $SCRIPT_PATH"
echo "  服务名: cpuinfo-fix.service"
echo ""
echo "  管理命令:"
echo "    查看状态: systemctl status cpuinfo-fix"
echo "    卸载:     systemctl disable cpuinfo-fix && rm -f $SCRIPT_PATH $SERVICE_FILE"