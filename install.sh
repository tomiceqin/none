#!/bin/bash
set -e

# =====================================================
#  Color Setup
# =====================================================
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

# =====================================================
banner() {
    echo -e "${GREEN}"
    echo "============================================================"
    echo "      Xray VLESS + Reality + TLS Installer v4 旗舰版"
    echo "============================================================"
    echo -e "${RESET}"
}

pause() { echo -e "${YELLOW}按回车继续...${RESET}"; read -r; }

# =====================================================
#  Reality Keypair Generator — V4 自适应解析（新旧兼容）
# =====================================================
generate_reality_keys() {
    OUT=$($XRAY_BIN x25519 2>/dev/null || true)

    PRIVATE=$(echo "$OUT" | grep -E 'PrivateKey' | awk -F ': ' '{print $2}')
    PUBLIC=$(echo "$OUT"  | grep -E 'Password'   | awk -F ': ' '{print $2}')
    HASH32=$(echo "$OUT"  | grep -E 'Hash32'     | awk -F ': ' '{print $2}')

    [[ -z "$PRIVATE" ]] && PRIVATE=$(echo "$OUT" | grep "Private key" | awk '{print $3}')
    [[ -z "$PUBLIC"  ]] && PUBLIC=$(echo "$OUT" | grep "Public key"  | awk '{print $3}')

    if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
        echo -e "${RED}[ERROR] Reality 密钥生成失败${RESET}"
        exit 1
    fi
}

# =====================================================
#  Install Function
# =====================================================
install_xray() {
    clear; banner

    echo -e "${YELLOW}请输入你的真实域名:${RESET}"
    read -p "Domain: " DOMAIN

    echo -e "${YELLOW}Reality serverName:${RESET}"
    read -p "serverName: " SERVER_NAME

    echo -e "${YELLOW}Reality dest:${RESET}"
    read -p "dest: " DEST

    UUID=$(cat /proc/sys/kernel/random/uuid)

    apt update && apt install -y nginx wget curl socat

    # 安装 Xray
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
    sleep 2

    generate_reality_keys
    SHORTID=$(openssl rand -hex 3)

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

    apt install -y certbot python3-certbot-nginx
    certbot --nginx --agree-tos --redirect -m admin@$DOMAIN -d $DOMAIN --non-interactive

# ================= Xray Config ========================
cat >$CONFIG_FILE <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": 443,
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
          "xver": 0
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

    systemctl restart xray

    SHARE_LINK="vless://$UUID@$DOMAIN:443?encryption=none&flow=xtls-rprx-vision&security=reality&fp=chrome&sni=$SERVER_NAME&sid=$SHORTID&pbk=$PUBLIC&type=tcp#Reality-$DOMAIN"
    echo "$SHARE_LINK" > $SHARE_FILE

    echo -e "${GREEN}安装完成！${RESET}"
    echo -e "分享链接：${CYAN}$SHARE_LINK${RESET}"
    pause
}

# =====================================================
#  Health Check 面板
# =====================================================
health_check() {
    clear; banner
    echo -e "${CYAN}============ 健康检查 Health Check ============${RESET}"

    echo -e "${BLUE}1) Xray 服务状态:${RESET}"
    systemctl is-active --quiet xray && echo -e "  ${GREEN}✔ 正常${RESET}" || echo -e "  ${RED}✘ 异常${RESET}"

    echo -e "${BLUE}2) 80/443 端口检查:${RESET}"
    lsof -i:443 >/dev/null && echo -e "  ${GREEN}✔ 443 正常${RESET}" || echo -e "  ${RED}✘ 443 未监听${RESET}"

    lsof -i:80 >/dev/null && echo -e "  ${GREEN}✔ 80 正常${RESET}" || echo -e "  ${RED}✘ 80 未监听${RESET}"

    echo -e "${BLUE}3) TLS 证书检查:${RESET}"
    if [[ -d "/etc/letsencrypt/live" ]]; then
        echo -e "  ${GREEN}✔ 已找到证书${RESET}"
    else
        echo -e "  ${RED}✘ 未找到证书${RESET}"
    fi

    echo -e "${BLUE}4) Reality 握手检查:${RESET}"
    if grep -q "reality" $CONFIG_FILE; then
        echo -e "  ${GREEN}✔ Reality 配置存在${RESET}"
    else
        echo -e "  ${RED}✘ Reality 配置缺失${RESET}"
    fi

    pause
}

# =====================================================
# 自动修复 Auto Repair
# =====================================================
auto_repair() {
    clear; banner
    echo -e "${CYAN}============ 自动修复 Auto Repair ============${RESET}"

    echo -e "${BLUE}修复 Xray 服务...${RESET}"
    systemctl restart xray && echo -e "  ${GREEN}✔ Xray 已重启${RESET}"

    echo -e "${BLUE}修复证书...${RESET}"
    certbot renew --force-renewal && echo -e "  ${GREEN}✔ 证书更新成功${RESET}"

    echo -e "${BLUE}修复 Nginx...${RESET}"
    systemctl restart nginx && echo -e "  ${GREEN}✔ Nginx 已重启${RESET}"

    # 重新生成 Reality keypair
    echo -e "${BLUE}检查 Reality Keypair ...${RESET}"
    generate_reality_keys
    echo -e "  ${GREEN}✔ Reality Keypair 正常${RESET}"

    pause
}

# =====================================================
# 日志面板 Log Panel
# =====================================================
log_panel() {
    clear; banner

    echo -e "${BLUE}1) 实时 Xray 日志"
    echo -e "2) 仅 ERROR/WARNING"
    echo -e "3) Nginx 错误日志"
    echo -e "0) 返回${RESET}"

    read -p "选择: " L

    case $L in
        1) journalctl -u xray -f ;;
        2) journalctl -u xray -f | grep -E "error|warning|fail" ;;
        3) tail -f /var/log/nginx/error.log ;;
    esac
}

# =====================================================
# 导出分享链接 + 二维码
# =====================================================
export_info() {
    clear; banner
    echo -e "${CYAN}============ 分享链接导出 ============${RESET}"

    if [[ ! -f "$SHARE_FILE" ]]; then
        echo -e "${RED}未找到 share.txt${RESET}"
        pause
        return
    fi

    LINK=$(cat $SHARE_FILE)
    echo -e "${GREEN}$LINK${RESET}"

    echo -e "${YELLOW}是否生成二维码？ (y/n)${RESET}"
    read ans
    if [[ "$ans" == "y" ]]; then
        apt install -y qrencode
        qrencode -t ANSIUTF8 "$LINK"
    fi

    pause
}

# =====================================================
# 主菜单 MENU
# =====================================================
while true; do
    clear
    banner
    echo -e "${BLUE}1) 安装 Xray Reality + TLS + 网站"
    echo -e "2) 健康检查 (Health Check)"
    echo -e "3) 自动修复 Auto Repair"
    echo -e "4) 日志面板 Log Panel"
    echo -e "5) 导出分享链接 (含二维码)"
    echo -e "6) 重启 Xray"
    echo -e "7) 重启 Nginx"
    echo -e "0) 退出${RESET}"
    read -p "选择: " NUM

    case $NUM in
        1) install_xray ;;
        2) health_check ;;
        3) auto_repair ;;
        4) log_panel ;;
        5) export_info ;;
        6) systemctl restart xray ;;
        7) systemctl restart nginx ;;
        0) exit ;;
        *) echo -e "${RED}无效选择${RESET}" && pause ;;
    esac
done
