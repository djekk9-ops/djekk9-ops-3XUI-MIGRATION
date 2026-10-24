#!/usr/bin/env python3
"""Read-only detection of public IPv4 and outbound interface (Python stdlib)."""
import argparse
import ipaddress
import json
import os
import re
import subprocess
import urllib.request


def valid_public(ip):
    try:
        a = ipaddress.IPv4Address(ip.strip())
        return bool(a.is_global)
    except (ValueError, AttributeError):
        return False


def default_interface():
    try:
        out = subprocess.check_output(['ip', '-4', 'route', 'show', 'default'], text=True, timeout=5)
        for line in out.splitlines():
            m = re.search(r'\bdev\s+(\S+)', line)
            if m:
                return m.group(1)
    except (OSError, subprocess.SubprocessError):
        pass
    return ''


def public_ipv4():
    explicit = os.environ.get('PUBLIC_IP', '').strip()
    if explicit:
        if not valid_public(explicit):
            raise SystemExit('PUBLIC_IP должен быть публичным IPv4-адресом')
        return explicit
    # Disable any proxy inherited from the shell: detect the VPS itself.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for url in ('https://api4.ipify.org', 'https://ipv4.icanhazip.com'):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': '3xui-migration-v2/2.0'})
            with opener.open(req, timeout=6) as response:
                data = response.read(64).decode('ascii').strip()
            if valid_public(data):
                return data
        except (OSError, ValueError, UnicodeError):
            continue
    # No fake public IP guesses from NAT/private address ranges.
    return ''


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--format', choices=['json', 'shell'], default='json')
    args = p.parse_args()
    vals = {'public_ipv4': public_ipv4(), 'interface': default_interface()}
    if args.format == 'json':
        print(json.dumps(vals, ensure_ascii=False))
    else:
        import shlex
        for key, value in vals.items():
            print(f'{key.upper()}={shlex.quote(value)}')
