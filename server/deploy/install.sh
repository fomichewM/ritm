#!/bin/sh
# Установка/обновление на VDS (запуск от root после rsync в /opt/ritm-api/app).
set -eu
cd /opt/ritm-api
chown -R ritm:ritm /opt/ritm-api/app
sudo -u ritm venv/bin/pip install -q -r app/requirements.txt
if [ ! -f .env ]; then
  umask 077
  { echo "RITM_DB_DSN=postgresql:///ritm"
    echo "RITM_JWT_SECRET=$(openssl rand -hex 48)"
    echo "RITM_BUNDLE_ID=com.oporagroup.ritm"
    echo "RITM_TEST_LOGIN=0"; } > .env
  chown ritm:ritm .env; chmod 600 .env
fi
# B6: пуши чата (APNs, ключ .p8 из кабинета Apple Developer — кладёт владелец):
#   RITM_APNS_KEY_PATH=/opt/ritm-api/apns.p8 (600, ritm), RITM_APNS_KEY_ID=…, RITM_APNS_TEAM_ID=…
# Без них чат работает, пуши не уходят (журнал в памяти процесса).
grep -q RITM_APNS_KEY_PATH .env || echo "# RITM_APNS_KEY_PATH= RITM_APNS_KEY_ID= RITM_APNS_TEAM_ID=" >> .env
install -m 644 app/deploy/ritm-api.service app/deploy/ritm-backup.service app/deploy/ritm-backup.timer /etc/systemd/system/
install -m 755 app/deploy/ritm-backup.sh /usr/local/sbin/ritm-backup.sh
systemctl daemon-reload
systemctl enable --now ritm-backup.timer
systemctl enable ritm-api
systemctl restart ritm-api
