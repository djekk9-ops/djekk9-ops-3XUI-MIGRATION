#!/usr/bin/env bash
# Read-only VPS checks. No secrets, token URLs or private key contents printed.
set -Eeuo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
echo '===== Проверка нового / текущего VPS ====='
if command -v python3 >/dev/null && [[ -f $DIR/hostinfo.py ]]; then
  python3 "$DIR/hostinfo.py" || true
fi
printf '\nDefault route:\n'
if command -v ip >/dev/null; then ip -4 route show default || true; fi
printf '\nСостояние служб:\n'
if command -v systemctl >/dev/null; then
 for s in x-ui nginx; do
  printf '%s: ' "$s"
  systemctl is-active "$s" 2>/dev/null || true
 done
fi
printf '\nИнтересующие порты (TCP и UDP):\n'
if command -v ss >/dev/null; then
 ss -lntup 2>/dev/null | awk 'NR==1 || $0 ~ /:(443|8443|16610|31085|31086|31087|31088)([^0-9]|$)/' | head -35
fi
DOMAIN=''
[[ -f /root/3xui-migration-staged/domain.txt ]] && DOMAIN=$(head -n1 /root/3xui-migration-staged/domain.txt)
if [[ -z $DOMAIN ]]; then
 read -r -p 'Введите домен для проверки DNS/TLS (Enter = пропустить): ' DOMAIN || true
fi
if [[ -n $DOMAIN ]]; then
 if [[ $DOMAIN =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]]; then
  echo "\nDNS IPv4 для $DOMAIN:"
  if command -v getent >/dev/null; then
    getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '$2=="STREAM"{print $1}' | sort -u || true
  fi
  CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  if [[ -f $CERT ]]; then
   echo "Сертификат существует: $CERT"
   command -v openssl >/dev/null && openssl x509 -in "$CERT" -noout -dates || true
  else echo 'Сертификат по стандартному пути отсутствует.'; fi
 else echo 'Пропущен некорректный домен.'; fi
fi
printf '\nВсе проверки только читают состояние. DNS и службы не изменялись.\n'
