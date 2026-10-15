#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_NAME="${ESP_COMPOSE_PROJECT:-esp}"
BACKUP_ROOT="${ESP_BACKUP_ROOT:-./backups}"

log() {
    printf '[ESP backup] %s\n' "$*"
}

fail() {
    printf '[ESP backup] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  backup-esp.sh [--project PROJECT] [--backup-root PATH]

Options:
  --project PROJECT    Compose project name.
                       Default: ESP_COMPOSE_PROJECT or "esp".
  --backup-root PATH   Directory in which backup directories are created.
                       Default: ESP_BACKUP_ROOT or "./backups".
  -h, --help           Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --project)
            [ "$#" -ge 2 ] || fail "--project requires a value"
            PROJECT_NAME="$2"
            shift 2
            ;;
        --backup-root)
            [ "$#" -ge 2 ] || fail "--backup-root requires a value"
            BACKUP_ROOT="$2"
            shift 2
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

[ -n "$PROJECT_NAME" ] || fail "project name must not be empty"
[ -n "$BACKUP_ROOT" ] || fail "backup root must not be empty"

WEB_CONTAINER="${PROJECT_NAME}-web-1"
DB_CONTAINER="${PROJECT_NAME}-db-1"

timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
backup_dir="${BACKUP_ROOT%/}/esp-backup-${timestamp}"

container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

log "validating source environment: ${PROJECT_NAME}"

container_running "$WEB_CONTAINER" ||
    fail "web container is not running: ${WEB_CONTAINER}"

container_running "$DB_CONTAINER" ||
    fail "database container is not running: ${DB_CONTAINER}"

web_health="$(docker inspect \
    -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$WEB_CONTAINER")"

db_health="$(docker inspect \
    -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$DB_CONTAINER")"

[ "$web_health" = "healthy" ] ||
    fail "web container is not healthy: ${web_health}"

[ "$db_health" = "healthy" ] ||
    fail "database container is not healthy: ${db_health}"

for path in \
    /var/www/html/conf/production/config-itop.php \
    /var/www/html/data/datamodel-production.xml \
    /var/www/html/data/instance.txt \
    /var/www/html/env-production
do
    docker exec "$WEB_CONTAINER" test -e "$path" ||
        fail "required ESP state missing: ${path}"
done

web_image="$(docker inspect -f '{{.Config.Image}}' "$WEB_CONTAINER")"
db_image="$(docker inspect -f '{{.Config.Image}}' "$DB_CONTAINER")"
db_name="$(docker exec "$DB_CONTAINER" sh -c 'printf "%s" "$MARIADB_DATABASE"')"

mkdir -p "$backup_dir"

web_stopped_for_backup="false"

cleanup_failed_backup() {
    rc=$?

    if [ "$rc" -ne 0 ]; then
        log "backup failed; removing incomplete backup directory"
        rm -rf -- "$backup_dir"

        if [ "$web_stopped_for_backup" = "true" ]; then
            log "backup failed; restarting ESP web container"
            docker start "$WEB_CONTAINER" >/dev/null 2>&1 || true
        fi
    fi

    exit "$rc"
}

trap cleanup_failed_backup EXIT

log "quiescing ESP web container for consistent backup"
docker stop "$WEB_CONTAINER" >/dev/null
web_stopped_for_backup="true"

log "creating MariaDB logical dump"

docker exec "$DB_CONTAINER" sh -c '
    : "${MARIADB_DATABASE:?MARIADB_DATABASE is required}"
    : "${MARIADB_USER:?MARIADB_USER is required}"
    : "${MARIADB_PASSWORD:?MARIADB_PASSWORD is required}"

    MYSQL_PWD="$MARIADB_PASSWORD" \
      mariadb-dump \
        --user="$MARIADB_USER" \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        --hex-blob \
        --databases "$MARIADB_DATABASE"
' | gzip -9 > "${backup_dir}/database.sql.gz"

archive_web_path() {
    source_path="$1"
    output_file="$2"

    docker run --rm \
      --entrypoint tar \
      --volumes-from "$WEB_CONTAINER" \
      "$web_image" \
      -C /var/www/html -czf - "$source_path" \
      > "$output_file"
}

log "archiving ESP configuration"
archive_web_path conf "${backup_dir}/conf.tar.gz"

log "archiving ESP data"
archive_web_path data "${backup_dir}/data.tar.gz"

log "archiving compiled production environment"
archive_web_path env-production "${backup_dir}/env-production.tar.gz"

log "validating generated archives"

gzip -t "${backup_dir}/database.sql.gz"
tar -tzf "${backup_dir}/conf.tar.gz" >/dev/null
tar -tzf "${backup_dir}/data.tar.gz" >/dev/null
tar -tzf "${backup_dir}/env-production.tar.gz" >/dev/null

cat > "${backup_dir}/manifest.txt" <<MANIFEST
ESP Backup Manifest
===================

created_utc=${timestamp}
compose_project=${PROJECT_NAME}
database_name=${db_name}
web_image=${web_image}
database_image=${db_image}
web_health=${web_health}
database_health=${db_health}

artifacts:
database.sql.gz
conf.tar.gz
data.tar.gz
env-production.tar.gz
MANIFEST

(
    cd "$backup_dir"
    sha256sum \
        database.sql.gz \
        conf.tar.gz \
        data.tar.gz \
        env-production.tar.gz \
        > SHA256SUMS
)

log "verifying checksums"
(
    cd "$backup_dir"
    sha256sum -c SHA256SUMS
)

log "restarting ESP web container"
docker start "$WEB_CONTAINER" >/dev/null
web_stopped_for_backup="false"

log "waiting for ESP web health after backup"

web_recovered="false"

for attempt in $(seq 1 60); do
    web_health_after="$(
        docker inspect "$WEB_CONTAINER"           --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
    )"

    if [ "$web_health_after" = "healthy" ]; then
        web_recovered="true"
        break
    fi

    sleep 2
done

[ "$web_recovered" = "true" ] ||
    fail "ESP web container did not become healthy after backup"

trap - EXIT

log "backup completed successfully"
printf '%s\n' "$backup_dir"
