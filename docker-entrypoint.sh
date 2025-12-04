#!/bin/sh

set -e

CONFIG_DIR="/proxy_files"
SINGBOX_CONFIG="$CONFIG_DIR/sing-box.json"
ARGO_CONFIG="$CONFIG_DIR/argo.yml"
CLOUDFLARED_PATH="/usr/local/bin/cloudflared"

echo "==== Proxy Server 启动 ===="
echo "Service Type: $SERVICE_TYPE"

###############################################
# 1. 生成 sing-box 配置（包含 VMESS + WS）
###############################################
generate_singbox_config() {
    echo "[INFO] 生成 sing-box 配置..."

cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": 28888,
      "users": [{"uuid": "11111111-1111-1111-1111-111111111111"}],
      "transport": {
        "type": "ws",
        "path": "/vless"
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": 28889,
      "users": [{"uuid": "22222222-2222-2222-2222-222222222222", "alterId": 0}],
      "transport": {
        "type": "ws",
        "path": "/vmess"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" },
    { "type": "block" }
  ]
}
EOF
}


###############################################
# 2. 生成 Argo 隧道配置（和你脚本保持完全一致）
###############################################
generate_argo_config() {
    echo "[INFO] 生成 Argo ingress 配置..."

cat > "$ARGO_CONFIG" <<EOF
log-level: info
ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://127.0.0.1:${ARGO_PORT}
  - service: http_status:404
EOF
}


###############################################
# 3. 启动 cloudflared（使用你脚本的稳定模式）
###############################################
start_argo() {
    if [ -n "$ARGO_TOKEN" ]; then
        echo "[INFO] 使用 Argo 固定隧道 TOKEN 模式"
        "$CLOUDFLARED_PATH" tunnel \
            --config "$ARGO_CONFIG" \
            run --token "$ARGO_TOKEN" \
            > "$CONFIG_DIR/argo.log" 2>&1 &
    else
        echo "[INFO] 使用 临时隧道（不推荐）"
        "$CLOUDFLARED_PATH" tunnel \
            --url "http://127.0.0.1:${ARGO_PORT}" \
            > "$CONFIG_DIR/argo.log" 2>&1 &
    fi
}


###############################################
# 4. 启动 sing-box
###############################################
start_singbox() {
    echo "[INFO] 启动 sing-box..."
    /usr/local/bin/sing-box run -c "$SINGBOX_CONFIG"
}


###############################################
# 主流程
###############################################
generate_singbox_config
generate_argo_config
start_argo
sleep 2
start_singbox

