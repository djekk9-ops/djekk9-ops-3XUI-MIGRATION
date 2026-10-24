#!/usr/bin/env bash
# Interactive Russian menu. Subordinate scripts stay alongside this file.
set -Eeuo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ $EUID -eq 0 ]] || { echo 'Нужен root: sudo bash menu.sh' >&2; exit 1; }

pause(){ printf '\n'; read -r -p 'Нажмите Enter для возврата в меню...' _ || true; }
need_cmds(){
 local missing=() c answer
 for c in "$@"; do command -v "$c" >/dev/null || missing+=("$c"); done
 if ((${#missing[@]})); then
  echo "Отсутствуют утилиты: ${missing[*]}"
  echo 'Можно установить зависимости командой: apt update && apt install -y python3 gnupg curl tar iproute2'
  read -r -p 'Установить стандартные зависимости? [да/нет]: ' answer
  if [[ $answer == да ]]; then
    command -v apt-get >/dev/null || { echo 'На этом сервере нет apt-get.'; return 1; }
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y python3 gnupg curl tar iproute2 || return 1
    for c in "$@"; do command -v "$c" >/dev/null || return 1; done
  else return 1; fi
 fi
}
while true; do
 cat <<'MENU'

╔══════════════════════════════════════════════════╗
║        3x-ui Migration Manager v2.2              ║
║          Управление переносом VPS                ║
╠══════════════════════════════════════════════════╣
║  1. Создать зашифрованную резервную копию        ║
║  2. Восстановить конфигурацию на НОВОМ VPS        ║
║  3. Проверить сервер, IP, DNS и сертификаты      ║
║  4. Посмотреть подготовленную конфигурацию Nginx ║
║  5. Применить Nginx (с подтверждением)           ║
║  6. Где инструкция и резервные копии             ║
║  0. Выход                                        ║
╚══════════════════════════════════════════════════╝
MENU
 read -r -p 'Выберите пункт [0–6]: ' CHOICE || break
 case "$CHOICE" in
  1)
   if need_cmds python3 tar gpg ip; then
    echo 'Будет создан ЛОКАЛЬНЫЙ зашифрованный архив с ключами и клиентами.'
    bash "$DIR/backup.sh" || echo 'Резервное копирование завершилось с ошибкой.'
   fi
   pause;;
  2)
   echo 'ВНИМАНИЕ: восстановление допускается ТОЛЬКО на новом/пустом VPS!'
   echo 'Не запускайте восстановление на рабочем VPS с существующими подключениями.'
   if need_cmds python3 gpg tar curl ip systemctl; then
    read -r -p 'Путь к зашифрованному архиву на НОВОМ VPS: ' ARCHIVE
    if [[ -f $ARCHIVE && $ARCHIVE == *.gpg ]]; then
      bash "$DIR/restore.sh" "$ARCHIVE" --same-domain || echo 'Восстановление не выполнено.'
    else
      echo 'Не найден файл .gpg. Сначала скопируйте архив на новый VPS по SFTP/SCP.'
    fi
   fi
   pause;;
  3) bash "$DIR/check.sh" || true; pause;;
  4)
   STAGE=/root/3xui-migration-staged/nginx
   if [[ -d $STAGE ]]; then
     echo "Подготовленная конфигурация: $STAGE"
     find "$STAGE" -maxdepth 3 -type f -printf '%P\n' | head -100
     echo 'Файлы не активированы. Перед включением проверьте пути сертификатов и proxy_pass.'
   else echo 'Подготовленной конфигурации Nginx нет (пока не проводилось восстановление).'; fi
   pause;;
  5) bash "$DIR/apply-nginx.sh" || echo 'Nginx не был применён.'; pause;;
  6)
   echo "Инструкция: $DIR/README.md"
   echo 'Архивы резервных копий по умолчанию: /root/3xui-backup-*.tar.gz.gpg'
   echo 'После скачивания держите архивы вне VPS. Не публикуйте их на GitHub.'
   pause;;
  0) echo 'Выход.'; exit 0;;
  *) echo 'Неизвестный пункт меню.';;
 esac
done
