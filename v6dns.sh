#!/bin/bash

# v6dns.sh - 纯V6机器自动配置可用的NAT64 DNS

LOG_FILE="/var/log/v6dns.log"
RESOLV_CONF="/etc/resolv.conf"

# NAT64 DNS64 服务器列表
DNS64_SERVERS=(
    "2602:fc59:b0:9e::64"
    "2602:fc59:11:1::64"
    "2a00:1098:2b::1"
    "2a00:1098:2c::1"
    "2a01:4f8:c2c:123f::1"
    "2a01:4f9:c010:3f02::1"
    "2001:67c:2b0::4"
    "2001:67c:2b0::6"
)

# 普通 DNS（纯V4备用）
DNS_V4=(
    "8.8.8.8"
    "1.1.1.1"
)

# 普通 DNS（纯V6备用）
DNS_V6=(
    "2001:4860:4860::8888"
    "2606:4700:4700::1111"
)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# 测试 DNS 是否可用
test_dns() {
    local dns="$1"
    # 尝试解析 a.root-servers.net，2秒超时
    if ping6 -c1 -W2 "$dns" &>/dev/null; then
        return 0
    fi
    return 1
}

# 判断机器是纯V4还是纯V6还是双栈
detect_stack() {
    local has_v4=false
    local has_v6=false

    ip -4 addr show scope global 2>/dev/null | grep -q "inet " && has_v4=true
    ip -6 addr show scope global 2>/dev/null | grep -q "inet6 " && has_v6=true

    if $has_v4 && $has_v6; then
        echo "dual"
    elif $has_v6; then
        echo "ipv6"
    elif $has_v4; then
        echo "ipv4"
    else
        echo "none"
    fi
}

main() {
    log "===== 开始检测 ====="

    local stack
    stack=$(detect_stack)
    log "网络类型: $stack"

    # 解锁 resolv.conf
    chattr -i "$RESOLV_CONF" 2>/dev/null

    local working_dns=()

    case "$stack" in
        ipv6)
            log "检测到纯V6环境，测试 NAT64 DNS64..."
            for dns in "${DNS64_SERVERS[@]}"; do
                if test_dns "$dns"; then
                    log "可用: $dns"
                    working_dns+=("$dns")
                    # 找到两个就够了
                    if [[ ${#working_dns[@]} -ge 2 ]]; then
                        break
                    fi
                else
                    log "不可用: $dns"
                fi
            done

            # 备用普通V6 DNS
            for dns in "${DNS_V6[@]}"; do
                working_dns+=("$dns")
            done
            ;;
        ipv4)
            log "检测到纯V4环境"
            working_dns=("${DNS_V4[@]}")
            ;;
        dual)
            log "检测到双栈环境"
            working_dns=("${DNS_V6[@]}" "${DNS_V4[@]}")
            ;;
        *)
            log "未检测到有效网络接口，跳过"
            exit 1
            ;;
    esac

    # 写入 resolv.conf
    if [[ ${#working_dns[@]} -gt 0 ]]; then
        : > "$RESOLV_CONF"
        for dns in "${working_dns[@]}"; do
            echo "nameserver $dns" >> "$RESOLV_CONF"
        done
        log "已写入 resolv.conf: ${working_dns[*]}"
    fi

    # 锁定文件防覆盖
    chattr +i "$RESOLV_CONF"
    log "已锁定 resolv.conf"
    log "===== 完成 ====="
}

main