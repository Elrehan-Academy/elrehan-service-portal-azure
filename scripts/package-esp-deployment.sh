#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITOP_VERSION="${ITOP_VERSION:-3.3.0-21411}"
ITOP_ZIP="$ROOT/docker/iTop-${ITOP_VERSION}.zip"

EXPECTED_ITOP_SHA256='b4e52f8d5da53d990630a11dbda943de110cb9df6fea8228e382443975abc0e4'

OUTPUT_DIR="${1:-$ROOT/artifacts}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE="$(mktemp -d)"
PACKAGE="$OUTPUT_DIR/esp-deployment-${TIMESTAMP}.tar.gz"
CHECKSUM="${PACKAGE}.sha256"

cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

if [[ ! -s "$ITOP_ZIP" ]]; then
  echo "FAIL: missing iTop distribution: $ITOP_ZIP" >&2
  exit 1
fi

ACTUAL_ITOP_SHA256="$(sha256sum "$ITOP_ZIP" | awk '{print $1}')"

if [[ "$ACTUAL_ITOP_SHA256" != "$EXPECTED_ITOP_SHA256" ]]; then
  echo 'FAIL: iTop distribution checksum mismatch' >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
mkdir -p "$STAGE/esp"

cp "$ROOT/compose.yaml" "$STAGE/esp/"
cp -a "$ROOT/docker" "$STAGE/esp/"
cp -a "$ROOT/branding" "$STAGE/esp/"

# Preserve licensing, attribution and third-party notices in every
# redistributable ESP deployment artifact.
for compliance_file in LICENSE NOTICE.md THIRD_PARTY_NOTICES.md; do
  if [[ ! -s "$ROOT/$compliance_file" ]]; then
    echo "FAIL: required compliance file missing: $compliance_file" >&2
    exit 1
  fi

  cp "$ROOT/$compliance_file" "$STAGE/esp/"
done

cat > "$STAGE/esp/DEPLOYMENT-MANIFEST.txt" <<MANIFEST
artifact=Elrehan Service Portal
created_at=${TIMESTAMP}
itop_version=${ITOP_VERSION}
itop_sha256=${ACTUAL_ITOP_SHA256}
itop_license=GNU Affero General Public License v3
upstream=Combodo iTop Community
modified_distribution=yes
branding_and_automation=Elrehan
source_commit=$(git -C "$ROOT" rev-parse HEAD)
MANIFEST

tar \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -C "$STAGE" \
  -czf "$PACKAGE" \
  esp

(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$PACKAGE")" > "$(basename "$CHECKSUM")"
)

echo "package=$PACKAGE"
echo "checksum=$CHECKSUM"
echo "source_commit=$(git -C "$ROOT" rev-parse HEAD)"
echo "itop_sha256=$ACTUAL_ITOP_SHA256"
