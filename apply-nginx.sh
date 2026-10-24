#!/usr/bin/env bash
# Apply a staged nginx tree on the target VPS; validate actual active sites and rollback on error.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Нужен root.' >&2; exit 1; }
STAGE=/root/3xui-migration-staged/nginx
[[ -s "$STAGE/nginx.conf" ]] || { echo "Нет nginx.conf или он пуст: $STAGE" >&2; exit 1; }
command -v nginx >/dev/null || { echo 'Установите Nginx: apt update && apt install -y nginx' >&2; exit 1; }
[[ -d "$STAGE/sites-enabled" ]] || { echo 'Нет сайтов в sites-enabled.' >&2; exit 1; }
WORK=$(mktemp -d /root/.3xui-nginx-XXXXXX)
trap 'rm -rf -- "$WORK"' EXIT
cp -a "$STAGE" "$WORK/nginx"
mkdir -p "$WORK/nginx/sites-available" "$WORK/nginx/sites-enabled"
# If an old VPS has an independent active file in sites-enabled, it is authoritative.
# Rewrite the candidate to conventional self-contained relative symlinks.
ACTIVE=0
for source in "$STAGE/sites-enabled/"*; do
  [[ -e "$source" || -L "$source" ]] || continue
  name=$(basename "$source")
  real_source="$source"
  if [[ -L "$source" ]]; then
    target=$(readlink "$source")
    # Resolve preserved absolute symlinks against the STAGED tree, never the live VPS.
    if [[ $target == /etc/nginx/sites-available/* ]]; then
      real_source="$STAGE/sites-available/${target##*/}"
    elif [[ $target == ../sites-available/* ]]; then
      real_source="$STAGE/sites-available/${target##*/}"
    else
      echo "Неизвестная ссылка сайта: $source -> $target" >&2; exit 1
    fi
  fi
  [[ -f "$real_source" && -s "$real_source" && ! -L "$real_source" ]] || { echo "Пустой/неправильный active site: $source" >&2; exit 1; }
  [[ $name != *[[:space:]/]* ]] || { echo 'Неправильное имя сайта.' >&2; exit 1; }
  install -m 644 "$real_source" "$WORK/nginx/sites-available/$name"
  rm -f -- "$WORK/nginx/sites-enabled/$name"
  ln -s "../sites-available/$name" "$WORK/nginx/sites-enabled/$name"
  [[ -s "$WORK/nginx/sites-enabled/$name" ]] || { echo "Ошибка копирования $name" >&2; exit 1; }
  if ! cmp -s "$real_source" "$WORK/nginx/sites-enabled/$name"; then
    echo "Контрольная проверка сайта не прошла: $name" >&2; exit 1
  fi
  ACTIVE=$((ACTIVE+1))
done
(( ACTIVE > 0 )) || { echo 'Нет ни одного активного сайта, отмена.' >&2; exit 1; }
# Reject empty active sites even if nginx -t would consider them valid.
find -L "$WORK/nginx/sites-enabled" -type f -empty -print -quit | grep -q . && {
  echo 'Пустой сайт обнаружен в подготовленном дереве.' >&2; exit 1;
}
NEED_443=0
if grep -Eqs '^[[:space:]]*listen[[:space:]].*443.*ssl' "$WORK/nginx/sites-enabled/"*; then NEED_443=1; fi
printf 'Подготовлено активных сайтов: %s; ожидается TLS-порт 443: %s\n' "$ACTIVE" "$NEED_443"
echo 'ВНИМАНИЕ: на НОВОМ VPS будет заменён весь каталог /etc/nginx.'
read -r -p 'Для продолжения введите NGINX: ' CONFIRM
[[ $CONFIRM == NGINX ]] || { echo 'Отменено.'; exit 1; }
STAMP=$(date -u +%Y%m%d-%H%M%S)
OLD="/etc/nginx.before-3xui-$STAMP-$$"
[[ ! -e $OLD ]] || { echo 'Каталог резервной копии занят.' >&2; exit 1; }
ROLLBACK=0
rollback(){
  if (( ROLLBACK )); then
    echo 'Ошибка применения Nginx, возвращаю предыдущую конфигурацию.' >&2
    if [[ -d /etc/nginx ]]; then mv /etc/nginx "$WORK/failed-nginx"; fi
    if [[ -d $OLD ]]; then mv "$OLD" /etc/nginx; fi
    if command -v nginx >/dev/null && nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
    fi
  fi
}
trap 'rollback; exit 1' ERR
if [[ -d /etc/nginx ]]; then mv /etc/nginx "$OLD"; fi
mv "$WORK/nginx" /etc/nginx
ROLLBACK=1
nginx -t
# nginx -T must actually include the enabled site and its expected listeners.
FULL=$(nginx -T 2>&1)
grep -q '# configuration file /etc/nginx/sites-enabled/' <<< "$FULL"
if (( NEED_443 )); then
  grep -Eq '^[[:space:]]*listen[[:space:]].*443.*ssl' <<< "$FULL"
fi
if systemctl is-active --quiet nginx; then
  systemctl reload nginx
else
  systemctl enable --now nginx
fi
sleep 2
systemctl is-active --quiet nginx
if (( NEED_443 )); then
  ss -lnt | awk 'NR>1 {print $4}' | grep -Eq '(^|:)443$'
fi
ROLLBACK=0
trap - ERR
echo "ГОТОВО: Nginx запущен, активных сайтов: $ACTIVE."
echo "Предыдущая конфигурация: $OLD"
echo 'DNS не менялся, работа VPN требует отдельного клиентского теста.'
