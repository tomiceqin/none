#!/bin/bash
set -e

# ==================== Colors ====================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

echo -e "${GREEN}==========================================================${RESET}"
echo -e "${GREEN}        Xray VLESS + Reality + TLS + Website Installer     ${RESET}"
echo -e "${GREEN}==========================================================${RESET}"

# ==================== Input Region ====================
echo -e "${YELLOW}请输入你的真实域名（用于 HTTPS 网站 & 证书）：${RESET}"
read -p "Domain: " DOMAIN

echo -e "${YELLOW}请输入 Reality 伪装域名 serverName（如：www.cloudflare.com）：${RESET}"
read -p "serverName: " SERVER_NAME

echo -e "${YELLOW}请输入 Reality dest（如：www.cloudflare.com:443）：${RESET}"
read -p "dest: " DEST

UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_CONFIG="/usr/local/etc/xray/config.json"
WEBROOT="/var/www/html"

echo -e "${BLUE}配置确认：${RESET}"
echo -e " 域名:        ${GREEN}$DOMAIN${RESET}"
echo -e " serverName:  ${GREEN}$SERVER_NAME${RESET}"
echo -e " dest:        ${GREEN}$DEST${RESET}"
echo -e " UUID:        ${GREEN}$UUID${RESET}"
sleep 1

# ==================== Port Check ====================
check_port() {
    if lsof -i:"$1" >/dev/null 2>&1; then
        echo -e "${RED}[错误] 端口 $1 已被占用，请先处理后再运行脚本！${RESET}"
        exit 1
    fi
}

echo -e "${YELLOW}检查 80 和 443 端口占用情况...${RESET}"
check_port 80
check_port 443

# ==================== Update System ====================
echo -e "${YELLOW}更新系统...${RESET}"
apt update -y
apt install -y curl wget socat nginx

# ==================== Install Xray ====================
echo -e "${YELLOW}正在安装 Xray-core ...${RESET}"
bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

# Give filesystem time to sync
sleep 2

# ==================== Verify Xray Installed ====================
if ! command -v xray >/dev/null 2>&1; then
    echo -e "${RED}[致命错误] Xray 未成功安装，无法继续！${RESET}"
    exit 1
fi
echo -e "${GREEN}Xray 安装成功！${RESET}"

# ==================== Generate Reality Keypair ====================
echo -e "${YELLOW}正在生成 Reality Keypair ...${RESET}"

generate_keys() {
    OUT=$(xray x25519 2>/dev/null || true)
    PRIVATE=$(echo "$OUT" | grep Private | awk '{print $3}')
    PUBLIC=$(echo "$OUT" | grep Public | awk '{print $3}')
}

generate_keys

if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
    echo -e "${RED}[警告] Reality 密钥生成失败，正在重试...${RESET}"
    sleep 2
    generate_keys
fi

if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
    echo -e "${RED}[致命错误] Reality 密钥仍然为空！请检查 xray 可执行性！${RESET}"
    exit 1
fi

SHORT_ID=$(openssl rand -hex 3)

echo -e "${GREEN}Reality 私钥: ${RESET}$PRIVATE"
echo -e "${GREEN}Reality 公钥: ${RESET}$PUBLIC"
echo -e "${GREEN}shortId: ${RESET}$SHORT_ID"

# ==================== Configure Nginx ====================
echo -e "${YELLOW}安装网站 & 配置 Nginx ...${RESET}"

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

# ==================== Install HTTPS Certificate ====================
echo -e "${YELLOW}申请 Let's Encrypt 证书 ...${RESET}"
apt install -y certbot python3-certbot-nginx

certbot --nginx --agree-tos --redirect \
    -d $DOMAIN -m admin@$DOMAIN --non-interactive

# ==================== Write Xray Config ====================
echo -e "${YELLOW}写入 Xray Reality 配置 ...${RESET}"

cat >$XRAY_CONFIG <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
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
          "serverNames": ["$SERVER_NAME"],
          "privateKey": "$PRIVATE",
          "shortIds": ["$SHORT_ID"],
          "xver": 0
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# ==================== Restart Xray ====================
echo -e "${YELLOW}重启 Xray ...${RESET}"
systemctl enable xray --now
systemctl restart xray

echo -e "${GREEN}==========================================================${RESET}"
echo -e "${GREEN}  Xray Reality + TLS + HTTPS 网站 已成功部署！${RESET}"
echo -e "${GREEN}==========================================================${RESET}"

echo -e "${BLUE}客户端连接信息：${RESET}"
echo -e " 地址:            ${GREEN}$DOMAIN${RESET}"
echo -e " 端口:            ${GREEN}443${RESET}"
echo -e " UUID:            ${GREEN}$UUID${RESET}"
echo -e " flow:            ${GREEN}xtls-rprx-vision${RESET}"
echo -e " Reality 公钥:    ${GREEN}$PUBLIC${RESET}"
echo -e " Reality 私钥:    ${GREEN}$PRIVATE${RESET}"
echo -e " shortId:         ${GREEN}$SHORT_ID${RESET}"
echo -e " serverName:      ${GREEN}$SERVER_NAME${RESET}"
echo -e " dest:            ${GREEN}$DEST${RESET}"
echo -e " uTLS 指纹:       ${GREEN}chrome${RESET}"
echo -e "${GREEN}网站目录:         ${RESET}$WEBROOT"
echo -e "${GREEN}你可以直接上传静态网站！${RESET}"
