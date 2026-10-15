#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
    cat <<'USAGE'
Usage:
  restore-esp.sh --project PROJECT --backup BACKUP_DIR --confirm-restore

Restores an ESP backup into an existing disposable target Compose project.

Safety:
  - PROJECT is mandatory.
  - BACKUP_DIR is mandatory.
  - --confirm-restore is mandatory.
  - Restore to the source project recorded in the backup is refused.
  - Docker volumes are never deleted by this script.
USAGE
}

fail() {
    printf '[ESP restore] ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[ESP restore] %s\n' "$*"
}

PROJECT_NAME=""
BACKUP_DIR=""
CONFIRM="false"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --project)
            [ "$#" -ge 2 ] || fail "--project requires a value"
            PROJECT_NAME="$2"
            shift 2
            ;;
        --backup)
            [ "$#" -ge 2 ] || fail "--backup requires a value"
            BACKUP_DIR="$2"
            shift 2
            ;;
        --confirm-restore)
            CONFIRM="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[ -n "$PROJECT_NAME" ] || fail "--project is required"
[ -n "$BACKUP_DIR" ] || fail "--backup is required"
[ "$CONFIRM" = "true" ] || fail "--confirm-restore is required"

[ -d "$BACKUP_DIR" ] || fail "backup directory does not exist: $BACKUP_DIR"

for file in \
    database.sql.gz \
    conf.tar.gz \
    data.tar.gz \
    env-production.tar.gz \
    SHA256SUMS \
    manifest.txt
do
    [ -s "$BACKUP_DIR/$file" ] ||
        fail "required backup artifact missing: $file"
done

log "verifying backup checksums"
(
    cd "$BACKUP_DIR"
    sha256sum -c SHA256SUMS
) || fail "backup checksum verification failed"

source_project="$(
    sed -n 's/^compose_project=//p' "$BACKUP_DIR/manifest.txt" |
    head -1
)"

[ -n "$source_project" ] ||
    fail "source project missing from backup manifest"

[ "$PROJECT_NAME" != "$source_project" ] ||
    fail "refusing restore into source project: $PROJECT_NAME"

source_database="$(
    sed -n 's/^database_name=//p' "$BACKUP_DIR/manifest.txt" |
    head -1
)"

[ -n "$source_database" ] ||
    fail "database name missing from backup manifest"

case "$source_database" in
    *[!A-Za-z0-9_]*|'')
        fail "invalid database name in backup manifest"
        ;;
esac

WEB_CONTAINER="${PROJECT_NAME}-web-1"
DB_CONTAINER="${PROJECT_NAME}-db-1"

docker inspect "$WEB_CONTAINER" >/dev/null 2>&1 ||
    fail "target web container does not exist: $WEB_CONTAINER"

docker inspect "$DB_CONTAINER" >/dev/null 2>&1 ||
    fail "target database container does not exist: $DB_CONTAINER"

db_running="$(
    docker inspect -f '{{.State.Running}}' "$DB_CONTAINER"
)"

[ "$db_running" = "true" ] ||
    fail "target database container is not running"

db_health="$(
    docker inspect \
      -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      "$DB_CONTAINER"
)"

[ "$db_health" = "healthy" ] ||
    fail "target database container is not healthy: $db_health"

target_database="$(
    docker inspect "$DB_CONTAINER"       --format '{{range .Config.Env}}{{println .}}{{end}}' |
    sed -n 's/^MARIADB_DATABASE=//p' |
    head -1
)"

[ -n "$target_database" ] ||
    fail "MARIADB_DATABASE missing from target database container"

case "$target_database" in
    *[!A-Za-z0-9_]*|'')
        fail "invalid target database name"
        ;;
esac

[ "$target_database" = "$source_database" ] ||
    fail "backup database does not match target database"

log "validated backup/target database: $target_database"

log "validating target persistent mounts"

for destination in \
    /var/www/html/conf \
    /var/www/html/data \
    /var/www/html/env-production
do
    mounted="$(
        docker inspect "$WEB_CONTAINER" \
          --format '{{range .Mounts}}{{println .Destination}}{{end}}' |
        grep -Fx "$destination" || true
    )"

    [ "$mounted" = "$destination" ] ||
        fail "required target mount missing: $destination"
done

db_mount="$(
    docker inspect "$DB_CONTAINER" \
      --format '{{range .Mounts}}{{println .Destination}}{{end}}' |
    grep -Fx '/var/lib/mysql' || true
)"

[ "$db_mount" = "/var/lib/mysql" ] ||
    fail "required target database mount missing: /var/lib/mysql"

log "validating target container networking"

web_networks="$(
    docker inspect "$WEB_CONTAINER"       --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}'
)"

db_networks="$(
    docker inspect "$DB_CONTAINER"       --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}'
)"

[ -n "$web_networks" ] ||
    fail "target web container has no Docker network"

[ -n "$db_networks" ] ||
    fail "target database container has no Docker network"

shared_network=""

for network in $web_networks; do
    if printf '%s\n' "$db_networks" | grep -Fxq "$network"; then
        shared_network="$network"
        break
    fi
done

[ -n "$shared_network" ] ||
    fail "target web and database containers do not share a Docker network"

log "validated shared target network: $shared_network"

esp_db_host="$(
    docker inspect "$WEB_CONTAINER"       --format '{{range .Config.Env}}{{println .}}{{end}}' |
    sed -n 's/^ESP_DB_HOST=//p' |
    head -1
)"

[ -n "$esp_db_host" ] ||
    fail "ESP_DB_HOST missing from target web container"

db_aliases="$(
    docker inspect "$DB_CONTAINER" \
      --format '{{json .NetworkSettings.Networks}}' |
    python3 -c '
import json
import sys

network_name = sys.argv[1]
networks = json.load(sys.stdin)

if network_name not in networks:
    sys.exit(2)

for alias in networks[network_name].get("Aliases") or []:
    print(alias)
' "$shared_network"
)"

printf '%s\n' "$db_aliases" | grep -Fxq "$esp_db_host" ||
    fail "ESP_DB_HOST does not identify target database on shared network"

log "validated target database network alias: $esp_db_host"

web_image="$(
    docker inspect "$WEB_CONTAINER" --format '{{.Config.Image}}'
)"

[ -n "$web_image" ] ||
    fail "unable to determine target ESP web image"

log "validated target ESP helper image: $web_image"

web_running="$(
    docker inspect -f '{{.State.Running}}' "$WEB_CONTAINER"
)"

if [ "$web_running" = "true" ]; then
    log "stopping target web container before filesystem restore"
    docker stop "$WEB_CONTAINER" >/dev/null
else
    log "target web container is already stopped"
fi

restart_web_on_failure() {
    rc=$?

    if [ "$rc" -ne 0 ]; then
        if [ "$web_running" = "true" ]; then
            log "restore failed; restoring original web running state"
            docker start "$WEB_CONTAINER" >/dev/null 2>&1 || true
        else
            log "restore failed; target web was originally stopped and will remain stopped"
        fi
    fi

    exit "$rc"
}

trap restart_web_on_failure EXIT

log "clearing target ESP filesystem state"

for destination in \
    /var/www/html/conf \
    /var/www/html/data \
    /var/www/html/env-production
do
    docker run --rm \
      --entrypoint /bin/sh \
      --volumes-from "$WEB_CONTAINER" \
      "$web_image" \
      -c "find '$destination' -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
done

log "restoring ESP configuration"
gzip -cd "$BACKUP_DIR/conf.tar.gz" |
docker run --rm -i \
  --entrypoint /usr/bin/tar \
  --volumes-from "$WEB_CONTAINER" \
  "$web_image" \
  -C /var/www/html -xf -

log "restoring ESP data"
gzip -cd "$BACKUP_DIR/data.tar.gz" |
docker run --rm -i \
  --entrypoint /usr/bin/tar \
  --volumes-from "$WEB_CONTAINER" \
  "$web_image" \
  -C /var/www/html -xf -

log "restoring compiled production environment"
gzip -cd "$BACKUP_DIR/env-production.tar.gz" |
docker run --rm -i \
  --entrypoint /usr/bin/tar \
  --volumes-from "$WEB_CONTAINER" \
  "$web_image" \
  -C /var/www/html -xf -

log "recreating target database"

docker exec "$DB_CONTAINER" sh -c '
    : "${MARIADB_DATABASE:?MARIADB_DATABASE is required}"
    : "${MARIADB_USER:?MARIADB_USER is required}"
    : "${MARIADB_PASSWORD:?MARIADB_PASSWORD is required}"

    MYSQL_PWD="$MARIADB_PASSWORD" \
      mariadb \
        --user="$MARIADB_USER" \
        -e "DROP DATABASE IF EXISTS \`$MARIADB_DATABASE\`;
            CREATE DATABASE \`$MARIADB_DATABASE\`
            CHARACTER SET utf8mb4
            COLLATE utf8mb4_unicode_ci;"
'

log "importing database backup"

gzip -cd "$BACKUP_DIR/database.sql.gz" |
docker exec -i "$DB_CONTAINER" sh -c '
    MYSQL_PWD="$MARIADB_PASSWORD" \
      mariadb --user="$MARIADB_USER"
'

log "starting restored web container"
docker start "$WEB_CONTAINER" >/dev/null

trap - EXIT

log "restore completed"
log "target project: $PROJECT_NAME"
