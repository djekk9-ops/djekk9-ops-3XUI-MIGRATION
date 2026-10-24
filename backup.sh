#!/usr/bin/env bash
# 3x-ui migration kit: encrypted snapshot of SQLite, Nginx, TLS and optional custom certs.
set -Eeuo pipefail
umask 077

if [[ $EUID -ne 0 ]]; then echo 'Запустите от root: sudo bash backup.sh' >&2; exit 1; fi
for cmd in python3 tar gpg mktemp cp ip; do
  command -v "$cmd" >/dev/null || { echo "Не найдена команда $cmd" >&2; exit 1; }
done
DB=/etc/x-ui/x-ui.db
[[ -f "$DB" ]] || { echo "База 3x-ui $DB не найдена (поддерживается SQLite, не PostgreSQL)." >&2; exit 1; }
OUT="${1:-/root/3xui-backup-$(date -u +%Y%m%d-%H%M%S).tar.gz.gpg}"
[[ ! -e "$OUT" ]] || { echo "Файл уже существует: $OUT" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
TMP=$(mktemp -d /root/.3xui-backup.XXXXXXXX)
cleanup(){ rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/etc/x-ui"
# Record the source host identity, without embedding a fixed old VPS address.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$SCRIPT_DIR/hostinfo.py" ]] || { echo 'Отсутствует hostinfo.py — загрузите весь комплект v2' >&2; exit 1; }
python3 "$SCRIPT_DIR/hostinfo.py" > "$TMP/hostinfo.json"
python3 - "$TMP/hostinfo.json" <<'PYHOST'
import json,sys
s=json.load(open(sys.argv[1]))
print('Исходный публичный IPv4:', s['public_ipv4'] or 'не определён; при переносе потребуется ввод вручную')
print('Исходный интерфейс:', s['interface'] or 'не определён')
PYHOST

# Python SQLite backup API takes a consistent online snapshot even if the panel is running.
python3 - "$DB" "$TMP/etc/x-ui/x-ui.db" <<'PY'
import sqlite3, sys
source, target = sys.argv[1:]
s = sqlite3.connect(f'file:{source}?mode=ro', uri=True, timeout=30)
t = sqlite3.connect(target)
s.backup(t)
t.close(); s.close()
with sqlite3.connect(target) as c:
    if c.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
        raise SystemExit('Ошибка проверки резервной копии SQLite')
    count = c.execute('SELECT count(*) FROM inbounds').fetchone()[0]
    if count < 1:
        raise SystemExit('База не содержит входящих подключений')
    print(f'Сохранено входящих подключений: {count}')
PY

for path in /etc/nginx /etc/letsencrypt /root/cert /etc/x-ui/cert; do
  if [[ -e "$path" ]]; then
    mkdir -p "$TMP$(dirname "$path")"
    cp -a "$path" "$TMP$path"
  fi
done
cat > "$TMP/README-INSIDE.txt" <<TEXT
3x-ui backup, created $(date -u +'%Y-%m-%d %H:%M:%S UTC')
Source host: $(hostname)
Contains PRIVATE keys, passwords, client IDs and subscription settings.
DO NOT publish or send to strangers. Keep the encryption passphrase separately.
TLS certificates in this archive refer to ORIGINAL domain(s).
Nginx files must be reviewed before activation on a new server.
TEXT

echo 'ВНИМАНИЕ: архив включает приватные ключи, пароль панели и клиентские доступы.'
echo 'Придумайте отдельный пароль для шифрования архива (не пароль панели).'

read -r -s -p 'Пароль архива: ' PASS; echo
read -r -s -p 'Повторите пароль: ' VERIFY; echo
[[ -n "$PASS" && "$PASS" == "$VERIFY" ]] || { echo 'Пароли пусты или не совпадают' >&2; exit 1; }
unset VERIFY
# No unencrypted tarball is written to disk.
if tar -C "$TMP" -czf - . | gpg --batch --yes --pinentry-mode loopback \
    --passphrase-fd 3 --symmetric --cipher-algo AES256 \
    --output "$OUT" 3<<<"$PASS"; then
  unset PASS
  chmod 600 "$OUT"
  echo "ГОТОВО: $OUT"
  echo 'Скопируйте архив с сервера в безопасное место, отдельно сохранив пароль.'
else
  unset PASS
  rm -f -- "$OUT"
  echo 'Ошибка создания зашифрованного архива.' >&2
  exit 1
fi
