#!/bin/bash

INSTALL_DIR="/opt/wendu"
SERVICE_FILE="/etc/systemd/system/wendu-monitor.service"

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本"
    echo "执行方式：sudo bash install_wendu.sh"
    exit 1
fi

echo "======================================"
echo "  温度监控工具 wendu 一键安装"
echo "  实时刷新 + 飞书告警 + 开机自启"
echo "======================================"
echo ""

# 前置：先更新软件源并且全自动升级所有可升级包，消除apt可升级提示
echo "[前置] 更新软件源并升级全部软件包，请稍等……"
apt update -qq
apt upgrade -y

# 1. 创建安装目录
echo "[1/6] 创建安装目录 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 2. 安装系统依赖
echo "[2/6] 安装依赖包 (lm-sensors / python3-requests / python3-curses)"
apt install -y lm-sensors python3-requests python3-curses > /dev/null 2>&1

# 3. 写入配置文件
echo "[3/6] 生成默认配置文件 config.json"
cat > "$INSTALL_DIR/config.json" << 'EOF'
{
    "feishu": {
        "webhook_url": "https://open.feishu.cn/open-apis/bot/v2/hook/替换为你的webhook地址",
        "secret": "替换为你的签名密钥",
        "enable": false
    },
    "threshold": {
        "cpu_critical": 85,
        "cpu_warning": 75,
        "nvme_critical": 75,
        "nvme_warning": 65
    },
    "monitor": {
        "interval": 60,
        "alert_cooldown": 300
    }
}
EOF

# 4. 写入主程序 wendu.py
echo "[4/6] 写入主程序 wendu.py"
cat > "$INSTALL_DIR/wendu.py" << 'PYEOF'
#!/usr/bin/env python3
import json
import os
import sys
import time
import hmac
import hashlib
import base64
import urllib.parse
import subprocess
import re
from datetime import datetime

CONFIG_PATH = "/opt/wendu/config.json"
SERVICE_NAME = "wendu-monitor"

def load_config():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)

def gen_feishu_sign(secret):
    timestamp = str(int(time.time()))
    string_to_sign = f"{timestamp}\n{secret}"
    hmac_code = hmac.new(
        string_to_sign.encode("utf-8"),
        digestmod=hashlib.sha256
    ).digest()
    sign = urllib.parse.quote_plus(base64.b64encode(hmac_code))
    return timestamp, sign

def send_feishu(title, content):
    cfg = load_config()["feishu"]
    if not cfg.get("enable") or not cfg.get("webhook_url"):
        return

    url = cfg["webhook_url"]
    secret = cfg.get("secret", "")

    payload = {
        "msg_type": "interactive",
        "card": {
            "header": {
                "title": {"tag": "plain_text", "content": title},
                "template": "red"
            },
            "elements": [
                {"tag": "markdown", "content": content}
            ]
        }
    }

    if secret:
        timestamp, sign = gen_feishu_sign(secret)
        url += f"&timestamp={timestamp}&sign={sign}"

    try:
        import requests
        requests.post(url, json=payload, timeout=5)
    except Exception:
        pass

def get_sensors_data():
    try:
        out = subprocess.check_output(["sensors"], text=True)
    except FileNotFoundError:
        print("错误：未安装 lm-sensors，请先执行 sudo apt install lm-sensors")
        sys.exit(1)

    data = {"cpu_cores": {}, "cpu_package": None, "nvme": None, "acpi": None}

    # CPU Package
    m = re.search(r"Package id 0:\s+\+([\d.]+)°C", out)
    if m:
        data["cpu_package"] = float(m.group(1))

    # CPU 核心
    for match in re.finditer(r"Core (\d+):\s+\+([\d.]+)°C", out):
        data["cpu_cores"][int(match.group(1))] = float(match.group(2))

    # NVMe Composite
    m = re.search(r"Composite:\s+\+([\d.]+)°C", out)
    if m:
        data["nvme"] = float(m.group(1))

    # ACPI 环境温度
    m = re.search(r"temp1:\s+\+([\d.]+)°C", out)
    if m:
        data["acpi"] = float(m.group(1))

    return data

def print_cli():
    data = get_sensors_data()
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    print("=" * 40)
    print(f"  温度监控 - {now}")
    print("=" * 40)

    if data["cpu_package"] is not None:
        print(f"  CPU 封装 : {data['cpu_package']:>5.1f} °C")
    for core, temp in sorted(data["cpu_cores"].items()):
        print(f"  CPU 核心{core}: {temp:>5.1f} °C")

    if data["nvme"] is not None:
        print(f"  NVMe 固态 : {data['nvme']:>5.1f} °C")

    if data["acpi"] is not None:
        print(f"  主板环境  : {data['acpi']:>5.1f} °C")

    print("=" * 40)

def live_view():
    """实时刷新温度界面，终端原位重绘，不刷屏"""
    import curses

    def draw(stdscr):
        curses.curs_set(0)
        stdscr.nodelay(True)
        refresh_interval = 2

        while True:
            key = stdscr.getch()
            if key == ord('q'):
                break

            data = get_sensors_data()
            now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

            stdscr.clear()
            stdscr.addstr(0, 0, "=" * 40)
            stdscr.addstr(1, 0, f"  实时温度监控 - {now}")
            stdscr.addstr(2, 0, "=" * 40)

            line = 3
            if data["cpu_package"] is not None:
                stdscr.addstr(line, 0, f"  CPU 封装 : {data['cpu_package']:>5.1f} °C")
                line += 1
            for core, temp in sorted(data["cpu_cores"].items()):
                stdscr.addstr(line, 0, f"  CPU 核心{core}: {temp:>5.1f} °C")
                line += 1

            if data["nvme"] is not None:
                stdscr.addstr(line, 0, f"  NVMe 固态 : {data['nvme']:>5.1f} °C")
                line += 1

            if data["acpi"] is not None:
                stdscr.addstr(line, 0, f"  主板环境  : {data['acpi']:>5.1f} °C")
                line += 1

            stdscr.addstr(line + 1, 0, "=" * 40)
            stdscr.addstr(line + 2, 0, "  按 q 退出")

            stdscr.refresh()
            time.sleep(refresh_interval)

    try:
        curses.wrapper(draw)
    except KeyboardInterrupt:
        pass

def monitor_loop():
    cfg = load_config()
    th = cfg["threshold"]
    interval = cfg["monitor"]["interval"]
    cooldown = cfg["monitor"]["alert_cooldown"]

    last_alert = {"cpu": 0, "nvme": 0}

    print("温度监控已启动，按 Ctrl+C 退出\n")

    while True:
        try:
            data = get_sensors_data()
        except Exception:
            time.sleep(interval)
            continue
        now = time.time()
        alerts = []

        # CPU 告警
        if data["cpu_package"] and data["cpu_package"] >= th["cpu_critical"]:
            if now - last_alert["cpu"] > cooldown:
                alerts.append(("CPU温度严重告警",
                    f"CPU 封装温度：**{data['cpu_package']}°C**\n"
                    f"阈值：{th['cpu_critical']}°C"))
                last_alert["cpu"] = now

        # NVMe 告警
        if data["nvme"] and data["nvme"] >= th["nvme_critical"]:
            if now - last_alert["nvme"] > cooldown:
                alerts.append(("NVMe温度严重告警",
                    f"NVMe 温度：**{data['nvme']}°C**\n"
                    f"阈值：{th['nvme_critical']}°C"))
                last_alert["nvme"] = now

        for title, content in alerts:
            send_feishu(title, content)
            print(f"[{datetime.now().strftime('%H:%M:%S')}] 已发送告警: {title}")

        time.sleep(interval)

def manage_service(action):
    """管理 systemd 服务"""
    cmd = ["systemctl", action, SERVICE_NAME]
    subprocess.run(cmd, check=True)
    if action != "status":
        print(f"✅ 服务 {action} 操作完成")

def print_help():
    print("wendu 温度监控工具")
    print("")
    print("基础用法:")
    print("  wendu          查看当前温度（单次）")
    print("  wendu live     实时刷新温度界面（原位不刷屏，q退出）")
    print("  wendu monitor  前台运行监控告警程序")
    print("")
    print("服务管理:")
    print("  wendu start    启动后台监控服务")
    print("  wendu stop     停止后台监控服务")
    print("  wendu restart  重启后台服务（修改配置后执行）")
    print("  wendu status   查看服务运行状态")
    print("  wendu enable   启用开机自启")
    print("  wendu disable  禁用开机自启")
    print("")
    print("其他:")
    print("  wendu help     查看帮助")

def main():
    if len(sys.argv) < 2:
        print_cli()
        return

    cmd = sys.argv[1]

    if cmd == "monitor":
        try:
            monitor_loop()
        except KeyboardInterrupt:
            print("\n已停止监控")
    elif cmd == "live":
        live_view()
    elif cmd in ["start", "stop", "restart", "status", "enable", "disable"]:
        manage_service(cmd)
    elif cmd in ["-h", "--help", "help"]:
        print_help()
    else:
        print(f"未知命令: {cmd}")
        print_help()
        sys.exit(1)

if __name__ == "__main__":
    main()
PYEOF

# 5. 设置权限和软链接
echo "[5/6] 设置执行权限并创建全局命令"
chmod +x "$INSTALL_DIR/wendu.py"
ln -sf "$INSTALL_DIR/wendu.py" /usr/local/bin/wendu

# 6. 创建 systemd 开机自启服务
echo "[6/6] 创建 systemd 开机自启服务"
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Wendu Temperature Monitor Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/wendu
ExecStart=/usr/bin/python3 /opt/wendu/wendu.py monitor
Restart=always
RestartSec=10
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo ""
echo "======================================"
echo "  ✅ 安装完成！"
echo "======================================"
echo ""
echo "基础命令："
echo "  wendu          # 单次查看温度"
echo "  wendu live     # 实时刷新温度（原位不刷屏，q退出）"
echo "  wendu monitor  # 前台运行告警监控"
echo ""
echo "服务管理："
echo "  wendu enable   # 启用开机自启"
echo "  wendu start    # 启动后台监控服务"
echo "  wendu restart  # 修改配置后重启生效"
echo "  wendu status   # 查看服务状态"
echo ""
echo "配置文件路径：/opt/wendu/config.json"
echo "⚠️  请填入飞书webhook和密钥并将enable设为true，再启动服务"
echo ""
echo "如首次使用传感器，请先执行："
echo "  sudo sensors-detect （全程回车默认即可）"
echo "  加载传感器驱动：modprobe lm_sensors"
echo ""