FROM ghcr.io/nezhahq/nezha:latest

# 用 builder 自带的远程下载（不依赖镜像内的 wget）
ADD https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 /usr/local/bin/cloudflared
RUN chmod +x /usr/local/bin/cloudflared && cloudflared --version

COPY start.sh /start.sh
RUN chmod +x /start.sh

# 自签名证书（仅用于 cloudflared -> 面板 的内部 HTTPS，不对外暴露）
COPY tls/cert.pem /etc/nezha-tls/cert.pem
COPY tls/key.pem /etc/nezha-tls/key.pem
RUN chmod 600 /etc/nezha-tls/key.pem

ENTRYPOINT ["/start.sh"]
