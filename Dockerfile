FROM ghcr.io/nezhahq/nezha:latest

# cloudflared（gRPC 穿透）
ADD https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 /usr/local/bin/cloudflared
RUN chmod +x /usr/local/bin/cloudflared && cloudflared --version

# Caddy（TLS 终止 + h2c 反代，解决面板内置 HTTPS 不支持 HTTP/2 的问题）
# 面板的 mux 要求 r.ProtoMajor == 2，cloudflared 的 http2Origin 要求源站为 https；
# 面板自带 HTTPS server 不支持 HTTP/2，所以用 Caddy 在中间做转换：
#   cloudflared --(HTTPS/HTTP2)--> Caddy:8444 --(h2c)--> 面板:8008
ADD https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_amd64.tar.gz /tmp/caddy.tar.gz
RUN tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy && \
    chmod +x /usr/local/bin/caddy && \
    rm /tmp/caddy.tar.gz && \
    caddy version

COPY start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]
