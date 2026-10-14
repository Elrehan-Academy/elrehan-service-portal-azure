#!/bin/sh
set -eu

log() {
    printf '%s\n' "[ESP entrypoint] $*"
}

log "starting Elrehan Service Portal initialization"

/usr/local/bin/bootstrap-esp.sh

log "initialization complete; starting Apache"

exec apache2-foreground
