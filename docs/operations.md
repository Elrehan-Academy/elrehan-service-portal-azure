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

## Sprint 8 Azure Deployment

Sprint 8 established the first reproducible Azure deployment of the Elrehan
Service Portal.

### Architecture

The validated Azure deployment uses:

- Azure resource group `rg-esp-sprint8-weu`
- West Europe
- Ubuntu 24.04 LTS
- parameterized VM size, validated with `Standard_B2s`
- Azure VNet and dedicated ESP subnet
- NSG with SSH restricted to the deployment workstation address
- static Standard public IP
- SSH-key authentication only
- Docker Engine and Docker Compose installed during host bootstrap
- ESP Apache/PHP container
- MariaDB 10.11 container
- persistent Docker volumes for database, configuration, application data, and
  compiled production environment
- ESP HTTP listener bound only to `127.0.0.1:8080`

The Azure VM does not require a GitHub PAT or GitHub repository credentials.
Deployment artifacts are created by the trusted deployment workstation and
transferred to the VM over SSH.

The private GitHub repository therefore remains outside the runtime trust
boundary.

### Deployment Package

`scripts/package-esp-deployment.sh` creates a deployment archive containing
only the required application build inputs.

The upstream iTop archive is included in the deployment package but remains
excluded from Git.

The package is accompanied by a SHA-256 checksum and manifest identifying the
iTop version, iTop archive checksum, creation time, and source Git commit.

### Application Deployment

`scripts/deploy-esp-application.sh`:

1. validates the deployment-package checksum;
2. waits for SSH;
3. waits for Azure host bootstrap readiness;
4. refuses to overwrite an initialized ESP deployment;
5. generates runtime credentials only for a new deployment;
6. transfers the deployment package and protected runtime environment;
7. builds and starts the Docker Compose application;
8. waits for ESP container health;
9. follows the normal iTop HTTP redirect and requires final HTTP 200;
10. validates the database.

Runtime credentials are stored in:

    /opt/esp/config/esp.env

with mode `0600` and ownership `root:root`.

### Azure Acceptance Evidence

The Sprint 8 Azure deployment passed application acceptance before reboot:

- ESP web container: healthy
- MariaDB container: healthy
- final HTTP status after redirect: 200
- database tables: 249
- branding checks: 4/4
- production configuration: mode 440, owner `www-data:www-data`
- runtime environment: mode 600, owner `root:root`
- ESP production module: compiled
- application listener: `127.0.0.1:8080`

Evidence is stored on the test VM under:

    /opt/esp/evidence/application.txt

### Reboot and Persistence Acceptance

The Azure VM was restarted using Azure VM restart.

Docker was enabled at boot and the ESP and MariaDB containers restarted
automatically without running `docker compose up` manually.

Post-reboot acceptance proved:

- Docker service active
- ESP web container healthy
- MariaDB container healthy
- 249 database tables preserved
- final HTTP status 200
- branding checks 4/4
- production configuration permissions preserved
- runtime secret permissions preserved
- ESP module remained compiled
- listener remained `127.0.0.1:8080`
- persistent Docker volumes remained present
- pre-reboot acceptance evidence survived the VM restart

The persistent volumes validated were:

- `db-data`
- `esp-conf`
- `esp-data`
- `esp-env-production`

Post-reboot evidence is stored under:

    /opt/esp/evidence/reboot-acceptance.txt

### Sprint 8 Engineering Issues and Resolutions

#### Deployment package checksum path

**Symptom**

Checksum validation failed after changing into the artifact directory.

**Root cause**

The checksum file contained the relative path `artifacts/<package>` while the
validation process was already executing from inside `artifacts/`.

This resulted in an effective lookup of `artifacts/artifacts/<package>`.

**Resolution**

Checksum generation now occurs from inside the output directory and records
only the package basename.

**Validation**

The rebuilt deployment artifact passed `sha256sum -c`.

#### Protected application directory

**Symptom**

The first application deployment stopped with:

    cd: /opt/esp/app: Permission denied

**Root cause**

`/opt/esp/app` is intentionally protected as `root:root` mode `0750`, but the
deployment command attempted to enter it as the unprivileged Azure SSH user.

**Resolution**

Application build and startup operations are executed with root privileges
while retaining the protected directory ownership and permissions.

**Validation**

The ESP image subsequently built successfully and the Compose workload
started.

#### Docker Compose project context

**Issue**

Compose health and diagnostic commands were executed outside the application
directory and did not explicitly identify the Compose project file.

**Resolution**

Non-build Compose operations now specify both:

    --project-directory "$APP_ROOT"
    -f "$APP_ROOT/compose.yaml"

**Validation**

All expected Compose execution contexts were structurally checked before the
deployment retry.

#### iTop root HTTP redirect

**Symptom**

The application deployer reported:

    FAIL: ESP HTTP status=302

even though the web container was healthy.

**Root cause**

A request to the iTop root path legitimately redirects:

    / -> /pages/UI.php

The validator checked only the first HTTP response.

**Resolution**

The deployment validator now follows redirects with `curl -L` and evaluates
the final HTTP response.

**Validation**

The root request returned HTTP 302, `/pages/UI.php` returned HTTP 200, and the
complete redirect chain finished with HTTP 200. All four expected branding
checks were also present.

#### Initialized deployment credential protection

**Risk**

The original deployer generated new MariaDB and ESP administrator credentials
on every invocation.

Because the MariaDB database is persistent, rerunning the installer against an
initialized host could replace the runtime environment with new credentials
while the existing database retained the original credentials.

**Resolution**

Before credential generation or payload transfer, the deployer checks for an
existing non-empty:

    /opt/esp/config/esp.env

If found, deployment stops without generating credentials or overwriting the
application.

Upgrade and restore operations must use their dedicated workflows instead of
the initial-deployment path.

**Validation**

A deliberate rerun against the initialized Azure test VM exited with code 1.

The test proved:

- existing runtime configuration detected;
- overwrite refused;
- credential generation was never reached;
- payload transfer was never reached;
- both existing containers remained healthy;
- ESP continued returning final HTTP 200.

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

## Sprint 9 HTTPS, Certificates, and Azure Security

Sprint 9 adds the public HTTPS and security layer to the single-VM Azure
deployment established during Sprint 8.

### HTTPS Architecture

The validated request path is:

    Internet
        ->
    Azure NSG TCP/443
        ->
    Nginx TLS termination
        ->
    http://127.0.0.1:8080
        ->
    ESP Apache/PHP container

TCP/80 is retained for HTTP-to-HTTPS redirect and ACME HTTP validation.

The ESP container itself remains bound only to:

    127.0.0.1:8080

Port 8080 is not exposed by the Azure NSG and was independently verified as
inaccessible from the deployment workstation.

### Azure DNS

The Azure Standard Public IP uses an optional parameterized DNS label.

The Sprint 9 test deployment uses:

    elrehan-service-portal.westeurope.cloudapp.azure.com

The Bicep root module accepts `dnsLabel` and passes it to the compute module.
The compute module configures the Public IP `dnsSettings` only when a DNS
label is supplied.

The root deployment also exposes the resulting Public IP FQDN as an output.

This allows later automation to use the same infrastructure-derived FQDN for
application installation and HTTPS configuration.

### Fresh-Installation Public URL

`scripts/deploy-esp-application.sh` requires:

    --fqdn <public-esp-fqdn>

The unattended iTop installation now receives:

    ESP_URL=https://<public-esp-fqdn>

while the container listener remains independently configured as:

    ESP_BIND_ADDRESS=127.0.0.1
    ESP_HTTP_PORT=8080

The public application identity and the private backend listener are therefore
separate concerns.

This prevents a new deployment from using `http://127.0.0.1:8080` as iTop's
canonical application URL.

The deployer validates the supplied FQDN and rejects malformed values before
connecting to the Azure host.

### Nginx and Certificate Automation

`scripts/configure-esp-https.sh`:

1. verifies the ESP host bootstrap and healthy application container;
2. installs Nginx, Certbot, and the Certbot Nginx plugin;
3. configures Nginx to proxy only to `127.0.0.1:8080`;
4. requests a Let's Encrypt certificate when no certificate exists;
5. reuses an existing valid certificate on later runs;
6. enables HTTP-to-HTTPS redirect;
7. configures iTop with its public HTTPS application identity;
8. enables reverse-proxy awareness;
9. installs a Certbot renewal deploy hook that validates and reloads Nginx;
10. enables `certbot.timer`;
11. validates HTTPS and records evidence.

The HTTPS automation does not use `--force-renewal` or duplicate-certificate
behavior.

When an existing certificate and renewal configuration are present, the script
checks that the certificate is valid for more than 24 hours and uses
`certbot install` to reapply the existing certificate to the regenerated Nginx
configuration without requesting a replacement certificate.

### Certificate Acceptance

The Sprint 9 certificate was successfully issued for:

    elrehan-service-portal.westeurope.cloudapp.azure.com

Validated certificate properties included:

- Let's Encrypt issuer
- public FQDN as certificate subject
- successful external HTTPS connection
- HTTP 301 redirect to HTTPS
- HTTPS final status 200
- certificate expiry `2027-01-13`

Initial certificate issuance alone was not considered sufficient acceptance.

### Automatic Certificate Renewal

Automatic renewal uses the operating-system Certbot timer:

    certbot.timer

The timer is enabled and active.

The deploy hook is:

    /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

After a successful renewal the hook:

1. runs `nginx -t`;
2. reloads Nginx.

A separate renewal simulation was executed with:

    certbot renew --dry-run

The simulated renewal completed successfully.

Evidence is stored on the Azure VM under:

    /opt/esp/evidence/certificate-renewal.txt

The evidence records:

- `renewal_dry_run=PASS`
- Nginx active
- ESP web container healthy
- MariaDB container healthy
- HTTPS 200
- Certbot timer active
- renewal hook present
- overall result PASS

### iTop Public HTTPS Identity

The public iTop configuration is:

    app_root_url=https://elrehan-service-portal.westeurope.cloudapp.azure.com
    behind_reverse_proxy=true

Nginx supplies the required proxy headers, including:

- `Host`
- `X-Real-IP`
- `X-Forwarded-For`
- `X-Forwarded-Proto`

Rendered public-page acceptance proved:

- HTTPS status 200
- zero `127.0.0.1` or localhost URL references
- 53 references to the public HTTPS FQDN during the acceptance run

The production iTop configuration remains:

    owner=www-data
    group=www-data
    mode=0440

### HTTPS Idempotency

The HTTPS automation was deliberately rerun against the initialized Sprint 9
Azure VM.

Before and after the rerun, the certificate had the same:

- SHA-256 fingerprint
- serial number
- `notBefore`
- `notAfter`

The script reported that the existing certificate was found and reused.

After the rerun:

- HTTPS remained 200
- `app_root_url` remained the public HTTPS FQDN
- `behind_reverse_proxy` remained true
- no replacement certificate was issued

This validates the existing-certificate path independently from initial
certificate issuance.

### HTTPS Reboot Acceptance

The Azure VM was restarted after HTTPS and renewal configuration.

Post-reboot validation proved:

- Docker active
- Nginx active
- `certbot.timer` active
- ESP web container healthy
- MariaDB container healthy
- ESP listener still `127.0.0.1:8080`
- internal application HTTP 200
- public HTTPS 200
- certificate persisted unchanged
- public TCP/8080 remained inaccessible

Evidence is stored under:

    /opt/esp/evidence/https-reboot-acceptance.txt

### Sprint 9 Security Acceptance

Final security acceptance proved:

- SSH TCP/22 restricted to the deployment workstation `/32`
- HTTP TCP/80 allowed for redirect and ACME
- HTTPS TCP/443 allowed publicly
- ESP TCP/8080 inaccessible externally
- ESP backend listener restricted to `127.0.0.1:8080`
- `/opt/esp/config/esp.env` owned by `root:root`, mode `0600`
- iTop production configuration owned by `www-data:www-data`, mode `0440`
- Docker active
- Nginx active
- Certbot timer active
- renewal hook present and executable
- web and database containers healthy
- no Git repository metadata under `/opt/esp`
- no deployment SSH private key, Git credential file, or equivalent deployment
  credential found under `/home/azureuser` or `/opt/esp`
- no obvious tracked GitHub PAT, private key, or Azure client-secret material
  found by the repository acceptance scan

The Azure VM does not require access to the private GitHub repository.

### Sprint 9 Evidence

The primary Azure-host evidence files are:

    /opt/esp/evidence/https.txt
    /opt/esp/evidence/certificate-renewal.txt
    /opt/esp/evidence/https-reboot-acceptance.txt

Together with the Sprint 8 application and reboot evidence, these demonstrate
the application, persistence, HTTPS, renewal, and reboot lifecycle.

### Sprint 9 Engineering Issues and Resolutions

#### Bicep DNS patch matched the wrong source text

**Symptom**

The first scripted attempt to add the DNS-label parameter stopped with:

    FAIL: expected sshPublicKey parameter block not found in main.bicep

**Root cause**

The patch expected description text that did not exactly match the source
file.

**Resolution**

The existing Bicep source was inspected first and the patch was reapplied
against the exact source text.

**Validation**

The failed attempt left the repository unchanged. The corrected Bicep source
subsequently compiled and passed Azure deployment validation.

#### HTTPS automation contained a test-host dependency

**Issue**

An early HTTPS automation draft validated the specific Sprint 8 hostname
`esp-s8-vm`.

That would prevent the same automation from being reused by a clean Sprint 10
deployment.

**Resolution**

Target validation was changed to use generic ESP bootstrap state, runtime
configuration, and container health rather than a specific VM hostname.

**Validation**

The source contains no Sprint 8 hostname dependency and successfully operated
against the existing ESP runtime.

#### Localhost was used as iTop's application identity

**Symptom**

TLS and Nginx were operational, but rendered iTop pages contained absolute
URLs referencing:

    http://127.0.0.1:8080

The effective configuration showed:

    app_root_url=http://127.0.0.1:8080
    behind_reverse_proxy=false

**Root cause**

The initial Azure application deployer used one localhost value for iTop's
canonical application URL while also correctly binding the container to
localhost.

Application identity and listener binding had been conflated.

**Resolution**

The lifecycle now separates the two concepts.

Fresh installations require a public FQDN and use:

    ESP_URL=https://<public-esp-fqdn>

while continuing to use:

    ESP_BIND_ADDRESS=127.0.0.1
    ESP_HTTP_PORT=8080

HTTPS automation also enforces `behind_reverse_proxy=true`.

**Validation**

The rendered public page contained zero localhost references and 53 references
to the public HTTPS FQDN during acceptance.

#### Docker exec did not attach standard input

**Symptom**

The first automated iTop identity migration appeared to execute, but the
configuration remained unchanged and the expected migration output was absent.

**Root cause**

The script supplied the migration through a heredoc to:

    docker exec esp-web-1 sh -s

without attaching standard input.

**Resolution**

The command was changed to:

    docker exec -i esp-web-1 sh -s

**Validation**

A diagnostic test proved that the command without `-i` executed no supplied
input, while the `-i` form produced the expected output.

#### PHP replacement syntax corrupted the reverse-proxy setting

**Symptom**

A later migration attempt emitted PHP warnings involving `${1}`.

Inspection showed a partially migrated configuration:

    app_root_url=https://elrehan-service-portal.westeurope.cloudapp.azure.com

but the original:

    'behind_reverse_proxy' => false,

had become:

    true,

PHP syntax remained valid, but the `behind_reverse_proxy` key no longer
existed in `$MySettings`.

**Root cause**

The PHP replacement string used:

    "${1}true"

to represent a regular-expression capture-group replacement.

PHP interpreted `${1}` as variable interpolation instead of the intended
regular-expression backreference.

**Resolution**

The known-good pre-HTTPS configuration backup was used as the deterministic
repair baseline.

A repaired candidate was created first, then validated for:

- PHP syntax
- exact public `app_root_url`
- `behind_reverse_proxy=true`

Only after all checks passed was it atomically activated.

The automation source was then changed to avoid the ambiguous capture-group
replacement.

**Validation**

The repaired live configuration reported:

    app_root_url=https://elrehan-service-portal.westeurope.cloudapp.azure.com
    behind_reverse_proxy=true

with mode `0440`, ownership `www-data:www-data`, healthy containers, and
HTTPS 200.

#### Partial migration required backup-based recovery

**Issue**

The failed PHP migration was not completely non-mutating. The first
replacement succeeded before the second replacement damaged the reverse-proxy
setting.

**Resolution**

HTTPS identity migration creates a timestamped pre-change configuration backup
before modification.

The failed state was inspected before any further write, and the known-good
backup was used as the repair source rather than repeatedly editing the damaged
configuration.

**Validation**

The backup passed PHP syntax validation and contained the original localhost
URL and complete `behind_reverse_proxy` setting. The repaired configuration
passed independent runtime and public-page acceptance.

#### Expected grep no-match interacted with pipefail

**Symptom**

A validation command could terminate when counting an expected zero number of
localhost references.

**Root cause**

`grep` returns status 1 when there are no matches. With `set -o pipefail`,
that expected no-match status caused the pipeline to fail.

**Resolution**

Zero-match validation explicitly tolerates the grep status before piping the
result to `wc -l`.

**Validation**

Public-page acceptance completed successfully and reported:

    localhost_reference_count=0

#### Existing certificate behavior was implicit

**Issue**

The first HTTPS automation always invoked `certbot --nginx`.

Although Certbot normally avoids unnecessary replacement of an unexpired
certificate, the deployment automation did not explicitly control this
behavior.

**Resolution**

The script now distinguishes between first issuance and an existing
certificate.

When the certificate, private key, and renewal configuration already exist,
the script:

1. checks certificate validity;
2. refuses an existing certificate expiring within 24 hours;
3. uses `certbot install` to reapply the certificate;
4. does not request a new certificate.

**Validation**

A live idempotency test preserved the certificate fingerprint, serial number,
start date, and expiry date exactly while HTTPS remained 200.

#### SSH exposure was parameterized

**Risk**

An early infrastructure draft could have left SSH broadly accessible.

**Resolution**

The NSG SSH rule uses the required `sshSourceAddressPrefix` Bicep parameter.
The deployment workstation public address is supplied as a `/32`.

**Validation**

Sprint 9 final security acceptance showed:

    Allow-SSH  77.248.238.151/32  TCP/22
    Allow-HTTP *                  TCP/80
    Allow-HTTPS *                TCP/443

ESP TCP/8080 remained inaccessible externally.


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

## Sprint 10 Azure Clean-Room Release Acceptance

Sprint 10 validated ESP on a fresh Azure single-VM deployment before the
v0.1.0 release.

### Acceptance Environment

The acceptance environment used:

- Azure region: West Europe
- Ubuntu 24.04 VM
- Docker Engine 29.9.1
- Docker Compose 5.6.0
- ESP/iTop 3.3.0-21411
- MariaDB 10.11
- HTTPS through Nginx and Let's Encrypt
- ESP web container bound only to `127.0.0.1:8080`

The Azure deployment, application bootstrap, HTTPS configuration, persistent
restart behavior, backup, and isolated restore were validated.

### Acceptance Results

The following release gates passed:

- Azure infrastructure deployment succeeded.
- ESP unattended installation completed successfully.
- Production database contained 249 tables.
- ESP extension compiled successfully.
- HTTP redirected to HTTPS.
- Public ESP UI returned HTTPS 200.
- Let's Encrypt certificate was issued successfully.
- Certbot renewal dry-run passed.
- ESP and MariaDB remained healthy after VM restart.
- Persistent configuration, database, data, and compiled environment survived
  the restart.
- Application-consistent Azure backup completed successfully.
- All backup SHA-256 checksums passed.
- Backup source returned healthy after backup.
- Backup was restored into a separate disposable Compose project.
- Restored database contained 249 tables.
- Restored ESP configuration and extension were present.
- Restored test endpoint returned HTTP 200.
- Production containers remained healthy throughout restore testing.
- Production public HTTPS remained HTTP 200 after restore testing.

The accepted Azure backup was:

    /opt/esp/backups/esp-backup-20261016T095316Z

The backup contained:

- `database.sql.gz`
- `conf.tar.gz`
- `data.tar.gz`
- `env-production.tar.gz`
- `manifest.txt`
- `SHA256SUMS`

### Engineering Issues and Resolutions — Sprint 10

#### Reverse proxy redirected authentication to HTTPS port 80

**Symptom**

Authentication requests could redirect to a URL containing HTTPS with port 80.

**Root cause**

Nginx forwarded the protocol but did not explicitly provide the external HTTPS
port to the application.

**Resolution**

Added:

    proxy_set_header X-Forwarded-Port 443;

to the HTTPS reverse-proxy configuration.

**Validation**

The corrected public HTTPS endpoint returned HTTP 200.

#### ESP public URL required a trailing slash

**Symptom**

Generated resource URLs could concatenate the deployment environment name
directly onto the FQDN, producing malformed asset URLs.

**Root cause**

The generated ESP public URL did not end with `/`.

**Resolution**

Deployment and HTTPS automation now generate:

    https://<fqdn>/

rather than:

    https://<fqdn>

**Validation**

Application assets and the ESP UI returned successfully after correction.

#### Nginx enabled-site backup created duplicate configuration

**Symptom**

Nginx reported duplicate listening configuration after a configuration backup.

**Root cause**

A backup symlink was created inside `sites-enabled`, causing Nginx to load both
the active configuration and its backup.

**Resolution**

Removed the accidental enabled backup. Configuration backups must be stored
outside `sites-enabled`, preferably from `sites-available` or another
non-enabled location.

#### Repository branding source drift

**Symptom**

The deployment repository did not contain all files used by the known-good ESP
branding environment.

**Root cause**

The portal UI hook, ESP theme CSS, and current module wiring had not all been
migrated into the Azure deployment repository.

**Resolution**

Migrated only the active production branding files from the known-good
environment and verified them against known-good SHA-256 checksums.

Unused image variants and development backup files were intentionally excluded.

**Validation**

PHP syntax validation passed using PHP 8.3. The updated ESP image built
successfully and a disposable clean-room installation returned HTTP 200 with
249 database tables and the ESP extension compiled.

#### Backup script executed outside the application directory

**Symptom**

The acceptance command reported permission denied when attempting to change
directory to `/opt/esp/app`.

**Root cause**

The Azure administration account does not have direct traversal permission for
that protected application directory.

**Resolution**

No backup correction was required. The backup script operates against the
specified Docker Compose project and an absolute backup destination and
therefore did not depend on the attempted working-directory change.

**Validation**

The backup completed successfully, all generated artifacts passed checksum
validation, and the production application returned HTTPS 200 afterward.

#### Disposable restore target conflicted with production port 8080

**Symptom**

The disposable restore web container could not start because
`127.0.0.1:8080` was already allocated by the production ESP container.

**Root cause**

The disposable Compose project inherited the production default
`ESP_HTTP_PORT=8080`.

**Resolution**

Set the disposable restore target to:

    ESP_HTTP_PORT=18091

No production configuration was changed.

**Validation**

The disposable web container started successfully on
`127.0.0.1:18091`, while the production web container remained healthy on
`127.0.0.1:8080`.

#### Restore isolation validation

The Sprint 10 backup was restored into the separate Compose project:

    esp-s10-restore-test

The restore script validated the backup checksums, database identity,
persistent mounts, Docker network, database alias, and helper image before
crossing the destructive restore boundary.

The restored environment contained 249 database tables, retained the ESP
configuration and extension, and returned HTTP 200.

The production `esp-db-1` and `esp-web-1` containers remained healthy and the
public production endpoint continued returning HTTPS 200.

### Planned Automated Backup Policy

The current v0.1.0 acceptance proves the application-aware backup and restore
mechanism. Backup scheduling and off-VM retention must not be assumed unless
the corresponding automation has been deployed.

The target production design is:

- automatic backup enabled by default
- daily application-aware backup
- seven days of local backup retention
- optional Azure Storage off-VM backup
- 30-day default Azure Storage retention
- private Blob container
- Azure Managed Identity for upload authorization where supported
- no Storage Account secret embedded in the repository or VM configuration
- restore remains an explicit administrator operation

Local-only backup must not be considered sufficient protection against complete
VM or OS-disk loss.

Azure VM-level backup may be added as an additional recovery layer, but it does
not replace the application-aware ESP backup and restore mechanism.
