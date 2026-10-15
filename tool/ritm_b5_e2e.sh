#!/bin/zsh
# «Ритм» B5: e2e «Сообщества» на ЛОКАЛЬНОЙ копии сервера (Mac): PostgreSQL 17
# во временном каталоге + FastAPI с RITM_TEST_LOGIN=1. Прод /opt/ritm-api не трогаем.
set -e
cd ~/WhoopRU
PG=/opt/homebrew/opt/postgresql@17/bin
export PATH=$HOME/development/flutter/bin:$PATH
$PG/pg_ctl -D ~/WhoopRU/ritm_pg status >/dev/null 2>&1 || $PG/pg_ctl -D ~/WhoopRU/ritm_pg -o "-p 54329 -k /tmp" -l ~/WhoopRU/ritm_pg.log start >/dev/null
sleep 1
$PG/dropdb -h /tmp -p 54329 -U ritm --if-exists ritm_e2e
$PG/createdb -h /tmp -p 54329 -U ritm ritm_e2e
export RITM_DB_DSN="postgresql://ritm@/ritm_e2e?host=/tmp&port=54329"
export RITM_JWT_SECRET=$(openssl rand -hex 32)
export RITM_TEST_LOGIN=1 RITM_BUNDLE_ID=com.oporagroup.ritm
cd ritm_server
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8199 > ~/WhoopRU/ritm_e2e_server.log 2>&1 &
SRV=$!
trap "kill $SRV 2>/dev/null" EXIT
for i in {1..30}; do curl -sf http://127.0.0.1:8199/health >/dev/null && break; sleep .5; done
echo "health: $(curl -s http://127.0.0.1:8199/health)"
cd ~/WhoopRU/edge
RITM_E2E=http://127.0.0.1:8199 flutter test --dart-define=RITM_TEST_LOGIN=true test/ritm_b5_e2e_test.dart 2>&1 | grep -vE "^\s*(package:|dart:)" | tail -25
echo "--- SQL: таблицы и столбцы базы (нет пульса/ВСР/ЭКГ/стресса/биовозраста) ---"
$PG/psql -h /tmp -p 54329 -U ritm -d ritm_e2e -Atc "select table_name||': '||string_agg(column_name||' '||data_type, ', ' order by ordinal_position) from information_schema.columns where table_schema='public' group by table_name order by 1"
echo "--- строк после e2e: users=$($PG/psql -h /tmp -p 54329 -U ritm -d ritm_e2e -Atc 'select count(*) from users where deleted_at is null') daily_summary=$($PG/psql -h /tmp -p 54329 -U ritm -d ritm_e2e -Atc 'select count(*) from daily_summary') ---"
