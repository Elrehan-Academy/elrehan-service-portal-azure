# Elrehan Service Portal for Azure

Automated Azure deployment of the Elrehan Service Portal (ESP).

ESP provides a branded IT service management platform based on iTop,
with automated infrastructure deployment, application installation,
branding, validation, and lifecycle operations.

## Project status

The current development baseline provides:

- reproducible ESP Docker image based on iTop Community 3.3.0-21411
- Elrehan Service Portal branding extension
- zero-touch unattended iTop installation
- persistent Docker Compose deployment with MariaDB 10.11
- application backup and restore workflows
- Azure infrastructure deployed with Bicep
- Ubuntu VM bootstrap with Docker Engine and Docker Compose
- private deployment artifact delivery without GitHub credentials on the VM
- parameterized Azure Public IP DNS label
- public FQDN supplied to iTop during fresh installation
- Nginx TLS termination with the ESP backend restricted to `127.0.0.1:8080`
- Let's Encrypt certificate issuance
- automatic Certbot renewal with Nginx reload hook
- proven certificate renewal dry-run
- HTTP-to-HTTPS redirect
- iTop reverse-proxy awareness and public HTTPS application identity
- idempotent HTTPS configuration that reuses an existing valid certificate
- Azure VM reboot recovery for Docker, ESP, Nginx, and certificate renewal
- security acceptance covering NSG exposure, protected runtime secrets, and
  private ESP backend access

Sprint 9 HTTPS, certificate, and Azure security acceptance is complete on the
current Azure test deployment.

The next stage is Sprint 10: clean-room end-to-end deployment and release
acceptance.

Detailed deployment, recovery, HTTPS, certificate, security, evidence, and
engineering issue/resolution information is maintained in
`docs/operations.md`.

## Repository structure

- `infra/` - Azure infrastructure as code
- `scripts/` - deployment and lifecycle automation
- `branding/` - Elrehan Service Portal branding
- `portal/` - Azure deployment experience
- `tests/` - deployment and application validation
- `docs/` - architecture and operational documentation
- `.github/workflows/` - CI validation

## Operations

For container lifecycle, backup, restore, recovery, safety guidance, and
engineering issue/resolution history, see the
[ESP Operations Runbook](docs/operations.md).
