#!/usr/bin/env python3
"""Otwiera N równoległych połączeń TCP (timeout 1 s) i mówi, ile się udało.
Udane connect() = kernel zakończył handshake i wstawił połączenie do kolejki
accept — nawet jeśli aplikacja jeszcze go nie odebrała."""
import socket
import sys

host, port, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ok, socks = 0, []
for _ in range(n):
    s = socket.socket()
    s.settimeout(1)
    try:
        s.connect((host, port))
        ok += 1
        socks.append(s)
    except OSError:
        s.close()
print(f"{ok}/{n} połączeń nawiązanych")
sys.exit(0 if ok == n else 1)
