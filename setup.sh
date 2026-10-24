#!/usr/bin/env bash
# 3x-ui Migration Manager — GitHub bootstrap and local installer.
# Usage: sudo bash setup.sh --repo OWNER/REPO [--ref v2.2.0] [--no-run]
set -Eeuo pipefail
umask 077

error(){ printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
usage(){
cat <<'HELP'
3x-ui Migration Manager v2.2 — установка менеджера
  sudo bash setup.sh --repo GITHUB_OWNER/GITHUB_REPO [--ref main] [--no-run]
  sudo bash setup.sh --source /путь/к/распакованным/файлам [--no-run]
  sudo bash setup.sh --repo OWNER/REPO --ref v2.2.0 --update

Скрипт загружает ТОЛЬКО программные файлы. Архивы с ключами и паролями
НЕ загружаются на GitHub и НЕ отправляются установщиком в интернет.
Проверяйте скрипт и используйте зафиксированный Git-тег после публикации.
HELP
}

[[ $EUID -eq 0 ]] || error 'Запустите с sudo или от root.'
REPO=''; REF='main'; SOURCE=''; NO_RUN=0; UPDATE=0; NO_SHORTCUT=0
DEST="${XUI_MANAGER_DIR:-/opt/3xui-migration}"
while (($#)); do
 case "$1" in
   --repo) (($#>=2)) || error 'После --repo нужен OWNER/REPO'; REPO="$2"; shift 2;;
   --ref) (($#>=2)) || error 'После --ref нужен тег'; REF="$2"; shift 2;;
   --source) (($#>=2)) || error 'После --source нужен путь'; SOURCE="$2"; shift 2;;
   --no-run) NO_RUN=1; shift;;
   --update) UPDATE=1; shift;;
   --no-shortcut) NO_SHORTCUT=1; shift;;
   --help|-h) usage; exit 0;;
   *) error "Неизвестный аргумент: $1";;
 esac
done
[[ -n $SOURCE || -n $REPO ]] || { usage; error 'Не указан репозиторий или локальный каталог.'; }
[[ -z $SOURCE || -z $REPO ]] || error 'Используйте только один из вариантов: --repo или --source.'
[[ -z $REPO || $REPO =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || error 'Репозиторий должен иметь вид OWNER/REPO.'
[[ $REF =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || error 'Некорректная ветка/метка (используйте main или v2.2.0).'
[[ $DEST == /* && $DEST != / && $DEST != /opt && $DEST != /root && $DEST != /etc ]] || error 'Некорректная целевая папка.'
[[ ! -L $DEST ]] || error 'Папка назначения не должна быть символьной ссылкой.'
if [[ -e $DEST && $UPDATE -ne 1 ]]; then
 error "$DEST уже существует. Используйте --update для установки новой версии с сохранением предыдущей."
fi
for c in tar mktemp cp mv chmod; do command -v "$c" >/dev/null || error "Отсутствует утилита: $c"; done
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/source"
if [[ -n $SOURCE ]]; then
 [[ -d $SOURCE ]] || error "Не найдена папка: $SOURCE"
 cp -a "$SOURCE/." "$TMP/source/"
else
 command -v curl >/dev/null || error 'Установите curl: apt update && apt install -y curl'
 echo "Скачивание версии '$REF' из https://github.com/$REPO ..."
 curl --proto '=https' --tlsv1.2 --fail --show-error --silent --location \
   --connect-timeout 15 --max-time 180 --retry 2 \
   "https://codeload.github.com/$REPO/tar.gz/$REF" -o "$TMP/code.tar.gz" \
   || error 'Не удалось скачать код. Проверьте репозиторий и тег/ветку.'
 # GitHub source archives have a single top-level directory.
 tar -tzf "$TMP/code.tar.gz" >/dev/null || error 'Получен повреждённый архив.'
 tar -xzf "$TMP/code.tar.gz" -C "$TMP/source" --strip-components=1 \
   --no-same-owner --no-same-permissions || error 'Не удалось распаковать код.'
fi
FILES=(menu.sh check.sh backup.sh restore.sh apply-nginx.sh adapt_db.py db_guard.py test_db_guard.py hostinfo.py README.md)
for f in "${FILES[@]}"; do
 [[ -f "$TMP/source/$f" && ! -L "$TMP/source/$f" ]] || error "Отсутствует обязательный файл: $f"
done
for f in menu.sh check.sh backup.sh restore.sh apply-nginx.sh; do
 bash -n "$TMP/source/$f" || error "Ошибка синтаксиса: $f"
done
if command -v python3 >/dev/null; then
 PYTHONDONTWRITEBYTECODE=1 python3 - "$TMP/source/adapt_db.py" "$TMP/source/db_guard.py" "$TMP/source/test_db_guard.py" "$TMP/source/hostinfo.py" <<'PY'
import ast,sys
for path in sys.argv[1:]:
    ast.parse(open(path,encoding='utf-8').read(), filename=path)
PY
fi
STAGING="$(dirname "$DEST")/.3xui-migration.new.$$"
mkdir -p "$(dirname "$DEST")"
[[ ! -e $STAGING ]] || error 'Временная папка уже существует.'
mkdir -m 700 "$STAGING"
for f in "${FILES[@]}"; do install -m 600 "$TMP/source/$f" "$STAGING/$f"; done
chmod 700 "$STAGING"/{menu.sh,check.sh,backup.sh,restore.sh,apply-nginx.sh}
if [[ -e $DEST ]]; then
 STAMP=$(date -u +%Y%m%d-%H%M%S)
 mv -- "$DEST" "${DEST}.previous-${STAMP}"
 echo "Старая версия сохранена: ${DEST}.previous-${STAMP}"
fi
mv -- "$STAGING" "$DEST"
if [[ $NO_SHORTCUT -eq 0 && $DEST == /opt/3xui-migration ]]; then
 cat > /usr/local/bin/3xui-migrate <<'WRAPPER'
#!/usr/bin/env bash
exec bash /opt/3xui-migration/menu.sh "$@"
WRAPPER
 chmod 755 /usr/local/bin/3xui-migrate
fi
printf '\nМенеджер установлен: %s\n' "$DEST"
echo 'Установка программных файлов НЕ изменяла текущие VPN и 3x-ui.'
if [[ $NO_RUN -eq 0 ]]; then
 exec bash "$DEST/menu.sh"
else
 echo "Запуск: sudo bash $DEST/menu.sh"
fi
