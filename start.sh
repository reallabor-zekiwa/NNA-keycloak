#!/bin/bash
# Starts Keycloak for NNA_ENV=test|prod and keeps the realm "nna" in line with this repo:
#  1. first start: --import-realm creates the realm from realms/nna-<env>.json (later starts skip it)
#  2. every start: setup.sh applies realms/nna-<env>-settings.json and the default roles (kcadm, bootstrap admin)
# Changes made only in the admin console survive unless they touch a setting listed in the settings file.
set -euo pipefail
ENV_NAME="${NNA_ENV:-test}"
SRC="/opt/nna/realms/nna-${ENV_NAME}.json"
if [ ! -f "$SRC" ]; then
  echo "start.sh: no realm file for NNA_ENV=${ENV_NAME} ($SRC)" >&2
  exit 1
fi
mkdir -p /opt/keycloak/data/import
printf '%s' "$(<"$SRC")" > /opt/keycloak/data/import/nna.json      # pure bash copy – the base image is minimal
# realm "team" (team VPN login, prod only) – imported once like "nna", then kept in line by setup.sh
TEAM="/opt/nna/realms/team-${ENV_NAME}.json"
if [ -f "$TEAM" ]; then printf '%s' "$(<"$TEAM")" > /opt/keycloak/data/import/team.json; fi
# realm "material" (material library login, since 2026-11-14) – imported once, then kept in line by setup.sh
MAT="/opt/nna/realms/material-${ENV_NAME}.json"
if [ -f "$MAT" ]; then printf '%s' "$(<"$MAT")" > /opt/keycloak/data/import/material.json; fi

/opt/keycloak/bin/kc.sh start --optimized --import-realm "$@" &
KC=$!
trap 'kill -TERM "$KC" 2>/dev/null' TERM INT
( /bin/bash /opt/nna/setup.sh "$ENV_NAME" || echo "setup.sh: failed (Keycloak keeps running)" >&2 ) &
wait "$KC"
