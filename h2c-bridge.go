// h2c-bridge: TLS 终止 + h2c 反代，专为哪吒面板 gRPC 设计
// 链路: cloudflared --(HTTPS/HTTP2)--> :8444 --(h2c)--> localhost:8008
//
// 为什么不用 Caddy: Caddy 的 reverse_proxy h2c 在此场景下实际走了 HTTP/1.1,
// 导致哪吒 mux (要求 r.ProtoMajor == 2) 一直 404。此程序显式使用 h2c transport,
// 每条请求打日志，可精确定位协议问题。
package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"time"

	"golang.org/x/net/http2"
)

func main() {
	listenAddr := envOr("BRIDGE_LISTEN", ":8444")
	backendAddr := envOr("BRIDGE_BACKEND", "localhost:8008")

	backendURL, err := url.Parse("http://" + backendAddr)
	if err != nil {
		log.Fatalf("backend URL 解析失败: %v", err)
	}

	// h2c transport: 对后端强制使用 HTTP/2 明文 (prior knowledge 模式)
	h2cTransport := &http2.Transport{
		// AllowHTTP: true 表示使用 h2c (HTTP/2 明文)，而非 HTTPS
		AllowHTTP: true,
		// DialTLS 被 h2c 模式忽略；用 Dial 拨明文 TCP
		DialTLS: func(network, addr string, cfg *tls.Config) (net.Conn, error) {
			return net.Dial(network, addr)
		},
	}

	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(backendURL)
			// 保留原始 Host，供后端日志/路由使用
			r.Out.Host = r.In.Host
			log.Printf("[proxy] %s %s -> h2c %s (in proto=%s)",
				r.In.Method, r.In.URL.Path, backendAddr, r.In.Proto)
		},
		Transport: h2cTransport,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("[proxy ERROR] %s %s: %v", r.Method, r.URL.Path, err)
			http.Error(w, "bridge upstream error", http.StatusBadGateway)
		},
	}

	// 生成自签名证书 (仅本容器内部使用，cloudflared 侧 noTLSVerify 跳过校验)
	cert, err := generateSelfSigned()
	if err != nil {
		log.Fatalf("生成自签名证书失败: %v", err)
	}

	server := &http.Server{
		Addr:    listenAddr,
		Handler: proxy,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{cert},
			// 明确声明支持 h2，供 ALPN 协商
			NextProtos: []string{"h2", "http/1.1"},
		},
	}
	// 对 TLS 启用 HTTP/2 (Go 默认对 TLS server 自动启用 h2，此处显式配置以防万一)
	if err := http2.ConfigureServer(server, &http2.Server{}); err != nil {
		log.Fatalf("配置 HTTP/2 失败: %v", err)
	}

	log.Printf("[bridge] listening on %s (TLS+h2) -> h2c %s", listenAddr, backendAddr)
	log.Fatal(server.ListenAndServeTLS("", ""))
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func generateSelfSigned() (tls.Certificate, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "localhost"},
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(10 * 365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{
		Certificate: [][]byte{der},
		PrivateKey:  key,
	}, nil
}
