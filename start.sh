#!/bin/sh
# Render 启动脚本：同时拉起 cloudflared tunnel（gRPC 穿透）和哪吒面板
# 需要 Render 环境变量：CF_TUNNEL_CREDS（credentials.json 的 base64）
# 原理：
# 1. dashboard 建的 tunnel 用 --token 跑会忽略本地 ingress，改用 credentials-file + 本地 config.yml
# 2. cloudflared 的 http2Origin 不支持明文 h2c，必须是 https 源站；面板开启内置 HTTPS（8443，自签名证书）
# 3. cloudflared 以 https:// + http2Origin + noTLSVerify 连接面板，gRPC 才能走通

set -e

# 官方镜像原 entrypoint 的行为
printf "nameserver 127.0.0.11\nnameserver 8.8.4.4\nnameserver 223.5.5.5\n" > /etc/resolv.conf

if [ -z "$CF_TUNNEL_CREDS" ]; then
  echo "[start] ERROR: CF_TUNNEL_CREDS 未设置，去 Render Dashboard -> Environment 加上"
  exit 1
fi

# --- 面板 HTTPS 配置（供 cloudflared 的 http2Origin 使用）---
# 面板配置文件位置：/dashboard/data/config.yaml
PANEL_CONFIG="/dashboard/data/config.yaml"
TLS_CERT="/etc/nezha-tls/cert.pem"
TLS_KEY="/etc/nezha-tls/key.pem"
HTTPS_PORT="8443"

if [ ! -f "$TLS_CERT" ] || [ ! -f "$TLS_KEY" ]; then
  echo "[start] ERROR: TLS 证书缺失 ($TLS_CERT)，检查 Dockerfile 是否 COPY 了 tls/ 目录"
  exit 1
fi

mkdir -p /dashboard/data
if [ ! -f "$PANEL_CONFIG" ]; then
  echo "[start] 创建面板初始配置（含 HTTPS）..."
  cat > "$PANEL_CONFIG" <<EOF
listen_port: 8008
https:
  listen_port: $HTTPS_PORT
  tls_cert_path: $TLS_CERT
  tls_key_path: $TLS_KEY
  insecure_tls: false
EOF
elif ! grep -q "^https:" "$PANEL_CONFIG"; then
  echo "[start] 向现有面板配置注入 HTTPS 段..."
  cat >> "$PANEL_CONFIG" <<EOF
https:
  listen_port: $HTTPS_PORT
  tls_cert_path: $TLS_CERT
  tls_key_path: $TLS_KEY
  insecure_tls: false
EOF
else
  echo "[start] 面板配置已有 https 段，跳过注入"
fi

# --- cloudflared 配置 ---
mkdir -p /etc/cloudflared
echo "$CF_TUNNEL_CREDS" | base64 -d > /etc/cloudflared/creds.json
chmod 600 /etc/cloudflared/creds.json
# 从凭证文件动态提取 TunnelID，避免写死导致凭证更新后对不上
TUNNEL_ID=$(grep -o '"TunnelID"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/cloudflared/creds.json | cut -d'"' -f4)
if [ -z "$TUNNEL_ID" ]; then
  echo "[start] ERROR: 无法从凭证中提取 TunnelID"
  exit 1
fi
echo "[start] tunnel id: $TUNNEL_ID"

cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/creds.json
protocol: http2
# 新版面板 HTTP 与 gRPC 复用同一端口；gRPC 走面板的 HTTPS 端口（8443），
# 因为 cloudflared 的 http2Origin 要求源站为 https（不支持明文 h2c）
ingress:
  - hostname: grpc.coco.gv.uy
    service: https://localhost:$HTTPS_PORT
    originRequest:
      http2Origin: true
      noTLSVerify: true
      connectTimeout: 30s
  - service: http_status:404
EOF

echo "[start] launching cloudflared (gRPC -> grpc.coco.gv.uy via https origin, http2Origin on) ..."
cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run &
TUNNEL_PID=$!

# 给 tunnel 几秒建立连接
sleep 8
if ! kill -0 $TUNNEL_PID 2>/dev/null; then
  echo "[start] ERROR: cloudflared 启动失败，看上面日志"
  exit 1
fi
echo "[start] cloudflared running (pid $TUNNEL_PID)"

echo "[start] launching nezha dashboard (http:8008, https:$HTTPS_PORT) ..."
exec /dashboard/app
