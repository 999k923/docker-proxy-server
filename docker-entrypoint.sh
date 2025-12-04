#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ===================== 工作目录 =====================
WORK_DIR="proxy_files"
mkdir -p "$WORK_DIR"
echo "📁 工作目录: $WORK_DIR"

# ===================== 环境变量 =====================
SERVICE_TYPE="${SERVICE_TYPE:-1}"  # 1: hy2, 2: tuic
SERVICE_PORT="${SERVICE_PORT:-28888}"
IP_VERSION="${IP_VERSION:-}"  # 4, 6, 或空
MASQ_DOMAINS=(
    "www.microsoft.com" "www.cloudflare.com" "www.bing.com"
    "www.apple.com" "www.amazon.com" "www.wikipedia.org"
    "cdnjs.cloudflare.com" "cdn.jsdelivr.net" "static.cloudflareinsights.com"
    "www.speedtest.net"
)
MASQ_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}

# ===================== 服务选择 =====================
if [[ "$SERVICE_TYPE" == "1" ]]; then
    SELECTED_SERVICE="hy2"
    LINK_FILE="$WORK_DIR/hy2_link.txt"
elif [[ "$SERVICE_TYPE" == "2" ]]; then
    SELECTED_SERVICE="tuic"
    LINK_FILE="$WORK_DIR/tuic_link.txt"
else
    echo "❌ 无效 SERVICE_TYPE: $SERVICE_TYPE"
    exit 1
fi
touch "$LINK_FILE"
echo "✅ 选择服务: $SELECTED_SERVICE"
echo "🎯 随机选择SNI伪装域名: $MASQ_DOMAIN"

# ===================== 服务变量 =====================
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
fi

# ===================== 加载现有配置 =====================
load_existing_config() {
    if [[ "$SELECTED_SERVICE" == "hy2" && -f "$SERVER_CONFIG" ]]; then
        AUTH_PASSWORD=$(grep '"password":' "$SERVER_CONFIG" | sed -E 's/.*"password":\s*"([^"]+)".*/\1/')
        echo "📂 已加载 HY2 配置"
        return 0
    elif [[ "$SELECTED_SERVICE" == "tuic" && -f "$SERVER_TOML" ]]; then
        local user_line
        user_line=$(grep -A1 '^\[users\]' "$SERVER_TOML" | tail -n1)
        TUIC_UUID=$(echo "$user_line" | awk -F'=' '{print $1}' | tr -d ' ')
        TUIC_PASSWORD=$(echo "$user_line" | awk -F'"' '{print $2}')
        echo "📂 已加载 TUIC 配置"
        return 0
    fi
    return 1
}

# ===================== 证书生成 =====================
generate_certificate() {
    if [[ ! -f "$CERT_PEM" || ! -f "$KEY_PEM" ]] || ! openssl x509 -checkend 0 -noout -in "$CERT_PEM" 2>/dev/null; then
        local cert_days=90
        [[ "$SELECTED_SERVICE" == "tuic" ]] && cert_days=365
        echo "🔐 生成自签证书..."
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=$MASQ_DOMAIN" -days "$cert_days" -nodes >/dev/null 2>&1
        chmod 600 "$KEY_PEM"
        chmod 644 "$CERT_PEM"
        echo "✅ 证书生成完成"
    fi
}

# ===================== 二进制下载 =====================
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
    fi
}

# ===================== 配置生成 =====================
generate_config() {
    if [[ "$SELECTED_SERVICE" == "hy2" ]]; then
        [[ -z "$AUTH_PASSWORD" ]] && AUTH_PASSWORD=$(openssl rand -hex 16)
        cat > "$SERVER_CONFIG" <<EOF
{
  "listen": ":$SERVICE_PORT",
  "tls": {
    "cert": "$CERT_PEM",
    "key": "$KEY_PEM",
    "alpn": ["h3"]
  },
  "auth": {
    "type": "password",
    "password": "$AUTH_PASSWORD"
  },
  "quic": {
    "maxUdpPayloadSize": 1200,
    "initConnReceiveWindow": 8388608,
    "initStreamReceiveWindow": 8388608,
    "maxIdleTimeout": "30s"
  }
}
EOF
    else
        [[ -z "$TUIC_UUID" ]] && TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
        [[ -z "$TUIC_PASSWORD" ]] && TUIC_PASSWORD=$(openssl rand -hex 16)

        # 根据 IP_VERSION 设置监听地址和 dual_stack
        if [[ "$IP_VERSION" == "4" ]]; then
            SERVER_BIND="0.0.0.0:$SERVICE_PORT"
            DUAL_STACK=false
        elif [[ "$IP_VERSION" == "6" ]]; then
            SERVER_BIND="[::]:$SERVICE_PORT"
            DUAL_STACK=false
        else
            SERVER_BIND="0.0.0.0:$SERVICE_PORT"
            DUAL_STACK=true
        fi

        cat > "$SERVER_TOML" <<EOF
server = "$SERVER_BIND"
dual_stack = $DUAL_STACK
[users]
$TUIC_UUID = "$TUIC_PASSWORD"
[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]
insecure = true
EOF
    fi
}

# ===================== 链接生成 =====================
generate_link() {
    local ip="$1"
    if [[ "$ip" =~ ":" ]]; then
        ip="[$ip]"
    fi

    if [[ "$SELECTED_SERVICE" == "hy2" ]]; then
        echo "hysteria2://$AUTH_PASSWORD@$ip:$SERVICE_PORT?sni=$MASQ_DOMAIN&alpn=h3&insecure=1#Hy2-JSON" > "$LINK_FILE"
    else
        local clean_uuid clean_pass
        clean_uuid=$(echo "$TUIC_UUID" | tr -d ' ')
        clean_pass=$(echo "$TUIC_PASSWORD" | tr -d ' ')
        echo "tuic://$clean_uuid:$clean_pass@$ip:$SERVICE_PORT?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$MASQ_DOMAIN&allow_insecure=1#TUIC-HIGH-PERF" > "$LINK_FILE"
    fi
    echo "📱 链接生成: $LINK_FILE"
}

# ===================== 守护进程 =====================
run_daemon() {
    local cmd
    if [[ "$SELECTED_SERVICE" == "hy2" ]]; then
        cmd=("$HY2_BIN" "server" "-c" "$SERVER_CONFIG")
    else
        cmd=("$TUIC_BIN" "-c" "$SERVER_TOML")
    fi

    while true; do
        echo "🚀 启动 $SELECTED_SERVICE 服务..."
        "${cmd[@]}" >> "$LOG_FILE" 2>&1
        echo "⚠️ $SELECTED_SERVICE 服务已退出，5秒后重启..." >> "$LOG_FILE" 2>&1
        sleep 5
    done
}

# ===================== 获取公网 IP =====================
get_server_ip() {
    curl -s https://api64.ipify.org || curl -s https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# ===================== 主函数 =====================
main() {
    load_existing_config || echo "⚙️ 初始化新配置..."
    generate_certificate
    check_binary
    generate_config

    local server_ip
    server_ip=$(get_server_ip)
    generate_link "$server_ip"

    echo "🎉 $SELECTED_SERVICE 服务启动完成: $server_ip:$SERVICE_PORT"
    echo "🎯 SNI/伪装域名: $MASQ_DOMAIN"
    echo "📄 日志文件: $LOG_FILE"

    run_daemon
}

main "$@"
