# 阶段1: 编译 h2c-bridge (Go)
FROM golang:1.24-alpine AS bridge-builder
WORKDIR /src
COPY h2c-bridge.go .
# 锁定 x/net 版本，避免 latest 要求更新的 Go
RUN go mod init bridge 2>/dev/null; \
    go get golang.org/x/net@v0.38.0 && \
    go mod tidy && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o h2c-bridge h2c-bridge.go

# 阶段2: 运行镜像
FROM ghcr.io/nezhahq/nezha:latest

# rclone（R2 备份/恢复 SQLite 数据）
ADD https://downloads.rclone.org/rclone-current-linux-amd64.zip /tmp/rclone.zip
RUN (apk add --no-cache unzip 2>/dev/null || (apt-get update -qq && apt-get install -y -qq unzip 2>/dev/null)) ; \
    cd /tmp && unzip -q -o rclone.zip && cp rclone-*-linux-amd64/rclone /usr/local/bin/ && \
    chmod +x /usr/local/bin/rclone && rm -rf /tmp/rclone.zip rclone-*-linux-amd64 && \
    rclone version

# cloudflared（gRPC 穿透）
ADD https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 /usr/local/bin/cloudflared
RUN chmod +x /usr/local/bin/cloudflared && cloudflared --version

# h2c-bridge（TLS 终止 + h2c 反代，替代 Caddy）
# 背景: 面板的 mux 要求 r.ProtoMajor == 2；cloudflared 的 http2Origin 要求源站为 https；
# 面板自带 HTTPS server 不支持 HTTP/2；Caddy 的 reverse_proxy h2c 在此场景实际走了 HTTP/1.1。
# h2c-bridge 用 Go 的 http2.Transport(AllowHTTP=true) 强制 h2c 到面板 8008:
#   cloudflared --(HTTPS/HTTP2)--> h2c-bridge:8444 --(h2c)--> 面板:8008
COPY --from=bridge-builder /src/h2c-bridge /usr/local/bin/h2c-bridge
RUN chmod +x /usr/local/bin/h2c-bridge

COPY start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]
