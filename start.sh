#!/bin/bash
# Picks the realm file of this environment (NNA_ENV=test|prod) and starts Keycloak.
# --import-realm only creates the realm when it does not exist yet; later changes made in the admin
# console stay (the database is the source of truth after the first start).
set -euo pipefail
ENV_NAME="${NNA_ENV:-test}"
SRC="/opt/nna/realms/nna-${ENV_NAME}.json"
if [ ! -f "$SRC" ]; then
  echo "start.sh: no realm file for NNA_ENV=${ENV_NAME} ($SRC)" >&2
  exit 1
fi
mkdir -p /opt/keycloak/data/import
# pure bash copy – the Keycloak base image is minimal
printf '%s' "$(<"$SRC")" > /opt/keycloak/data/import/nna.json
exec /opt/keycloak/bin/kc.sh start --optimized --import-realm "$@"
