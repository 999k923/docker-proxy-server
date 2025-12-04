#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ===================== 工作目录 =====================
WORK_DIR="/proxy_files"
mkdir -p "$WORK_DIR"
echo "📁 工作目录: $WORK_DIR"

# ===================== 环境变量 =====================
SERVICE_TYPE="${SERVICE_TYPE:-1}"  # 1: hy2, 2: tuic, 3: vmess-argo
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
elif [[ "$SERVICE_TYPE" == "3" ]]; then
    SELECTED_SERVICE="vmess-argo"
    LINK_FILE="$WORK_DIR/vmess_argo_link.txt"
    ARGO_PORT=28888
    ARGO_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    ARGO_TOKEN="${ARGO_TOKEN:-}"   # 可通过环境变量传入
    ARGO_DOMAIN="${ARGO_DOMAIN:-}"
else
    echo "❌ 无效 SERVICE_TYPE: $SERVICE_TYPE"
    exit 1
fi
touch "$LINK_FILE"
echo "✅ 选择服务: $SELECTED_SERVICE"
echo "🎯 随机选择SNI伪装域名: $MASQ_DOMAIN"

# ===================== 服务变量 =====================
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
elif [[ "$SELECTED_SERVICE" == "vmess-argo" ]]; then
    SINGBOX_CONFIG="$WORK_DIR/sing-box.json"
    ARGO_CONFIG="$WORK_DIR/argo.yml"
    SINGBOX_BIN="$WORK_DIR/sing-box"
    CLOUDFLARED_BIN="$WORK_DIR/cloudflared"
    LOG_FILE="$WORK_DIR/vmess_argo.log"
fi

# ===================== 证书生成 =====================
generate_certificate() {
    if [[ "$SELECTED_SERVICE" == "hy2" || "$SELECTED_SERVICE" == "tuic" ]]; then
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
    elif [[ "$SELECTED_SERVICE" == "vmess-argo" ]]; then
        # 下载 sing-box
        if [[ ! -f "$SINGBOX_BIN" ]]; then
            CPU_ARCH=$(uname -m)
            [[ "$CPU_ARCH" == "x86_64" ]] && CPU_ARCH="amd64"
            [[ "$CPU_ARCH" == "aarch64" ]] && CPU_ARCH="arm64"
            echo "📥 下载 sing-box..."
            TMP_TAR="$WORK_DIR/sing-box.tar.gz"
            SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v1.9.0/sing-box-1.9.0-linux-${CPU_ARCH}.tar.gz"
            curl -L -f -o "$TMP_TAR" "$SINGBOX_URL"
            tar -xzf "$TMP_TAR" -C "$WORK_DIR"
            mv "$WORK_DIR/sing-box-1.9.0-linux-${CPU_ARCH}/sing-box" "$SINGBOX_BIN"
            chmod +x "$SINGBOX_BIN"
            rm -rf "$TMP_TAR" "$WORK_DIR/sing-box-1.9.0-linux-${CPU_ARCH}"
        fi
        # 下载 cloudflared
        if [[ ! -f "$CLOUDFLARED_BIN" ]]; then
            echo "📥 下载 cloudflared..."
            CPU_ARCH=$(uname -m)
            [[ "$CPU_ARCH" == "x86_64" ]] && CPU_ARCH="amd64"
            [[ "$CPU_ARCH" == "aarch64" ]] && CPU_ARCH="arm64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CPU_ARCH}"
            curl -L -f -o "$CLOUDFLARED_BIN" "$CLOUDFLARED_URL"
            chmod +x "$CLOUDFLARED_BIN"
        fi
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
    elif [[ "$SELECTED_SERVICE" == "tuic" ]]; then
        [[ -z "$TUIC_UUID" ]] && TUIC_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
        [[ -z "$TUIC_PASSWORD" ]] && TUIC_PASSWORD=$(openssl rand -hex 16)
        cat > "$SERVER_TOML" <<EOF
server = "0.0.0.0:$SERVICE_PORT"
[users]
$TUIC_UUID = "$TUIC_PASSWORD"
[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]
EOF
    elif [[ "$SELECTED_SERVICE" == "vmess-argo" ]]; then
        cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": {"level":"info","timestamp":true},
  "inbounds":[
    {
      "type":"vmess",
      "tag":"vmess-in",
      "listen":"127.0.0.1",
      "listen_port":${ARGO_PORT},
      "users":[{"uuid":"${ARGO_UUID}","alterId":0}],
      "transport":{"type":"ws","path":"/${ARGO_UUID}-vm"}
    }
  ],
  "outbounds":[{"type":"direct","tag":"direct"}]
}
EOF
        cat > "$ARGO_CONFIG" <<EOF
log-level: info
ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://127.0.0.1:${ARGO_PORT}
  - service: http_status:404
EOF
    fi
}

# ===================== 链接生成 =====================
generate_link() {
    SERVER_IP=$(curl -s https://api64.ipify.org || echo "YOUR_SERVER_IP")
    if [[ "$SELECTED_SERVICE" == "hy2" ]]; then
        echo "hysteria2://$AUTH_PASSWORD@$SERVER_IP:$SERVICE_PORT?sni=$MASQ_DOMAIN&alpn=h3&insecure=1#Hy2-JSON" > "$LINK_FILE"
    elif [[ "$SELECTED_SERVICE" == "tuic" ]]; then
        echo "tuic://$TUIC_UUID:$TUIC_PASSWORD@$SERVER_IP:$SERVICE_PORT?sni=$MASQ_DOMAIN&alpn=h3#TUIC-HIGH-PERF" > "$LINK_FILE"
    elif [[ "$SELECTED_SERVICE" == "vmess-argo" ]]; then
        VMESS_JSON=$(printf '{"v":"2","ps":"vmess-argo","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/%s-vm","tls":"tls","sni":"%s"}' "$ARGO_DOMAIN" "$ARGO_UUID" "$ARGO_DOMAIN" "$ARGO_UUID" "$ARGO_DOMAIN")
        VMESS_BASE64=$(echo "$VMESS_JSON" | tr -d '\n' | base64 -w0)
        echo "vmess://${VMESS_BASE64}" > "$LINK_FILE"
    fi
    echo "📱 链接生成: $LINK_FILE"
}

# ===================== 启动服务 =====================
run_daemon() {
    if [[ "$SELECTED_SERVICE" == "hy2" ]]; then
        cmd=("$HY2_BIN" "server" "-c" "$SERVER_CONFIG")
        while true; do
            echo "🚀 启动 HY2..."
            "${cmd[@]}" >> "$LOG_FILE" 2>&1
            echo "⚠️ HY2 服务已退出，5秒后重启..." >> "$LOG_FILE" 2>&1
            sleep 5
        done
    elif [[ "$SELECTED_SERVICE" == "tuic" ]]; then
        cmd=("$TUIC_BIN" "-c" "$SERVER_TOML")
        while true; do
            echo "🚀 启动 TUIC..."
            "${cmd[@]}" >> "$LOG_FILE" 2>&1
            echo "⚠️ TUIC 服务已退出，5秒后重启..." >> "$LOG_FILE" 2>&1
            sleep 5
        done
    elif [[ "$SELECTED_SERVICE" == "vmess-argo" ]]; then
        echo "🚀 启动 sing-box (VMess)..."
        nohup "$SINGBOX_BIN" run -c "$SINGBOX_CONFIG" >> "$LOG_FILE" 2>&1 &
        echo "🚀 启动 cloudflared..."
        if [[ -n "$ARGO_TOKEN" && -n "$ARGO_DOMAIN" ]]; then
            nohup "$CLOUDFLARED_BIN" tunnel --config "$ARGO_CONFIG" run --token "$ARGO_TOKEN" >> "$WORK_DIR/argo.log" 2>&1 &
        else
            nohup "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:${ARGO_PORT}" >> "$WORK_DIR/argo.log" 2>&1 &
        fi
    fi
}

# ===================== 主函数 =====================
main() {
    generate_certificate
    check_binary
    generate_config
    generate_link
    run_daemon
}

main "$@"
