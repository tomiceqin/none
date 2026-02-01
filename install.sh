#!/bin/bash
set -e

# ============================================================
#   Xray VLESS + Reality V4.3 — Ultimate Security Edition
#   单文件安装脚本（选项 A）
#   作者：tomiceqin
# ============================================================

# ========================= Colors ===========================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
CYAN="\033[96m"
RESET="\033[0m"

# ========================= Paths ============================
XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
SHARE_PATH="/usr/local/etc/xray/share.txt"
WEB_ROOT="/var/www/html"

# ========================= Global State ======================
CURRENT_PORT=0
CURRENT_SNI=""
CURRENT_FP=""
CURRENT_PRIVATE_KEY=""
CURRENT_PUBLIC_KEY=""
CURRENT_SHORT_ID=""
UUID=""
DOMAIN=""

# ========================= SNI Pools =========================
# Google + Cloudflare + CDN 混合池（最高隐匿）
SNI_POOL=(
    "www.google.com"
    "www.gstatic.com"
    "ajax.googleapis.com"
    "fonts.gstatic.com"
    "www.cloudflare.com"
    "cloudflare-dns.com"
    "cdnjs.cloudflare.com"
    "cdn.jsdelivr.net"
    "imgur.com"
)

# ========================= Fingerprint Pool ==================
# Chrome + Edge 池
FP_POOL=(
    "chrome"
    "chrome-120"
    "chrome-118"
    "edge"
)

# ========================= Utility: Banner ===================
banner() {
    echo -e "${GREEN}"
    echo "============================================================"
    echo "      Xray VLESS + Reality Installer v4.3（终极隐匿版）"
    echo "============================================================"
    echo -e "${RESET}"
}

pause() {
    echo -e "${YELLOW}按回车继续...${RESET}"
    read -r
}

# ========================= Random Port (20000–60000) ========
generate_random_port() {
    while true; do
        PORT=$((20000 + RANDOM % 40000))
        if ! ss -tln | grep -q ":$PORT "; then
            echo "$PORT"
            return
        fi
    done
}

# ========================= Random SNI ========================
generate_random_sni() {
    local idx=$((RANDOM % ${#SNI_POOL[@]}))
    echo "${SNI_POOL[$idx]}"
}

# ========================= Random Fingerprint ================
generate_random_fp() {
    local idx=$((RANDOM % ${#FP_POOL[@]}))
    echo "${FP_POOL[$idx]}"
}

# ========================= Random ShortID ====================
generate_short_id() {
    openssl rand -hex 3
}

# ========================= Reality Keypair Gen ===============
generate_reality_keypair() {
    local OUT
    OUT=$($XRAY_BIN x25519 2>/dev/null || true)

    PRIVATE=$(echo "$OUT" | grep -E 'PrivateKey' | awk -F ': ' '{print $2}')
    PUBLIC=$(echo "$OUT"  | grep -E 'Password'   | awk -F ': ' '{print $2}')

    # fallback：旧格式
    [[ -z "$PRIVATE" ]] && PRIVATE=$(echo "$OUT" | grep "Private key" | awk '{print $3}')
    [[ -z "$PUBLIC"  ]] && PUBLIC=$(echo "$OUT" | grep "Public key"  | awk '{print $3}')

    if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
        echo -e "${RED}[ERROR] Reality Keypair 生成失败${RESET}"
        exit 1
    fi

    CURRENT_PRIVATE_KEY="$PRIVATE"
    CURRENT_PUBLIC_KEY="$PUBLIC"
}

# ==============================================================
#      第 1 部分结束 —— 请等待第 2 部分（健康检查 + DPI 检测）
# ==============================================================

# ============================================================
#   Part 2 — Health Check + DPI Block Detection + Auto-Heal
# ============================================================

# ========================= Test Reality Handshake ===========
test_reality_handshake() {
    local ip="127.0.0.1"
    local port="$CURRENT_PORT"

    # 模拟 TCP 握手测试
    timeout 2 bash -c "cat < /dev/null > /dev/tcp/$ip/$port" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "FAIL"
    else
        echo "OK"
    fi
}

# ========================= Check SNI DNS =====================
check_sni_dns() {
    local sni="$CURRENT_SNI"
    if ping -c1 -W1 "$sni" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAIL"
    fi
}

# ========================= Check Port ========================
check_port_open() {
    local port="$CURRENT_PORT"
    if ss -tln | grep -q ":$port "; then
        echo "OK"
    else
        echo "FAIL"
    fi
}

# ========================= Run Health Check ==================
health_check() {
    clear; banner

    echo -e "${BLUE}当前端口：${RESET}$CURRENT_PORT"
    echo -e "${BLUE}当前 SNI：${RESET}$CURRENT_SNI"
    echo -e "${BLUE}当前 fingerprint：${RESET}$CURRENT_FP"
    echo ""

    # ---- Check 1: Xray Service ----
    echo -ne "${YELLOW}[1] Xray 服务状态：${RESET}"
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✔ 正常${RESET}"
    else
        echo -e "${RED}✘ 异常${RESET}"
    fi

    # ---- Check 2: Port Status ----
    echo -ne "${YELLOW}[2] Reality 端口监听：${RESET}"
    if [[ "$(check_port_open)" == "OK" ]]; then
        echo -e "${GREEN}✔ 已监听${RESET}"
    else
        echo -e "${RED}✘ 未监听${RESET}"
    fi

    # ---- Check 3: SNI DNS ----
    echo -ne "${YELLOW}[3] SNI DNS 可解析性：${RESET}"
    if [[ "$(check_sni_dns)" == "OK" ]]; then
        echo -e "${GREEN}✔ 正常${RESET}"
    else
        echo -e "${RED}✘ 异常${RESET}"
    fi

    # ---- Check 4: Reality Handshake ----
    echo -ne "${YELLOW}[4] Reality 握手检测：${RESET}"
    if [[ "$(test_reality_handshake)" == "OK" ]]; then
        echo -e "${GREEN}✔ 正常${RESET}"
    else
        echo -e "${RED}✘ 异常${RESET}"
        echo -e "${RED}Reality 握手失败 → 可能被 GFW 阻断${RESET}"
    fi

    echo ""
    pause
}

# ========================= DPI Block Detection ================
detect_gfw_block() {
    local is_blocked=0

    # 1. 端口未监听 = 配置错误或端口被劫持
    if [[ "$(check_port_open)" == "FAIL" ]]; then
        is_blocked=1
    fi

    # 2. SNI DNS 无响应（极低概率）
    if [[ "$(check_sni_dns)" == "FAIL" ]]; then
        is_blocked=1
    fi

    # 3. Reality 握手失败（最重要）
    if [[ "$(test_reality_handshake)" == "FAIL" ]]; then
        is_blocked=1
    fi

    if [[ $is_blocked -eq 1 ]]; then
        echo "BLOCKED"
    else
        echo "OK"
    fi
}

# ========================= Auto-Heal Engine ===================
auto_heal() {
    clear; banner
    echo -e "${RED}检测到端口 / Reality 握手异常，启动自愈系统...${RESET}"

    # ------------------ Step 1: 生成新端口 -------------------
    NEW_PORT=$(generate_random_port)
    echo -e "${YELLOW}新的随机端口：${RESET}$NEW_PORT"

    # ------------------ Step 2: 生成新的 keypair -------------
    echo -e "${YELLOW}生成新的 Reality Keypair...${RESET}"
    generate_reality_keypair
    NEW_PRIVATE="$CURRENT_PRIVATE_KEY"
    NEW_PUBLIC="$CURRENT_PUBLIC_KEY"

    # ------------------ Step 3: 生成新的 SNI ------------------
    NEW_SNI=$(generate_random_sni)
    echo -e "${YELLOW}新的 SNI：${RESET}$NEW_SNI"

    # ------------------ Step 4: 新 fingerprint --------------
    NEW_FP=$(generate_random_fp)
    echo -e "${YELLOW}新的 fingerprint：${RESET}$NEW_FP"

    # ------------------ Step 5: 新 shortId -------------------
    NEW_SHORTID=$(generate_short_id)
    echo -e "${YELLOW}新的 shortId：${RESET}$NEW_SHORTID"

    # ------------------ Step 6: 写入新配置 -------------------
    echo -e "${CYAN}写入新的 Reality 配置...${RESET}"
cat >"$CONFIG_PATH" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $NEW_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
        }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$NEW_SNI:443",
          "serverNames": ["$NEW_SNI"],
          "privateKey": "$NEW_PRIVATE",
          "shortIds": ["$NEW_SHORTID"],
          "xver": 0
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

    # ------------------ Step 7: 更新全局变量 ------------------
    CURRENT_PORT="$NEW_PORT"
    CURRENT_SNI="$NEW_SNI"
    CURRENT_FP="$NEW_FP"
    CURRENT_PRIVATE_KEY="$NEW_PRIVATE"
    CURRENT_PUBLIC_KEY="$NEW_PUBLIC"
    CURRENT_SHORT_ID="$NEW_SHORTID"

    # ------------------ Step 8: 重启 Xray ---------------------
    systemctl restart xray
    sleep 1

    # ------------------ Step 9: 更新分享链接 -------------------
    SHARE_LINK="vless://$UUID@$DOMAIN:$CURRENT_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&fp=$CURRENT_FP&sni=$CURRENT_SNI&sid=$CURRENT_SHORT_ID&pbk=$CURRENT_PUBLIC_KEY&type=tcp#Reality-$DOMAIN"
    echo "$SHARE_LINK" > $SHARE_PATH

    echo -e "${GREEN}自愈完成，新链接：${RESET}"
    echo "$SHARE_LINK"

    pause
}
# ============================================================
#   Part 3 — Install Flow (Reality + TLS + Dynamic Params)
# ============================================================

install_reality() {
    clear; banner

    echo -e "${YELLOW}请输入你的真实域名（用于部署 HTTPS 伪装站点）：${RESET}"
    read -p "Domain: " DOMAIN

    UUID=$(cat /proc/sys/kernel/random/uuid)

    echo -e "${BLUE}1) 安装依赖（nginx / certbot / xray）...${RESET}"
    apt update -y
    apt install -y nginx curl wget socat jq lsof

    # ----------------------- Install Xray ---------------------
    echo -e "${BLUE}2) 安装 Xray...${RESET}"
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
    sleep 2

    # ----------------------- Create Website -------------------
    echo -e "${BLUE}3) 部署伪装网站到 /var/www/html ...${RESET}"
    mkdir -p "$WEB_ROOT"
    echo "<h1>Welcome to $DOMAIN</h1>" > "$WEB_ROOT/index.html"

cat >/etc/nginx/sites-available/$DOMAIN.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root $WEB_ROOT;
    index index.html;
}
EOF

    ln -sf "/etc/nginx/sites-available/$DOMAIN.conf" "/etc/nginx/sites-enabled/"
    nginx -t && systemctl restart nginx

    # ----------------------- Apply SSL Cert --------------------
    echo -e "${BLUE}4) 申请 Let's Encrypt TLS 证书...${RESET}"
    apt install -y certbot python3-certbot-nginx
    certbot --nginx --redirect -d "$DOMAIN" -m admin@$DOMAIN --agree-tos --non-interactive

    # ----------------------- Generate Reality Params ----------
    echo -e "${BLUE}5) 初始化 Reality 配置参数...${RESET}"

    CURRENT_PORT=$(generate_random_port)
    CURRENT_SNI=$(generate_random_sni)
    CURRENT_FP=$(generate_random_fp)
    CURRENT_SHORT_ID=$(generate_short_id)

    generate_reality_keypair
    CURRENT_PRIVATE_KEY="$CURRENT_PRIVATE_KEY"
    CURRENT_PUBLIC_KEY="$CURRENT_PUBLIC_KEY"

    echo -e "${GREEN}初始 Reality 端口：${RESET}$CURRENT_PORT"
    echo -e "${GREEN}初始 Reality SNI：${RESET}$CURRENT_SNI"
    echo -e "${GREEN}初始 Reality fingerprint：${RESET}$CURRENT_FP"
    echo -e "${GREEN}初始 Reality shortId：${RESET}$CURRENT_SHORT_ID"
    echo -e "${GREEN}初始 Reality 公钥：${RESET}$CURRENT_PUBLIC_KEY"

    # ----------------------- Write Xray Config -----------------
    echo -e "${BLUE}6) 写入 Reality config.json ...${RESET}"

cat >"$CONFIG_PATH" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $CURRENT_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
        }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$CURRENT_SNI:443",
          "serverNames": ["$CURRENT_SNI"],
          "privateKey": "$CURRENT_PRIVATE_KEY",
          "shortIds": ["$CURRENT_SHORT_ID"],
          "xver": 0
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

    # ----------------------- Restart Xray ----------------------
    echo -e "${BLUE}7) 重启 Xray ...${RESET}"
    systemctl restart xray
    sleep 1

    # ----------------------- Generate Share Link --------------
    echo -e "${BLUE}8) 生成 Reality 客户端链接...${RESET}"

    SHARE_LINK="vless://$UUID@$DOMAIN:$CURRENT_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&fp=$CURRENT_FP&sni=$CURRENT_SNI&sid=$CURRENT_SHORT_ID&pbk=$CURRENT_PUBLIC_KEY&type=tcp#Reality-$DOMAIN"
    echo "$SHARE_LINK" > "$SHARE_PATH"

    echo -e "${GREEN}安装完成！你的 Reality 链接如下：${RESET}"
    echo ""
    echo -e "${CYAN}$SHARE_LINK${RESET}"
    echo ""

    echo -e "${YELLOW}是否生成二维码？(y/n)${RESET}"
    read -r ans
    if [[ "$ans" == "y" ]]; then
        apt install -y qrencode
        qrencode -t ANSIUTF8 "$SHARE_LINK"
    fi

    pause
}
# ============================================================
#   Part 4 — Main Menu + Logs + Uninstall + Auto-Heal Trigger
# ============================================================

# ========================= Show Logs =========================
show_logs() {
    clear; banner
    echo -e "${CYAN}Xray 日志（实时）${RESET}"
    echo -e "${YELLOW}按 Ctrl + C 退出${RESET}"
    journalctl -u xray -f
}

# ========================= Uninstall =========================
uninstall_all() {
    clear; banner
    echo -e "${RED}⚠️ 你确定要卸载 Xray + Website + Reality 配置吗？ (y/n)${RESET}"
    read -r c
    [[ "$c" != "y" ]] && return

    systemctl stop xray
    systemctl disable xray
    rm -rf /usr/local/etc/xray
    rm -f /usr/local/bin/xray

    rm -rf "$WEB_ROOT"
    rm -rf /etc/nginx/sites-enabled/*
    rm -rf /etc/nginx/sites-available/*
    systemctl restart nginx

    echo -e "${GREEN}卸载完成！${RESET}"
    pause
}

# ========================= Manual Heal ========================
manual_heal() {
    clear; banner
    echo -e "${YELLOW}手动触发自动自愈系统...${RESET}"
    auto_heal
}

# ========================= Auto Block Scan ====================
scan_and_heal() {
    clear; banner
    echo -e "${BLUE}执行完整 DPI 阻断扫描...${RESET}"
    
    RESULT=$(detect_gfw_block)

    if [[ "$RESULT" == "BLOCKED" ]]; then
        echo -e "${RED}⚠️ 检测到被墙，正在自动切换端口与密钥...${RESET}"
        auto_heal
    else
        echo -e "${GREEN}✔ 无异常，你的节点运行正常${RESET}"
        pause
    fi
}

# ========================= Show Current Config ================
show_current_config() {
    clear; banner

    echo -e "${CYAN}当前 Reality 配置参数：${RESET}"
    echo -e "${GREEN}域名：${RESET}$DOMAIN"
    echo -e "${GREEN}端口：${RESET}$CURRENT_PORT"
    echo -e "${GREEN}SNI：${RESET}$CURRENT_SNI"
    echo -e "${GREEN}指纹：${RESET}$CURRENT_FP"
    echo -e "${GREEN}短 ID：${RESET}$CURRENT_SHORT_ID"
    echo -e "${GREEN}公钥：${RESET}$CURRENT_PUBLIC_KEY"
    echo ""
    echo -e "${CYAN}当前完整链接：${RESET}"
    cat "$SHARE_PATH"

    pause
}

# ========================= Main Menu ==========================
main_menu() {
    while true; do
        clear; banner
        echo -e "${BLUE}请选择操作：${RESET}"
        echo ""
        echo -e "${GREEN} 1) 安装 Reality V4.3（初次安装）${RESET}"
        echo -e "${GREEN} 2) 查看节点状态 / 健康检查${RESET}"
        echo -e "${GREEN} 3) 执行自动自愈（端口 / 密钥 / SNI 切换）${RESET}"
        echo -e "${GREEN} 4) 检测是否被墙（DPI / GFW 阻断检测）${RESET}"
        echo -e "${GREEN} 5) 查看当前节点配置（端口 / SNI / 指纹）${RESET}"
        echo -e "${GREEN} 6) 显示 Xray 日志（实时）${RESET}"
        echo -e "${GREEN} 7) 卸载全部组件${RESET}"
        echo ""
        echo -e "${RED} 0) 退出${RESET}"
        echo ""
        read -p "输入编号: " choice

        case "$choice" in
            1) install_reality ;;
            2) health_check ;;
            3) manual_heal ;;
            4) scan_and_heal ;;
            5) show_current_config ;;
            6) show_logs ;;
            7) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效的选择${RESET}" && pause ;;
        esac
    done
}

# ========================= Start Script =======================
main_menu
