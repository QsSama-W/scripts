# Scripts

常用运维脚本集合，兼容 Alpine / Debian 系统。

项目地址：https://github.com/QsSama-W/scripts

## 脚本列表

| 脚本 | 功能 |
|------|------|
| `menu.sh` | 脚本管理器（一键选择执行所有脚本） |
| `bbr.sh` | 启用 BBR 拥塞控制算法 |
| `hostname.sh` | 修改主机名 |
| `install_ddns_go.sh` | 安装/更新 DDNS-GO |
| `install-singbox-lite.sh` | 安装 sing-box（多协议支持） |
| `install-singbox-lite-SANs.sh` | 安装 sing-box（带 SANs 证书） |
| `open_v6_port.sh` | LXC/LXD 开放 IPv6 端口 |
| `v6set.sh` | IPv6 地址管理工具 |
| `zzj-v2.sh` | Realm 端口转发管理 |
| `update13.sh` | Debian 12 升级到 Debian 13 (Trixie) |
| `v6dns.sh` | 纯V6机器自动配置NAT64 DNS |
| `cleanup.sh` | Debian/Alpine 系统垃圾清理 |
| `upgrade-debian.sh` | Debian 13 系统更新（带内存/磁盘检查） |

## 一键安装

## 一键安装

### 脚本管理器（一键选择所有脚本）

一键拉取最新脚本列表并选择执行，自动安装缺失依赖（Debian/Alpine 通用）：
```bash
[ -x "$(command -v curl)" ] || { command -v apk >/dev/null && apk add -f curl || apt-get install -y curl; }; [ -x "$(command -v bash)" ] || { command -v apk >/dev/null && apk add -f bash || apt-get install -y bash; }; curl -sL -o /tmp/menu.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/menu.sh?t=$RANDOM"; bash /tmp/menu.sh
```

### BBR 启用

Alpine / Debian 通用：
```bash
wget -O bbr.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/bbr.sh?t=$RANDOM" && bash bbr.sh
```

### 修改主机名

```bash
wget -O hostname.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/hostname.sh?t=$RANDOM" && bash hostname.sh
```

### 安装 DDNS-GO

需要 bash：
```bash
wget -O install_ddns_go.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/install_ddns_go.sh?t=$RANDOM" && bash install_ddns_go.sh
```

### 安装 sing-box（多协议版）

支持 Shadowsocks / Hysteria2 / TUIC / VLESS Reality，需要 bash：
```bash
wget -O install-singbox-lite.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/install-singbox-lite.sh?t=$RANDOM" && bash install-singbox-lite.sh
```

### 安装 sing-box（带 SANs 版本）

与上一版区别在于自签证书带 SANs 扩展，需要 bash：
```bash
wget -O install-singbox-lite-SANs.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/install-singbox-lite-SANs.sh?t=$RANDOM" && bash install-singbox-lite-SANs.sh
```

### LXC/LXD 开放 IPv6 端口

需要 bash：
```bash
wget -O open_v6_port.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/open_v6_port.sh?t=$RANDOM" && bash open_v6_port.sh
```

### IPv6 地址管理

需要 bash：
```bash
wget -O v6set.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/v6set.sh?t=$RANDOM" && bash v6set.sh
```

### Realm 端口转发

需要 bash：
```bash
wget -O zzj-v2.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/zzj-v2.sh?t=$RANDOM" && bash zzj-v2.sh
```

### Debian 11 升级到 Debian 12

需要 bash：
```bash
apt install -y wget && wget -O update12.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/update12.sh?t=$RANDOM" && bash update12.sh
```


### Debian 12 升级到 Debian 13

需要 bash：
```bash
apt update && apt install -y wget && wget -O update13.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/update13.sh?t=$RANDOM" && bash update13.sh
```

### 纯V6机器配置NAT64 DNS

需要 bash：
```bash
wget -O v6dns.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/v6dns.sh?t=$RANDOM" && bash v6dns.sh
```

### 下载速度测试

需要 bash：
```bash
wget -O speed-test.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/speed-test.sh?t=$RANDOM" && bash speed-test.sh
```

### 挂载数据盘到/www

需要 bash：
```bash
wget -O mount_www.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/mount_www.sh?t=$RANDOM" && bash mount_www.sh
```

### 系统垃圾清理

Debian / Alpine 通用，需要 bash：
```bash
wget -O cleanup.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/cleanup.sh?t=$RANDOM" && bash cleanup.sh
```

### Debian 13 系统更新

需要 bash（自动检查内存≥1G、磁盘≥10G）：
```bash
wget -O upgrade-debian.sh "https://raw.githubusercontent.com/QsSama-W/scripts/main/upgrade-debian.sh?t=$RANDOM" && bash upgrade-debian.sh
```