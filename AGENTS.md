# Repository Guidelines

## Project Structure & Module Organization

- `infra/azure/` contains Azure Bicep, cloud-init, and deployment scripts.
- `docker/` defines the iTop/ESP image, PHP/Apache configuration, and container bootstrap.
- `branding/elrehan-service-portal/` is the PHP/XML/CSS branding extension and its image assets.
- `scripts/` contains packaging, deployment, HTTPS, backup, and restore workflows.
- `docs/` contains the operational runbook; `README.md` describes the validated release baseline.
- `tests/` is reserved for deployment/application validation; no automated tests are checked in.

## Build, Test, and Development Commands

Use Docker Compose for local work. Set required secrets and `ESP_URL`, then run:

```bash
docker compose build
docker compose up -d
docker compose ps
docker compose logs -f web
```

Run `docker compose down` only when stopping the stack; never add `-v` unless deleting persistent data is intentional. Create a deployment artifact with `./scripts/package-esp-deployment.sh` (requires the pinned iTop ZIP), and validate Azure templates with `az bicep build --file infra/azure/main.bicep`.

Before committing shell changes, run `bash -n scripts/*.sh infra/azure/scripts/*.sh infra/azure/cloud-init/*.sh docker/scripts/*.sh`. Use the documented backup and restore scripts for lifecycle validation rather than manually altering volumes.

## Coding Style & Naming Conventions

Use two spaces in YAML and Bicep, four spaces in PHP, and four spaces in Bash. Shell scripts should retain `set -Eeuo pipefail`, quote expansions, validate arguments, and use uppercase names for configuration variables. Use lowercase kebab-case for script filenames and descriptive resource/module names in Bicep. Keep secrets out of source, logs, and committed artifacts.

## Testing Guidelines

There is no project test framework or coverage threshold. Validate changes with syntax checks, `az bicep build`, Docker health checks, and the relevant acceptance flow in `docs/operations.md`. For deployment or restore changes, document the environment and observed health/recovery result in the pull request.

## Commit & Pull Request Guidelines

Use imperative Conventional Commit subjects such as `feat:`, `fix:`, `chore:`, and `release:`; keep the subject focused and concise. Pull requests should explain the behavior change, identify affected deployment or operational paths, link an issue when applicable, list validation commands/results, and include screenshots or logs when changing the portal or user-visible deployment experience. Do not commit backups, credentials, generated secrets, or local deployment artifacts.

## Security & Operations

Treat `.env` values, SSH keys, certificates, and backup directories as sensitive. Preserve checksum verification and pinned upstream artifact versions. Review `docs/operations.md` before backup, restore, HTTPS, or VM recovery work, and never expose the ESP backend beyond its intended local bind address.

## Agent-Specific Instructions

- Never run `git commit`, `git push`, `git reset`, `git revert`, `git checkout`, `git switch`, or change branches unless explicitly instructed by the user.
- Preserve all pre-existing uncommitted changes. Never overwrite, discard, or revert them.
- Modify only files required for the current task.
- Do not change architecture, deployment contracts, security behavior, or release versions unless explicitly required.
- Never expose, print, or commit secrets, credentials, private keys, certificates, tokens, or generated passwords.
- After implementation, run relevant validation commands and report their results.
- Before completion, show a concise summary of changed files and the Git diff.
- Do not commit or push during normal implementation; the user reviews and accepts changes first.
