#!/usr/bin/env python3
"""
dns2socks5.py — Local UDP DNS → remote TCP DNS via SOCKS5 proxy.

Usage:
  python3 dns2socks5.py [--port PORT] [--upstream DNS_IP] [--socks-proxy HOST:PORT]

Default: listen on UDP :5353, forward to 1.1.1.1:53 via SOCKS5 127.0.0.1:10808.
"""

import argparse
import socket
import struct
import threading
import socks
import sys

BUFSIZE = 4096
TIMEOUT = 5


def resolve_via_socks5(query_data: bytes, upstream: str, proxy_host: str, proxy_port: int) -> bytes:
    """
    Connect to the upstream DNS server via the SOCKS5 proxy (TCP),
    send the query (RFC 1035 TCP framing), and return the response.
    """
    s = socks.socksocket(socket.AF_INET, socket.SOCK_STREAM)
    s.set_proxy(socks.SOCKS5, proxy_host, proxy_port)
    s.settimeout(TIMEOUT)
    try:
        s.connect((upstream, 53))
        # TCP DNS framing: 2-byte length prefix (big-endian) + raw DNS message
        length_prefix = struct.pack('!H', len(query_data))
        s.sendall(length_prefix + query_data)
        # Read response length
        raw_len = s.recv(2)
        if len(raw_len) < 2:
            raise ConnectionError("short DNS response length header")
        resp_len = struct.unpack('!H', raw_len)[0]
        # Read the full response
        response = b''
        while len(response) < resp_len:
            chunk = s.recv(min(resp_len - len(response), BUFSIZE))
            if not chunk:
                raise ConnectionError("short DNS response body")
            response += chunk
        return response
    finally:
        s.close()


def dns_server(upstream: str, proxy_host: str, proxy_port: int, listen_port: int):
    """
    UDP server that receives DNS queries, forwards them via SOCKS5 TCP,
    and sends the response back over UDP.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('0.0.0.0', listen_port))
    print(f"[dns2socks5] Listening on 0.0.0.0:{listen_port}")
    print(f"[dns2socks5] Upstream: {upstream}:53 via SOCKS5 {proxy_host}:{proxy_port}")
    sys.stdout.flush()

    while True:
        data, addr = sock.recvfrom(BUFSIZE)
        threading.Thread(
            target=_handle_query,
            args=(sock, data, addr, upstream, proxy_host, proxy_port),
            daemon=True
        ).start()


def _handle_query(sock, data, addr, upstream, proxy_host, proxy_port):
    try:
        response = resolve_via_socks5(data, upstream, proxy_host, proxy_port)
        sock.sendto(response, addr)
    except Exception as e:
        print(f"[dns2socks5] Error: {e}", file=sys.stderr)
        sys.stderr.flush()


def main():
    parser = argparse.ArgumentParser(description='DNS-to-SOCKS5 relay')
    parser.add_argument('--port', type=int, default=5353,
                        help='Local UDP port to listen on (default: 5353)')
    parser.add_argument('--upstream', default='1.1.1.1',
                        help='Upstream DNS server IP (default: 1.1.1.1)')
    parser.add_argument('--socks-proxy', default='127.0.0.1:10808',
                        help='SOCKS5 proxy address (default: 127.0.0.1:10808)')
    args = parser.parse_args()

    proxy_host, proxy_port_str = args.socks_proxy.split(':')
    proxy_port = int(proxy_port_str)

    dns_server(args.upstream, proxy_host, proxy_port, args.port)


if __name__ == '__main__':
    main()