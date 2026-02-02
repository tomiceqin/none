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
    echo "      Xray VLESS + Reality Installer v5.0 (Optimized)"
    echo "============================================================"
    echo -e "${RESET}"
}

pause() { echo -e "${YELLOW}按回车继续...${RESET}"; read -r; }

# ==================== 系统检查与优化 ====================
optimize_system() {
    echo -e "${BLUE}[1/3] 开启 BBR 拥塞控制算法...${RESET}"
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${GREEN}✔ BBR 已启动${RESET}"
    else
        echo -e "${GREEN}✔ BBR 已在运行中${RESET}"
    fi

    echo -e "${BLUE}[2/3] 优化网络内核参数...${RESET}"
    # 增加连接队列长度
    cat > /etc/sysctl.d/99-xray-optimize.conf <<EOF
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
EOF
    sysctl --system > /dev/null 2>&1
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
    # 稍微等待确保二进制文件写入磁盘并可执行
    sleep 2
    OUT=$($XRAY_BIN x25519 2>/dev/null || true)
    
    # 支持多种输出格式解析 (新版 PrivateKey: xxx / 旧版 Private key: xxx)
    PRIVATE=$(echo "$OUT" | grep -i "Private" | awk -F ': ' '{print $2}' | tr -d ' ')
    [[ -z "$PRIVATE" ]] && PRIVATE=$(echo "$OUT" | grep -i "Private key" | awk '{print $NF}')

    PUBLIC=$(echo "$OUT"  | grep -i "Public"  | awk -F ': ' '{print $2}' | tr -d ' ')
    [[ -z "$PUBLIC"  ]] && PUBLIC=$(echo "$OUT"  | grep -i "Public key"  | awk '{print $NF}')

    # 调试输出：如果提取失败，显示原始输出以便排查
    if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
        echo -e "${RED}[ERROR] Reality 密钥生成或提取失败${RESET}"
        echo -e "${YELLOW}Xray x25519 原始输出如下：${RESET}"
        echo "$OUT"
        exit 1
    fi

    # 正常流程下仅在安装日志中显示部分信息（可选，这里选择静默或简单提示）
    echo -e "${GREEN}✔ Reality 密钥提取成功${RESET}"
}

# ==================== 安装函数 ====================
install_xray() {
    clear; banner
    
    # 基础系统优化
    optimize_system

    echo -e "\n${YELLOW}请输入你的展示域名（用于伪装 HTTPS 网页）：${RESET}"
    read -p "Domain: " DOMAIN

    echo -e "${YELLOW}请选择 Reality 伪装目标网站 (dest)：${RESET}"
    echo -e "${CYAN}1) www.microsoft.com (全球加速推荐)${RESET}"
    echo -e "${CYAN}2) www.apple.com (低延迟推荐)${RESET}"
    echo -e "${CYAN}3) dl.google.com (谷歌下载)${RESET}"
    echo -e "${CYAN}4) www.lovelive-anime.jp (二次元常用)${RESET}"
    echo -e "${CYAN}5) 自定义输入${RESET}"
    read -p "选择 [1-5]: " DEST_CHOICE

    case $DEST_CHOICE in
        1) SERVER_NAME="www.microsoft.com" ;;
        2) SERVER_NAME="www.apple.com" ;;
        3) SERVER_NAME="dl.google.com" ;;
        4) SERVER_NAME="www.lovelive-anime.jp" ;;
        5)
            echo -e "${YELLOW}请输入 Reality serverName（需支持 TLS 1.3）：${RESET}"
            read -p "serverName: " SERVER_NAME
            ;;
        *) SERVER_NAME="www.microsoft.com" ;;
    esac

    DEST="${SERVER_NAME}:443"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORTID=$(openssl rand -hex 4)
    REALITY_PORT=$(generate_random_port)

    echo -e "${BLUE}[3/3] 安装依赖与 Xray-core...${RESET}"
    apt update -y
    apt install -y nginx curl wget socat lsof jq certbot python3-certbot-nginx
    
    # 安装最新官方 Xray
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
    echo -e "${BLUE}等待 Xray 核心初始化...${RESET}"
    
    generate_reality_keys

    # 配置 Nginx 展示页面
    mkdir -p $WEBROOT
    echo "<h1>Welcome to $DOMAIN</h1><p>System status: Normal</p>" > $WEBROOT/index.html

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
    
    # 配置 SSL
    echo -e "${BLUE}申请 SSL 证书...${RESET}"
    certbot --nginx --redirect -m admin@$DOMAIN -d $DOMAIN --agree-tos --non-interactive || echo "证书申请失败，但不影响 Reality 运行（Reality 使用 dest 网站证书）"

    # ==================== 核心配置：VLESS + REALITY + VISION + SpiderX ====================
cat >$CONFIG_FILE <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/dev/null"
  },
  "dns": {
    "servers": ["8.8.8.8", "1.1.1.1", "localhost"]
  },
  "inbounds": [
    {
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": 0,
          "serverNames": [
            "$SERVER_NAME"
          ],
          "privateKey": "$PRIVATE",
          "shortIds": [
            "$SHORTID"
          ],
          "fingerprint": "chrome",
          "spiderX": "/"
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

    systemctl restart xray

    # 放行防火墙 (TCP + UDP)
    if command -v ufw > /dev/null 2>&1; then
        ufw allow $REALITY_PORT/tcp
        ufw allow $REALITY_PORT/udp
    fi
    if command -v firewall-cmd > /dev/null 2>&1; then
        firewall-cmd --permanent --add-port=$REALITY_PORT/tcp
        firewall-cmd --permanent --add-port=$REALITY_PORT/udp
        firewall-cmd --reload
    fi
    iptables -I INPUT -p tcp --dport $REALITY_PORT -j ACCEPT
    iptables -I INPUT -p udp --dport $REALITY_PORT -j ACCEPT

    SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)
    [[ -z "$SERVER_IP" ]] && SERVER_IP="$DOMAIN"

    # 生成包含 spx 参数的分享链接
    SHARE_LINK="vless://$UUID@$SERVER_IP:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&fp=chrome&sni=$SERVER_NAME&sid=$SHORTID&spx=%2F&pbk=$PUBLIC&type=tcp#Reality_V5_$DOMAIN"
    echo "$SHARE_LINK" > $SHARE_FILE

    echo -e "\n${GREEN}============================================================${RESET}"
    echo -e "${GREEN}安装完成！${RESET}"
    echo -e "系统环境：${CYAN}BBR 已开启，TCP 参数已优化${RESET}"
    echo -e "Reality 端口：${CYAN}$REALITY_PORT (TCP+UDP)${RESET}"
    echo -e "SpiderX 路径：${CYAN}/${RESET}"
    echo -e "分享链接：\n${YELLOW}$SHARE_LINK${RESET}"
    echo -e "${GREEN}============================================================${RESET}"
    pause
}

health_check() {
    clear; banner
    echo -e "${CYAN}========== 健康检查 Health Check ==========${RESET}"
    systemctl is-active --quiet xray && echo -e "Xray 服务: ${GREEN}✔ 正常运行${RESET}" || echo -e "Xray 服务: ${RED}✘ 停止${RESET}"
    
    PORT=$(jq '.inbounds[0].port' $CONFIG_FILE)
    if ss -tln | grep -q ":$PORT "; then
        echo -e "端口监听: ${GREEN}✔ $PORT 正常监听${RESET}"
    else
        echo -e "端口监听: ${RED}✘ $PORT 未监听${RESET}"
    fi
    pause
}

auto_repair() {
    clear; banner
    echo -e "${BLUE}尝试修复 Xray 服务...${RESET}"
    systemctl restart xray
    sleep 2
    health_check
}

export_info() {
    clear; banner
    echo -e "${CYAN}========== 分享链接 ==========${RESET}"
    cat $SHARE_FILE
    echo -e "\n"
    pause
}

# ==================== 菜单 ====================
while true; do
    clear; banner
    echo -e "1) ${GREEN}安装 Reality v5.0 (含所有优化)${RESET}"
    echo -e "2) 健康检查"
    echo -e "3) 自动修复"
    echo -e "4) 导出分享链接"
    echo -e "0) 退出"
    read -p "选择: " NUM

    case $NUM in
        1) install_xray ;;
        2) health_check ;;
        3) auto_repair ;;
        4) export_info ;;
        0) exit ;;
        *) echo -e "${RED}无效选择${RESET}" && pause ;;
    esac
done
