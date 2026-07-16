#!/usr/bin/env python3
"""
Manual LSP hover test for nimlangserver.

Starts the server on a socket port, performs a full LSP handshake,
waits for nimsuggest to initialize, then fires a hover request.

Usage:
    python3 test_hover.py
    python3 test_hover.py --port 19999 --line 5 --char 12

Notes:
- The server expects ALL messages (even notifications) to carry an id,
  matching the behavior of the internal Nim test client (LspSocketClient).
  Sending notifications without an id causes raiseIncompleteObject parse errors.
- Hover is only attempted after receiving the "Nimsuggest initialized for ..."
  window/showMessage notification so nimsuggest is actually ready.
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time

# --- defaults ---
DEFAULT_PORT = 19879
DEFAULT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ls.nim")
DEFAULT_LINE = 227  # ls.nim line 228 (0-indexed): initHashSet[string]()
DEFAULT_CHAR = 20   # start of 'initHashSet'
SERVER_BIN = os.path.join(os.path.dirname(__file__), "nimlangserver")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--file", default=DEFAULT_FILE)
    p.add_argument("--line", type=int, default=DEFAULT_LINE, help="0-indexed LSP line")
    p.add_argument("--char", type=int, default=DEFAULT_CHAR, help="0-indexed LSP character")
    p.add_argument("--no-server", action="store_true", help="Don't start server (assume already running)")
    p.add_argument("--timeout", type=int, default=60, help="Seconds to wait for nimsuggest")
    return p.parse_args()


def lsp_msg(obj):
    body = json.dumps(obj)
    return f"Content-Length: {len(body)}\r\n\r\n{body}".encode()


class LspClient:
    def __init__(self, host, port):
        self._messages = []
        self._lock = threading.Lock()
        self._done = threading.Event()
        self._req_id = 0
        self._sock = socket.create_connection((host, port), timeout=5)
        t = threading.Thread(target=self._recv_loop, daemon=True)
        t.start()

    def _recv_loop(self):
        buf = b""
        while not self._done.is_set():
            try:
                self._sock.settimeout(0.2)
                chunk = self._sock.recv(8192)
                if not chunk:
                    break
                buf += chunk
                while b"\r\n\r\n" in buf:
                    header, rest = buf.split(b"\r\n\r\n", 1)
                    try:
                        length = int(header.decode().split("Content-Length: ")[1].strip())
                    except (IndexError, ValueError):
                        buf = rest
                        continue
                    if len(rest) >= length:
                        msg = json.loads(rest[:length])
                        with self._lock:
                            self._messages.append(msg)
                        buf = rest[length:]
                    else:
                        break
            except socket.timeout:
                continue
            except Exception:
                break

    def _next_id(self):
        self._req_id += 1
        return self._req_id

    def send(self, method, params, with_id=True):
        obj = {"jsonrpc": "2.0", "method": method, "params": params}
        if with_id:
            obj["id"] = self._next_id()
        self._sock.sendall(lsp_msg(obj))
        return obj.get("id")

    def wait_response(self, req_id, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for i, m in enumerate(self._messages):
                    if m.get("id") == req_id:
                        return self._messages.pop(i)
            time.sleep(0.05)
        return None

    def wait_notification(self, method, text_contains=None, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for i, m in enumerate(self._messages):
                    if m.get("method") == method:
                        if text_contains is None or text_contains in str(m.get("params", {})):
                            return self._messages.pop(i)
            time.sleep(0.1)
        return None

    def close(self):
        self._done.set()
        self._sock.close()


def main():
    args = parse_args()
    file_uri = f"file://{args.file}"
    root_uri = "file://" + os.path.dirname(args.file)

    server_proc = None
    if not args.no_server:
        print(f"Starting nimlangserver on port {args.port}...")
        server_proc = subprocess.Popen(
            [SERVER_BIN, "--socket", f"--port={args.port}", "--lsp"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        time.sleep(1.0)

    try:
        client = LspClient("127.0.0.1", args.port)

        # 1. initialize
        rid = client.send("initialize", {
            "processId": None,
            "rootUri": root_uri,
            "capabilities": {
                "textDocument": {"hover": {"contentFormat": ["markdown", "plaintext"]}}
            },
            "initializationOptions": {}
        })
        r = client.wait_response(rid)
        caps = r["result"]["capabilities"]
        print(f"[initialize] ok — {len(caps)} capabilities: {list(caps)[:5]}...")

        # 2. initialized (sent with id — required by this server's parser)
        rid = client.send("initialized", {})
        client.wait_response(rid, timeout=3)  # response may not come; that's fine
        print("[initialized] sent")

        # 3. didOpen
        content = open(args.file).read()
        rid = client.send("textDocument/didOpen", {
            "textDocument": {
                "uri": file_uri,
                "languageId": "nim",
                "version": 1,
                "text": content
            }
        })
        client.wait_response(rid, timeout=3)
        print(f"[didOpen] sent — {args.file.split('/')[-1]}")

        # 4. Wait for nimsuggest
        print(f"[nimsuggest] waiting up to {args.timeout}s for initialization...")
        ns = client.wait_notification("window/showMessage", "Nimsuggest initialized", args.timeout)
        if ns:
            print(f"[nimsuggest] ready: {ns['params']['message']}")
        else:
            print("[nimsuggest] WARNING: ready notification not received — hover may return null")

        # 5. hover
        print(f"[hover] line={args.line} char={args.char} ...")
        rid = client.send("textDocument/hover", {
            "textDocument": {"uri": file_uri},
            "position": {"line": args.line, "character": args.char}
        })
        hover = client.wait_response(rid, timeout=30)

        print()
        if hover is None:
            print("RESULT: timeout — no hover response within 30s")
            sys.exit(1)
        elif "error" in hover:
            print(f"RESULT: error — {hover['error']}")
            sys.exit(1)
        elif hover.get("result") is None:
            print("RESULT: null (no hover info at this position)")
        else:
            r = hover["result"]
            print(f"RESULT: range={r.get('range')}")
            contents = r.get("contents", {})
            if isinstance(contents, dict):
                print(f"  kind:  {contents.get('kind')}")
                print(f"  value:\n{contents.get('value')}")
            else:
                print(f"  contents: {contents}")

        client.close()

    finally:
        if server_proc:
            server_proc.terminate()
            server_proc.wait()
            print("\n[server] stopped")


if __name__ == "__main__":
    main()
