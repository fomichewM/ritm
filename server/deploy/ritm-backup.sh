#!/bin/sh
# Ночной дамп базы ritm, хранится 14 дней.
set -eu
D=/var/backups/ritm
install -d -m 700 -o postgres -g postgres "$D"
F="$D/ritm_$(date -u +%Y%m%dT%H%M%SZ).dump"
runuser -u postgres -- pg_dump -Fc ritm > "$F.tmp"
mv "$F.tmp" "$F"; chmod 600 "$F"
find "$D" -name 'ritm_*.dump' -mtime +14 -delete
