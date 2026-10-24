#!/usr/bin/env python3
"""Validate/normalize SQLite backup before deployment; no live 3x-ui access."""
import argparse
import os
import sqlite3
from pathlib import Path


def check_db(path: Path, expected=None):
    with sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=30) as db:
        result = db.execute('PRAGMA integrity_check').fetchone()[0]
        if result != 'ok':
            raise RuntimeError('SQLite integrity_check: ' + result)
        count = db.execute('SELECT count(*) FROM inbounds').fetchone()[0]
        if not count or (expected is not None and count != expected):
            raise RuntimeError(f'Inbound count mismatch: {count}, expected {expected}')
    return count


def normalize(src: Path, dst: Path, disable_telegram=False):
    if src.resolve() == dst.resolve():
        raise RuntimeError('Output must differ from input')
    n = check_db(src)
    if dst.exists():
        raise RuntimeError('Output already exists: ' + str(dst))
    try:
        with sqlite3.connect(f'file:{src}?mode=ro', uri=True) as s:
            with sqlite3.connect(dst) as d:
                s.backup(d)  # coherent snapshot; excludes WAL sidecars
                if disable_telegram:
                    d.execute("UPDATE settings SET value='false' WHERE key='tgBotEnable'")
                d.commit()
                d.execute('PRAGMA wal_checkpoint(TRUNCATE)')
                d.execute('PRAGMA journal_mode=DELETE')
                if d.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                    raise RuntimeError('Normalized database is invalid')
        os.chmod(dst, 0o600)
        if check_db(dst, n) != n:
            raise RuntimeError('Unexpected inbound count')
        if disable_telegram:
            with sqlite3.connect(f'file:{dst}?mode=ro', uri=True) as db:
                row = db.execute("SELECT value FROM settings WHERE key='tgBotEnable'").fetchone()
                if row and row[0] != 'false':
                    raise RuntimeError('Telegram bot was not disabled')
        return n
    except Exception:
        dst.unlink(missing_ok=True)
        raise


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--db', required=True, type=Path)
    p.add_argument('--output', type=Path)
    p.add_argument('--expected', type=int)
    p.add_argument('--disable-telegram', action='store_true')
    a = p.parse_args()
    if a.output:
        n = normalize(a.db, a.output, a.disable_telegram)
        print(f'Database snapshot OK, inbounds: {n}, Telegram disabled: {a.disable_telegram}')
    else:
        print(f'Database integrity OK, inbounds: {check_db(a.db, a.expected)}')

if __name__ == '__main__':
    main()
