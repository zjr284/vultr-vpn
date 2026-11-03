#!/usr/bin/env python3
"""vultr-vpn 订阅分发服务

同时监听：
  - 80/tcp   明文 HTTP（ACME 续期时会临时停止本服务）
  - 8443/tcp HTTPS（存在证书时；需额外放行该端口，可选）

订阅内容放在 /var/www/dsh-sub/<token>.txt，由 vpn-sub-update 生成。
"""
import functools
import http.server
import os
import ssl
import threading

ROOT = "/var/www/dsh-sub"
CERT = "/etc/hysteria/cert.pem"
KEY = "/etc/hysteria/key.pem"


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def list_directory(self, path):
        self.send_error(404, "Not Found")
        return None


def serve(port, use_tls):
    handler = functools.partial(Handler, directory=ROOT)
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)
    if use_tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT, KEY)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()


if __name__ == "__main__":
    if os.path.exists(CERT) and os.path.exists(KEY):
        threading.Thread(target=serve, args=(8443, True), daemon=True).start()
    serve(80, False)
