# Elrehan Service Portal — Container Operations

This document describes the operational lifecycle, backup, restore, recovery,
and tested failure scenarios for the Elrehan Service Portal (ESP).

ESP is powered by iTop and customized, branded, and automated by Elrehan.

## Scope

This runbook covers the current single-VM Docker Compose architecture.

Persistent application state consists of:

- MariaDB database
- `/var/www/html/conf`
- `/var/www/html/data`
- `/var/www/html/env-production`

The application image contains the iTop application source, ESP extension,
branding, bootstrap logic, and lifecycle scripts.

`env-production-build` is generated state and is not persisted.

## Important Safety Rules

Never use:

    docker compose down -v

against an ESP environment unless permanent deletion of its persistent data is
explicitly intended.

The `-v` option removes named volumes and can destroy the ESP database,
configuration, application data, and compiled production environment.

Backups may contain configuration, application data, and credentials. Treat
every ESP backup as sensitive data.

The repository ignores the local `backups/` directory. Backup artifacts must
never be committed to Git.

## Health and Status

Check the ESP containers with:

    docker compose ps

For the web container, the health check validates:

- ESP configuration exists
- required application state exists
- compiled production environment exists
- ESP branding/module is compiled
- the internal web request contains `Elrehan Service Portal`

Both the ESP web container and MariaDB should report `healthy` before an
operation is considered successful.

## Normal Lifecycle

Start:

    docker compose up -d

Stop without deleting persistent state:

    docker compose stop

Start an existing stopped environment:

    docker compose start

Restart:

    docker compose restart

Do not use `down -v` as a normal lifecycle command.

## Zero-Touch Startup Behavior

On container startup, the ESP entrypoint invokes the bootstrap process.

For a new persistent environment, the native iTop unattended installer creates
the production installation.

For an existing persistent environment, the bootstrap detects the existing
production configuration and skips installation.

Expected recovery behavior includes a log message similar to:

    existing production configuration detected; installation skipped

This prevents an existing installation from being recreated after a container,
Docker daemon, or VM restart.

## Backup

Backup script:

    scripts/backup-esp.sh

Usage:

    ./scripts/backup-esp.sh \
      --project <compose-project> \
      --backup-root <backup-directory>

The script validates the source environment before beginning.

For application consistency, the web container is briefly quiesced while the
backup is created. MariaDB remains running.

Backup sequence:

1. Validate source containers and persistent mounts.
2. Capture source metadata.
3. Stop the ESP web container.
4. Create a logical MariaDB dump.
5. Archive ESP configuration.
6. Archive ESP application data.
7. Archive the compiled production environment.
8. Validate the backup artifacts.
9. Generate SHA-256 checksums.
10. Restart the ESP web container.
11. Wait for ESP to return healthy.

If backup processing fails after the script stops the web container, the
failure handler attempts to restart it.

A successful backup contains:

- `database.sql.gz`
- `conf.tar.gz`
- `data.tar.gz`
- `env-production.tar.gz`
- `manifest.txt`
- `SHA256SUMS`

The tested application-consistent backup maintenance window was approximately
23 seconds in the Sprint 7 test environment. This is test evidence, not a
guaranteed production duration.

## Restore

Restore script:

    scripts/restore-esp.sh

Usage:

    ./scripts/restore-esp.sh \
      --project <target-compose-project> \
      --backup <backup-directory> \
      --confirm-restore

Restore is intentionally destructive to the selected target environment.

It replaces the target ESP persistent filesystem state and recreates the target
application database from the selected backup.

It does not delete Docker volumes.

### Restore Safety Validation

Before reaching the destructive boundary, the restore script validates:

- required backup artifacts exist
- backup SHA-256 checksums
- backup database identity
- target database identity
- backup and target database names match
- required target persistent mounts
- target web and database containers have Docker networks
- target web and database containers share a network
- `ESP_DB_HOST` exists
- `ESP_DB_HOST` identifies the target database container on the shared network
- target ESP helper image can be identified

Only after these checks succeed may filesystem clearing and database recreation
begin.

### Restore Sequence

1. Verify backup checksums.
2. Validate source/target database identity.
3. Validate persistent mounts.
4. Validate Docker topology and database hostname.
5. Identify the target ESP image.
6. Stop the target web container when required.
7. Clear the target ESP persistent filesystem directories.
8. Restore configuration.
9. Restore application data.
10. Restore compiled production environment.
11. Recreate the target database.
12. Import the database dump.
13. Start the ESP web container.
14. Validate application health externally.

The restore uses the target ESP image itself as the filesystem helper. It does
not require a separate Alpine helper image.

### Restore Failure Considerations

Restore is not transactional.

A failure after the destructive boundary can leave the target partially
restored. In that situation, diagnose the failure and repeat the restore from a
known-good backup.

The failure handler preserves the target web container's original running state
where possible.

Do not assume a failed restore automatically rolled back filesystem or database
changes.

### ESP URL During Disaster Recovery

The restored ESP configuration contains the URL from the source installation.

This is correct when disaster recovery recreates the service behind the same
production DNS/FQDN.

When restoring into a test environment using a different URL, the restored
configuration may therefore still reference the source URL. Treat URL
translation for cloned/test environments separately from production DR.

## Recovery Validation

Sprint 7 validated the following lifecycle chain:

    Linux VM reboot
        ->
    Docker service starts
        ->
    MariaDB container starts
        ->
    ESP web container starts
        ->
    persistent volumes mount
        ->
    bootstrap detects existing installation
        ->
    installation is skipped
        ->
    ESP returns healthy

The tested environment recovered successfully after:

- controlled Compose stop/start
- Docker daemon restart
- full Linux VM reboot

After recovery, the test installation retained 249 database tables and returned
HTTP 200.

## Backup and Restore Acceptance Evidence

The known-good Sprint 7 backup was created using application quiescing.

Validation showed:

- backup checksums passed
- database dump contained 249 tables
- filesystem archives were valid
- source returned healthy after backup
- backup artifacts were ignored by Git

A complete restore into the disposable restore environment validated:

- restore exit code 0
- restore duration approximately 31 seconds
- no Alpine helper dependency
- target returned healthy
- restored database contained 249 tables
- HTTP response was 200
- ESP branding checks passed
- bootstrap skipped reinstallation
- protected source remained healthy and unchanged

Durations above describe the development acceptance environment and should not
be treated as production SLAs.

## Engineering Issues and Resolutions

### Backup CLI argument handling

**Symptom**

The first backup implementation did not correctly support the intended explicit
project selection.

**Root cause**

Operational parameters were initially oriented around environment variables
rather than a complete command-line parser.

**Resolution**

Added explicit `--project` and `--backup-root` handling, help output, missing
value checks, and rejection of unknown arguments.

**Validation**

Valid arguments succeeded. Unknown arguments and missing values returned a
controlled non-zero exit without creating a backup.

### Parser called `fail()` before its definition

**Symptom**

An invalid CLI argument produced a `fail: command not found` style error.

**Root cause**

Argument parsing could execute before the `fail()` function had been defined.

**Resolution**

Moved logging and failure functions before argument parsing.

**Validation**

Invalid arguments now return the expected ESP backup error and exit code 1.

### Temporary backup location did not survive reboot

**Symptom**

An earlier test backup stored below `/tmp` was unavailable after host reboot.

**Root cause**

`/tmp` is not an appropriate durable backup location.

**Resolution**

Acceptance backups were moved to the project-local ignored `backups/`
location. Production Azure backups will ultimately be stored outside the ESP VM.

### Backup consistency window

**Symptom**

The initial backup sequence dumped MariaDB and archived filesystem state while
the ESP web application remained active.

**Risk**

Application writes between the database dump and filesystem archive could
produce an inconsistent recovery point.

**Resolution**

Implemented a short application quiesce: stop only the ESP web container,
capture database and persistent filesystem state, then restart the web
container and wait for health.

**Validation**

The quiesced backup completed successfully and the application returned
healthy. The measured test maintenance window was approximately 23 seconds.

### Archiving a stopped web container

**Symptom**

Filesystem backup could not rely on `docker exec` after the web container had
been stopped for application consistency.

**Root cause**

Commands cannot be executed inside a stopped container.

**Resolution**

Use the ESP image as a temporary helper with the source container's volumes
mounted through `--volumes-from`.

### Restore archive decompression

**Symptom**

An earlier restore path could perform incompatible/double decompression.

**Root cause**

The gzip stream was already decompressed before being passed to tar.

**Resolution**

The restore pipeline now decompresses with `gzip -cd` and passes an
uncompressed tar stream to `tar -xf`.

### Incorrect disposable restore topology

**Symptom**

A manually created restore-test web container did not have the expected
Compose network/port topology.

**Root cause**

The container was created outside the intended Compose topology.

**Resolution**

Recreated the target using Compose and added restore-time network validation.

### Backup/target database mismatch risk

**Risk**

A valid backup could theoretically be restored into a target configured for a
different database name.

**Resolution**

The restore reads the source database identity from the backup manifest,
validates identifiers, reads the target MariaDB database setting, and requires
the source and target database names to match before the destructive boundary.

**Validation**

A deliberately modified backup manifest was rejected with exit code 1 before
filesystem clearing. The target remained healthy with 249 tables.

### Restore failure and original web state

**Risk**

Failure handling could change a target that was intentionally stopped before
restore.

**Resolution**

The restore records the original web running state. Failure recovery restarts
the web container only when it had originally been running.

### Alpine restore dependency

**Issue**

The restore initially used `alpine:3.20` as a helper image for filesystem
operations.

**Impact**

This introduced an unnecessary external runtime image dependency.

**Resolution**

Verified that the ESP image contains the required shell, tar, find, rm, and
mkdir tools. Restore now uses the target ESP image itself.

**Validation**

A complete restore succeeded without Alpine, returned HTTP 200, restored 249
tables, passed branding validation, and left the source healthy.

### Database hostname topology validation

**Issue**

Checking only that the ESP and MariaDB containers share a Docker network does
not prove that the hostname configured in `ESP_DB_HOST` identifies the intended
database container.

**Resolution**

Restore now validates `ESP_DB_HOST` against the target database aliases on the
shared Docker network before entering the destructive phase.

Network metadata is retrieved as JSON and parsed outside the Docker Go
template to avoid fragile dynamic template interpolation.

**Validation**

The valid target resolved `db` to the target MariaDB container. A negative test
using a deliberately invalid database hostname exited with code 1 before
filesystem clearing or database recreation. The target remained healthy with
249 tables.

### Docker Go-template quoting during validation

**Symptom**

A read-only test command returned:

    template parsing error: unexpected EOF

The SSH session subsequently disconnected.

**Root cause**

The ad-hoc validation command used fragile shell interpolation inside a Docker
Go template.

**Impact**

No restore or destructive operation had started.

**Resolution**

After reconnecting, all protected containers were verified healthy. Dynamic
network lookup was changed to retrieve Docker network metadata as JSON and
parse it separately.

**Validation**

The hardened lookup correctly found the `db` alias, and the subsequent negative
guard test passed.

## Production Backup Direction

The current scripts establish the application-level backup and restore
mechanism.

For Azure production deployment, backups should be copied outside the ESP VM
and protected using appropriate retention, access control, and encryption.

The planned v1 disaster-recovery model is:

    external backup
        ->
    deploy fresh ESP VM
        ->
    restore known-good ESP backup
        ->
    validate health
        ->
    restore/confirm production DNS

Azure-specific backup storage, retention, encryption, and disaster-recovery
automation belong to the Azure infrastructure/security implementation rather
than this local Sprint 7 container lifecycle.

## HTTPS

TLS is intentionally outside this Sprint 7 container-operations scope.

The production Azure design must include:

- DNS
- Nginx TLS termination/reverse proxy
- HTTP-to-HTTPS redirect
- Let's Encrypt certificate issuance
- automatic certificate renewal
- Nginx reload after renewal
- renewal dry-run/staging validation

Initial certificate issuance alone is not sufficient acceptance evidence.
Renewal must also be proven.

## Current Limitations

The current release is a single-VM architecture.

It does not yet provide:

- VM/application HA
- managed database HA
- cross-region automatic failover
- automated Azure backup retention
- automated DNS failover
- container orchestration

Those capabilities can be introduced in later editions without changing the
basic ESP application backup model.
