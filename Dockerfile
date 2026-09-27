FROM ghcr.io/nezhahq/nezha:latest

# 用 builder 自带的远程下载（不依赖镜像内的 wget）
ADD https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 /usr/local/bin/cloudflared
RUN chmod +x /usr/local/bin/cloudflared && cloudflared --version

COPY start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]
