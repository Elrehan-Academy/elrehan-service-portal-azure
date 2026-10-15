#!/usr/bin/env bash
set -Eeuo pipefail

exec > >(tee -a /var/log/esp-bootstrap.log) 2>&1

STATUS_FILE='/var/lib/esp/bootstrap-status.txt'
ESP_ROOT='/opt/esp'

mkdir -p /var/lib/esp "$ESP_ROOT"
chmod 0755 /var/lib/esp "$ESP_ROOT"

write_status() {
  local status="$1"

  cat > "$STATUS_FILE" <<STATUS
status=$status
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATUS

  chmod 0644 "$STATUS_FILE"
}

trap 'write_status failed' ERR

write_status running

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
  ca-certificates \
  curl \
  gnupg

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

. /etc/os-release

cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO

apt-get update

apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

docker version
docker compose version

install -d -m 0750 "$ESP_ROOT/app"
install -d -m 0750 "$ESP_ROOT/config"
install -d -m 0750 "$ESP_ROOT/evidence"

cat > "$ESP_ROOT/evidence/runtime.txt" <<RUNTIME
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker=$(docker --version)
compose=$(docker compose version)
RUNTIME

chmod 0644 "$ESP_ROOT/evidence/runtime.txt"

write_status ready

echo 'ESP host bootstrap completed successfully.'
