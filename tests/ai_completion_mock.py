"""Local-only completion fixture: Python standard library, no API traffic.

The Lua integration test owns this process and writes control.json atomically.
Only synthetic test buffers and fake credentials are recorded in its cache.
"""
import argparse
import json
import select
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True)
args = parser.parse_args()
root = Path(args.root)
root.mkdir(parents=True, exist_ok=True)
lock = threading.Lock()
sequence = 0


def event(value):
    with lock:
        with (root / "events.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(value, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        global sequence
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            config = json.loads((root / "control.json").read_text(encoding="utf-8"))
        except Exception:
            self.send_error(400)
            return
        with lock:
            sequence += 1
            request_id = sequence
        event({"event": "request", "id": request_id, "time": time.time(),
               "path": self.path, "body": body, "authorization": self.headers.get("Authorization")})
        deadline = time.monotonic() + float(config.get("delay", 0))
        while time.monotonic() < deadline:
            readable, _, _ = select.select([self.connection], [], [], min(0.03, max(0, deadline - time.monotonic())))
            if readable:
                try:
                    if self.connection.recv(1, socket.MSG_PEEK) == b"":
                        event({"event": "disconnect", "id": request_id, "time": time.time()})
                        return
                except (ConnectionResetError, OSError):
                    event({"event": "disconnect", "id": request_id, "time": time.time()})
                    return
        mode = config.get("mode", "success")
        text = config.get("completion", "AI_FIXTURE_RESULT")
        code = int(mode) if mode in {"401", "429", "500"} else 200
        if mode == "invalid":
            payload = b"INVALID_RESPONSE_BODY_SHOULD_NOT_LEAK"
        elif code != 200:
            payload = json.dumps({"error": {"message": "PRIVATE_RESPONSE_SHOULD_NOT_LEAK"}}).encode()
        else:
            payload = json.dumps({"id": "local-fixture", "object": "text_completion", "model": body.get("model"),
                                  "choices": [{"index": 0, "text": text,
                                               "message": {"role": "assistant", "content": text},
                                               "finish_reason": "stop"}]}).encode()
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            event({"event": "response", "id": request_id, "time": time.time(), "status": code})
        except (BrokenPipeError, ConnectionResetError, OSError):
            event({"event": "disconnect", "id": request_id, "time": time.time()})
        self.close_connection = True


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
(root / "ready.json").write_text(json.dumps({"port": server.server_port}), encoding="utf-8")
server.serve_forever(poll_interval=0.05)
