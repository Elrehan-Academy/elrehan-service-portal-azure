#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage:
  deploy-esp-application.sh \
    --host <public-ip-or-fqdn> \
    --fqdn <public-esp-fqdn> \
    --package <esp-deployment.tar.gz> \
    [--user azureuser] \
    [--identity ~/.ssh/id_ed25519]

The script:
  - verifies the deployment package checksum
  - waits for the Azure host bootstrap
  - transfers the package over SSH
  - creates protected ESP runtime secrets
  - builds and starts ESP with Docker Compose
  - validates container health and HTTP
USAGE
}

HOST=''
FQDN=''
REMOTE_USER='azureuser'
IDENTITY="$HOME/.ssh/id_ed25519"
PACKAGE=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:?missing --host value}"
      shift 2
      ;;
    --fqdn)
      FQDN="${2:?missing --fqdn value}"
      shift 2
      ;;
    --user)
      REMOTE_USER="${2:?missing --user value}"
      shift 2
      ;;
    --identity)
      IDENTITY="${2:?missing --identity value}"
      shift 2
      ;;
    --package)
      PACKAGE="${2:?missing --package value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$HOST" ]] || {
  echo 'FAIL: --host is required' >&2
  exit 2
}

[[ -n "$FQDN" ]] || {
  echo 'FAIL: --fqdn is required' >&2
  exit 2
}

if [[ ! "$FQDN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo 'FAIL: --fqdn contains invalid characters' >&2
  exit 2
fi

if [[ "$FQDN" != *.* ]]; then
  echo 'FAIL: --fqdn must be a fully qualified domain name' >&2
  exit 2
fi

[[ -s "$PACKAGE" ]] || {
  echo 'FAIL: --package must reference an existing non-empty file' >&2
  exit 2
}

[[ -s "$IDENTITY" ]] || {
  echo 'FAIL: SSH identity is unavailable' >&2
  exit 2
}

CHECKSUM="${PACKAGE}.sha256"

[[ -s "$CHECKSUM" ]] || {
  echo "FAIL: missing package checksum: $CHECKSUM" >&2
  exit 1
}

PACKAGE_DIR="$(cd "$(dirname "$PACKAGE")" && pwd)"
PACKAGE_NAME="$(basename "$PACKAGE")"

(
  cd "$PACKAGE_DIR"
  sha256sum -c "$(basename "$CHECKSUM")"
)

SSH_OPTS=(
  -i "$IDENTITY"
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
)

REMOTE="${REMOTE_USER}@${HOST}"

echo 'Waiting for SSH...'

for attempt in $(seq 1 60); do
  if ssh "${SSH_OPTS[@]}" "$REMOTE" true 2>/dev/null; then
    echo 'PASS: SSH available'
    break
  fi

  if [[ "$attempt" -eq 60 ]]; then
    echo 'FAIL: SSH did not become available' >&2
    exit 1
  fi

  sleep 10
done

echo 'Waiting for host bootstrap...'

for attempt in $(seq 1 90); do
  STATUS="$(
    ssh "${SSH_OPTS[@]}" "$REMOTE" \
      "sudo awk -F= '/^status=/{print \$2}' /var/lib/esp/bootstrap-status.txt 2>/dev/null || true"
  )"

  case "$STATUS" in
    ready)
      echo 'PASS: host bootstrap ready'
      break
      ;;
    failed)
      echo 'FAIL: Azure host bootstrap reported failure' >&2
      exit 1
      ;;
  esac

  if [[ "$attempt" -eq 90 ]]; then
    echo 'FAIL: host bootstrap did not reach ready state' >&2
    exit 1
  fi

  sleep 10
done

echo 'Checking for an existing ESP deployment...'

if ssh "${SSH_OPTS[@]}" "$REMOTE" \
    'sudo test -s /opt/esp/config/esp.env'
then
  echo 'FAIL: existing ESP runtime configuration detected on target.' >&2
  echo 'Refusing to generate new credentials or overwrite the deployment.' >&2
  echo 'Use the documented upgrade/restore workflow for an initialized ESP host.' >&2
  exit 1
fi

echo 'PASS: target has no existing ESP runtime configuration'

echo 'Creating runtime secrets locally...'

DB_ROOT_PASSWORD="$(openssl rand -hex 24)"
ESP_DB_PASSWORD="$(openssl rand -hex 24)"
ESP_ADMIN_PASSWORD="$(openssl rand -hex 24)"

ENV_FILE="$(mktemp)"

cleanup() {
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

cat > "$ENV_FILE" <<ENV
ITOP_VERSION=3.3.0-21411
ESP_IMAGE=local/esp:3.3.0-21411
ESP_BIND_ADDRESS=127.0.0.1
ESP_HTTP_PORT=8080
ESP_URL=https://${FQDN}/
ESP_DB_NAME=itop
ESP_DB_USER=itop
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
ESP_DB_PASSWORD=${ESP_DB_PASSWORD}
ESP_ADMIN_USER=admin
ESP_ADMIN_PASSWORD=${ESP_ADMIN_PASSWORD}
ENV

chmod 0600 "$ENV_FILE"

REMOTE_PACKAGE="/tmp/${PACKAGE_NAME}"
REMOTE_ENV='/tmp/esp-runtime.env'

echo 'Transferring deployment payload...'

scp "${SSH_OPTS[@]}" \
  "$PACKAGE" \
  "$REMOTE:$REMOTE_PACKAGE"

scp "${SSH_OPTS[@]}" \
  "$ENV_FILE" \
  "$REMOTE:$REMOTE_ENV"

echo 'Installing ESP application...'

ssh "${SSH_OPTS[@]}" "$REMOTE" \
  "REMOTE_PACKAGE='$REMOTE_PACKAGE' REMOTE_ENV='$REMOTE_ENV' bash -s" <<'REMOTE'
set -Eeuo pipefail

APP_ROOT='/opt/esp/app'
ENV_TARGET='/opt/esp/config/esp.env'

sudo install -d -m 0750 -o root -g root \
  /opt/esp/app \
  /opt/esp/config \
  /opt/esp/evidence

sudo rm -rf "${APP_ROOT:?}/"*

sudo tar \
  -xzf "$REMOTE_PACKAGE" \
  --strip-components=1 \
  -C "$APP_ROOT"

sudo install \
  -m 0600 \
  -o root \
  -g root \
  "$REMOTE_ENV" \
  "$ENV_TARGET"

sudo rm -f "$REMOTE_PACKAGE" "$REMOTE_ENV"

sudo bash -c '
cd /opt/esp/app

docker compose \
  --env-file /opt/esp/config/esp.env \
  build

docker compose \
  --env-file /opt/esp/config/esp.env \
  up -d
'

echo 'Waiting for ESP container health...'

for attempt in $(seq 1 90); do
  WEB_ID="$(
    sudo docker compose \
      --project-directory "$APP_ROOT" \
      -f "$APP_ROOT/compose.yaml" \
      --env-file "$ENV_TARGET" \
      ps -q web
  )"

  if [[ -n "$WEB_ID" ]]; then
    HEALTH="$(
      sudo docker inspect \
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
        sudo docker compose \
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
    sudo docker compose \
      --project-directory "$APP_ROOT" \
      -f "$APP_ROOT/compose.yaml" \
      --env-file "$ENV_TARGET" \
      ps >&2
    exit 1
  fi

  sleep 10
done

HTTP_CODE="$(
  curl \
    -sS \
    -L \
    -o /tmp/esp-http-response \
    -w '%{http_code}' \
    http://127.0.0.1:8080/
)"

if [[ "$HTTP_CODE" != '200' ]]; then
  echo "FAIL: ESP HTTP status=$HTTP_CODE" >&2
  exit 1
fi

TABLE_COUNT="$(
  sudo docker compose \
    --project-directory "$APP_ROOT" \
    -f "$APP_ROOT/compose.yaml" \
    --env-file "$ENV_TARGET" \
    exec -T db \
    mariadb \
      -uitop \
      "-p$(sudo awk -F= '/^ESP_DB_PASSWORD=/{print $2}' "$ENV_TARGET")" \
      itop \
      -Nse \
      "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='itop';"
)"

cat <<EVIDENCE | sudo tee /opt/esp/evidence/application.txt >/dev/null
validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
http_status=${HTTP_CODE}
database_tables=${TABLE_COUNT}
web_health=healthy
EVIDENCE

echo "HTTP status: $HTTP_CODE"
echo "Database tables: $TABLE_COUNT"
echo 'PASS: ESP application validation completed'
REMOTE

echo
echo '============================================'
echo 'ESP APPLICATION DEPLOYMENT COMPLETE'
echo '============================================'
