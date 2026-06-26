# Scripts

常用运维脚本集合，兼容 Alpine / Debian 系统。

项目地址：https://github.com/QsSama-W/scripts

## 脚本列表

| 脚本 | 功能 |
|------|------|
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

## 一键安装

### BBR 启用

Alpine / Debian 通用：
```bash
wget -qO- https://raw.githubusercontent.com/QsSama-W/scripts/main/bbr.sh?t=$RANDOM | sh
```

### 修改主机名

```bash
wget -qO- https://raw.githubusercontent.com/QsSama-W/scripts/main/hostname.sh?t=$RANDOM | sh
```

### 安装 DDNS-GO

需要 bash：
```bash
wget -qO- https://raw.githubusercontent.com/QsSama-W/scripts/main/install_ddns_go.sh?t=$RANDOM | bash
```

### 安装 sing-box（多协议版）

支持 Shadowsocks / Hysteria2 / TUIC / VLESS Reality，需要 bash：
```bash
wget -qO- https://raw.githubusercontent.com/QsSama-W/scripts/main/install-singbox-lite.sh?t=$RANDOM | bash
```

### 安装 sing-box（带 SANs 版本）

与上一版区别在于自签证书带 SANs 扩展，需要 bash：
```bash
wget -qO- https://raw.githubusercontent.com/QsSama-W/scripts/main/install-singbox-lite-SANs.sh?t=$RANDOM | bash
```

### LXC/LXD 开放 IPv6 端口

需要 bash：
```bash
wget -qO- https://raw.githubusercontent.com/QsSama-W/scripts/main/open_v6_port.sh?t=$RANDOM | bash
```

### IPv6 地址管理

需要 bash：
```bash
wget -qO- https://raw.githubusercontent.com/QsSama-W/scripts/main/v6set.sh?t=$RANDOM | bash
```

### Realm 端口转发

需要 bash：
```bash
wget -qO- https://raw.githubusercontent.com/QsSama-W/scripts/main/zzj-v2.sh?t=$RANDOM | bash
```

### Debian 12 升级到 Debian 13

需要 bash：
```bash
apt update && apt install -y wget && wget -O - https://raw.githubusercontent.com/QsSama-W/scripts/main/update13.sh?t=$RANDOM | bash
```

### 纯V6机器配置NAT64 DNS

需要 bash：
```bash
wget -qO- https://raw.githubusercontent.com/QsSama-W/scripts/main/v6dns.sh?t=$RANDOM | bash
```
