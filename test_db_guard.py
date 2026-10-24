#!/usr/bin/env python3
"""Local non-root regression tests for SQLite normalization."""
import sqlite3
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

SCRIPT = Path(__file__).with_name('db_guard.py')

with TemporaryDirectory() as td:
    source = Path(td) / 'source.db'
    new = Path(td) / 'new.db'
    with sqlite3.connect(source) as db:
        db.executescript('''
        CREATE TABLE inbounds (id INTEGER PRIMARY KEY, protocol TEXT);
        INSERT INTO inbounds VALUES (1,'vless'),(2,'hysteria');
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO settings VALUES ('tgBotEnable','true'),('tgBotToken','dont-change');
        ''')
    subprocess.run([sys.executable, str(SCRIPT), '--db', str(source), '--output', str(new), '--disable-telegram'], check=True)
    subprocess.run([sys.executable, str(SCRIPT), '--db', str(new), '--expected', '2'], check=True)
    with sqlite3.connect(f'file:{new}?mode=ro', uri=True) as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert db.execute("SELECT value FROM settings WHERE key='tgBotEnable'").fetchone()[0] == 'false'
        assert db.execute("SELECT value FROM settings WHERE key='tgBotToken'").fetchone()[0] == 'dont-change'
    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as db:
        assert db.execute("SELECT value FROM settings WHERE key='tgBotEnable'").fetchone()[0] == 'true'
    # Deliberately corrupt a byte in the header: must reject it.
    broken = Path(td) / 'broken.db'
    broken.write_bytes(b'not a sqlite database')
    result = subprocess.run([sys.executable, str(SCRIPT), '--db', str(broken)], capture_output=True, text=True)
    assert result.returncode != 0
print('PASS: snapshot, Telegram isolation, inbound count, corruption detection')
