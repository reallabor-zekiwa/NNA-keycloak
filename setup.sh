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

# 1b. mail login (since 2026-11-13): the mail service only relays for its SASL users, and only from noreply@… –
#     the settings file names the user (smtpServer.user), the password comes from the cluster (env MAIL_SMTP_PASSWORD,
#     never in git). Applied after every settings update, because the settings file carries no password.
smtp_password() {   # $1 realm
  if [ -z "${MAIL_SMTP_PASSWORD:-}" ]; then
    echo "setup.sh: MAIL_SMTP_PASSWORD not set – realm $1 cannot send mail (the mail service needs a login)" >&2
    return 0
  fi
  $KCADM update "realms/$1" --merge -s "smtpServer.password=${MAIL_SMTP_PASSWORD//[$'\r\n\t ']/}" >/dev/null \
    && echo "setup.sh: mail login set for realm $1"
}
smtp_password nna

# 1c. client "nna-admin" of realm nna (since 2026-11-19, creator panel): creators sign in to the panel with their NEB
#     account on admin.* and creator.* (realms/nna-<env>-admin-client.json: redirect URIs + web origins only, merged –
#     the realm import ran only once, so new hosts must be applied here).
NNA_ADMIN_CLIENT="/opt/nna/realms/nna-${ENV_NAME}-admin-client.json"
if [ -f "$NNA_ADMIN_CLIENT" ]; then
  CID=$($KCADM get clients -r nna -q clientId=nna-admin --fields id --format csv --noquotes 2>/dev/null | head -n 1)
  [ -n "$CID" ] && $KCADM update "clients/$CID" -r nna --merge -f "$NNA_ADMIN_CLIENT" >/dev/null \
    && echo "setup.sh: nna client nna-admin redirect URIs applied"
fi
# 2. every new account may view/manage/delete itself (account client exists only after the realm was created)
$KCADM add-roles -r nna --rname default-roles-nna --cclientid account \
  --rolename view-profile --rolename manage-account --rolename delete-account >/dev/null 2>&1 \
  && echo "setup.sh: default roles incl. delete-account"

# 2b. Sign in with Apple: Keycloak keeps Apple's tokens (storeToken, step 5); each user may read their own stored token
#     (GET /realms/nna/broker/apple/token) – auth-service does that at sign-in and revokes it at Apple when the
#     account is deleted (Apple guideline 5.1.1(v)).
$KCADM add-roles -r nna --rname default-roles-nna --cclientid broker --rolename read-token >/dev/null 2>&1 \
  && echo "setup.sh: default role broker/read-token"

# 3. ask for the password on the sign-up form (Keycloak 26 default with e-mail verification: password only after the
#    confirmation link – two steps for our users). Setting of the "Password Validation" step of the registration flow.
password_on_signup() {   # $1 realm
  while IFS=, read -r id provider cfg; do
    [ "$provider" = "registration-password-action" ] || continue
    body="{\"alias\":\"$1-registration-password\",\"config\":{\"always_set_password_on_register_form\":\"true\"}}"
    if [ -z "$cfg" ]; then
      $KCADM create "authentication/executions/$id/config" -r "$1" -b "$body" >/dev/null
    else
      $KCADM update "authentication/config/$cfg" -r "$1" -b "$body" >/dev/null
    fi && echo "setup.sh: password on the sign-up form ($1)"
  done < <($KCADM get authentication/flows/registration/executions -r "$1" \
             --fields id,providerId,authenticationConfig --format csv --noquotes 2>/dev/null)
}
password_on_signup nna

# values pasted into a terminal (kubectl --from-file=…=/dev/stdin) end with a newline – strip whitespace
for v in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET APPLE_SERVICES_ID APPLE_TEAM_ID APPLE_KEY_ID; do
  if [ -n "${!v:-}" ]; then x="${!v}"; x="${x//[$'\r\n\t ']/}"; printf -v "$v" '%s' "$x"; fi
done

# 4. Google sign-in (always with Google's account picker – prompt=select_account: after "Sign out" the next
#    Google tap must not silently reuse the Google session, Vitalina 2026-11-11) – only if the cluster secret env-keycloak provides GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET
if [ -n "${GOOGLE_CLIENT_ID:-}" ] && [ -n "${GOOGLE_CLIENT_SECRET:-}" ]; then
  if $KCADM get identity-provider/instances/google -r nna >/dev/null 2>&1; then
    $KCADM update identity-provider/instances/google -r nna -s enabled=true -s 'config.prompt=select_account' \
      -s "config.clientId=$GOOGLE_CLIENT_ID" -s "config.clientSecret=$GOOGLE_CLIENT_SECRET" >/dev/null
  else
    $KCADM create identity-provider/instances -r nna -s alias=google -s providerId=google -s enabled=true \
      -s trustEmail=true -s 'config.syncMode=IMPORT' -s 'config.defaultScope=openid email profile' -s 'config.prompt=select_account' \
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
    -s "config.clientSecret=$APPLE_P8_KEY" -s 'config.defaultScope=name%20email' -s storeToken=true >/dev/null \
    && echo "setup.sh: Sign in with Apple configured (tokens stored)"
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

# 7. realm "team" – the team's VPN login (prod only, since 2026-11-12). Headscale signs people in here (client
#    "headscale", secret = cluster secret headscale-oidc, the same value Headscale gets in nna-test). Accounts, the
#    group "vpn" and the role "superadmin" follow realms/team-users.json (generated team-users.tsv).
#    Login (flow team-browser): password, then superadmins a PASSKEY, everyone else an authenticator code.
#    Forgot password (flow team-reset): mail link, new password, then the SAME second factor – a mailbox alone never
#    gets anyone in, and the reset never removes a code or passkey (lost device → an admin removes it in the console).
TEAM_SETTINGS="/opt/nna/realms/team-${ENV_NAME}-settings.json"
if [ -f "$TEAM_SETTINGS" ] && $KCADM get realms/team --fields realm >/dev/null 2>&1; then
  $KCADM update realms/team -f "$TEAM_SETTINGS" && echo "setup.sh: team realm settings applied"
  smtp_password team
  # client "nna-admin" (since 2026-11-13): the admin panels sign in with the team account (realms/team-admin-client.json,
  # incl. the "groups" claim – auth-service only lets members of "vpn" in). Re-applied on every start.
  ADMIN_CLIENT=/opt/nna/realms/team-admin-client.json
  if [ -f "$ADMIN_CLIENT" ]; then
    CID=$($KCADM get clients -r team -q clientId=nna-admin --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    if [ -z "$CID" ]; then
      $KCADM create clients -r team -f "$ADMIN_CLIENT" >/dev/null && echo "setup.sh: team client nna-admin created"
    else
      $KCADM update "clients/$CID" -r team -f "$ADMIN_CLIENT" >/dev/null && echo "setup.sh: team client nna-admin updated"
    fi
  fi
  # role superadmin + required actions (realm may predate them – import only runs once)
  $KCADM get roles/superadmin -r team >/dev/null 2>&1 || $KCADM create roles -r team -s name=superadmin \
    -s 'description=VPN admin – login needs a passkey' >/dev/null
  for RA in CONFIGURE_TOTP webauthn-register; do
    $KCADM update "authentication/required-actions/$RA" -r team -s enabled=true -s defaultAction=false >/dev/null 2>&1 \
      || $KCADM create authentication/register-required-action -r team -s providerId="$RA" -s name="$RA" >/dev/null 2>&1
  done
  # flows, built once (an existing flow is left alone; to change it: new alias, e.g. team-browser-2, and bind that)
  team_flow() {   # $1 alias, $2 description – top-level flow
    $KCADM get authentication/flows -r team --fields alias --format csv --noquotes 2>/dev/null | grep -qx "$1" \
      || $KCADM create authentication/flows -r team -s alias="$1" -s providerId=basic-flow -s topLevel=true \
           -s builtIn=false -s description="$2" >/dev/null
  }
  team_sub() {    # $1 parent alias, $2 new sub-flow alias
    $KCADM create "authentication/flows/$1/executions/flow" -r team \
      -b "{\"alias\":\"$2\",\"type\":\"basic-flow\",\"provider\":\"registration-page-form\",\"description\":\"$2\"}" >/dev/null
  }
  team_step() {   # $1 flow alias, $2 authenticator provider
    $KCADM create "authentication/flows/$1/executions/execution" -r team -b "{\"provider\":\"$2\"}" >/dev/null
  }
  # NOTE: the Keycloak image has bash, grep, cut and head – no awk/sed (2026-11-12: awk made the first flows empty)
  team_nth_id() {  # $1 top flow, $2 display name or provider id, $3 nth match → execution id
    local id dn pid n=0
    while IFS=, read -r id dn pid; do
      if [ "$dn" = "$2" ] || [ "$pid" = "$2" ]; then
        n=$((n + 1)); if [ "$n" -eq "${3:-1}" ]; then printf '%s' "$id"; return 0; fi
      fi
    done < <($KCADM get "authentication/flows/$1/executions" -r team --fields id,displayName,providerId --format csv --noquotes 2>/dev/null)
    return 1
  }
  team_req() {    # $1 top flow, $2 display name or provider id, $3 requirement, [$4 nth match]
    local ID
    ID=$(team_nth_id "$1" "$2" "${4:-1}") || { echo "setup.sh: team flow $1: step $2 not found" >&2; return 1; }
    $KCADM update "authentication/flows/$1/executions" -r team -b "{\"id\":\"$ID\",\"requirement\":\"$3\"}" >/dev/null
  }
  team_role_cond() {   # $1 top flow, $2 nth conditional-user-role, $3 negate true|false, $4 config alias
    local ID
    ID=$(team_nth_id "$1" conditional-user-role "$2") || { echo "setup.sh: team flow $1: role condition $2 not found" >&2; return 1; }
    $KCADM create "authentication/executions/$ID/config" -r team \
      -b "{\"alias\":\"$4\",\"config\":{\"condUserRole\":\"superadmin\",\"negate\":\"$3\"}}" >/dev/null
    $KCADM update "authentication/flows/$1/executions" -r team -b "{\"id\":\"$ID\",\"requirement\":\"REQUIRED\"}" >/dev/null
  }
  team_has_flow() { $KCADM get authentication/flows -r team --fields alias --format csv --noquotes 2>/dev/null | grep -qx "$1"; }
  team_count_req() {   # $1 top flow → number of REQUIRED steps
    $KCADM get "authentication/flows/$1/executions" -r team --fields requirement --format csv --noquotes 2>/dev/null | grep -cx REQUIRED
  }
  # version 2 (2026-11-12): version 1 (team-browser/team-reset) was built without awk → every step disabled
  B=team-browser-2; RS=team-reset-2
  if ! team_has_flow "$B"; then
    team_flow "$B" "Team VPN login: password + passkey (superadmin) or authenticator code"
    team_step "$B" auth-cookie;                          team_req "$B" auth-cookie ALTERNATIVE
    team_sub  "$B" team-forms-2;                         team_req "$B" team-forms-2 ALTERNATIVE
    team_step team-forms-2 auth-username-password-form;  team_req "$B" auth-username-password-form REQUIRED
    team_sub  team-forms-2 team-passkey-2;               team_req "$B" team-passkey-2 CONDITIONAL
    team_step team-passkey-2 conditional-user-role;      team_role_cond "$B" 1 false team-browser-2-is-superadmin
    team_step team-passkey-2 webauthn-authenticator;     team_req "$B" webauthn-authenticator REQUIRED
    team_sub  team-forms-2 team-code-2;                  team_req "$B" team-code-2 CONDITIONAL
    team_step team-code-2 conditional-user-role;         team_role_cond "$B" 2 true team-browser-2-not-superadmin
    team_step team-code-2 auth-otp-form;                 team_req "$B" auth-otp-form REQUIRED
    echo "setup.sh: team flow $B built"
  fi
  if ! team_has_flow "$RS"; then
    team_flow "$RS" "Team VPN forgot password: mail link + new password + the same second factor"
    team_step "$RS" reset-credentials-choose-user;       team_req "$RS" reset-credentials-choose-user REQUIRED
    team_step "$RS" reset-credential-email;              team_req "$RS" reset-credential-email REQUIRED
    team_step "$RS" reset-password;                      team_req "$RS" reset-password REQUIRED
    team_sub  "$RS" team-reset-passkey-2;                team_req "$RS" team-reset-passkey-2 CONDITIONAL
    team_step team-reset-passkey-2 conditional-user-role; team_role_cond "$RS" 1 false team-reset-2-is-superadmin
    team_step team-reset-passkey-2 webauthn-authenticator; team_req "$RS" webauthn-authenticator REQUIRED
    team_sub  "$RS" team-reset-code-2;                   team_req "$RS" team-reset-code-2 CONDITIONAL
    team_step team-reset-code-2 conditional-user-role;   team_role_cond "$RS" 2 true team-reset-2-not-superadmin
    team_step team-reset-code-2 auth-otp-form;           team_req "$RS" auth-otp-form REQUIRED
    echo "setup.sh: team flow $RS built"
  fi
  # bind only flows that are complete (login: password, 2 role conditions, passkey, code = 5 REQUIRED; reset: 3 more = 7);
  # otherwise fall back to Keycloak's own flows (they still ask for the code) and say so
  if [ "$(team_count_req "$B")" -ge 5 ] && [ "$(team_count_req "$RS")" -ge 7 ]; then
    $KCADM update realms/team -s browserFlow="$B" -s resetCredentialsFlow="$RS" >/dev/null && echo "setup.sh: team flows $B + $RS bound"
    for OLD in team-browser team-reset; do   # version 1, never usable
      OID=$($KCADM get authentication/flows -r team --fields id,alias --format csv --noquotes 2>/dev/null | grep ",$OLD\$" | cut -d, -f1 | head -n 1)
      [ -n "$OID" ] && $KCADM delete "authentication/flows/$OID" -r team >/dev/null 2>&1 && echo "setup.sh: removed old flow $OLD"
    done
  else
    $KCADM update realms/team -s browserFlow=browser -s "resetCredentialsFlow=reset credentials" >/dev/null
    echo "setup.sh: team flows INCOMPLETE ($B: $(team_count_req "$B"), $RS: $(team_count_req "$RS") required) – Keycloak's own flows bound" >&2
  fi
  GID=$($KCADM get groups -r team --fields id,name --format csv --noquotes 2>/dev/null | grep ',vpn$' | cut -d, -f1 | head -n 1)
  if [ -z "$GID" ]; then
    $KCADM create groups -r team -s name=vpn >/dev/null
    GID=$($KCADM get groups -r team --fields id,name --format csv --noquotes 2>/dev/null | grep ',vpn$' | cut -d, -f1 | head -n 1)
  fi
  if [ -n "${HEADSCALE_OIDC_CLIENT_SECRET:-}" ]; then
    HS_SECRET="${HEADSCALE_OIDC_CLIENT_SECRET//[$'\r\n\t ']/}"
    HS_ARGS=(-s name="Headscale (team VPN)" -s enabled=true -s publicClient=false -s standardFlowEnabled=true
             -s directAccessGrantsEnabled=false -s implicitFlowEnabled=false -s serviceAccountsEnabled=false
             -s clientAuthenticatorType=client-secret -s "secret=$HS_SECRET" -s consentRequired=false
             -s 'redirectUris=["https://headscale.test.neb-network.app/oidc/callback"]' -s 'webOrigins=[]'
             -s 'attributes."pkce.code.challenge.method"=S256')
    CID=$($KCADM get clients -r team -q clientId=headscale --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    if [ -z "$CID" ]; then
      $KCADM create clients -r team -s clientId=headscale "${HS_ARGS[@]}" >/dev/null
      CID=$($KCADM get clients -r team -q clientId=headscale --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    else
      $KCADM update "clients/$CID" -r team "${HS_ARGS[@]}" >/dev/null
    fi
    # group names in the token (claim "groups") – Headscale only lets members of "vpn" in (oidc.allowed_groups)
    if ! $KCADM get "clients/$CID/protocol-mappers/models" -r team --fields name --format csv --noquotes 2>/dev/null | grep -q '^groups$'; then
      $KCADM create "clients/$CID/protocol-mappers/models" -r team -s name=groups -s protocol=openid-connect \
        -s protocolMapper=oidc-group-membership-mapper -s 'config."claim.name"=groups' -s 'config."full.path"=false' \
        -s 'config."id.token.claim"=true' -s 'config."access.token.claim"=true' -s 'config."userinfo.token.claim"=true' >/dev/null
    fi
    echo "setup.sh: team client headscale ready"
  fi
  WANT=" "
  SUPER=" "
  while IFS=$'\t' read -r U EMAIL FIRST LAST SA RESET_MS; do
    [ -n "$U" ] || continue
    if [ "$SA" = 1 ]; then RA='["webauthn-register"]'; else RA='["CONFIGURE_TOTP"]'; fi
    TID=$($KCADM get users -r team -q username="$U" -q exact=true --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    if [ -z "$TID" ]; then
      # no password: the person uses "Forgot password?" on the login page, then sets up an authenticator app
      $KCADM create users -r team -s username="$U" -s email="$EMAIL" -s firstName="$FIRST" -s lastName="$LAST" \
        -s enabled=true -s emailVerified=true -s "requiredActions=$RA" >/dev/null \
        && echo "setup.sh: team account $U created"
      TID=$($KCADM get users -r team -q username="$U" -q exact=true --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    else
      $KCADM update "users/$TID" -r team -s email="$EMAIL" -s emailVerified=true >/dev/null
    fi
    [ -n "$TID" ] && [ -n "$GID" ] || continue
    $KCADM update "users/$TID/groups/$GID" -r team -s realm=team -s userId="$TID" -s groupId="$GID" -n >/dev/null
    # second factor reset (lost/wrong device): team-users.json "reset_second_factor_before" → passkeys/codes created
    # before that moment are deleted once; the next login sets up a new one (credentials made later are kept)
    if [ -n "${RESET_MS:-}" ] && [ "$RESET_MS" != 0 ]; then
      NDEL=0
      while IFS=, read -r CID2 CTYPE CDATE; do
        case "$CTYPE" in webauthn|otp) ;; *) continue ;; esac
        [ -n "$CDATE" ] && [ "$CDATE" -lt "$RESET_MS" ] 2>/dev/null || continue
        $KCADM delete "users/$TID/credentials/$CID2" -r team >/dev/null && NDEL=$((NDEL + 1))
      done < <($KCADM get "users/$TID/credentials" -r team --fields id,type,createdDate --format csv --noquotes 2>/dev/null)
      if [ "$NDEL" -gt 0 ]; then
        $KCADM update "users/$TID" -r team -s "requiredActions=$RA" >/dev/null
        echo "setup.sh: team account $U: $NDEL old second factor(s) removed – set up again on next login"
      fi
    fi
    WANT="$WANT$TID "
    if [ "$SA" = 1 ]; then
      $KCADM add-roles -r team --uid "$TID" --rolename superadmin >/dev/null && SUPER="$SUPER$U "
    fi
  done < /opt/nna/realms/team-users.tsv
  # superadmin only for who is marked in the list
  for M in $($KCADM get roles/superadmin/users -r team --fields username --format csv --noquotes 2>/dev/null); do
    case "$SUPER" in *" $M "*) ;; *) $KCADM remove-roles -r team --uusername "$M" --rolename superadmin >/dev/null \
      && echo "setup.sh: removed superadmin from $M" ;; esac
  done
  # whoever is in "vpn" but no longer in the list loses VPN logins
  if [ -n "$GID" ]; then
    for M in $($KCADM get "groups/$GID/members" -r team --fields id --format csv --noquotes 2>/dev/null); do
      case "$WANT" in *" $M "*) ;; *) $KCADM delete "users/$M/groups/$GID" -r team >/dev/null && echo "setup.sh: removed $M from vpn" ;; esac
    done
  fi
  echo "setup.sh: team accounts in line with team-users.json"
fi
# 8. realm "material" – login of the material library (since 2026-11-14, own realm next to "nna"): sign-up with
#    e-mail confirmation, reset, account deletion; no Google/Apple. Client "material-library" (public, PKCE) from
#    realms/material-<env>-client.json, re-applied on every start. auth-service (grant_type=material) checks the tokens.
MAT_SETTINGS="/opt/nna/realms/material-${ENV_NAME}-settings.json"
MAT_CLIENT="/opt/nna/realms/material-${ENV_NAME}-client.json"
if [ -f "$MAT_SETTINGS" ] && $KCADM get realms/material --fields realm >/dev/null 2>&1; then
  $KCADM update realms/material -f "$MAT_SETTINGS" && echo "setup.sh: material realm settings applied"
  smtp_password material
  $KCADM add-roles -r material --rname default-roles-material --cclientid account \
    --rolename view-profile --rolename manage-account --rolename delete-account >/dev/null 2>&1 \
    && echo "setup.sh: material default roles incl. delete-account"
  password_on_signup material
  if [ -f "$MAT_CLIENT" ]; then
    CID=$($KCADM get clients -r material -q clientId=material-library --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    if [ -z "$CID" ]; then
      $KCADM create clients -r material -f "$MAT_CLIENT" >/dev/null && echo "setup.sh: material client created"
    else
      $KCADM update "clients/$CID" -r material -f "$MAT_CLIENT" >/dev/null && echo "setup.sh: material client updated"
    fi
  fi
elif [ -f "$MAT_SETTINGS" ]; then
  echo "setup.sh: realm material missing – it is imported on the next start (start.sh)" >&2
fi
# 9. realm "crm" – login of EspoCRM (crm.neb-network.app, since 2026-11-16): no sign-up, accounts only from
#    realms/crm-users.json (generated crm-users.tsv): missing ones are created without a password ("Forgot password?"
#    on the login page), accounts no longer listed are disabled. Client "espocrm" (confidential, PKCE) from
#    realms/crm-<env>-client.json; its secret = env CRM_OIDC_SECRET (generated cluster secret crm-oidc, the same
#    value EspoCRM gets). Re-applied on every start.
CRM_SETTINGS="/opt/nna/realms/crm-${ENV_NAME}-settings.json"
CRM_CLIENT="/opt/nna/realms/crm-${ENV_NAME}-client.json"
if [ -f "$CRM_SETTINGS" ] && $KCADM get realms/crm --fields realm >/dev/null 2>&1; then
  $KCADM update realms/crm -f "$CRM_SETTINGS" && echo "setup.sh: crm realm settings applied"
  smtp_password crm
  if [ -f "$CRM_CLIENT" ] && [ -n "${CRM_OIDC_SECRET:-}" ]; then
    CRM_SECRET="${CRM_OIDC_SECRET//[$'\r\n\t ']/}"
    CID=$($KCADM get clients -r crm -q clientId=espocrm --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    if [ -z "$CID" ]; then
      $KCADM create clients -r crm -f "$CRM_CLIENT" -s "secret=$CRM_SECRET" >/dev/null && echo "setup.sh: crm client espocrm created"
    else
      $KCADM update "clients/$CID" -r crm -f "$CRM_CLIENT" -s "secret=$CRM_SECRET" >/dev/null && echo "setup.sh: crm client espocrm updated"
    fi
  elif [ -f "$CRM_CLIENT" ]; then
    echo "setup.sh: CRM_OIDC_SECRET not set – client espocrm not configured" >&2
  fi
  WANT=" "
  while IFS=$'\t' read -r U EMAIL FIRST LAST; do
    [ -n "$U" ] || continue
    UID2=$($KCADM get users -r crm -q username="$U" -q exact=true --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    if [ -z "$UID2" ]; then
      $KCADM create users -r crm -s username="$U" -s email="$EMAIL" -s firstName="$FIRST" -s lastName="$LAST" \
        -s enabled=true -s emailVerified=true >/dev/null && echo "setup.sh: crm account $U created"
      UID2=$($KCADM get users -r crm -q username="$U" -q exact=true --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    else
      $KCADM update "users/$UID2" -r crm -s email="$EMAIL" -s firstName="$FIRST" -s lastName="$LAST" \
        -s enabled=true -s emailVerified=true >/dev/null
    fi
    [ -n "$UID2" ] && WANT="$WANT$UID2 "
  done < /opt/nna/realms/crm-users.tsv
  # whoever is no longer in the list can no longer sign in (disabled, not deleted)
  while IFS=, read -r M MU; do
    [ -n "$M" ] || continue
    case "$WANT" in *" $M "*) ;; *) $KCADM update "users/$M" -r crm -s enabled=false >/dev/null && echo "setup.sh: crm account $MU disabled" ;; esac
  done < <($KCADM get users -r crm --fields id,username --format csv --noquotes 2>/dev/null)
  echo "setup.sh: crm accounts in line with crm-users.json"
elif [ -f "$CRM_SETTINGS" ]; then
  echo "setup.sh: realm crm missing – it is imported on the next start (start.sh)" >&2
fi
# 10. realm "verleih" – login of the Verleihschrank Zeitz (since 2026-11-19), like "material": sign-up with e-mail
#     confirmation, reset, account deletion; no Google/Apple. User profile (birthday, address, phone required at
#     sign-up) from realms/verleih-profile.json. Client "verleihschrank" (public, PKCE) from
#     realms/verleih-<env>-client.json. Service client "verleihschrank-backend" (realms/verleih-backend-client.json):
#     secret = env VERLEIH_BACKEND_SECRET (cluster secret, created by an admin, never in git) – read users and
#     grant/revoke the roles Verified/Verifier. All re-applied on every start.
VL_SETTINGS="/opt/nna/realms/verleih-${ENV_NAME}-settings.json"
VL_CLIENT="/opt/nna/realms/verleih-${ENV_NAME}-client.json"
VL_BACKEND="/opt/nna/realms/verleih-backend-client.json"
VL_PROFILE="/opt/nna/realms/verleih-profile.json"
if [ -f "$VL_SETTINGS" ] && $KCADM get realms/verleih --fields realm >/dev/null 2>&1; then
  $KCADM update realms/verleih -f "$VL_SETTINGS" && echo "setup.sh: verleih realm settings applied"
  smtp_password verleih
  $KCADM add-roles -r verleih --rname default-roles-verleih --cclientid account \
    --rolename view-profile --rolename manage-account --rolename delete-account >/dev/null 2>&1 \
    && echo "setup.sh: verleih default roles incl. delete-account"
  password_on_signup verleih
  # roles (the realm may predate one – import only runs once)
  for R in User Verified Verifier Admin; do
    $KCADM get "roles/$R" -r verleih >/dev/null 2>&1 || { $KCADM create roles -r verleih -s name="$R" >/dev/null \
      && echo "setup.sh: verleih role $R created"; }
  done
  if [ -f "$VL_PROFILE" ]; then
    $KCADM update users/profile -r verleih -f "$VL_PROFILE" >/dev/null && echo "setup.sh: verleih user profile applied"
  fi
  if [ -f "$VL_CLIENT" ]; then
    CID=$($KCADM get clients -r verleih -q clientId=verleihschrank --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    if [ -z "$CID" ]; then
      $KCADM create clients -r verleih -f "$VL_CLIENT" >/dev/null && echo "setup.sh: verleih client created"
    else
      $KCADM update "clients/$CID" -r verleih -f "$VL_CLIENT" >/dev/null && echo "setup.sh: verleih client updated"
      # a client update leaves its mappers alone: keep the token claims (roles, birthday, street, postalCode, city,
      # phone) in line with realms/verleih-mapper-<name>.json – create missing ones, update existing ones
      for MF in /opt/nna/realms/verleih-mapper-*.json; do
        [ -f "$MF" ] || continue
        MN="${MF##*/verleih-mapper-}"; MN="${MN%.json}"
        MID=""
        while IFS=, read -r ID NM; do [ "$NM" = "$MN" ] && MID="$ID"; done \
          < <($KCADM get "clients/$CID/protocol-mappers/models" -r verleih --fields id,name --format csv --noquotes 2>/dev/null)
        if [ -z "$MID" ]; then
          $KCADM create "clients/$CID/protocol-mappers/models" -r verleih -f "$MF" >/dev/null && echo "setup.sh: verleih mapper $MN added"
        else
          $KCADM update "clients/$CID/protocol-mappers/models/$MID" -r verleih -f "$MF" -s "id=$MID" >/dev/null \
            || echo "setup.sh: verleih mapper $MN not updated" >&2
        fi
      done
    fi
  fi
  if [ -f "$VL_BACKEND" ] && [ -n "${VERLEIH_BACKEND_SECRET:-}" ]; then
    VL_SECRET="${VERLEIH_BACKEND_SECRET//[$'\r\n\t ']/}"
    CID=$($KCADM get clients -r verleih -q clientId=verleihschrank-backend --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    if [ -z "$CID" ]; then
      $KCADM create clients -r verleih -f "$VL_BACKEND" -s "secret=$VL_SECRET" >/dev/null && echo "setup.sh: verleih backend client created"
      CID=$($KCADM get clients -r verleih -q clientId=verleihschrank-backend --fields id --format csv --noquotes 2>/dev/null | head -n 1)
    else
      $KCADM update "clients/$CID" -r verleih -f "$VL_BACKEND" -s "secret=$VL_SECRET" >/dev/null && echo "setup.sh: verleih backend client updated"
    fi
    # Keycloak 26.6+: admin API tokens need the scope "kc-admin-api" with the admin-API audience (as for nna-backend)
    SID=$($KCADM get client-scopes -r verleih --fields id,name --format csv --noquotes 2>/dev/null | grep ',kc-admin-api$' | cut -d, -f1)
    if [ -z "$SID" ]; then
      $KCADM create client-scopes -r verleih -s name=kc-admin-api -s protocol=openid-connect \
        -s 'attributes."include.in.token.scope"=true' -s 'attributes."display.on.consent.screen"=false' >/dev/null
      SID=$($KCADM get client-scopes -r verleih --fields id,name --format csv --noquotes 2>/dev/null | grep ',kc-admin-api$' | cut -d, -f1)
    fi
    if [ -n "$SID" ] && ! $KCADM get "client-scopes/$SID/protocol-mappers/models" -r verleih --fields name --format csv --noquotes 2>/dev/null | grep -q '^admin-api-audience$'; then
      $KCADM create "client-scopes/$SID/protocol-mappers/models" -r verleih -s name=admin-api-audience -s protocol=openid-connect \
        -s protocolMapper=oidc-admin-api-audience-mapper -s 'config."access.token.claim"=true' >/dev/null
    fi
    [ -n "$CID" ] && [ -n "$SID" ] && $KCADM update "clients/$CID/default-client-scopes/$SID" -r verleih >/dev/null 2>&1 \
      && echo "setup.sh: kc-admin-api scope on verleihschrank-backend"
    # read users + change their role mappings (needed to grant/revoke Verified/Verifier). Keycloak has no narrower
    # built-in role for "map only these realm roles" – the backend must only ever touch Verified and Verifier.
    $KCADM add-roles -r verleih --uusername service-account-verleihschrank-backend --cclientid realm-management \
      --rolename view-users --rolename manage-users >/dev/null && echo "setup.sh: verleih backend service account ready"
  elif [ -f "$VL_BACKEND" ]; then
    echo "setup.sh: VERLEIH_BACKEND_SECRET not set – client verleihschrank-backend not configured" >&2
  fi
elif [ -f "$VL_SETTINGS" ]; then
  echo "setup.sh: realm verleih missing – it is imported on the next start (start.sh)" >&2
fi
echo "setup.sh: done"
