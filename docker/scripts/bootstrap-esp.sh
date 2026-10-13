#!/bin/sh
set -eu

TEMPLATE="/opt/esp/setup/esp-install.xml.template"
RESPONSE="/tmp/esp-install.xml"
INSTALLER="/var/www/html/setup/unattended-install/unattended-install.php"
INSTALLATION_XML="/var/www/html/datamodels/2.x/installation.xml"
CONFIG="/var/www/html/conf/production/config-itop.php"

log() {
    printf '%s\n' "[ESP bootstrap] $*"
}

fail() {
    printf '%s\n' "[ESP bootstrap] ERROR: $*" >&2
    exit 1
}

cleanup() {
    rm -f "$RESPONSE"
}

trap cleanup EXIT INT TERM

for var in \
    ESP_DB_HOST \
    ESP_DB_USER \
    ESP_DB_PASSWORD \
    ESP_DB_NAME \
    ESP_URL \
    ESP_ADMIN_USER \
    ESP_ADMIN_PASSWORD
do
    eval "value=\${$var:-}"
    [ -n "$value" ] || fail "required environment variable $var is not set"
done

[ -f "$TEMPLATE" ] || fail "installation template not found"
[ -f "$INSTALLER" ] || fail "iTop unattended installer not found"
[ -f "$INSTALLATION_XML" ] || fail "iTop installation metadata not found"

if [ -f "$CONFIG" ]; then
    log "existing production configuration detected; installation skipped"
    exit 0
fi

log "waiting for MariaDB"

attempt=1
while [ "$attempt" -le 60 ]; do
    if MYSQL_PWD="$ESP_DB_PASSWORD" \
       mysql \
         --protocol=TCP \
         -h "$ESP_DB_HOST" \
         -u "$ESP_DB_USER" \
         "$ESP_DB_NAME" \
         -Nse 'SELECT 1' >/dev/null 2>&1
    then
        log "database connection successful"
        break
    fi

    if [ "$attempt" -eq 60 ]; then
        fail "database did not become ready"
    fi

    sleep 2
    attempt=$((attempt + 1))
done

log "generating protected unattended-install response"

export TEMPLATE RESPONSE
export ESP_DB_HOST ESP_DB_USER ESP_DB_PASSWORD ESP_DB_NAME
export ESP_URL ESP_ADMIN_USER ESP_ADMIN_PASSWORD

php <<'PHP'
<?php

$template = getenv('TEMPLATE');
$response = getenv('RESPONSE');

$content = file_get_contents($template);
if ($content === false) {
    fwrite(STDERR, "Unable to read ESP installation template\n");
    exit(1);
}

$values = [
    '__DB_HOST__'            => getenv('ESP_DB_HOST'),
    '__DB_USER__'            => getenv('ESP_DB_USER'),
    '__DB_PASSWORD__'        => getenv('ESP_DB_PASSWORD'),
    '__DB_NAME__'            => getenv('ESP_DB_NAME'),
    '__ESP_URL__'            => getenv('ESP_URL'),
    '__ESP_ADMIN_USER__'     => getenv('ESP_ADMIN_USER'),
    '__ESP_ADMIN_PASSWORD__' => getenv('ESP_ADMIN_PASSWORD'),
];

foreach ($values as $placeholder => $value) {
    $content = str_replace(
        $placeholder,
        htmlspecialchars($value, ENT_XML1 | ENT_QUOTES, 'UTF-8'),
        $content
    );
}

if (preg_match('/__[A-Z0-9_]+__/', $content)) {
    fwrite(STDERR, "Unresolved installation placeholder remains\n");
    exit(1);
}

libxml_use_internal_errors(true);
$xml = simplexml_load_string($content);

if ($xml === false) {
    fwrite(STDERR, "Generated installation XML is invalid\n");
    exit(1);
}

if (file_put_contents($response, $content) === false) {
    fwrite(STDERR, "Unable to write installation response\n");
    exit(1);
}

chmod($response, 0600);
PHP

[ -s "$RESPONSE" ] || fail "installation response was not generated"

chown www-data:www-data "$RESPONSE"
chmod 0600 "$RESPONSE"

log "running native iTop unattended installation as www-data"

su -s /bin/sh www-data -c \
    "php '$INSTALLER' --param-file='$RESPONSE' --installation_xml='$INSTALLATION_XML'"

[ -f "$CONFIG" ] || fail "production configuration was not created"

CONFIG_OWNER="$(stat -c '%U:%G' "$CONFIG")"
[ "$CONFIG_OWNER" = "www-data:www-data" ] \
    || fail "production configuration has unexpected ownership: $CONFIG_OWNER"

grep -q "'elrehan-service-portal'" \
    /var/www/html/env-production/autoload.php \
    || fail "ESP module was not compiled into production environment"

log "ESP unattended installation completed successfully"
log "temporary response file will be removed"
