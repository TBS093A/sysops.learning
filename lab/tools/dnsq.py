#!/usr/bin/env python3
"""Minimalny odpowiednik `dig +short NAZWA A @SERWER` — pyta serwer DNS
bezpośrednio przez UDP (omija /etc/hosts i nsswitch)."""
import random
import socket
import struct
import sys

name = sys.argv[1]
server = sys.argv[2] if len(sys.argv) > 2 else "10.0.1.1"
qid = random.randint(0, 65535)
q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)          # nagłówek: RD=1, 1 pytanie
q += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"
q += struct.pack(">HH", 1, 1)                                # typ A, klasa IN
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
s.sendto(q, (server, 53))
data, _ = s.recvfrom(512)
rcode = data[3] & 0x0F
ancount = struct.unpack(">H", data[6:8])[0]
print(f";; serwer {server}  rcode={rcode} ({'NOERROR' if rcode == 0 else 'NXDOMAIN' if rcode == 3 else 'błąd'})  odpowiedzi={ancount}")
off = len(q)
for _ in range(ancount):
    off += 2 if data[off] & 0xC0 == 0xC0 else data[off:].index(b"\0") + 1
    typ, _cls, ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
    off += 10
    if typ == 1:
        print(f"{name}\t{ttl}\tIN\tA\t{socket.inet_ntoa(data[off:off + rdlen])}")
    off += rdlen
