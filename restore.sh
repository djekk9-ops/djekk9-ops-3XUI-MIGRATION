#!/usr/bin/env bash
# 3x-ui Migration Manager v2.2 - safer same-domain restore to a fresh VPS.
set -Eeuo pipefail
umask 077
abort(){ echo "ОШИБКА: $*" >&2; exit 1; }
usage(){ echo 'Использование: bash restore.sh АРХИВ --same-domain [--domain=origin.example.com]'; exit 2; }
[[ $EUID -eq 0 ]] || abort 'Запустите от root.'
[[ $# -ge 1 ]] || usage
ARCHIVE=$1; shift
[[ -f "$ARCHIVE" ]] || abort "Нет архива: $ARCHIVE"
SAME_DOMAIN=false; DOMAIN=''
for arg in "$@"; do
  case "$arg" in
    --same-domain) SAME_DOMAIN=true ;;
    --domain=*) DOMAIN="${arg#--domain=}" ;;
    *) usage ;;
  esac
done
[[ $SAME_DOMAIN == true ]] || abort 'Автоадаптация допускает только перенос с тем же доменом: используйте --same-domain.'
[[ -z $DOMAIN || $DOMAIN =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || abort 'Неверное имя домена.'
source /etc/os-release
case "$ID" in ubuntu|debian) ;; *) abort 'Поддерживается Ubuntu/Debian';; esac
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for file in hostinfo.py adapt_db.py db_guard.py; do
  [[ -f "$SCRIPT_DIR/$file" ]] || abort "Отсутствует $file — установите полный комплект v2.2"
done
for cmd in python3 gpg tar curl systemctl ip install sha256sum; do
  command -v "$cmd" >/dev/null || abort "Отсутствует утилита $cmd"
done
# A populated target is NEVER overwritten by this unattended restore.
if [[ -f /etc/x-ui/x-ui.db ]]; then
  COUNT=$(python3 - <<'PY'
import sqlite3
try:
 with sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro',uri=True) as db:
  print(db.execute('SELECT count(*) FROM inbounds').fetchone()[0])
except Exception: print('UNKNOWN')
PY
)
  if [[ $COUNT == UNKNOWN ]] || [[ $COUNT -gt 0 ]]; then
    abort 'На VPS есть подключения или неизвестная база. На рабочем сервере повторное восстановление запрещено.'
  fi
fi
STAGED=/root/3xui-migration-staged
[[ ! -e "$STAGED" ]] || abort "Уже существует $STAGED. Разберитесь с предыдущим переносом."
TMP=$(mktemp -d /root/.3xui-v2-restore.XXXXXXXX)
cleanup(){ rm -rf -- "$TMP"; }
trap cleanup EXIT
read -r -s -p 'Пароль зашифрованной резервной копии: ' PASS; echo
mkdir -p "$TMP/unpacked"
if ! (gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --decrypt "$ARCHIVE" 3<<<"$PASS" | tar -C "$TMP/unpacked" -xzf -); then
  unset PASS
  abort 'Ошибка расшифровки/распаковки.'
fi
unset PASS
DB="$TMP/unpacked/etc/x-ui/x-ui.db"
[[ -f "$DB" ]] || abort 'База SQLite отсутствует в архиве.'
ORIGINAL_COUNT=$(python3 "$SCRIPT_DIR/db_guard.py" --db "$DB" | sed -n 's/.*inbounds: //p')
[[ $ORIGINAL_COUNT =~ ^[0-9]+$ && $ORIGINAL_COUNT -gt 0 ]] || abort 'Ошибка проверки базы.'
HOSTINFO=$(python3 "$SCRIPT_DIR/hostinfo.py")
NEW_IP=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["public_ipv4"])' "$HOSTINFO")
NEW_IF=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["interface"])' "$HOSTINFO")
[[ -n $NEW_IP && -n $NEW_IF ]] || abort 'Не удалось определить публичный IP или интерфейс.'
OLD_IP=''; OLD_IF=''
if [[ -f "$TMP/unpacked/hostinfo.json" ]]; then
  OLD_IP=$(python3 - "$TMP/unpacked/hostinfo.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get('public_ipv4',''))
PY
)
  OLD_IF=$(python3 - "$TMP/unpacked/hostinfo.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get('interface',''))
PY
)
fi
OLD_IP="${OLD_PUBLIC_IP:-$OLD_IP}"; OLD_IF="${OLD_INTERFACE:-$OLD_IF}"
if [[ -z $OLD_IP ]]; then
  read -r -p 'Старый публичный IPv4 (Enter = не менять): ' OLD_IP
fi
if [[ -z $OLD_IF ]]; then
  read -r -p 'Имя старого интерфейса (Enter = не менять): ' OLD_IF
fi
if [[ -z $DOMAIN ]]; then
  read -r -p 'Основной домен (останется прежним): ' DOMAIN
fi
[[ $DOMAIN =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || abort 'Укажите корректный домен.'
mkdir -p "$TMP/stage"
# Normalize with SQLite backup API, rather than copying the live SQLite file or its WAL/SHM.
python3 "$SCRIPT_DIR/db_guard.py" --db "$DB" --output "$TMP/stage/x-ui.db"
python3 "$SCRIPT_DIR/adapt_db.py" --db "$TMP/stage/x-ui.db" \
  --old-ip "$OLD_IP" --new-ip "$NEW_IP" \
  --old-interface "$OLD_IF" --new-interface "$NEW_IF" --report "$TMP/stage/adaptation.json"
python3 "$SCRIPT_DIR/db_guard.py" --db "$TMP/stage/x-ui.db" --expected "$ORIGINAL_COUNT"
# Disable Telegram on the new VPS by default, preserving the token but avoiding 409 conflicts.
python3 "$SCRIPT_DIR/db_guard.py" --db "$TMP/stage/x-ui.db" \
  --output "$TMP/stage/x-ui.deploy.db" --disable-telegram
python3 "$SCRIPT_DIR/db_guard.py" --db "$TMP/stage/x-ui.deploy.db" --expected "$ORIGINAL_COUNT"
echo
echo '===== ПЛАН ПЕРЕНОСА ====='
echo "Найдено входящих подключений: $ORIGINAL_COUNT"
echo "Новый VPS IPv4: $NEW_IP (старый: ${OLD_IP:-не указан})"
echo "Интерфейс: $NEW_IF (старый: ${OLD_IF:-не указан})"
echo "Домен: $DOMAIN (тот же)"
echo 'UUID и TLS-ключи будут сохранены.'
echo 'Telegram-бот на новом VPS будет ОТКЛЮЧЁН (токен сохраняется).'
echo 'DNS/CDN и старый VPS не изменяются. Nginx будет подготовлен и установлен при отсутствии, но НЕ активирован.'
read -r -p 'Для подтверждения введите ПЕРЕНОС: ' CONFIRM
[[ $CONFIRM == ПЕРЕНОС ]] || { echo 'Отмена; на VPS ничего не изменено.'; exit 0; }
if ! command -v x-ui >/dev/null 2>&1; then
  INSTALL_VERSION="${XUI_VERSION:-v3.10.2}"
  echo "Установка 3x-ui ($INSTALL_VERSION)."
  curl -fsSL --connect-timeout 10 --max-time 90 \
    https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh -o "$TMP/install.sh"
  XUI_NONINTERACTIVE=1 bash "$TMP/install.sh" "$INSTALL_VERSION" || abort 'Ошибка установки 3x-ui.'
fi
command -v x-ui >/dev/null || abort 'Команда x-ui после установки не найдена.'
if [[ -f /etc/x-ui/x-ui.db ]]; then
  COUNT=$(python3 - <<'PY'
import sqlite3
try:
 with sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro',uri=True) as db:
  print(db.execute('SELECT count(*) FROM inbounds').fetchone()[0])
except Exception: print('UNKNOWN')
PY
)
  [[ $COUNT == 0 ]] || abort 'Во время установки появилась непустая или повреждённая БД: перенос прерван.'
fi
mkdir -p "$STAGED"
cp -a "$TMP/stage/adaptation.json" "$STAGED/adaptation.json"
printf '%s\n' "$NEW_IP" > "$STAGED/new-ip.txt"
printf '%s\n' "$NEW_IF" > "$STAGED/new-interface.txt"
printf '%s\n' "$DOMAIN" > "$STAGED/domain.txt"
if [[ -d "$TMP/unpacked/etc/nginx" ]]; then
  cp -a "$TMP/unpacked/etc/nginx" "$STAGED/nginx"
  python3 - "$STAGED/nginx" "$OLD_IP" "$NEW_IP" <<'PY'
import pathlib,re,sys
root,old,new=sys.argv[1:]
if not old or old==new: sys.exit()
pattern=re.compile(r'(?<![0-9.])'+re.escape(old)+r'(?![0-9.])')
for p in pathlib.Path(root).rglob('*'):
 if not p.is_file() or p.is_symlink(): continue
 try: content=p.read_text(encoding='utf8')
 except (UnicodeDecodeError,OSError): continue
 if pattern.search(content):
  p.write_text(pattern.sub(lambda m:new,content),encoding='utf8')
  print('Подготовлен Nginx:',p)
PY
  # Catch the empty active-site problem before announcing a successful stage.
  if [[ -d "$STAGED/nginx/sites-enabled" ]]; then
    while IFS= read -r -d '' site; do
      [[ -s "$site" ]] || abort "Пустой/битый активный сайт Nginx: $site"
    done < <(find -L "$STAGED/nginx/sites-enabled" -maxdepth 1 -type f -print0)
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    echo 'Nginx отсутствует. Устанавливаю пакет (без применения подготовленной конфигурации).'
    command -v apt-get >/dev/null || abort 'Невозможно автоматически установить Nginx без apt-get.'
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
    command -v nginx >/dev/null || abort 'Nginx не установлен.'
  fi
fi
# Restore same-domain certificate paths; DNS remains unchanged.
if [[ -d "$TMP/unpacked/etc/letsencrypt" ]]; then
  mkdir -p /etc/letsencrypt
  cp -a "$TMP/unpacked/etc/letsencrypt/." /etc/letsencrypt/
fi
for path in /root/cert /etc/x-ui/cert; do
  if [[ -d "$TMP/unpacked$path" ]]; then
    mkdir -p "$path"
    cp -a "$TMP/unpacked$path/." "$path/"
  fi
done
systemctl stop x-ui || true
mkdir -p /etc/x-ui
BACKUP_DB=''
if [[ -f /etc/x-ui/x-ui.db ]]; then
  BACKUP_DB="/root/x-ui-before-migration-$(date -u +%Y%m%d-%H%M%S)-$$.db"
  cp -a /etc/x-ui/x-ui.db "$BACKUP_DB"
fi
# Make a complete, atomic replacement. A failed launch never reports success.
install -m 600 "$TMP/stage/x-ui.deploy.db" /etc/x-ui/x-ui.db.migrating
python3 "$SCRIPT_DIR/db_guard.py" --db /etc/x-ui/x-ui.db.migrating --expected "$ORIGINAL_COUNT"
# Service is stopped, so leftover WAL/SHM from a different database may be removed.
rm -f /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm
mv -f /etc/x-ui/x-ui.db.migrating /etc/x-ui/x-ui.db
if ! python3 "$SCRIPT_DIR/db_guard.py" --db /etc/x-ui/x-ui.db --expected "$ORIGINAL_COUNT"; then
  echo 'Восстановленная БД повреждена, откатываю установку.' >&2
  if [[ -n $BACKUP_DB ]]; then cp -a "$BACKUP_DB" /etc/x-ui/x-ui.db; fi
  abort 'Не пройдена проверка базы после установки.'
fi
systemctl reset-failed x-ui || true
systemctl start x-ui || true
# A systemd start may succeed while x-ui crashes milliseconds later.
for _ in 1 2 3 4 5; do
  sleep 2
  systemctl is-active --quiet x-ui || break
done
if ! systemctl is-active --quiet x-ui || ! python3 "$SCRIPT_DIR/db_guard.py" --db /etc/x-ui/x-ui.db --expected "$ORIGINAL_COUNT"; then
  echo 'x-ui не удержался в активном состоянии либо база повреждена.' >&2
  journalctl -u x-ui -n 20 --no-pager -l >&2 || true
  systemctl stop x-ui || true
  cp -a /etc/x-ui/x-ui.db "$STAGED/failed-x-ui.db" || true
  if [[ -n $BACKUP_DB ]]; then
    cp -a "$BACKUP_DB" /etc/x-ui/x-ui.db
    systemctl reset-failed x-ui || true
    systemctl start x-ui || true
  fi
  abort 'Восстановление НЕ выполнено. Сохранён исходный файл базы.'
fi
if [[ -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]] && command -v openssl >/dev/null 2>&1; then
  openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || \
    echo 'ВНИМАНИЕ: TLS-сертификат истёк или не распознаётся.' >&2
else
  echo "ВНИМАНИЕ: нет сертификата /etc/letsencrypt/live/$DOMAIN/fullchain.pem" >&2
fi
printf '\nГОТОВО: 3x-ui ЗАПУЩЕНА, БД проверена, восстановлено подключений: %s.\n' "$ORIGINAL_COUNT"
echo "Новый IP: $NEW_IP; интерфейс: $NEW_IF"
echo "Отчёт изменений: $STAGED/adaptation.json"
echo "Nginx подготовлен: $STAGED/nginx (применяется отдельно через меню)."
echo 'Telegram-бот на новом VPS отключён до окончательного переключения.'
echo 'Старый VPS и DNS не отключайте до проверки нового.'
