#!/usr/bin/env python3
import base64
import hashlib
import json
import socketserver
import sys
import threading
import time


state = {"claims": 0, "websockets": 0}
lock = threading.Lock()


def ws_frame(text):
    payload = text.encode("utf-8")
    if len(payload) < 126:
        header = bytes([0x81, len(payload)])
    else:
        header = bytes([0x81, 126, (len(payload) >> 8) & 0xFF, len(payload) & 0xFF])
    return header + payload


def send_http(sock, status, body=b"", content_type="text/plain"):
    headers = (
        f"HTTP/1.1 {status}\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("utf-8")
    sock.sendall(headers + body)


def send_json(sock, obj):
    body = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    send_http(sock, "200 OK", body, "application/json")


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.request.recv(8192)
            if not chunk:
                return
            data += chunk

        request = data.decode("utf-8", errors="replace")
        first_line = request.split("\r\n", 1)[0]

        if "upgrade: websocket" in request.lower():
            self.accept_websocket(request)
            return

        if first_line.startswith("GET /api/auth/get-session"):
            send_json(
                self.request,
                {
                    "session": {"expiresAt": "2099-01-01T00:00:00.000Z"},
                    "user": {
                        "id": "ui-test-user",
                        "email": "ui-test@recappi.local",
                        "name": "UI Test",
                        "image": None,
                    },
                },
            )
            return

        if first_line.startswith("POST /api/openai/realtime/sessions"):
            with lock:
                state["claims"] += 1
                claim = state["claims"]

            port = self.server.server_address[1]
            print(f"claim={claim}", file=sys.stderr, flush=True)
            send_json(
                self.request,
                {
                    "sessionId": f"fake-session-{claim}",
                    "mode": "transcription",
                    "websocketUrl": f"ws://127.0.0.1:{port}/realtime/{claim}",
                    "token": "fake-ws-token",
                    "tokenType": "Bearer",
                    "expiresAt": 4102444800,
                    "quota": {
                        "tier": "test",
                        "periodStart": 0,
                        "periodEnd": 4102444800,
                        "mintsUsed": claim,
                        "mintsCap": 100,
                        "claimsPerMinute": 60,
                    },
                },
            )
            return

        send_http(self.request, "404 Not Found")

    def accept_websocket(self, request):
        key = None
        for line in request.split("\r\n"):
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
                break
        if not key:
            return

        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("utf-8")).digest()
        ).decode("ascii")
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        ).encode("utf-8")
        self.request.sendall(response)

        with lock:
            state["websockets"] += 1
            ws_index = state["websockets"]

        print(f"websocket={ws_index}", file=sys.stderr, flush=True)
        if ws_index == 1:
            self.request.sendall(
                ws_frame(
                    '{"type":"conversation.item.input_audio_transcription.delta",'
                    '"item_id":"item-before-disconnect","content_index":0,'
                    '"delta":"Caption before websocket disconnect."}'
                )
            )
            time.sleep(0.1)
            self.request.close()
        else:
            self.request.sendall(
                ws_frame(
                    '{"type":"conversation.item.input_audio_transcription.delta",'
                    '"item_id":"item-after-reconnect","content_index":0,'
                    '"delta":"Caption after websocket reconnect."}'
                )
            )
            time.sleep(30)


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


server = ThreadingTCPServer(("127.0.0.1", 0), Handler)
print(f"PORT={server.server_address[1]}", flush=True)
server.serve_forever()
