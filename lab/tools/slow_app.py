#!/usr/bin/env python3
"""Celowo wolna aplikacja TCP: przyjmuje (accept) jedno połączenie co 2 s.
listen() prosi o backlog 128, ale kernel przytnie go do net.core.somaxconn."""
import socket
import sys
import time

host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((host, port))
s.listen(128)
while True:
    c, _ = s.accept()
    c.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nok\n")
    c.close()
    time.sleep(2)
