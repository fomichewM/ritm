#!/bin/zsh
# «Ритм» B6: публичный снимок исходников (AGPL-3.0) — без личных данных.
# Делает чистую копию HEAD (без истории коммитов: в истории есть личные фикстуры),
# убирает личную выгрузку WHOOP, проверяет на секреты и личные данные.
# Использование: tool/ritm_public_snapshot.sh <папка>   (по умолчанию /tmp/ritm_public)
set -e
OUT=${1:-/tmp/ritm_public}
cd ~/WhoopRU/edge
rm -rf $OUT && mkdir -p $OUT
git archive HEAD | tar -x -C $OUT
cd $OUT
# 1) Личная выгрузка WHOOP Михаила (входы калибровки) — не публикуется.
rm -f test/fixtures/ritm_compare/recovery_whoop_inputs.json \
      test/fixtures/ritm_compare/sleep_whoop_inputs.json \
      test/fixtures/ritm_compare/need_whoop_60.json
# README форка — в корень (README.md апстрима остаётся как README_EDGE.md).
[ -f README.md ] && mv README.md README_EDGE.md
cp tool/ritm_public_README.md README.md
# 2) Проверка: секреты и личное. coach_config_key_test.dart — тест апстрима Edge с
#    заглушкой ключа (sk-…), не настоящий ключ.
fail=0
hits=$(grep -rIlE --exclude=ritm_public_snapshot.sh --exclude=coach_config_key_test.dart "BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[0-9A-Za-z-]{10,}" . || true)
[ -n "$hits" ] && { echo "СЕКРЕТЫ:"; echo "$hits"; fail=1; }
# Имя аккаунта GitHub в адресе публичного репозитория (github.com/fomichewM/ritm) — не утечка.
hits=$(grep -rIE --exclude=ritm_public_snapshot.sh "fomich|Фомич|@yandex\.ru|72\.56\.67\.48|2\.58\.124\.154|netangels_opora" . | grep -v "github\.com/fomichewM/ritm" | cut -d: -f1 | sort -u || true)
[ -n "$hits" ] && { echo "ЛИЧНОЕ:"; echo "$hits"; fail=1; }
hits=$(find . -name "*.p8" -o -name "*.pem" -o -name ".env" -o -name "*.mobileprovision" -o -name "*.p12" | head)
[ -n "$hits" ] && { echo "ФАЙЛЫ КЛЮЧЕЙ:"; echo "$hits"; fail=1; }
[ -n "$(find test/fixtures -name '*whoop_inputs*' -o -name 'need_whoop_*')" ] && { echo "ЛИЧНЫЕ ФИКСТУРЫ ОСТАЛИСЬ"; fail=1; }
echo "файлов: $(find . -type f | wc -l | tr -d ' '), размер: $(du -sh . | cut -f1)"
[ $fail = 0 ] && echo "ПРОВЕРКА: чисто" || { echo "ПРОВЕРКА: НЕ ЧИСТО — не публиковать"; exit 3; }
