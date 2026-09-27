FROM ghcr.io/nezhahq/nezha:latest

# busybox 底座没有 apt，直接下载 cloudflared 静态二进制
RUN wget -q -O /usr/local/bin/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    && chmod +x /usr/local/bin/cloudflared \
    && cloudflared --version

COPY start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]
