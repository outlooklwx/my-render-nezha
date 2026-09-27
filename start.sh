#!/bin/sh
# Render 启动脚本：同时拉起 cloudflared tunnel（gRPC 穿透）和哪吒面板
# 需要 Render 环境变量：CF_TUNNEL_CREDS（credentials.json 的 base64，见 tunnel-creds.b64.txt）
# 原理：dashboard 建的 tunnel 用 --token 跑会忽略本地 ingress；
# 改用 credentials-file + 本地 config.yml，http2Origin 就能生效。

set -e

# 官方镜像原 entrypoint 的行为
printf "nameserver 127.0.0.11\nnameserver 8.8.4.4\nnameserver 223.5.5.5\n" > /etc/resolv.conf

if [ -z "$CF_TUNNEL_CREDS" ]; then
  echo "[start] ERROR: CF_TUNNEL_CREDS 未设置，去 Render Dashboard -> Environment 加上"
  exit 1
fi

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
# 新版面板 HTTP 与 gRPC 复用同一端口（8008，h2c），没有独立的 5555
ingress:
  - hostname: grpc.coco.gv.uy
    service: http://localhost:8008
    originRequest:
      http2Origin: true
      connectTimeout: 30s
  - service: http_status:404
EOF

echo "[start] launching cloudflared (gRPC -> grpc.coco.gv.uy, http2Origin on) ..."
cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run &
TUNNEL_PID=$!

# 给 tunnel 几秒建立连接
sleep 8
if ! kill -0 $TUNNEL_PID 2>/dev/null; then
  echo "[start] ERROR: cloudflared 启动失败，看上面日志"
  exit 1
fi
echo "[start] cloudflared running (pid $TUNNEL_PID)"

echo "[start] launching nezha dashboard ..."
exec /dashboard/app
