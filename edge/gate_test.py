#!/usr/bin/env python3
# edge/gate_test.py
# Stage 3-5g gate: exercises the REAL trusted-edge service over HTTP.  Stdlib only.
# The ingest key is read from stdin (never argv, never printed).  Every line printed is an
# observed HTTP result; nothing is assumed.  Exit 0 only if every check passed.
#
# usage: printf '%s' "$KEY" | gate_test.py <host> <port>

import http.client
import struct
import sys
import time

host, port = sys.argv[1], int(sys.argv[2])
key = sys.stdin.read().strip()
fails = 0


def req(method, path, headers=None, body=None):
    c = http.client.HTTPConnection(host, port, timeout=15)
    try:
        c.request(method, path, body=body, headers=headers or {})
        r = c.getresponse()
        return r.status, dict(r.getheaders()), r.read()
    finally:
        c.close()


def check(name, ok, detail=""):
    global fails
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{(' — ' + detail) if detail else ''}")
    if not ok:
        fails += 1


def jpeg_dims(b):
    i = 2
    while i + 9 < len(b):
        if b[i] != 0xFF:
            i += 1
            continue
        m = b[i + 1]
        if m in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", b[i + 5:i + 9])
            return w, h
        i += 2 + struct.unpack(">H", b[i + 2:i + 4])[0]
    return None


K = {"X-Edge-Key": key}

# 1. fresh JPEG from the real camera
s, h, b = req("GET", "/frame.jpg", K)
check("GET /frame.jpg with key -> 200", s == 200, f"status {s}")
if s == 200:
    d = jpeg_dims(b)
    age = int(h.get("X-Frame-Age-Ms", "-1"))
    check("body is a JPEG", b[:2] == b"\xff\xd8" and b[-2:] == b"\xff\xd9", f"{len(b)} bytes, {d[0]}x{d[1]}" if d else f"{len(b)} bytes")
    check("frame is fresh (< 5000 ms old)", 0 <= age < 5000, f"age {age} ms")
    check("width <= 1280", d is not None and d[0] <= 1280)

# 2. auth
s, _, _ = req("GET", "/frame.jpg")
check("GET /frame.jpg without key -> 401", s == 401, f"status {s}")
s, _, _ = req("GET", "/frame.jpg", {"X-Edge-Key": "wrong"})
check("GET /frame.jpg wrong key -> 401", s == 401, f"status {s}")
s, _, _ = req("POST", "/events", {"Content-Type": "application/json"}, b"{}")
check("POST /events without key -> 401", s == 401, f"status {s}")
s, _, _ = req("POST", "/snapshot", {"Content-Type": "application/json"}, b"{}")
check("POST /snapshot without key -> 401", s == 401, f"status {s}")

# 3. routes
for m, p in (("GET", "/"), ("GET", "/healthz"), ("GET", "/events"), ("POST", "/frame.jpg"), ("DELETE", "/events"), ("PUT", "/x")):
    s, _, _ = req(m, p, K, b"" if m in ("POST", "PUT") else None)
    check(f"{m} {p} with key -> 404", s == 404, f"status {s}")

# 4. body cap
s, _, _ = req("POST", "/events", {**K, "Content-Type": "application/json"}, b"x" * 20000)
check("POST /events 20000-byte body -> 413", s == 413, f"status {s}")

# 5. validation + the real insert
bad = b'{"event_type":"nope","state":"detected","raw_payload":"x"}'
s, _, _ = req("POST", "/events", {**K, "Content-Type": "application/json"}, bad)
check("POST /events event_type not in allow-list -> 422", s == 422, f"status {s}")
good = b'{"event_type":"person","state":"detected","raw_payload":"stage 3-5g gate check (test row)","duration_s":null,"warned":false}'
s, _, b = req("POST", "/events", {**K, "Content-Type": "application/json"}, good)
check("POST /events valid -> 201 with row id", s == 201 and b'"id"' in b, f"status {s}, body {b.decode(errors='replace')[:60]}")
if s == 201:
    print("  ROW_ID=" + b.decode().split(":")[1].strip(" }"))

# 6. flood -> 429 (frame bucket: burst 20, 5/s)
codes = [req("GET", "/frame.jpg", K)[0] for _ in range(60)]
check("flood GET /frame.jpg x60 with key -> some 429", 429 in codes, f"200:{codes.count(200)} 429:{codes.count(429)} other:{len(codes) - codes.count(200) - codes.count(429)}")
codes = [req("GET", "/frame.jpg", {"X-Edge-Key": "bad%d" % i})[0] for i in range(30)]
check("flood bad keys x30 -> 401 then 429", 401 in codes and 429 in codes, f"401:{codes.count(401)} 429:{codes.count(429)}")

codes = [req("POST", "/events", {**K, "Content-Type": "application/json"}, bad)[0] for _ in range(40)]
check("flood POST /events x40 (invalid body, no rows) -> 422 then 429", 422 in codes and 429 in codes, f"422:{codes.count(422)} 429:{codes.count(429)}")

# 6b. POST /snapshot happy path and rate-limit
s, _, b = req("POST", "/snapshot", {**K, "Content-Type": "application/json"}, b"{}")
check("POST /snapshot with key -> 200 triggered:true", s == 200 and b'"triggered": true' in b or b'"triggered":true' in b, f"status {s}, body {b.decode(errors='replace')[:60]}")
codes = [req("POST", "/snapshot", {**K, "Content-Type": "application/json"}, b"{}")[0] for _ in range(10)]
check("flood POST /snapshot x10 -> some 429", 429 in codes, f"codes: {set(codes)}")

# 7. after the bucket refills the key works again
time.sleep(8)
s, _, _ = req("GET", "/frame.jpg", K)
check("legit request works again after 8 s", s == 200, f"status {s}")

print(f"GATE_TEST {'PASS' if fails == 0 else 'FAIL'} ({fails} failed)")
sys.exit(1 if fails else 0)
