#!/bin/bash
set -e

# ==================== Colors ====================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
CYAN="\033[96m"
RESET="\033[0m"

CONFIG_FILE="/usr/local/etc/xray/config.json"
SHARE_FILE="/usr/local/etc/xray/share.txt"
WEBROOT="/var/www/html"
XRAY_BIN="/usr/local/bin/xray"

banner() {
    echo -e "${CYAN}"
    echo "============================================================"
    echo "      Xray VLESS + Reality v5.2 (California Special)"
    echo "============================================================"
    echo -e "${RESET}"
}

pause() { echo -e "${YELLOW}按回车继续...${RESET}"; read -r; }

# ==================== 系统深度优化 (加州专版) ====================
optimize_system() {
    echo -e "${BLUE}[1/4] 开启 BBR 拥塞控制算法...${RESET}"
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi

    echo -e "${BLUE}[2/4] 加州-内地长连接内核调优...${RESET}"
    cat > /etc/sysctl.d/99-xray-california.conf <<EOF
# 增大 TCP 缓冲区以适应高延迟大带宽链路 (Long Fat Pipe)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_mem = 786432 1048576 1572864

# 优化连接初始化
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192

# 解决跨海链路 MTU 问题
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl --system > /dev/null 2>&1
    
    # 强制提升初始拥塞窗口 (initcwnd) 提升长距离首包响应
    # 获取默认网关名称
    GW_DEV=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -n "$GW_DEV" ]; then
        ip route change default $(ip route show dev $GW_DEV | awk '/default/ {print $0}') initcwnd 20 initrwnd 20 2>/dev/null || true
    fi
}

# ==================== 密钥与 ID 生成 ====================
generate_reality_keys() {
    sleep 2
    OUT=$($XRAY_BIN x25519 2>/dev/null || true)
    
    # 针对最新版 Xray 的兼容性提取逻辑
    PRIVATE=$(echo "$OUT" | grep -Ei "Private" | awk -F ': ' '{print $2}' | tr -d ' ')
    [[ -z "$PRIVATE" ]] && PRIVATE=$(echo "$OUT" | grep -i "Private key" | awk '{print $NF}')

    PUBLIC=$(echo "$OUT"  | grep -Ei "Public|Password" | head -n 1 | awk -F ': ' '{print $2}' | tr -d ' ')
    [[ -z "$PUBLIC"  ]] && PUBLIC=$(echo "$OUT"  | grep -i "Public key"  | awk '{print $NF}')

    if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
        echo -e "${RED}[ERROR] Reality 密钥提取失败，原始输出：${RESET}\n$OUT"
        exit 1
    fi
}

# ==================== 安装函数 ====================
install_xray() {
    clear; banner
    optimize_system

    echo -e "\n${YELLOW}请输入你的展示域名（仅用于伪装网站，不影响 Reality 握手）：${RESET}"
    read -p "Domain: " DOMAIN

    echo -e "${YELLOW}请选择伪装目标（影响 Reality 握手特征）：${RESET}"
    echo -e "${CYAN}1) dl.google.com (谷歌下载, 极快)${RESET}"
    echo -e "${CYAN}2) www.microsoft.com (微软, 稳定)${RESET}"
    echo -e "${CYAN}3) www.lovelive-anime.jp (日区混淆首选)${RESET}"
    echo -e "${CYAN}4) swdist.apple.com (苹果更新, 加州连接极佳)${RESET}"
    echo -e "${CYAN}5) www.yahoo.com (雅虎, 美国西海岸本土推荐)${RESET}"
    read -p "选择 [1-5]: " DEST_CHOICE

    case $DEST_CHOICE in
        1) SERVER_NAME="dl.google.com" ;;
        2) SERVER_NAME="www.microsoft.com" ;;
        3) SERVER_NAME="www.lovelive-anime.jp" ;;
        4) SERVER_NAME="swdist.apple.com" ;;
        5) SERVER_NAME="www.yahoo.com" ;;
        *) SERVER_NAME="dl.google.com" ;;
    esac

    DEST="${SERVER_NAME}:443"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORTID=$(openssl rand -hex 4)
    # 随机生成 SpiderX 路径
    SPX_PATH="/$(openssl rand -hex 3)"

    # 端口逻辑：优先使用 443，如果占用则提示
    REALITY_PORT=443
    if ss -tln | grep -q ":443 "; then
        echo -e "${YELLOW}警告: 443 端口已被占用，将使用随机高端口${RESET}"
        while true; do
            REALITY_PORT=$((20000 + RANDOM % 40000))
            ! ss -tln | grep -q ":$REALITY_PORT " && break
        done
    fi

    echo -e "${BLUE}[3/4] 安装依赖与 Xray-core...${RESET}"
    apt update -y && apt install -y curl wget lsof jq openssl
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
    
    generate_reality_keys

cat >$CONFIG_FILE <<EOF
{
  "log": { "loglevel": "warning", "access": "/dev/null" },
  "dns": { "servers": ["1.1.1.1", "8.8.8.8", "localhost"] },
  "inbounds": [
    {
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": 0,
          "serverNames": ["$SERVER_NAME"],
          "privateKey": "$PRIVATE",
          "shortIds": ["$SHORTID"],
          "fingerprint": "chrome",
          "spiderX": "$SPX_PATH"
        },
        "sockopt": { "tcpFastOpen": true, "tcpNoDelay": true }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }
  ],
  "outbounds": [
    { 
      "protocol": "freedom", 
      "tag": "direct", 
      "settings": { 
        "domainStrategy": "UseIPv4" 
      } 
    },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

    systemctl restart xray
    
    # 智能放行防火墙
    if command -v ufw > /dev/null 2>&1; then
        ufw allow $REALITY_PORT/tcp && ufw allow $REALITY_PORT/udp
    fi

    SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)
    # URL 编码 SpiderX 路径中的斜杠 (%2F)
    ENCODED_SPX=$(echo -n "$SPX_PATH" | sed 's/\//%2F/g')
    SHARE_LINK="vless://$UUID@$SERVER_IP:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&fp=chrome&sni=$SERVER_NAME&sid=$SHORTID&spx=$ENCODED_SPX&pbk=$PUBLIC&type=tcp#Reality_U_$DOMAIN"
    echo "$SHARE_LINK" > $SHARE_FILE

    echo -e "\n${GREEN}============================================================${RESET}"
    echo -e "安装完成！当前版本：${CYAN}v5.2 California Special${RESET}"
    echo -e "运行端口：${CYAN}$REALITY_PORT${RESET}"
    echo -e "SpiderX 混淆路径：${CYAN}$SPX_PATH${RESET}"
    echo -e "针对中国内地优化：${GREEN}IPv4 优先 + 初始窗口加速 (20)${RESET}"
    echo -e "分享链接：\n${YELLOW}$SHARE_LINK${RESET}"
    echo -e "${GREEN}============================================================${RESET}"
    pause
}

# 其他辅助功能 (省略重复，保持框架一致)
health_check() {
    clear; banner
    systemctl is-active --quiet xray && echo -e "Xray 服务: ${GREEN}✔ 正常${RESET}" || echo -e "Xray 服务: ${RED}✘ 异常${RESET}"
    pause
}

while true; do
    clear; banner
    echo -e "1) ${GREEN}安装 Reality v5.2 (针对加州-内地优化)${RESET}"
    echo -e "2) 健康检查"
    echo -e "0) 退出"
    read -p "选择: " NUM
    case $NUM in
        1) install_xray ;;
        2) health_check ;;
        0) exit ;;
        *) echo -e "${RED}无效选择${RESET}" && pause ;;
    esac
done
