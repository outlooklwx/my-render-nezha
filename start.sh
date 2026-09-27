#!/bin/sh
# Render 启动脚本：h2c-bridge（TLS终止/h2c）+ cloudflared tunnel（gRPC 穿透）+ 哪吒面板
# 需要 Render 环境变量：CF_TUNNEL_CREDS（credentials.json 的 base64）
#
# 链路：
#   Agent --(gRPC/HTTPS)--> CF Edge --(HTTP2)--> cloudflared
#         --(HTTPS/HTTP2, http2Origin)--> h2c-bridge:8444
#         --(h2c, HTTP2明文)--> 面板:8008
#
# 为什么需要 h2c-bridge：
# 1. 面板的 HTTP+gRPC mux 要求 r.ProtoMajor == 2（必须是 HTTP/2）
# 2. cloudflared 的 http2Origin 要求源站为 https（不支持明文 h2c 直连）
# 3. 面板自带的 HTTPS server 用 tls.Listener 实现，不会自动启用 HTTP/2
# 4. 面板的 HTTP server（8008）原生支持 h2c（SetUnencryptedHTTP2）
# 5. Caddy 的 reverse_proxy h2c 在此场景实际走了 HTTP/1.1，一直 404，
#    故改用自研 Go 程序 h2c-bridge，显式使用 http2.Transport(AllowHTTP=true) 强制 h2c

set -e

# 官方镜像原 entrypoint 的行为
printf "nameserver 127.0.0.11\nnameserver 8.8.4.4\nnameserver 223.5.5.5\n" > /etc/resolv.conf

if [ -z "$CF_TUNNEL_CREDS" ]; then
  echo "[start] ERROR: CF_TUNNEL_CREDS 未设置，去 Render Dashboard -> Environment 加上"
  exit 1
fi

# --- h2c-bridge：TLS 终止 + h2c 反代 ---
BRIDGE_PORT="8444"
PANEL_PORT="8008"

echo "[start] launching h2c-bridge (TLS termination on :$BRIDGE_PORT, h2c -> localhost:$PANEL_PORT) ..."
BRIDGE_LISTEN=":$BRIDGE_PORT" BRIDGE_BACKEND="localhost:$PANEL_PORT" \
  /usr/local/bin/h2c-bridge > /tmp/h2c-bridge.log 2>&1 &
BRIDGE_PID=$!
sleep 3
if ! kill -0 $BRIDGE_PID 2>/dev/null; then
  echo "[start] ERROR: h2c-bridge 启动失败，日志："
  cat /tmp/h2c-bridge.log || true
  exit 1
fi
echo "[start] h2c-bridge running (pid $BRIDGE_PID)"
# 后台 tail bridge 日志，方便 Render 日志里看到每条代理请求的协议
tail -F /tmp/h2c-bridge.log &
TAIL_PID=$!

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
    service: https://localhost:$BRIDGE_PORT
    originRequest:
      http2Origin: true
      noTLSVerify: true
      connectTimeout: 30s
  - service: http_status:404
EOF

echo "[start] launching cloudflared (gRPC -> grpc.coco.gv.uy via h2c-bridge https, http2Origin on) ..."
cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run &
TUNNEL_PID=$!

# 给 tunnel 几秒建立连接
sleep 8
if ! kill -0 $TUNNEL_PID 2>/dev/null; then
  echo "[start] ERROR: cloudflared 启动失败，看上面日志"
  exit 1
fi
echo "[start] cloudflared running (pid $TUNNEL_PID)"

# --- R2 备份/恢复（SQLite 持久化）---
# 需要 Render 环境变量：R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME
# 面板数据目录：/dashboard/data（SQLite + config.yaml）
DATA_DIR="/dashboard/data"
BACKUP_FILE="nezha-backup.tar.gz"

if [ -n "$R2_ACCOUNT_ID" ] && [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_BUCKET_NAME" ]; then
  export RCLONE_CONFIG_R2_TYPE="s3"
  export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  export RCLONE_CONFIG_R2_ACL="private"

  echo "[r2] 尝试从 R2 恢复备份..."
  # 只恢复 data 目录，不恢复 config.yaml（避免损坏的配置导致面板无法启动）
  # config.yaml 中的密钥通过环境变量 NZ_JWTSECRETKEY 固定
  if rclone copyto "r2:${R2_BUCKET_NAME}/${BACKUP_FILE}" "/tmp/${BACKUP_FILE}" 2>/tmp/r2-restore.log; then
    echo "[r2] 找到备份，正在恢复 data 目录..."
    mkdir -p "$DATA_DIR"
    # 先解压到临时目录，验证成功后再移动，避免损坏文件覆盖
    rm -rf /tmp/r2-restore && mkdir -p /tmp/r2-restore
    if tar -xzf "/tmp/${BACKUP_FILE}" -C /tmp/r2-restore 2>/dev/null && [ -d "/tmp/r2-restore/data" ]; then
      cp -a /tmp/r2-restore/data/. "$DATA_DIR"/
      echo "[r2] 恢复完成"
    else
      echo "[r2] 备份文件损坏或格式不对，跳过恢复，用空数据启动"
    fi
    rm -rf /tmp/r2-restore "/tmp/${BACKUP_FILE}"
  else
    echo "[r2] 没有找到备份（首次部署或备份未上传），用空数据启动"
  fi

  # 后台定时备份：每 10 分钟打包上传（只备份 data 目录）
  (
    while true; do
      sleep 600
      echo "[r2] 开始定时备份检查..."
      # 自动查找 SQLite 文件位置
      DB_FILE=$(find /dashboard -name "*.db" -o -name "sqlite*" 2>/dev/null | head -1)
      echo "[r2] 找到数据库文件: ${DB_FILE:-没找到}"
      echo "[r2] /dashboard/data 存在: $([ -d "$DATA_DIR" ] && echo yes || echo no)"
      ls -la /dashboard/ 2>/dev/null | head -20
      if [ -d "$DATA_DIR" ]; then
        tar -czf "/tmp/${BACKUP_FILE}" -C /dashboard data 2>/tmp/r2-backup-tar.log
        if rclone copyto "/tmp/${BACKUP_FILE}" "r2:${R2_BUCKET_NAME}/${BACKUP_FILE}" 2>/tmp/r2-backup.log; then
          echo "[r2] 定时备份成功 $(date -u +%FT%TZ)"
        else
          echo "[r2] 定时备份失败 $(date -u +%FT%TZ)，错误："
          cat /tmp/r2-backup.log 2>/dev/null | head -10
        fi
        rm -f "/tmp/${BACKUP_FILE}"
      else
        echo "[r2] 数据目录不存在，跳过备份"
      fi
    done
  ) &
  echo "[r2] 定时备份已启动（每 10 分钟）"
else
  echo "[r2] 未配置 R2 环境变量，跳过备份/恢复（重启会丢数据）"
fi

echo "[start] launching nezha dashboard (http:$PANEL_PORT with h2c) ..."
exec /dashboard/app
