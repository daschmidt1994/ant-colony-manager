#!/usr/bin/env sh
# Creates .env from .env.example and fills in the public address.
#   ./scripts/init-env.sh                       → http://<IP dieses Rechners>:8080
#   ./scripts/init-env.sh https://ants.example.com   → Internet-Betrieb mit Caddy
. "$(dirname -- "$0")/lib.sh"

[ -f .env ] && die ".env existiert bereits – nichts überschrieben"
url=${1:-}
if [ -z "$url" ]; then
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1)
  [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$ip" ] || ip=127.0.0.1
  url="http://$ip:8080"
fi
case "$url" in
  https://*.*)
    host=$(echo "$url" | sed -E 's#https://([^/:]+).*#\1#')
    cp .env.production.example .env
    sed -i "s#^ACM_DOMAIN=.*#ACM_DOMAIN=$host#" .env
    case "$host" in *.home.arpa|*.lan|*.local|*.internal) sed -i 's#^ACM_TLS_MODE=.*#ACM_TLS_MODE=internal#' .env ;; esac
    ;;
  http://*) cp .env.example .env ;;
  *) die "Adresse muss mit http:// oder https:// beginnen" ;;
esac
sed -i "s#^PUBLIC_APP_URL=.*#PUBLIC_APP_URL=$url#" .env
if [ "$(id -u)" != 0 ]; then
  sed -i "s#^PUID=.*#PUID=$(id -u)#; s#^PGID=.*#PGID=$(id -g)#" .env
fi
chmod 600 .env
say ".env erstellt – öffentliche Adresse: $url"
echo "Secrets werden beim ersten Start automatisch erzeugt (data/secrets/)."
echo "Weiter mit: docker compose up -d"
