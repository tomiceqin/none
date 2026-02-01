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
    echo -e "${GREEN}"
    echo "============================================================"
    echo "      Xray VLESS + Reality Installer v4.2（随机端口版）"
    echo "============================================================"
    echo -e "${RESET}"
}

pause() { echo -e "${YELLOW}按回车继续...${RESET}"; read -r; }

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

# ==================== Reality 密钥生成（兼容新旧格式） ====================
generate_reality_keys() {
    OUT=$($XRAY_BIN x25519 2>/dev/null || true)

    PRIVATE=$(echo "$OUT" | grep -E 'PrivateKey' | awk -F ': ' '{print $2}')
    PUBLIC=$(echo "$OUT"  | grep -E 'Password'   | awk -F ': ' '{print $2}')
    HASH32=$(echo "$OUT"  | grep -E 'Hash32'     | awk -F ': ' '{print $2}')

    # 旧版兼容
    [[ -z "$PRIVATE" ]] && PRIVATE=$(echo "$OUT" | grep "Private key" | awk '{print $3}')
    [[ -z "$PUBLIC"  ]] && PUBLIC=$(echo "$OUT" | grep "Public key"  | awk '{print $3}')

    if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
        echo -e "${RED}[ERROR] Reality密钥生成失败${RESET}"
        exit 1
    fi
}

# ==================== 安装函数 ====================
install_xray() {
    clear; banner

    echo -e "${YELLOW}请输入你的真实域名（用于 HTTPS 网站）：${RESET}"
    read -p "Domain: " DOMAIN

    echo -e "${YELLOW}请选择 Reality 伪装目标网站：${RESET}"
    echo -e "${CYAN}1) www.microsoft.com （推荐，稳定）${RESET}"
    echo -e "${CYAN}2) www.apple.com${RESET}"
    echo -e "${CYAN}3) gateway.icloud.com （推荐，低延迟）${RESET}"
    echo -e "${CYAN}4) www.cloudflare.com${RESET}"
    echo -e "${CYAN}5) www.tesla.com${RESET}"
    echo -e "${CYAN}6) 自定义输入${RESET}"
    read -p "选择 [1-6]: " DEST_CHOICE

    case $DEST_CHOICE in
        1) SERVER_NAME="www.microsoft.com" ;;
        2) SERVER_NAME="www.apple.com" ;;
        3) SERVER_NAME="gateway.icloud.com" ;;
        4) SERVER_NAME="www.cloudflare.com" ;;
        5) SERVER_NAME="www.tesla.com" ;;
        6)
            echo -e "${YELLOW}请输入 Reality serverName（必须支持 TLS 1.3）：${RESET}"
            read -p "serverName: " SERVER_NAME
            ;;
        *) SERVER_NAME="www.microsoft.com" ;;
    esac

    # dest 自动与 serverName 匹配，确保证书一致
    DEST="${SERVER_NAME}:443"
    echo -e "${GREEN}已选择目标: ${SERVER_NAME}${RESET}"

    UUID=$(cat /proc/sys/kernel/random/uuid)

    apt update -y
    apt install -y nginx curl wget socat lsof jq

    # 安装 Xray
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
    sleep 2

    # 生成 Reality keypair
    generate_reality_keys

    # 生成未占用的随机端口
    REALITY_PORT=$(generate_random_port)
    SHORTID=$(openssl rand -hex 3)

    echo -e "${GREEN}Reality 随机端口：${RESET}$REALITY_PORT"
    echo -e "${GREEN}Reality 公钥：${RESET}$PUBLIC"
    echo -e "${GREEN}Reality 私钥：${RESET}$PRIVATE"

    mkdir -p $WEBROOT
    echo "<h1>Welcome to $DOMAIN</h1>" > $WEBROOT/index.html

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

    apt install -y certbot python3-certbot-nginx
    certbot --nginx --redirect -m admin@$DOMAIN -d $DOMAIN --agree-tos --non-interactive

# ==================== 写入 Xray 配置 ====================
cat >$CONFIG_FILE <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "serverNames": ["$SERVER_NAME"],
          "privateKey": "$PRIVATE",
          "shortIds": ["$SHORTID"],
          "fingerprint": "chrome",
          "xver": 0
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

    systemctl restart xray

    # 放行防火墙端口
    echo -e "${BLUE}放行防火墙端口 $REALITY_PORT ...${RESET}"
    if command -v ufw > /dev/null 2>&1; then
        ufw allow $REALITY_PORT/tcp
    fi
    if command -v firewall-cmd > /dev/null 2>&1; then
        firewall-cmd --permanent --add-port=$REALITY_PORT/tcp
        firewall-cmd --reload
    fi
    # iptables 兜底
    iptables -I INPUT -p tcp --dport $REALITY_PORT -j ACCEPT 2>/dev/null || true

    # 获取服务器真实 IP 用于分享链接
    SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb || curl -s4 ipinfo.io/ip)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="$DOMAIN"
    fi

    SHARE_LINK="vless://$UUID@$SERVER_IP:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&fp=chrome&sni=$SERVER_NAME&sid=$SHORTID&pbk=$PUBLIC&type=tcp#Reality-$DOMAIN"
    echo "$SHARE_LINK" > $SHARE_FILE

    echo -e "${GREEN}安装完成！${RESET}"
    echo -e "服务器IP：${CYAN}$SERVER_IP${RESET}"
    echo -e "Reality端口：${CYAN}$REALITY_PORT${RESET}"
    echo -e "分享链接：${CYAN}$SHARE_LINK${RESET}"
    pause
}

# ==================== 健康检查 ====================
health_check() {
    clear; banner
    echo -e "${CYAN}========== 健康检查 Health Check ==========${RESET}"

    echo -e "${BLUE}1) Xray 服务状态${RESET}"
    systemctl is-active --quiet xray && echo -e "  ${GREEN}✔ 正常运行${RESET}" || systemctl status xray --no-pager

    echo -e "${BLUE}2) Reality 端口检查${RESET}"
    PORT=$(jq '.inbounds[0].port' $CONFIG_FILE)
    if ss -tln | grep -q ":$PORT "; then
        echo -e "  ${GREEN}✔ Reality 端口 $PORT 正常监听${RESET}"
    else
        echo -e "  ${RED}✘ Reality 端口未监听${RESET}"
    fi

    pause
}

# ==================== 自动修复 ====================
auto_repair() {
    clear; banner

    echo -e "${BLUE}修复 Xray 服务...${RESET}"
    systemctl restart xray

    echo -e "${BLUE}检查端口监听状态...${RESET}"
    PORT=$(jq '.inbounds[0].port' $CONFIG_FILE)
    if ss -tln | grep -q ":$PORT "; then
        echo -e "${GREEN}✔ Reality 端口 $PORT 正常监听${RESET}"
    else
        echo -e "${RED}端口 $PORT 未监听，尝试重新生成端口...${RESET}"
        NEW_PORT=$(generate_random_port)
        jq ".inbounds[0].port = $NEW_PORT" $CONFIG_FILE > $CONFIG_FILE.tmp
        mv $CONFIG_FILE.tmp $CONFIG_FILE
        # 放行新端口
        ufw allow $NEW_PORT/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=$NEW_PORT/tcp 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
        iptables -I INPUT -p tcp --dport $NEW_PORT -j ACCEPT 2>/dev/null || true
        systemctl restart xray
        echo -e "${GREEN}已切换端口到：$NEW_PORT${RESET}"
    fi

    pause
}

# ==================== 分享链接 ====================
export_info() {
    clear; banner
    echo -e "${CYAN}========== 分享链接 ==========${RESET}"
    cat $SHARE_FILE
    pause
}

# ==================== 菜单 ====================
while true; do
    clear; banner
    echo -e "${BLUE}1) 安装 Reality（随机端口 + TLS）"
    echo -e "2) 健康检查"
    echo -e "3) 自动修复"
    echo -e "4) 导出分享链接"
    echo -e "0) 退出${RESET}"
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
