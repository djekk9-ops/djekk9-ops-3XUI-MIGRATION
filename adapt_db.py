#!/usr/bin/env python3
"""Change only recognized host identity fields in a 3x-ui SQLite backup.
No global string replacement, no rotating client credentials.
"""
import argparse
import ipaddress
import json
import re
import sqlite3
from pathlib import Path

KNOWN_HOST_KEYS = {'address', 'host', 'hostname', 'server', 'serverAddress', 'serverIP',
                   'publicIP', 'publicIp', 'endpoint', 'listen', 'sendThrough',
                   'bindAddress', 'serverHost'}
KNOWN_INTERFACE_KEYS = {'externalInterface', 'ipv6ExternalInterface'}
SETTINGS_HOST_KEYS = {'subDomain', 'subJsonDomain', 'subHost', 'subListen', 'webListen',
                      'webDomain', 'panelDomain', 'subURI', 'subUrl', 'subURL'}


def replace_ip(value, old_ip, new_ip):
    if not old_ip or old_ip == new_ip or not isinstance(value, str):
        return value
    if value == old_ip:
        return new_ip
    # Recognize only an address with a port or a URL, not arbitrary plaintext.
    if value.startswith(old_ip + ':') and value[len(old_ip)+1:].isdigit():
        return new_ip + value[len(old_ip):]
    if re.match(r'^https?://', value):
        from urllib.parse import urlsplit, urlunsplit
        try:
            url = urlsplit(value)
            if url.hostname != old_ip:
                return value
            userinfo = ''
            if url.username:
                userinfo = url.username
                if url.password:
                    userinfo += ':' + url.password
                userinfo += '@'
            netloc = userinfo + new_ip + ((':' + str(url.port)) if url.port else '')
            return urlunsplit((url.scheme, netloc, url.path, url.query, url.fragment))
        except ValueError:
            return value
    return value


def patch_json(value, oldip, newip, oldif, newif, log, location='json'):
    if isinstance(value, list):
        return [patch_json(v, oldip, newip, oldif, newif, log, location + '[]') for v in value]
    if not isinstance(value, dict):
        return value
    out = {}
    for k, v in value.items():
        path = location + '.' + k
        if k in KNOWN_INTERFACE_KEYS and isinstance(v, str) and oldif and v == oldif:
            out[k] = newif
            log.append(f'Сетевой интерфейс: {path}: {oldif} -> {newif}')
        elif k in KNOWN_HOST_KEYS and isinstance(v, str):
            nv = replace_ip(v, oldip, newip)
            out[k] = nv
            if nv != v:
                log.append(f'IPv4: {path}: {oldip} -> {newip}')
        else:
            out[k] = patch_json(v, oldip, newip, oldif, newif, log, path)
    return out


def colnames(conn, table):
    return [r[1] for r in conn.execute(f'PRAGMA table_info({table})')]


def patch(db, oldip, newip, oldif, newif):
    logs = []
    unrecognized = []
    con = sqlite3.connect(str(db))
    try:
        if con.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Повреждена база SQLite')
        if 'inbounds' not in {r[0] for r in con.execute('SELECT name FROM sqlite_master WHERE type="table"')}:
            raise ValueError('В базе нет таблицы inbounds')
        cols = colnames(con, 'inbounds')
        n = con.execute('SELECT count(*) FROM inbounds').fetchone()[0]
        logs.append(f'Входящих подключений: {n}')
        if n == 0:
            raise ValueError('Резервная копия не содержит входящих подключений')
        if 'id' not in cols:
            raise ValueError('Нет первичного ключа inbounds.id')
        json_cols = [c for c in ['settings', 'stream_settings', 'streamSettings', 'sniffing'] if c in cols]
        fields = ['id'] + [c for c in ['listen', 'protocol'] if c in cols] + json_cols
        rows = con.execute('SELECT ' + ','.join('"' + x + '"' for x in fields) + ' FROM inbounds').fetchall()
        for row in rows:
            record = dict(zip(fields, row))
            changes = {}
            if isinstance(record.get('listen'), str):
                new = replace_ip(record['listen'], oldip, newip)
                if new != record['listen']:
                    changes['listen'] = new
                    logs.append(f'IPv4: inbound {record["id"]}.listen: {oldip} -> {newip}')
            for col in json_cols:
                raw = record.get(col)
                if not raw:
                    continue
                try:
                    js = json.loads(raw)
                except (TypeError, ValueError):
                    unrecognized.append(f'inbound {record["id"]}.{col}: JSON не распознан')
                    continue
                newjs = patch_json(js, oldip, newip, oldif, newif, logs, f'inbound {record["id"]}.{col}')
                if newjs != js:
                    changes[col] = json.dumps(newjs, ensure_ascii=False, separators=(',', ':'))
            if changes:
                con.execute('UPDATE inbounds SET ' + ','.join('"' + k + '"=?' for k in changes) + ' WHERE id=?',
                            [*changes.values(), record['id']])
        tables = {r[0] for r in con.execute('SELECT name FROM sqlite_master WHERE type="table"')}
        if 'settings' in tables and {'key', 'value'} <= set(colnames(con, 'settings')):
            for key, value in con.execute('SELECT key,value FROM settings').fetchall():
                if not isinstance(value, str):
                    continue
                # Setting keys are exclusively from a reviewed, small whitelist.
                if key in SETTINGS_HOST_KEYS:
                    nv = replace_ip(value, oldip, newip)
                    if nv != value:
                        con.execute('UPDATE settings SET value=? WHERE key=?', (nv, key))
                        logs.append(f'IPv4: settings.{key}: {oldip} -> {newip}')
        con.commit()
        if con.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('База не прошла проверку после изменений')
    finally:
        con.close()
    return {'old_public_ip': oldip or None, 'new_public_ip': newip,
            'old_interface': oldif or None, 'new_interface': newif,
            'changes': logs, 'warnings': unrecognized,
            'keys_rotated': False, 'notes': [
               'TLS SNI, домены, пути сертификатов, UUID/REALITY/AWG-ключи не менялись.',
               'DNS-записи и параметры Yandex Cloud CDN не изменялись.',
               'Ключи можно заменить позднее через 3x-ui с повторной выдачей клиентских конфигураций.'
            ]}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--db', required=True, type=Path)
    p.add_argument('--old-ip', default='')
    p.add_argument('--new-ip', required=True)
    p.add_argument('--old-interface', default='')
    p.add_argument('--new-interface', required=True)
    p.add_argument('--report', type=Path, required=True)
    a = p.parse_args()
    for v in [a.old_ip, a.new_ip]:
        if v:
            ipaddress.IPv4Address(v)
    if not re.fullmatch(r'[A-Za-z0-9_.:-]+', a.new_interface):
        raise SystemExit('Некорректное имя интерфейса')
    res = patch(a.db, a.old_ip, a.new_ip, a.old_interface, a.new_interface)
    a.report.parent.mkdir(parents=True, exist_ok=True)
    a.report.write_text(json.dumps(res, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('Сохранён отчёт:', a.report)
    for line in res['changes']:
        print(' •', line)


if __name__ == '__main__':
    main()
