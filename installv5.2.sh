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

# ==================== 系统检查与优化 (加州专版) ====================
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
    GW_DEV=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -n "$GW_DEV" ]; then
        ip route change default $(ip route show dev $GW_DEV | awk '/default/ {print $0}') initcwnd 20 initrwnd 20 2>/dev/null || true
    fi
}

# ==================== 自动生成未占用端口 ====================
generate_random_port() {
    while true; do
        PORT=$((20000 + RANDOM % 40000))  # 20000~60000
        if ! ss -tln | grep -q ":$PORT "; then
            echo "$PORT"
            return
        fi
    done
}

# ==================== Reality 密钥生成 (增强版) ====================
generate_reality_keys() {
    sleep 2
    OUT=$($XRAY_BIN x25519 2>/dev/null || true)
    
    # 提取私钥
    PRIVATE=$(echo "$OUT" | grep -Ei "Private" | awk -F ': ' '{print $2}' | tr -d ' ')
    [[ -z "$PRIVATE" ]] && PRIVATE=$(echo "$OUT" | grep -i "Private key" | awk '{print $NF}')

    # 提取公钥
    PUBLIC=$(echo "$OUT"  | grep -Ei "Public|Password" | head -n 1 | awk -F ': ' '{print $2}' | tr -d ' ')
    [[ -z "$PUBLIC"  ]] && PUBLIC=$(echo "$OUT"  | grep -i "Public key"  | awk '{print $NF}')

    if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
        echo -e "${RED}[ERROR] Reality 密钥生成或提取失败${RESET}"
        echo -e "${YELLOW}Xray x25519 原始输出如下：${RESET}"
        echo "$OUT"
        exit 1
    fi
    echo -e "${GREEN}✔ Reality 密钥提取成功${RESET}"
}

# ==================== 安装函数 ====================
install_xray() {
    clear; banner
    optimize_system

    echo -e "\n${YELLOW}请输入你的展示域名（仅用于伪装网站）：${RESET}"
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
    SPX_PATH="/$(openssl rand -hex 3)"

    # 端口逻辑：优先使用 443
    REALITY_PORT=443
    if ss -tln | grep -q ":443 "; then
        echo -e "${YELLOW}警告: 443 端口已被占用，将使用随机高端口${RESET}"
        REALITY_PORT=$(generate_random_port)
    fi

    echo -e "${BLUE}[3/4] 正在安装依赖与 Xray-core...${RESET}"
    apt update -y && apt install -y curl wget lsof jq openssl nginx
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
    
    generate_reality_keys

    # 配置 Nginx 展示页面
    mkdir -p $WEBROOT
    echo "<h1>Welcome to $DOMAIN</h1><p>System status: Normal (Optimized for California)</p>" > $WEBROOT/index.html

    cat >/etc/nginx/sites-available/$DOMAIN.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $WEBROOT;
    index index.html;
}
EOF
    ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx

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
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

    systemctl restart xray
    
    # 放行防火墙
    iptables -I INPUT -p tcp --dport $REALITY_PORT -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport $REALITY_PORT -j ACCEPT 2>/dev/null || true
    if command -v ufw > /dev/null 2>&1; then
        ufw allow $REALITY_PORT/tcp && ufw allow $REALITY_PORT/udp
    fi

    SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)
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

# ==================== 健康检查 ====================
health_check() {
    clear; banner
    echo -e "${CYAN}========== 健康检查 Health Check ==========${RESET}"
    systemctl is-active --quiet xray && echo -e "Xray 服务: ${GREEN}✔ 正常运行${RESET}" || echo -e "Xray 服务: ${RED}✘ 停止${RESET}"
    
    if [ -f "$CONFIG_FILE" ]; then
        PORT=$(jq '.inbounds[0].port' $CONFIG_FILE)
        if ss -tln | grep -q ":$PORT "; then
            echo -e "端口监听: ${GREEN}✔ $PORT 正常监听${RESET}"
        else
            echo -e "端口监听: ${RED}✘ $PORT 未监听${RESET}"
        fi
    else
        echo -e "${RED}配置文件不存在${RESET}"
    fi
    pause
}

# ==================== 自动修复 ====================
auto_repair() {
    clear; banner
    echo -e "${BLUE}正在尝试修复 Xray 服务...${RESET}"
    systemctl restart xray
    sleep 2
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}修复失败，尝试检查配置或重装${RESET}"
    else
        echo -e "${GREEN}✔ 服务已重启${RESET}"
    fi
    pause
}

# ==================== 分享链接 ====================
export_info() {
    clear; banner
    echo -e "${CYAN}========== 分享链接 ==========${RESET}"
    if [ -f "$SHARE_FILE" ]; then
        cat $SHARE_FILE
    else
        echo -e "${RED}分享文件不存在，请先安装${RESET}"
    fi
    echo -e "\n"
    pause
}

# ==================== 路径信息 ====================
show_paths() {
    clear; banner
    echo -e "${CYAN}========== 系统路径备查 ==========${RESET}"
    echo -e "${BLUE}1) Xray 核心配置:${RESET}  $CONFIG_FILE"
    echo -e "${BLUE}2) Xray 分享链接:${RESET}  $SHARE_FILE"
    echo -e "${BLUE}3) Nginx 网站根目录:${RESET} $WEBROOT"
    
    # 尝试查找 SSL 证书路径
    CERT_DIR="/etc/letsencrypt/live"
    if [ -d "$CERT_DIR" ]; then
        echo -e "${BLUE}4) SSL 证书目录:${RESET}    $CERT_DIR (子目录对应域名)"
    else
        echo -e "${BLUE}4) SSL 证书目录:${RESET}    尚未生成或不在默认路径"
    fi

    echo -e "${BLUE}5) Nginx 配置文件:${RESET} /etc/nginx/sites-available/"
    echo -e "------------------------------------------------------------"
    pause
}

# ==================== 菜单 ====================
while true; do
    clear; banner
    echo -e "1) ${GREEN}安装/覆盖安装 Reality v5.2 (针对加州-内地优化)${RESET}"
    echo -e "2) 健康检查"
    echo -e "3) 自动修复"
    echo -e "4) 导出分享链接"
    echo -e "5) 查看系统路径备查"
    echo -e "0) 退出"
    read -p "选择: " NUM

    case $NUM in
        1) install_xray ;;
        2) health_check ;;
        3) auto_repair ;;
        4) export_info ;;
        5) show_paths ;;
        0) exit ;;
        *) echo -e "${RED}无效选择${RESET}" && pause ;;
    esac
done
