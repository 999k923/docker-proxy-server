#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

WORK_DIR="/proxy_files"
mkdir -p "$WORK_DIR"
echo "📁 工作目录: $WORK_DIR"

SERVICE_TYPE="${SERVICE_TYPE:-1}"  # 1=hy2, 2=tuic, 3=argo
MASQ_DOMAINS=(
    "www.microsoft.com" "www.cloudflare.com" "www.bing.com"
    "www.apple.com" "www.amazon.com" "www.wikipedia.org"
    "cdnjs.cloudflare.com" "cdn.jsdelivr.net" "static.cloudflareinsights.com"
    "www.speedtest.net"
)
MASQ_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}

# ---------------- 服务选择 ----------------
if [[ "$SERVICE_TYPE" == "1" ]]; then
    SELECTED_SERVICE="hy2"
    LINK_FILE="$WORK_DIR/hy2_link.txt"
elif [[ "$SERVICE_TYPE" == "2" ]]; then
    SELECTED_SERVICE="tuic"
    LINK_FILE="$WORK_DIR/tuic_link.txt"
elif [[ "$SERVICE_TYPE" == "3" ]]; then
    SELECTED_SERVICE="argo"
    LINK_FILE="$WORK_DIR/argo_link.txt"
else
    echo "❌ 无效 SERVICE_TYPE: $SERVICE_TYPE"
    exit 1
fi
touch "$LINK_FILE"
echo "✅ 选择服务: $SELECTED_SERVICE"
echo "🎯 随机选择SNI伪装域名: $MASQ_DOMAIN"

# ---------------- 服务变量 ----------------
SERVICE_PORT=28888
if [[ "$SELECTED_SERVICE" == "hy2" ]]; then
    HY2_VERSION="app%2Fv2.6.3"
    SERVER_CONFIG="$WORK_DIR/server.json"
    CERT_PEM="$WORK_DIR/c.pem"
    KEY_PEM="$WORK_DIR/k.pem"
    AUTH_PASSWORD=""
    HY2_BIN="$WORK_DIR/hysteria-server"
    LOG_FILE="$WORK_DIR/hy2.log"
elif [[ "$SELECTED_SERVICE" == "tuic" ]]; then
    SERVER_TOML="$WORK_DIR/server.toml"
    CERT_PEM="$WORK_DIR/tuic-cert.pem"
    KEY_PEM="$WORK_DIR/tuic-key.pem"
    TUIC_BIN="$WORK_DIR/tuic-server"
    TUIC_UUID=""
    TUIC_PASSWORD=""
    LOG_FILE="$WORK_DIR/tuic.log"
elif [[ "$SELECTED_SERVICE" == "argo" ]]; then
    ARGO_TOKEN="${ARGO_TOKEN:-}"
    ARGO_DOMAIN="${ARGO_DOMAIN:-example.com}"
    ARGO_PORT="${ARGO_PORT:-443}"
    CLOUDLARED_BIN="$WORK_DIR/cloudflared"
    LOG_FILE="$WORK_DIR/argo.log"
fi

# ---------------- 下载二进制 ----------------
check_binary() {
    if [[ "$SELECTED_SERVICE" == "hy2" && ! -x "$HY2_BIN" ]]; then
        echo "📥 下载 hysteria-server..."
        curl -L -f -o "$HY2_BIN" "https://github.com/apernet/hysteria/releases/download/$HY2_VERSION/hysteria-linux-amd64"
        chmod +x "$HY2_BIN"
    elif [[ "$SELECTED_SERVICE" == "tuic" && ! -x "$TUIC_BIN" ]]; then
        echo "📥 下载 tuic-server..."
        TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
        curl -L -f -o "$TUIC_BIN" "$TUIC_URL"
        chmod +x "$TUIC_BIN"
    elif [[ "$SELECTED_SERVICE" == "argo" && ! -x "$CLOUDLARED_BIN" ]]; then
        echo "📥 下载 cloudflared..."
        curl -L -o "$CLOUDLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
        chmod +x "$CLOUDLARED_BIN"
    fi
}

# ---------------- 生成客户端链接 ----------------
generate_link() {
    local ip="$1"
    if [[ "$SELECTED_SERVICE" == "hy2" ]]; then
        echo "hysteria2://$AUTH_PASSWORD@$ip:$SERVICE_PORT?sni=$MASQ_DOMAIN&alpn=h3&insecure=1#Hy2-JSON" > "$LINK_FILE"
    elif [[ "$SELECTED_SERVICE" == "tuic" ]]; then
        echo "tuic://$TUIC_UUID:$TUIC_PASSWORD@$ip:$SERVICE_PORT?sni=$MASQ_DOMAIN&alpn=h3#TUIC-HIGH-PERF" > "$LINK_FILE"
    elif [[ "$SELECTED_SERVICE" == "argo" ]]; then
        # vmess 节点，固定端口443，host=www.visa.com.sg，tls开启
        VMESS_ID=$(cat /proc/sys/kernel/random/uuid)
        cat > "$LINK_FILE" <<EOF
vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"vm-argo\",\"add\":\"www.visa.com.sg\",\"port\":\"443\",\"id\":\"$VMESS_ID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$ARGO_DOMAIN\",\"path\":\"/\",\"tls\":\"tls\"}" | base64 -w0)
EOF
    fi
    echo "📱 链接生成: $LINK_FILE"
}

# ---------------- 获取公网 IP ----------------
get_server_ip() {
    curl -s https://api64.ipify.org || echo "YOUR_SERVER_IP"
}

# ---------------- 守护进程 ----------------
run_daemon() {
    if [[ "$SELECTED_SERVICE" == "hy2" ]]; then
        cmd=("$HY2_BIN" "server" "-c" "$SERVER_CONFIG")
    elif [[ "$SELECTED_SERVICE" == "tuic" ]]; then
        cmd=("$TUIC_BIN" "-c" "$SERVER_TOML")
    elif [[ "$SELECTED_SERVICE" == "argo" ]]; then
        # 新版 cloudflared 不支持 --token，一次性 tunnel 模式使用 run
        cmd=("$CLOUDLARED_BIN" "tunnel" "--no-autoupdate" "run" "--url" "tcp://localhost:$ARGO_PORT")
    fi

    while true; do
        echo "🚀 启动 $SELECTED_SERVICE 服务..." >> "$LOG_FILE" 2>&1
        "${cmd[@]}" >> "$LOG_FILE" 2>&1 || true
        echo "⚠️ $SELECTED_SERVICE 服务已退出，5秒后重启..." >> "$LOG_FILE" 2>&1
        sleep 5
    done
}

# ---------------- 主函数 ----------------
main() {
    echo "⚙️ 初始化新配置..."
    check_binary

    if [[ "$SELECTED_SERVICE" != "argo" ]]; then
        server_ip=$(get_server_ip)
        generate_link "$server_ip"
        echo "🎉 $SELECTED_SERVICE 服务启动完成: $server_ip:$SERVICE_PORT"
    else
        generate_link "argo"
        echo "🎉 ARGO Tunnel vmess 服务已生成节点: $ARGO_DOMAIN:$ARGO_PORT"
    fi

    echo "📄 日志文件: $LOG_FILE"
    run_daemon
}

main "$@"
