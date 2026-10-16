#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATUS_FILE='/var/lib/esp/deployment-status.txt'
BOOTSTRAP_STATUS_FILE='/var/lib/esp/bootstrap-status.txt'
ESP_ROOT='/opt/esp'
APP_ROOT="${ESP_ROOT}/app"
CONFIG_ROOT="${ESP_ROOT}/config"
EVIDENCE_ROOT="${ESP_ROOT}/evidence"

ARTIFACT_URL="${ESP_ARTIFACT_URL:-}"
ARTIFACT_SHA256="${ESP_ARTIFACT_SHA256:-}"

FQDN="${ESP_FQDN:-}"
CERTIFICATE_EMAIL="${ESP_CERTIFICATE_EMAIL:-}"
ADMIN_USER="${ESP_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ESP_ADMIN_PASSWORD:-}"
DB_CREDENTIAL_MODE="${ESP_DATABASE_CREDENTIAL_MODE:-generated}"
DB_USER="${ESP_DATABASE_USER:-itop}"
CUSTOM_DB_PASSWORD="${ESP_DATABASE_PASSWORD:-}"
CUSTOM_DB_ROOT_PASSWORD="${ESP_DATABASE_ROOT_PASSWORD:-}"

WORK_DIR=''

write_status() {
    local status="$1"

    install -d -m 0755 /var/lib/esp

    cat > "$STATUS_FILE" <<STATUS
status=${status}
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATUS

    chmod 0644 "$STATUS_FILE"
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

fail() {
    local rc=$?

    write_status failed
    echo "FAIL: ESP zero-touch deployment failed (exit=${rc})" >&2
    exit "$rc"
}

trap cleanup EXIT
trap fail ERR

write_status running

if [[ "$(id -u)" -ne 0 ]]; then
    echo 'FAIL: installer must run as root' >&2
    exit 1
fi

echo 'Waiting for ESP host bootstrap...'

for attempt in $(seq 1 90); do
    bootstrap_status="$(
        awk -F= '/^status=/{print $2}' \
            "$BOOTSTRAP_STATUS_FILE" 2>/dev/null || true
    )"

    case "$bootstrap_status" in
        ready)
            echo 'PASS: ESP host bootstrap ready'
            break
            ;;
        failed)
            echo 'FAIL: ESP host bootstrap reported failure' >&2
            exit 1
            ;;
    esac

    if [[ "$attempt" -eq 90 ]]; then
        echo 'FAIL: ESP host bootstrap did not reach ready state' >&2
        exit 1
    fi

    sleep 10
done

if [[ -z "$ARTIFACT_URL" ]]; then
    echo 'FAIL: ESP_ARTIFACT_URL is required' >&2
    exit 2
fi

if [[ ! "$ARTIFACT_URL" =~ ^https:// ]]; then
    echo 'FAIL: ESP_ARTIFACT_URL must use HTTPS' >&2
    exit 2
fi

if [[ ! "$ARTIFACT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'FAIL: ESP_ARTIFACT_SHA256 must be 64 lowercase hexadecimal characters' >&2
    exit 2
fi

if [[ -s "${CONFIG_ROOT}/esp.env" ]]; then
    echo 'FAIL: existing ESP runtime configuration detected.' >&2
    echo 'Refusing to overwrite an initialized ESP deployment.' >&2
    exit 1
fi

if [[ -z "$FQDN" || "$FQDN" != *.* ]]; then
    echo 'FAIL: ESP_FQDN must be a fully qualified domain name' >&2
    exit 2
fi

if [[ -z "$CERTIFICATE_EMAIL" ]]; then
    echo 'FAIL: ESP_CERTIFICATE_EMAIL is required' >&2
    exit 2
fi

if [[ "$CERTIFICATE_EMAIL" != *@*.* ]]; then
    echo 'FAIL: ESP_CERTIFICATE_EMAIL does not look like a valid email address' >&2
    exit 2
fi

if [[ -z "$ADMIN_USER" ]]; then
    echo 'FAIL: ESP_ADMIN_USER must not be empty' >&2
    exit 2
fi

if [[ -z "$ADMIN_PASSWORD" ]]; then
    echo 'FAIL: ESP_ADMIN_PASSWORD is required' >&2
    exit 2
fi

if [[ -z "$DB_USER" ]]; then
    echo 'FAIL: ESP_DATABASE_USER must not be empty' >&2
    exit 2
fi

case "$DB_CREDENTIAL_MODE" in
    generated)
        DB_PASSWORD="$(openssl rand -hex 24)"
        DB_ROOT_PASSWORD="$(openssl rand -hex 24)"
        ;;
    custom)
        if [[ -z "$CUSTOM_DB_PASSWORD" ]]; then
            echo 'FAIL: ESP_DATABASE_PASSWORD is required in custom mode' >&2
            exit 2
        fi

        if [[ -z "$CUSTOM_DB_ROOT_PASSWORD" ]]; then
            echo 'FAIL: ESP_DATABASE_ROOT_PASSWORD is required in custom mode' >&2
            exit 2
        fi

        DB_PASSWORD="$CUSTOM_DB_PASSWORD"
        DB_ROOT_PASSWORD="$CUSTOM_DB_ROOT_PASSWORD"
        ;;
    *)
        echo 'FAIL: ESP_DATABASE_CREDENTIAL_MODE must be generated or custom' >&2
        exit 2
        ;;
esac

install -d -m 0750 -o root -g root \
    "$APP_ROOT" \
    "$CONFIG_ROOT" \
    "$EVIDENCE_ROOT"

WORK_DIR="$(mktemp -d /tmp/esp-install.XXXXXX)"
chmod 0700 "$WORK_DIR"

ARTIFACT="${WORK_DIR}/esp-deployment.tar.gz"

echo 'Downloading immutable ESP deployment artifact...'

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 600 \
    --output "$ARTIFACT" \
    "$ARTIFACT_URL"

test -s "$ARTIFACT"

ACTUAL_SHA256="$(sha256sum "$ARTIFACT" | awk '{print $1}')"

if [[ "$ACTUAL_SHA256" != "$ARTIFACT_SHA256" ]]; then
    echo 'FAIL: ESP deployment artifact SHA256 mismatch' >&2
    exit 1
fi

echo 'PASS: ESP deployment artifact SHA256 verified'

echo 'Validating deployment archive...'

tar -tzf "$ARTIFACT" >/dev/null

if ! tar -xOzf "$ARTIFACT" esp/compose.yaml >/dev/null; then
    echo 'FAIL: deployment archive does not contain readable esp/compose.yaml' >&2
    exit 1
fi

echo 'PASS: ESP deployment archive validated'

echo 'Extracting ESP deployment artifact...'

rm -rf "${APP_ROOT:?}/"*

tar \
    -xzf "$ARTIFACT" \
    --strip-components=1 \
    -C "$APP_ROOT"

test -s "${APP_ROOT}/compose.yaml"
test -d "${APP_ROOT}/docker"

ENV_TARGET="${CONFIG_ROOT}/esp.env"

cat > "$ENV_TARGET" <<ENV
ITOP_VERSION=3.3.0-21411
ESP_IMAGE=local/esp:3.3.0-21411
ESP_BIND_ADDRESS=127.0.0.1
ESP_HTTP_PORT=8080
ESP_URL=https://${FQDN}/
ESP_DB_NAME=itop
ESP_DB_USER=${DB_USER}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
ESP_DB_PASSWORD=${DB_PASSWORD}
ESP_ADMIN_USER=${ADMIN_USER}
ESP_ADMIN_PASSWORD=${ADMIN_PASSWORD}
ENV

chown root:root "$ENV_TARGET"
chmod 0600 "$ENV_TARGET"

# Retain only the generated/custom application DB password in process memory
# for the local database acceptance query. It is never printed or persisted
# outside the protected runtime environment.
ESP_DB_PASSWORD_VALUE="$DB_PASSWORD"

# Remove secret values inherited through the installer environment as soon
# as the protected runtime configuration has been created.
unset ADMIN_PASSWORD
unset CUSTOM_DB_PASSWORD
unset CUSTOM_DB_ROOT_PASSWORD
unset DB_PASSWORD
unset DB_ROOT_PASSWORD

cat > "${EVIDENCE_ROOT}/artifact.txt" <<EVIDENCE
validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
artifact_sha256=${ACTUAL_SHA256}
archive_root=esp
compose_file=present
result=PASS
EVIDENCE

chmod 0644 "${EVIDENCE_ROOT}/artifact.txt"

write_status artifact_ready

echo 'PASS: ESP immutable artifact prepared successfully.'

echo 'Building ESP application image...'

cd "$APP_ROOT"

docker compose \
    --env-file "$ENV_TARGET" \
    build

echo 'Starting ESP application...'

docker compose \
    --env-file "$ENV_TARGET" \
    up -d

write_status application_starting

echo 'Waiting for ESP web container health...'

for attempt in $(seq 1 90); do
    WEB_ID="$(
        docker compose \
            --project-directory "$APP_ROOT" \
            -f "$APP_ROOT/compose.yaml" \
            --env-file "$ENV_TARGET" \
            ps -q web
    )"

    if [[ -n "$WEB_ID" ]]; then
        HEALTH="$(
            docker inspect \
                --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
                "$WEB_ID"
        )"

        case "$HEALTH" in
            healthy)
                echo 'PASS: ESP web container healthy'
                break
                ;;
            unhealthy|exited|dead)
                echo "FAIL: ESP web state=$HEALTH" >&2
                docker compose \
                    --project-directory "$APP_ROOT" \
                    -f "$APP_ROOT/compose.yaml" \
                    --env-file "$ENV_TARGET" \
                    ps >&2
                exit 1
                ;;
        esac
    fi

    if [[ "$attempt" -eq 90 ]]; then
        echo 'FAIL: ESP web container did not become healthy' >&2
        docker compose \
            --project-directory "$APP_ROOT" \
            -f "$APP_ROOT/compose.yaml" \
            --env-file "$ENV_TARGET" \
            ps >&2
        exit 1
    fi

    sleep 10
done

echo 'Validating ESP local HTTP endpoint...'

HTTP_CODE="$(
    curl \
        --silent \
        --show-error \
        --location \
        --output /tmp/esp-http-response \
        --write-out '%{http_code}' \
        http://127.0.0.1:8080/
)"

if [[ "$HTTP_CODE" != '200' ]]; then
    echo "FAIL: ESP HTTP status=$HTTP_CODE" >&2
    exit 1
fi

rm -f /tmp/esp-http-response

echo 'Validating ESP database...'

TABLE_COUNT="$(
    docker compose \
        --project-directory "$APP_ROOT" \
        -f "$APP_ROOT/compose.yaml" \
        --env-file "$ENV_TARGET" \
        exec -T db \
        mariadb \
            "-u${DB_USER}" \
            "-p${ESP_DB_PASSWORD_VALUE}" \
            itop \
            -Nse \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='itop';"
)"

if [[ ! "$TABLE_COUNT" =~ ^[0-9]+$ ]]; then
    echo 'FAIL: ESP database table count is not numeric' >&2
    exit 1
fi

if [[ "$TABLE_COUNT" -lt 1 ]]; then
    echo 'FAIL: ESP database contains no application tables' >&2
    exit 1
fi

# Database acceptance is complete; remove the temporary in-memory copy.
unset ESP_DB_PASSWORD_VALUE

cat > "${EVIDENCE_ROOT}/application.txt" <<EVIDENCE
validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
http_status=${HTTP_CODE}
database_tables=${TABLE_COUNT}
web_health=healthy
result=PASS
EVIDENCE

chmod 0644 "${EVIDENCE_ROOT}/application.txt"

write_status application_ready

echo "HTTP status: $HTTP_CODE"
echo "Database tables: $TABLE_COUNT"
echo 'PASS: ESP application validation completed'

write_status https_configuring

echo 'Installing Nginx and Certbot...'

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y nginx certbot python3-certbot-nginx

echo 'Configuring ESP Nginx reverse proxy...'

cat > /etc/nginx/sites-available/esp.conf <<NGINX
server {
    listen 80;
    listen [::]:80;

    server_name ${FQDN};

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port 443;
    }
}
NGINX

ln -sfn /etc/nginx/sites-available/esp.conf \
    /etc/nginx/sites-enabled/esp.conf

rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx

HTTP_PROXY_STATUS="$(
    curl \
        --location \
        --silent \
        --show-error \
        --output /dev/null \
        --write-out '%{http_code}' \
        -H "Host: ${FQDN}" \
        http://127.0.0.1/
)"

if [[ "$HTTP_PROXY_STATUS" != '200' ]]; then
    echo "FAIL: Nginx HTTP proxy validation returned ${HTTP_PROXY_STATUS}" >&2
    exit 1
fi

echo 'PASS: ESP Nginx HTTP proxy validated'

CERT_LIVE_DIR="/etc/letsencrypt/live/${FQDN}"
CERT_RENEWAL="/etc/letsencrypt/renewal/${FQDN}.conf"

if [[ -s "${CERT_LIVE_DIR}/cert.pem" &&
      -s "${CERT_LIVE_DIR}/privkey.pem" &&
      -s "$CERT_RENEWAL" ]]; then

    echo "PASS: existing certificate found for ${FQDN}; reusing it"

    if ! openssl x509 \
        -checkend 86400 \
        -noout \
        -in "${CERT_LIVE_DIR}/cert.pem"
    then
        echo 'FAIL: existing certificate expires within 24 hours' >&2
        exit 1
    fi

    certbot install \
        --cert-name "$FQDN" \
        --nginx \
        --redirect \
        --non-interactive
else
    echo "Requesting Let's Encrypt certificate for ${FQDN}..."

    certbot \
        --nginx \
        --non-interactive \
        --agree-tos \
        --email "$CERTIFICATE_EMAIL" \
        --redirect \
        -d "$FQDN"
fi

nginx -t

echo 'Configuring iTop public HTTPS identity...'

PUBLIC_URL="https://${FQDN}/"

WEB_ID="$(
    docker compose \
        --project-directory "$APP_ROOT" \
        -f "$APP_ROOT/compose.yaml" \
        --env-file "$ENV_TARGET" \
        ps -q web
)"

if [[ -z "$WEB_ID" ]]; then
    echo 'FAIL: ESP web container is unavailable for HTTPS configuration' >&2
    exit 1
fi

docker exec -i \
    -e ESP_PUBLIC_URL="$PUBLIC_URL" \
    "$WEB_ID" \
    sh -s <<'ITOP_CONFIG'
set -eu

CONFIG='/var/www/html/conf/production/config-itop.php'

if [ ! -f "$CONFIG" ]; then
    echo 'FAIL: persistent iTop configuration not found' >&2
    exit 1
fi

if grep -Fq "'app_root_url' => '${ESP_PUBLIC_URL}'" "$CONFIG" &&
   grep -Eq "'behind_reverse_proxy'[[:space:]]*=>[[:space:]]*true" "$CONFIG"
then
    echo 'PASS: iTop public HTTPS identity already configured'
else
    CONFIG_BACKUP="${CONFIG}.pre-https-$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a "$CONFIG" "$CONFIG_BACKUP"

    chmod 0640 "$CONFIG"

    php -r '
$config = $argv[1];
$url = getenv("ESP_PUBLIC_URL");

$content = file_get_contents($config);

if ($content === false || $url === false || $url === "") {
    fwrite(STDERR, "FAIL: unable to load iTop configuration inputs\n");
    exit(1);
}

$currentUrlPattern =
    "/\x27app_root_url\x27\s*=>\s*\x27[^\x27]*\x27/";

$currentProxyPattern =
    "/\x27behind_reverse_proxy\x27\s*=>\s*(?:true|false)/";

if (preg_match_all($currentUrlPattern, $content) !== 1) {
    fwrite(STDERR, "FAIL: app_root_url occurrence mismatch\n");
    exit(1);
}

if (preg_match_all($currentProxyPattern, $content) !== 1) {
    fwrite(STDERR, "FAIL: behind_reverse_proxy occurrence mismatch\n");
    exit(1);
}

$newUrl =
    "\x27app_root_url\x27 => " . var_export($url, true);

$newProxy =
    "\x27behind_reverse_proxy\x27 => true";

$content = preg_replace(
    $currentUrlPattern,
    $newUrl,
    $content,
    1,
    $urlCount
);

$content = preg_replace(
    $currentProxyPattern,
    $newProxy,
    $content,
    1,
    $proxyCount
);

if ($urlCount !== 1 || $proxyCount !== 1) {
    fwrite(STDERR, "FAIL: iTop identity replacement count mismatch\n");
    exit(1);
}

if (file_put_contents($config, $content) === false) {
    fwrite(STDERR, "FAIL: unable to update iTop configuration\n");
    exit(1);
}
' "$CONFIG"

    chown www-data:www-data "$CONFIG"
    chmod 0440 "$CONFIG"
fi

php -l "$CONFIG" >/dev/null

grep -Fq "'app_root_url' => '${ESP_PUBLIC_URL}'" "$CONFIG"
grep -Eq "'behind_reverse_proxy'[[:space:]]*=>[[:space:]]*true" "$CONFIG"

echo 'PASS: iTop public HTTPS identity configured'
ITOP_CONFIG

install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail

/usr/sbin/nginx -t
/bin/systemctl reload nginx
HOOK

chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

systemctl enable --now certbot.timer

echo 'Validating ESP HTTPS endpoint...'

HTTPS_STATUS="$(
    curl \
        --location \
        --silent \
        --show-error \
        --output /dev/null \
        --write-out '%{http_code}' \
        "https://${FQDN}/"
)"

if [[ "$HTTPS_STATUS" != '200' ]]; then
    echo "FAIL: HTTPS validation returned ${HTTPS_STATUS}" >&2
    exit 1
fi

WEB_ID="$(
    docker compose \
        --project-directory "$APP_ROOT" \
        -f "$APP_ROOT/compose.yaml" \
        --env-file "$ENV_TARGET" \
        ps -q web
)"

DB_ID="$(
    docker compose \
        --project-directory "$APP_ROOT" \
        -f "$APP_ROOT/compose.yaml" \
        --env-file "$ENV_TARGET" \
        ps -q db
)"

if [[ -z "$WEB_ID" || -z "$DB_ID" ]]; then
    echo 'FAIL: ESP containers unavailable during HTTPS validation' >&2
    exit 1
fi

WEB_HEALTH="$(
    docker inspect \
        --format '{{.State.Health.Status}}' \
        "$WEB_ID"
)"

DB_HEALTH="$(
    docker inspect \
        --format '{{.State.Health.Status}}' \
        "$DB_ID"
)"

if [[ "$WEB_HEALTH" != 'healthy' ]]; then
    echo "FAIL: ESP web health after HTTPS configuration=${WEB_HEALTH}" >&2
    exit 1
fi

if [[ "$DB_HEALTH" != 'healthy' ]]; then
    echo "FAIL: ESP database health after HTTPS configuration=${DB_HEALTH}" >&2
    exit 1
fi

LISTENER="$(
    ss -lnt |
        awk '$4 ~ /127\.0\.0\.1:8080$/ {print $4}' |
        head -n1
)"

if [[ "$LISTENER" != '127.0.0.1:8080' ]]; then
    echo "FAIL: ESP application listener is not restricted to localhost" >&2
    exit 1
fi

CERT_EXPIRY="$(
    openssl x509 \
        -in "/etc/letsencrypt/live/${FQDN}/cert.pem" \
        -noout \
        -enddate |
        cut -d= -f2-
)"

cat > "${EVIDENCE_ROOT}/https.txt" <<EVIDENCE
validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fqdn=${FQDN}
https_status=${HTTPS_STATUS}
web_health=${WEB_HEALTH}
db_health=${DB_HEALTH}
esp_listener=${LISTENER}
certificate_expiry=${CERT_EXPIRY}
nginx=$(systemctl is-active nginx)
certbot_timer=$(systemctl is-active certbot.timer)
result=PASS
EVIDENCE

chmod 0644 "${EVIDENCE_ROOT}/https.txt"

write_status ready

echo "ESP URL: https://${FQDN}/"
echo 'PASS: ESP zero-touch deployment completed successfully.'
