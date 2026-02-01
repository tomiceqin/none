#!/bin/bash
set -e

# ========= Colors ===========
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${GREEN}===========================================${RESET}"
echo -e "${GREEN}      Xray VLESS + Reality + TLS 一键安装器${RESET}"
echo -e "${GREEN}===========================================${RESET}"

# ========= Input Parameters ===========
echo -e "${YELLOW}请输入你的真实域名 (用来部署网站 & 免费证书)：${RESET}"
read -p "Domain: " DOMAIN

echo -e "${YELLOW}Reality 伪装域名 serverName（例如：www.google.com / www.cloudflare.com）：${RESET}"
read -p "serverName: " SERVER_NAME

echo -e "${YELLOW}dest（一般与 serverName 一致，例如：www.google.com:443）：${RESET}"
read -p "dest (格式 xxx:443): " DEST

UUID=$(cat /proc/sys/kernel/random/uuid)
WEBROOT="/var/www/html"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

echo -e "${GREEN}参数确认：${RESET}"
echo -e " 域名:       ${GREEN}$DOMAIN${RESET}"
echo -e " serverName: ${GREEN}$SERVER_NAME${RESET}"
echo -e " dest:       ${GREEN}$DEST${RESET}"
echo -e " UUID:       ${GREEN}$UUID${RESET}"
sleep 1

# ========= System Update ===========
echo -e "${YELLOW}正在更新系统...${RESET}"
apt update -y
apt install -y curl wget socat nginx

# ========= Install Xray ===========
echo -e "${YELLOW}正在安装 Xray-core...${RESET}"
bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

# ========= Generate Reality Keys ===========
echo -e "${YELLOW}生成 Reality Keypair ...${RESET}"
REALITY_PRIVATE_KEY=$(xray x25519 | grep Private | awk '{print $3}')
REALITY_PUBLIC_KEY=$(xray x25519 | grep Public | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 3)

echo -e "${GREEN}Reality 公钥: ${RESET}$REALITY_PUBLIC_KEY"
echo -e "${GREEN}Reality 私钥: ${RESET}$REALITY_PRIVATE_KEY"
echo -e "${GREEN}ShortId: ${RESET}$SHORT_ID"

# ========= Configure Nginx Website ===========
echo -e "${YELLOW}配置 Nginx 网站...${RESET}"

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

# ========= Install Certbot SSL ===========
echo -e "${YELLOW}申请 Let's Encrypt 证书...${RESET}"
apt install -y certbot python3-certbot-nginx

certbot --nginx --agree-tos --redirect -d $DOMAIN -m admin@$DOMAIN --non-interactive

# ========= Write Xray config ===========
echo -e "${YELLOW}写入 Xray Reality 配置...${RESET}"

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
          "privateKey": "$REALITY_PRIVATE_KEY",
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

# ========= Restart Xray ===========
echo -e "${YELLOW}启动 Xray 服务...${RESET}"
systemctl enable xray --now
systemctl restart xray

echo -e "${GREEN}===========================================${RESET}"
echo -e "${GREEN}   Xray Reality + TLS 安装完成！${RESET}"
echo -e "${GREEN}===========================================${RESET}"

echo -e "${YELLOW}客户端连接信息如下：${RESET}"

echo -e "地址:            ${GREEN}$DOMAIN${RESET}"
echo -e "端口:            ${GREEN}443${RESET}"
echo -e "UUID:            ${GREEN}$UUID${RESET}"
echo -e "flow:            ${GREEN}xtls-rprx-vision${RESET}"
echo -e "Reality 公钥:    ${GREEN}$REALITY_PUBLIC_KEY${RESET}"
echo -e "shortId:         ${GREEN}$SHORT_ID${RESET}"
echo -e "serverName:      ${GREEN}$SERVER_NAME${RESET}"
echo -e "dest:            ${GREEN}$DEST${RESET}"
echo -e "uTLS 指纹:       ${GREEN}chrome${RESET}"

echo -e "${GREEN}网站目录: ${RESET}$WEBROOT"
echo -e "${GREEN}你可以直接上传你的静态网站文件！${RESET}"

echo -e "${GREEN}祝你使用愉快！${RESET}"
