"""Loopback-only, bounded traffic fixture; no external requests."""
import socketserver
import time

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            self.request.recv(4096)
            self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2097152\r\nConnection: close\r\n\r\n")
            for _ in range(256):
                self.request.sendall(b"x" * 8192)
                time.sleep(0.05)
        except (OSError, TimeoutError):
            pass

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

with Server(("127.0.0.1", 27181), Handler) as server:
    print("ready", flush=True)
    server.serve_forever()
