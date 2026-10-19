"""센서 녹화 업로드 수신: POST /api/log → /data/YYYYmmdd-HHMMSS-<n>.json"""
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = os.environ.get("DATA_DIR", "/data")
MAX = 60 * 1024 * 1024


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        if self.path.rstrip("/") != "/api/log":
            return self._send(404, {"error": "not found"})
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX:
            return self._send(413, {"error": "size"})
        body = self.rfile.read(n)
        try:
            d = json.loads(body)
            rows = len(d.get("rows", []))
        except Exception:
            return self._send(400, {"error": "json"})
        name = time.strftime("%Y%m%d-%H%M%S", time.localtime()) + f"-{rows}.json"
        with open(os.path.join(DATA, name), "wb") as f:
            f.write(body)
        return self._send(200, {"name": name, "rows": rows})

    def do_GET(self):
        if self.path.rstrip("/") == "/api/health":
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "not found"})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    os.makedirs(DATA, exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
