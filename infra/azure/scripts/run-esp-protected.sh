#!/bin/sh
set -eu
umask 077

INSTALLER='/opt/esp/install/install-esp.sh'

if [ "$(id -u)" -ne 0 ]; then
    echo 'FAIL: protected ESP deployment wrapper must run as root' >&2
    exit 1
fi

echo 'Waiting for ESP installer to become available...'

attempt=1
while [ "$attempt" -le 120 ]; do
    if [ -x "$INSTALLER" ]; then
        echo 'PASS: ESP installer is available'
        break
    fi

    if [ "$attempt" -eq 120 ]; then
        echo 'FAIL: ESP installer did not become available within 20 minutes' >&2
        exit 1
    fi

    sleep 10
    attempt=$((attempt + 1))
done

decode() {
    printf '%s' "$1" | base64 --decode
}

export ESP_ARTIFACT_URL="$(decode '__ESP_ARTIFACT_URL_B64__')"
export ESP_ARTIFACT_SHA256="$(decode '__ESP_ARTIFACT_SHA256_B64__')"
export ESP_FQDN="$(decode '__ESP_FQDN_B64__')"
export ESP_CERTIFICATE_EMAIL="$(decode '__ESP_CERTIFICATE_EMAIL_B64__')"
export ESP_ADMIN_USER="$(decode '__ESP_ADMIN_USER_B64__')"
export ESP_ADMIN_PASSWORD="$(decode '__ESP_ADMIN_PASSWORD_B64__')"
export ESP_DATABASE_CREDENTIAL_MODE="$(decode '__ESP_DATABASE_CREDENTIAL_MODE_B64__')"
export ESP_DATABASE_USER="$(decode '__ESP_DATABASE_USER_B64__')"
export ESP_DATABASE_PASSWORD="$(decode '__ESP_DATABASE_PASSWORD_B64__')"
export ESP_DATABASE_ROOT_PASSWORD="$(decode '__ESP_DATABASE_ROOT_PASSWORD_B64__')"

"$INSTALLER"

unset ESP_ADMIN_PASSWORD
unset ESP_DATABASE_PASSWORD
unset ESP_DATABASE_ROOT_PASSWORD
