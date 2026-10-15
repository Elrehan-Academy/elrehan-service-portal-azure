#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  configure-esp-https.sh \
    --host <public-ip-or-host> \
    --fqdn <fqdn> \
    --email <letsencrypt-email> \
    [--user azureuser] \
    [--identity ~/.ssh/id_ed25519]

Configures the ESP Azure host with:
  - Nginx reverse proxy
  - Let's Encrypt certificate
  - HTTP to HTTPS redirect
  - Certbot automatic renewal
  - Nginx renewal deploy hook
  - HTTPS acceptance evidence

ESP remains bound to 127.0.0.1:8080.
EOF
}

HOST=""
FQDN=""
EMAIL=""
SSH_USER="azureuser"
IDENTITY="$HOME/.ssh/id_ed25519"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            HOST="${2:?missing --host value}"
            shift 2
            ;;
        --fqdn)
            FQDN="${2:?missing --fqdn value}"
            shift 2
            ;;
        --email)
            EMAIL="${2:?missing --email value}"
            shift 2
            ;;
        --user)
            SSH_USER="${2:?missing --user value}"
            shift 2
            ;;
        --identity)
            IDENTITY="${2:?missing --identity value}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "FAIL: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$HOST" || -z "$FQDN" || -z "$EMAIL" ]]; then
    echo 'FAIL: --host, --fqdn and --email are required.' >&2
    usage >&2
    exit 1
fi

if [[ ! -s "$IDENTITY" ]]; then
    echo "FAIL: SSH identity not found: $IDENTITY" >&2
    exit 1
fi

if [[ ! "$FQDN" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo 'FAIL: invalid FQDN.' >&2
    exit 1
fi

if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo 'FAIL: invalid email address.' >&2
    exit 1
fi

SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
    -i "$IDENTITY"
)

REMOTE="${SSH_USER}@${HOST}"

echo '=== ESP HTTPS CONFIGURATION ==='
echo "host=$HOST"
echo "fqdn=$FQDN"

echo
echo '--- 1. Verify target ---'

ssh "${SSH_OPTS[@]}" "$REMOTE" \
    "sudo grep -qx 'status=ready' /var/lib/esp/bootstrap-status.txt &&
     sudo test -s /opt/esp/config/esp.env &&
     sudo docker inspect --format '{{.State.Health.Status}}' esp-web-1 |
       grep -qx healthy"

echo 'PASS: ESP bootstrap, runtime configuration and healthy web container verified'

echo
echo '--- 2. Configure Nginx and Certbot ---'

ssh "${SSH_OPTS[@]}" "$REMOTE" \
    "sudo bash -s -- '$FQDN' '$EMAIL'" <<'REMOTE'
set -Eeuo pipefail

FQDN="$1"
EMAIL="$2"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y nginx certbot python3-certbot-nginx

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
    }
}
NGINX

ln -sfn /etc/nginx/sites-available/esp.conf \
    /etc/nginx/sites-enabled/esp.conf

rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx

HTTP_STATUS="$(
    curl -L \
      -sS \
      -o /dev/null \
      -w '%{http_code}' \
      -H "Host: ${FQDN}" \
      http://127.0.0.1/
)"

if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "FAIL: Nginx HTTP proxy validation returned ${HTTP_STATUS}" >&2
    exit 1
fi

CERT_LIVE_DIR="/etc/letsencrypt/live/${FQDN}"
CERT_RENEWAL="/etc/letsencrypt/renewal/${FQDN}.conf"

if [[ -s "${CERT_LIVE_DIR}/cert.pem" &&
      -s "${CERT_LIVE_DIR}/privkey.pem" &&
      -s "$CERT_RENEWAL" ]]; then

    echo "PASS: existing certificate found for ${FQDN}; reusing it"

    if ! openssl x509         -checkend 86400         -noout         -in "${CERT_LIVE_DIR}/cert.pem"
    then
        echo 'FAIL: existing certificate expires within 24 hours' >&2
        echo 'Use the documented renewal/recovery procedure before rerunning.' >&2
        exit 1
    fi

    # Re-apply the existing certificate to the regenerated HTTP-only
    # Nginx configuration without requesting a new certificate.
    certbot install         --cert-name "$FQDN"         --nginx         --redirect         --non-interactive
else
    echo "No existing certificate found for ${FQDN}; requesting one"

    certbot --nginx         --non-interactive         --agree-tos         --email "$EMAIL"         --redirect         -d "$FQDN"
fi

nginx -t

echo 'Configuring iTop public HTTPS identity...'

PUBLIC_URL="https://${FQDN}"

docker exec -i \
    -e ESP_PUBLIC_URL="$PUBLIC_URL" \
    esp-web-1 \
    sh -s <<'ITOP_CONFIG'
set -eu

CONFIG='/var/www/html/conf/production/config-itop.php'

if [ ! -f "$CONFIG" ]; then
    echo "FAIL: persistent iTop configuration not found" >&2
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

HTTPS_STATUS="$(
    curl -L \
      -sS \
      -o /dev/null \
      -w '%{http_code}' \
      "https://${FQDN}/"
)"

if [[ "$HTTPS_STATUS" != "200" ]]; then
    echo "FAIL: HTTPS validation returned ${HTTPS_STATUS}" >&2
    exit 1
fi

WEB_HEALTH="$(
    docker inspect \
      --format '{{.State.Health.Status}}' \
      esp-web-1
)"

DB_HEALTH="$(
    docker inspect \
      --format '{{.State.Health.Status}}' \
      esp-db-1
)"

LISTENER="$(
    ss -lnt |
      awk '$4 ~ /127\.0\.0\.1:8080$/ {print $4}' |
      head -n1
)"

CERT_EXPIRY="$(
    openssl x509 \
      -in "/etc/letsencrypt/live/${FQDN}/cert.pem" \
      -noout \
      -enddate |
      cut -d= -f2-
)"

cat > /opt/esp/evidence/https.txt <<EVIDENCE
validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fqdn=${FQDN}
https_status=${HTTPS_STATUS}
web_health=${WEB_HEALTH}
db_health=${DB_HEALTH}
esp_listener=${LISTENER}
certificate_expiry=${CERT_EXPIRY}
nginx=active
certbot_timer=$(systemctl is-active certbot.timer)
result=PASS
EVIDENCE

chmod 0644 /opt/esp/evidence/https.txt
REMOTE

echo
echo '--- 3. External HTTPS validation ---'

HTTPS_STATUS="$(
    curl -L \
      --connect-timeout 10 \
      --max-time 30 \
      -sS \
      -o /dev/null \
      -w '%{http_code}' \
      "https://${FQDN}/"
)"

echo "https_status=$HTTPS_STATUS"

test "$HTTPS_STATUS" = "200"

echo
echo 'PASS: ESP HTTPS configuration completed'
echo
echo 'NOTE: certificate renewal dry-run is a separate acceptance step.'
