#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ===================== 工作目录 =====================
WORK_DIR="proxy_files"
mkdir -p "$WORK_DIR"
echo "📁 工作目录: $WORK_DIR"

# ===================== 环境变量 =====================
SERVICE_TYPE="${SERVICE_TYPE:-1}"  # 1: hy2, 2: tuic, 3: vless-argo
SERVICE_PORT="${SERVICE_PORT:-28888}"
IP_VERSION="${IP_VERSION:-}"  # 4, 6, 或空
MASQ_DOMAINS=(
    "www.microsoft.com" "www.cloudflare.com" "www.bing.com"
    "www.apple.com" "www.amazon.com" "www.wikipedia.org"
    "cdnjs.cloudflare.com" "cdn.jsdelivr.net" "static.cloudflareinsights.com"
    "www.speedtest.net"
)
MASQ_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}

# ===================== 服务类型选择 =====================
if [[ "$SERVICE_TYPE" == "1" ]]; then
    SELECTED_SERVICE="hy2"
    LINK_FILE="$WORK_DIR/hy2_link.txt"
elif [[ "$SERVICE_TYPE" == "2" ]]; then
    SELECTED_SERVICE="tuic"
    LINK_FILE="$WORK_DIR/tuic_link.txt"
elif [[ "$SERVICE_TYPE" == "3" ]]; then
    SELECTED_SERVICE="vless"
    LINK_FILE="$WORK_DIR/vless_link.txt"
else
    echo "❌ 无效 SERVICE_TYPE: $SERVICE_TYPE"
    exit 1
fi
touch "$LINK_FILE"
echo "✅ 选择服务: $SELECTED_SERVICE"
echo "🎯 伪装域名: $MASQ_DOMAIN"

# ===================== 文件路径 =====================
if [[ "$SELECTED_SERVICE" == "vless" ]]; then
    CF_BIN="$WORK_DIR/cloudflared"
    SB_BIN="$WORK_DIR/sing-box"
    VLESS_CONF="$WORK_DIR/vless-config.json"
    LOG_FILE="$WORK_DIR/vless.log"
fi

# ===================== 载入 HY2/TUIC 控制区 =====================
load_existing_config() {
    if [[ "$SELECTED_SERVICE" == "hy2" && -f "$WORK_DIR/server.json" ]]; then
        AUTH_PASSWORD=$(grep '"password":' "$WORK_DIR/server.json" | sed -E 's/.*"password":\s*"([^"]+)".*/\1/')
        echo "📂 已加载 HY2 配置"
        return 0
    elif [[ "$SELECTED_SERVICE" == "tuic" && -f "$WORK_DIR/server.toml" ]]; then
        local user_line
        user_line=$(grep -A1 '^\[users\]' "$WORK_DIR/server.toml" | tail -n1)
        TUIC_UUID=$(echo "$user_line" | awk -F'=' '{print $1}' | tr -d ' ')
        TUIC_PASSWORD=$(echo "$user_line" | awk -F'"' '{print $2}')
        echo "📂 已加载 TUIC 配置"
        return 0
    fi
    return 1
}

# ===================== 自签证书（HY2/TUIC） =====================
generate_certificate() {
    [[ "$SELECTED_SERVICE" == "vless" ]] && return

    if [[ "$SELECTED_SERVICE" == "tuic" ]]; then
        CERT_PEM="$WORK_DIR/tuic-cert.pem"
        KEY_PEM="$WORK_DIR/tuic-key.pem"
    else
        CERT_PEM="$WORK_DIR/c.pem"
        KEY_PEM="$WORK_DIR/k.pem"
    fi

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

# ===================== 下载二进制（HY2/TUIC） =====================
check_binary() {
    if [[ "$SELECTED_SERVICE" == "hy2" ]]; then
        HY2_BIN="$WORK_DIR/hysteria-server"
        if [[ ! -x "$HY2_BIN" ]]; then
            echo "📥 下载 hysteria-server..."
            curl -L -f -o "$HY2_BIN" "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.3/hysteria-linux-amd64"
            chmod +x "$HY2_BIN"
        fi

    elif [[ "$SELECTED_SERVICE" == "tuic" ]]; then
        TUIC_BIN="$WORK_DIR/tuic-server"
        if [[ ! -x "$TUIC_BIN" ]]; then
            echo "📥 下载 tuic-server..."
            curl -L -f -o "$TUIC_BIN" "https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
            chmod +x "$TUIC_BIN"
        fi
    fi
}

# ==========================================================================================
# 🔥 VLESS / ARGO 功能
# ==========================================================================================

download_vless_bins() {
    local arch="amd64"

    [[ ! -x "$CF_BIN" ]] && {
        echo "📥 下载 cloudflared..."
        curl -L -o "$CF_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch"
        chmod +x "$CF_BIN"
    }

    [[ ! -x "$SB_BIN" ]] && {
        echo "📥 下载 sing-box..."
        local ver="1.8.0"
        local tar="singbox.tar.gz"
        curl -L -o "$tar" "https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box-$ver-linux-$arch.tar.gz"
        tar -xzf "$tar" --strip-components=1 -C "$WORK_DIR" "sing-box-$ver-linux-$arch/sing-box"
        rm -f "$tar"
        chmod +x "$SB_BIN"
    }
}

generate_vless_config() {
    USER_UUID=$(cat /proc/sys/kernel/random/uuid)
    WS_PATH="/$(echo $USER_UUID | cut -d'-' -f1)"
    VLESS_WS_PORT=8080

    cat > "$VLESS_CONF" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": $VLESS_WS_PORT,
    "users":[{"uuid":"$USER_UUID"}],
    "transport": {
      "type": "ws",
      "path": "$WS_PATH",
      "max_early_data": 16384,
      "early_data_header_name": "Sec-WebSocket-Protocol"
    },
    "multiplex": {"enabled": true}
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF

    echo "$USER_UUID" > "$WORK_DIR/vless_uuid.txt"
    echo "$WS_PATH" > "$WORK_DIR/vless_path.txt"
}

# -------------------- 修改 run_vless_daemon 只启动一次 --------------------
run_vless_daemon() {
    local VLESS_WS_PORT=8080

    while true; do
        rm -f "$WORK_DIR/cloudflared.log"
        echo "🚀 启动 Argo 隧道..."

        env GOGC=200 GOMEMLIMIT=32MiB GOMAXPROCS=1 \
            "$CF_BIN" tunnel --url "http://localhost:$VLESS_WS_PORT" --no-autoupdate --protocol quic \
            > "$WORK_DIR/cloudflared.log" 2>&1 &

        CF_PID=$!

        echo "⏳ 等待隧道域名..."
        local url=""
        for i in {1..30}; do
            url=$(grep -o -E "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$WORK_DIR/cloudflared.log" | head -n1)
            if [[ -n "$url" ]]; then break; fi
            sleep 1
        done

        if [[ -z "$url" ]]; then
            echo "❌ 获取 Argo 域名失败，打印 cloudflared 日志："
            cat "$WORK_DIR/cloudflared.log"
            echo "⚠️ 5 秒后重试..."
            kill -9 "$CF_PID" 2>/dev/null || true
            sleep 5
            continue
        fi

        HOST=$(echo "$url" | sed 's#https://##')
        echo "🌐 Argo 域名: $HOST"

        echo "🚀 启动 sing-box..."
        env GOGC=200 GOMEMLIMIT=32MiB GOMAXPROCS=1 \
            "$SB_BIN" run -c "$VLESS_CONF" >> "$LOG_FILE" 2>&1 &

        SB_PID=$!

        generate_vless_link "$HOST"

        # 等待任意进程退出，如果退出则循环重启
        wait -n "$CF_PID" "$SB_PID"
        echo "⚠️ VLESS 服务退出，5 秒后重启..."
        sleep 5
    done
}


generate_vless_link() {
    local HOST="$1"
    local UUID=$(cat "$WORK_DIR/vless_uuid.txt")
    local PATH=$(cat "$WORK_DIR/vless_path.txt")

    LINK="vless://${UUID}@${HOST}:443?encryption=none&security=tls&type=ws&host=${HOST}&path=${PATH}&sni=${HOST}#VLESS-Argo"

    echo "$LINK" > "$LINK_FILE"

    echo "📱 VLESS 链接已生成:"
    cat "$LINK_FILE"
}

# ==========================================================================================
# 主逻辑入口
# ==========================================================================================

main() {
    if [[ "$SELECTED_SERVICE" == "vless" ]]; then
        echo "📁 工作目录: $WORK_DIR"
        echo "🎯 伪装域名: $MASQ_DOMAIN"
        echo "⚙️ 初始化 VLESS + Argo 服务..."

        download_vless_bins
        generate_vless_config
        run_vless_once
        exit 0
    fi

    # HY2 / TUIC 原逻辑
    echo "📁 工作目录: $WORK_DIR"
    echo "🎯 伪装域名: $MASQ_DOMAIN"

    load_existing_config || echo "⚙️ 初始化新配置..."
    generate_certificate
    check_binary
    generate_config

    local server_ip
    server_ip=$(curl -s https://api64.ipify.org || echo "YOUR_SERVER_IP")
    generate_link "$server_ip"

    echo "🎉 $SELECTED_SERVICE 启动完成: $server_ip:$SERVICE_PORT"
    echo "🎯 SNI: $MASQ_DOMAIN"
    echo "📄 日志: $LOG_FILE"

    run_daemon
}

main "$@"
