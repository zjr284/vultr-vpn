#!/usr/bin/env python3
"""vultr-vpn 订阅分发服务

同时监听：
  - 80/tcp   明文 HTTP（ACME 续期时会临时停止本服务）
  - 8443/tcp HTTPS（存在证书时；需额外放行该端口，可选）

订阅内容放在 /var/www/dsh-sub/<token>.txt，由 vpn-sub-update 生成。
根路径 / 提供一个页面，直接把节点链接摆出来，方便复制或扫码。
"""
import base64
import functools
import html
import http.server
import os
import ssl
import threading

ROOT = "/var/www/dsh-sub"
CERT = "/etc/hysteria/cert.pem"
KEY = "/etc/hysteria/key.pem"

PAGE = """<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>vultr-vpn</title>
<style>
:root{color-scheme:light dark}
body{font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Noto Sans SC",sans-serif;
     max-width:820px;margin:40px auto;padding:0 20px}
h1{font-size:22px;margin-bottom:4px}
.sub{opacity:.6;font-size:13px;margin-bottom:24px}
.card{border:1px solid rgba(128,128,128,.35);border-radius:12px;padding:16px;margin:14px 0}
.card h2{font-size:15px;margin:0 0 10px}
code{display:block;word-break:break-all;background:rgba(128,128,128,.12);
     padding:10px;border-radius:8px;font-size:12.5px;margin:0}
button{margin-top:10px;padding:6px 14px;border-radius:8px;border:1px solid rgba(128,128,128,.5);
       background:transparent;font-size:13px;cursor:pointer}
a{color:#3b82f6}
</style>
<h1>vultr-vpn</h1>
<div class="sub">订阅地址见下方；客户端里添加「订阅」后即可自动更新节点。</div>
%s
<script>
document.querySelectorAll("button").forEach(b=>b.onclick=()=>{
  navigator.clipboard.writeText(b.previousElementSibling.textContent.trim());
  b.textContent="已复制";setTimeout(()=>b.textContent="复制",1200);});
</script>
"""

CARD = """<div class="card"><h2>%s</h2><code>%s</code><button>复制</button></div>"""


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def list_directory(self, path):
        self.send_error(404, "Not Found")
        return None

    def _index(self):
        cards = []
        try:
            names = sorted(n for n in os.listdir(ROOT) if n.endswith(".txt"))
        except OSError:
            names = []
        for n in names:
            try:
                raw = open(os.path.join(ROOT, n), "rb").read()
                text = base64.b64decode(raw).decode("utf-8", "replace").strip()
            except Exception:
                continue
            url = "http://%s/%s" % (self.headers.get("Host", ""), n)
            cards.append(CARD % ("订阅地址", html.escape(url)))
            for line in text.splitlines():
                line = line.strip()
                if not line:
                    continue
                tag = line.split("://", 1)[0].upper()
                cards.append(CARD % (tag + " 节点", html.escape(line)))
        body = PAGE % ("\n".join(cards) or "<p>还没有订阅内容。</p>")
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            return self._index()
        return super().do_GET()


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
