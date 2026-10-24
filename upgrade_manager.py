#!/usr/bin/env python3
"""Patch a local checkout of djekk9-ops/3XUI-MIGRATION to candidate v2.2.

Works offline; does NOT connect to GitHub, modify a VPS service, or read backups.
Keeps timestamped copies of the original project files for rollback.
"""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import py_compile
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPLACE = ('restore.sh', 'apply-nginx.sh', 'db_guard.py')
EDIT = ('setup.sh', 'menu.sh', 'backup.sh', 'adapt_db.py', 'README.md')


def once(content, old, new, name):
    if old not in content:
        raise RuntimeError(f'{name}: expected anchor not found: {old[:90]!r}')
    return content.replace(old, new, 1)


def patch_text(filename, s):
    if filename == 'setup.sh':
        s = once(s,
                 'FILES=(menu.sh check.sh backup.sh restore.sh apply-nginx.sh adapt_db.py hostinfo.py README.md)',
                 'FILES=(menu.sh check.sh backup.sh restore.sh apply-nginx.sh adapt_db.py db_guard.py hostinfo.py README.md)', filename)
        s = once(s, '"$TMP/source/adapt_db.py" "$TMP/source/hostinfo.py"',
                 '"$TMP/source/adapt_db.py" "$TMP/source/db_guard.py" "$TMP/source/hostinfo.py"', filename)
        s = s.replace('v2.1', 'v2.2')
    elif filename == 'menu.sh':
        s = once(s, '3x-ui Migration Manager v2.1', '3x-ui Migration Manager v2.2', filename)
        s = s.replace('Не запускайте восстановление на рабочем VPS с восемью подключениями.',
                      'Не запускайте восстановление на рабочем VPS с подключениями.')
    elif filename == 'backup.sh':
        s = once(s, "'PRAGMA quick_check'", "'PRAGMA integrity_check'", filename)
    elif filename == 'adapt_db.py':
        if s.count("'PRAGMA quick_check'") != 2:
            raise RuntimeError('adapt_db.py: expected 2 quick_check occurrences')
        s = s.replace("'PRAGMA quick_check'", "'PRAGMA integrity_check'")
    elif filename == 'README.md':
        s += '''\n\n## v2.2 — исправления по результатам тестовой миграции\n\n- SQLite: полная `integrity_check`, согласованный SQLite backup, атомарная установка базы, проверка после записи и запуска службы.\n- Telegram: бот отключён **только на новом VPS** в восстановленной базе по умолчанию, токен остаётся.\n- Nginx: установка пакета при необходимости; активация по отдельному подтверждению.\n- Nginx: автономная реконструкция sites-enabled, защита от пустых файлов и проверка реального прослушивания TLS-порта после перезагрузки.\n- Ошибка старта 3x-ui больше не выводится как успешная миграция; сохраняется диагностическая база, по возможности восстанавливается предыдущее состояние.\n\n**Ограничения:** повторное восстановление на VPS с существующими входящими подключениями запрещено.\nАвтопродление сертификата при DNS, указывающем на старый VPS, требует отдельной проверки после смены DNS.\nСначала проверяйте на отдельном новом VPS. Действующий VPS и DNS не изменяются автоматически.\n'''
    return s


def main():
    p = argparse.ArgumentParser()
    p.add_argument('repository', type=Path, help='local cloned/downloaded repository directory')
    a = p.parse_args()
    repo = a.repository.resolve()
    if not repo.is_dir() or not all((repo / f).is_file() for f in EDIT):
        raise SystemExit('Path must contain original 3XUI-MIGRATION repository files')
    timestamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup = repo / f'.pre-v2.2-{timestamp}'
    if backup.exists():
        raise SystemExit('Backup folder already exists')
    transformed = {f: patch_text(f, (repo / f).read_text(encoding='utf-8')) for f in EDIT}
    # Validate all files before modifying the repository.
    for f in REPLACE:
        if not (HERE / f).is_file():
            raise SystemExit('Missing candidate replacement file: ' + f)
    with tempfile.TemporaryDirectory() as td:
        temp = Path(td)
        for f in REPLACE:
            shutil.copy2(HERE / f, temp / f)
        for f, content in transformed.items():
            (temp / f).write_text(content, encoding='utf-8')
        for f in ('restore.sh', 'apply-nginx.sh', 'setup.sh', 'menu.sh', 'backup.sh'):
            subprocess.run(['bash', '-n', str(temp / f)], check=True)
        for f in ('adapt_db.py', 'db_guard.py'):
            compile((temp / f).read_text(encoding='utf-8'), f, 'exec')
    backup.mkdir(mode=0o700)
    for f in EDIT + tuple(x for x in REPLACE if (repo / x).exists()):
        shutil.copy2(repo / f, backup / f)
    for f in REPLACE:
        old_mode = (repo / f).stat().st_mode if (repo / f).exists() else None
        shutil.copy2(HERE / f, repo / f)
        os.chmod(repo / f, (old_mode & 0o777) if old_mode else (0o700 if f.endswith('.sh') else 0o600))
    for f, content in transformed.items():
        target = repo / f
        old_mode = target.stat().st_mode & 0o777
        tmp = repo / (f + '.v2.2.new')
        tmp.write_text(content, encoding='utf-8')
        os.chmod(tmp, old_mode)
        os.replace(tmp, target)
    print('Candidate v2.2 patched:', repo)
    print('Original scripts saved in:', backup)
    print('Check diffs, review secrets, then commit changes yourself.')

if __name__ == '__main__':
    main()
