#!/bin/sh
# Render 启动脚本：cloudflared tunnel（gRPC 穿透）+ Caddy（TLS终止/h2c）+ 哪吒面板
# 需要 Render 环境变量：CF_TUNNEL_CREDS（credentials.json 的 base64）
#
# 链路：
#   Agent --(gRPC/HTTPS)--> CF Edge --(HTTP2)--> cloudflared
#         --(HTTPS/HTTP2, http2Origin)--> Caddy:8444
#         --(h2c, HTTP2明文)--> 面板:8008
#
# 为什么需要 Caddy：
# 1. 面板的 HTTP+gRPC mux 要求 r.ProtoMajor == 2（必须是 HTTP/2）
# 2. cloudflared 的 http2Origin 要求源站为 https（不支持明文 h2c 直连）
# 3. 面板自带的 HTTPS server 用 tls.Listener 实现，不会自动启用 HTTP/2
# 4. 面板的 HTTP server（8008）原生支持 h2c（SetUnencryptedHTTP2）
# 所以：Caddy 终止 TLS（自签名，tls internal 自动生成），再以 h2c 反代到 8008

set -e

# 官方镜像原 entrypoint 的行为
printf "nameserver 127.0.0.11\nnameserver 8.8.4.4\nnameserver 223.5.5.5\n" > /etc/resolv.conf

if [ -z "$CF_TUNNEL_CREDS" ]; then
  echo "[start] ERROR: CF_TUNNEL_CREDS 未设置，去 Render Dashboard -> Environment 加上"
  exit 1
fi

# --- Caddy：TLS 终止 + h2c 反代 ---
CADDY_PORT="8444"
PANEL_PORT="8008"

mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
{
    # 关掉自动 HTTPS（避免监听 :80 干扰 Render 端口检测）
    auto_https off
    admin off
}
# 写明确主机名 localhost，tls internal 才能签出带正确 SAN 的证书
# （之前只写 :8444，Caddy 不知道给哪个域名签，导致 TLS 握手 internal error）
localhost:$CADDY_PORT {
    tls internal
    # 访问日志：看 cloudflared 过来的是 HTTP/1.1 还是 HTTP/2
    log {
        output stdout
        format console
    }
    # h2c:// + transport versions h2c：强制以后端 HTTP/2 明文方式连接面板 8008
    # （面板 8008 原生支持 h2c；mux 要求 r.ProtoMajor == 2）
    # 参考：https://github.com/gmountie/gmountie/blob/HEAD/docs/recipes/caddy-reverse-proxy.md
    reverse_proxy h2c://localhost:$PANEL_PORT {
        transport http {
            versions h2c
        }
    }
}
EOF

echo "[start] launching caddy (TLS termination on :$CADDY_PORT, h2c -> localhost:$PANEL_PORT) ..."
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!
sleep 4
if ! kill -0 $CADDY_PID 2>/dev/null; then
  echo "[start] ERROR: caddy 启动失败，看上面日志"
  exit 1
fi
echo "[start] caddy running (pid $CADDY_PID)"

# --- cloudflared ---
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
ingress:
  - hostname: grpc.coco.gv.uy
    service: https://localhost:$CADDY_PORT
    originRequest:
      http2Origin: true
      noTLSVerify: true
      connectTimeout: 30s
  - service: http_status:404
EOF

echo "[start] launching cloudflared (gRPC -> grpc.coco.gv.uy via Caddy https, http2Origin on) ..."
cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run &
TUNNEL_PID=$!

# 给 tunnel 几秒建立连接
sleep 8
if ! kill -0 $TUNNEL_PID 2>/dev/null; then
  echo "[start] ERROR: cloudflared 启动失败，看上面日志"
  exit 1
fi
echo "[start] cloudflared running (pid $TUNNEL_PID)"

echo "[start] launching nezha dashboard (http:$PANEL_PORT with h2c) ..."
exec /dashboard/app
