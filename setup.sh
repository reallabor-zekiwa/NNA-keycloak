#!/bin/bash
# Applies the NNA realm settings on every start (idempotent). Runs next to Keycloak inside the container,
# logs in with the bootstrap admin (KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD, a generated cluster secret).
set -uo pipefail
ENV_NAME="$1"
KCADM=/opt/keycloak/bin/kcadm.sh
export HOME=/tmp     # kcadm keeps its token in ~/.keycloak

for ((i = 0; i < 60; i++)); do       # wait until Keycloak answers (up to ~5 min)
  if $KCADM config credentials --server http://localhost:8080 --realm master \
       --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
$KCADM get realms/nna --fields realm >/dev/null || { echo "setup.sh: realm nna not reachable" >&2; exit 1; }

# 1. realm settings from git (sign-up, verification, reset, brute force, mail, tokens, languages …)
$KCADM update realms/nna -f "/opt/nna/realms/nna-${ENV_NAME}-settings.json" && echo "setup.sh: realm settings applied"

# 2. every new account may view/manage/delete itself (account client exists only after the realm was created)
$KCADM add-roles -r nna --rname default-roles-nna --cclientid account \
  --rolename view-profile --rolename manage-account --rolename delete-account >/dev/null 2>&1 \
  && echo "setup.sh: default roles incl. delete-account"

# 3. ask for the password on the sign-up form (Keycloak 26 default with e-mail verification: password only after the
#    confirmation link – two steps for our users). Setting of the "Password Validation" step of the registration flow.
while IFS=, read -r id provider cfg; do
  [ "$provider" = "registration-password-action" ] || continue
  body='{"alias":"nna-registration-password","config":{"always_set_password_on_register_form":"true"}}'
  if [ -z "$cfg" ]; then
    $KCADM create "authentication/executions/$id/config" -r nna -b "$body" >/dev/null
  else
    $KCADM update "authentication/config/$cfg" -r nna -b "$body" >/dev/null
  fi && echo "setup.sh: password on the sign-up form"
done < <($KCADM get authentication/flows/registration/executions -r nna \
           --fields id,providerId,authenticationConfig --format csv --noquotes 2>/dev/null)

# values pasted into a terminal (kubectl --from-file=…=/dev/stdin) end with a newline – strip whitespace
for v in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET APPLE_SERVICES_ID APPLE_TEAM_ID APPLE_KEY_ID; do
  if [ -n "${!v:-}" ]; then x="${!v}"; x="${x//[$'\r\n\t ']/}"; printf -v "$v" '%s' "$x"; fi
done

# 4. Google sign-in – only if the cluster secret env-keycloak provides GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET
if [ -n "${GOOGLE_CLIENT_ID:-}" ] && [ -n "${GOOGLE_CLIENT_SECRET:-}" ]; then
  if $KCADM get identity-provider/instances/google -r nna >/dev/null 2>&1; then
    $KCADM update identity-provider/instances/google -r nna -s enabled=true \
      -s "config.clientId=$GOOGLE_CLIENT_ID" -s "config.clientSecret=$GOOGLE_CLIENT_SECRET" >/dev/null
  else
    $KCADM create identity-provider/instances -r nna -s alias=google -s providerId=google -s enabled=true \
      -s trustEmail=true -s 'config.syncMode=IMPORT' -s 'config.defaultScope=openid email profile' \
      -s "config.clientId=$GOOGLE_CLIENT_ID" -s "config.clientSecret=$GOOGLE_CLIENT_SECRET" >/dev/null
  fi && echo "setup.sh: Google sign-in configured"
fi

# 5. Sign in with Apple (extension providers/apple-identity-provider-*.jar) – only if env-keycloak provides
#    APPLE_SERVICES_ID, APPLE_TEAM_ID, APPLE_KEY_ID and APPLE_P8_KEY (raw content of the .p8 file)
if [ -n "${APPLE_SERVICES_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_KEY_ID:-}" ] && [ -n "${APPLE_P8_KEY:-}" ]; then
  if $KCADM get identity-provider/instances/apple -r nna >/dev/null 2>&1; then
    OP=(update identity-provider/instances/apple)
  else
    OP=(create identity-provider/instances -s alias=apple -s providerId=apple -s 'config.syncMode=IMPORT')
  fi
  $KCADM "${OP[@]}" -r nna -s enabled=true -s trustEmail=true -s displayName=Apple \
    -s "config.clientId=$APPLE_SERVICES_ID" -s "config.teamId=$APPLE_TEAM_ID" -s "config.keyId=$APPLE_KEY_ID" \
    -s "config.clientSecret=$APPLE_P8_KEY" -s 'config.defaultScope=name%20email' >/dev/null \
    && echo "setup.sh: Sign in with Apple configured"
fi
# 6. service client "nna-backend" for auth-service (delete/find accounts) – secret = generated cluster secret
#    keycloak-backend, the same value auth-service gets (NNA-deployment)
if [ -n "${KEYCLOAK_BACKEND_SECRET:-}" ]; then
  CID=$($KCADM get clients -r nna -q clientId=nna-backend --fields id --format csv --noquotes 2>/dev/null | head -n 1)
  if [ -z "$CID" ]; then
    $KCADM create clients -r nna -s clientId=nna-backend -s name="NNA backend (auth-service)" -s enabled=true \
      -s publicClient=false -s serviceAccountsEnabled=true -s standardFlowEnabled=false \
      -s directAccessGrantsEnabled=false -s clientAuthenticatorType=client-secret \
      -s "secret=$KEYCLOAK_BACKEND_SECRET" >/dev/null
  else
    $KCADM update "clients/$CID" -r nna -s "secret=$KEYCLOAK_BACKEND_SECRET" -s serviceAccountsEnabled=true >/dev/null
  fi
  # the admin API only accepts tokens with audience "realm-management"
  CID=$($KCADM get clients -r nna -q clientId=nna-backend --fields id --format csv --noquotes 2>/dev/null | head -n 1)
  if ! $KCADM get "clients/$CID/protocol-mappers/models" -r nna --fields name --format csv --noquotes 2>/dev/null | grep -q '^realm-management-audience$'; then
    $KCADM create "clients/$CID/protocol-mappers/models" -r nna -s name=realm-management-audience -s protocol=openid-connect \
      -s protocolMapper=oidc-audience-mapper -s 'config."included.client.audience"=realm-management' \
      -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' >/dev/null && echo "setup.sh: audience mapper added"
  fi
  # Keycloak 26.6+: admin API tokens need the scope "kc-admin-api" and the admin-API audience
  SID=$($KCADM get client-scopes -r nna --fields id,name --format csv --noquotes 2>/dev/null | grep ',kc-admin-api$' | cut -d, -f1)
  if [ -z "$SID" ]; then
    $KCADM create client-scopes -r nna -s name=kc-admin-api -s protocol=openid-connect \
      -s 'attributes."include.in.token.scope"=true' -s 'attributes."display.on.consent.screen"=false' >/dev/null
    SID=$($KCADM get client-scopes -r nna --fields id,name --format csv --noquotes 2>/dev/null | grep ',kc-admin-api$' | cut -d, -f1)
  fi
  if ! $KCADM get "client-scopes/$SID/protocol-mappers/models" -r nna --fields name --format csv --noquotes 2>/dev/null | grep -q '^admin-api-audience$'; then
    $KCADM create "client-scopes/$SID/protocol-mappers/models" -r nna -s name=admin-api-audience -s protocol=openid-connect \
      -s protocolMapper=oidc-admin-api-audience-mapper -s 'config."access.token.claim"=true' >/dev/null
  fi
  $KCADM update "clients/$CID/default-client-scopes/$SID" -r nna >/dev/null 2>&1 && echo "setup.sh: kc-admin-api scope on nna-backend"
  $KCADM add-roles -r nna --uusername service-account-nna-backend --cclientid realm-management \
    --rolename manage-users --rolename view-users >/dev/null && echo "setup.sh: service client nna-backend ready"
fi
echo "setup.sh: done"
