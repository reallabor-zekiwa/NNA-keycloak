#!/usr/bin/env python3
"""Writes realms/nna-test.json and realms/nna-prod.json (the realm "nna" as Keycloak imports it on first start).
Edit here (team VPN accounts: team-users.json), run `python3 realms/make_realms.py`, commit the generated files. No secrets in here: Google/Apple client
secrets are entered in the admin console (Identity providers) – they then live only in Keycloak's database."""
import json
from pathlib import Path

PEOPLE = ["nigel", "siamak", "vitalina", "yigit", "hermann"]   # personal environments (NNA-deployment k8s/personal.json)

ENVS = {
    "test": {
        "display": "NEB Network (Test)",
        "kicker": "Welcome to · Test",
        "from": "noreply-test@neb-network.app",
        "smtp_user": "keycloak-test@neb-network.app",   # login at the mail service (password: env MAIL_SMTP_PASSWORD)
        "apps": ["https://the.test.neb-network.app", "https://admin.test.neb-network.app", "https://test.neb-network.app"]
                + [f"https://{a}-{p}.dev.neb-network.app" for p in PEOPLE for a in ("the", "admin")]
                + [f"https://{p}.dev.neb-network.app" for p in PEOPLE]
                + ["http://localhost:3000", "http://localhost:5173"],
    },
    "prod": {
        "display": "NEB Network",
        "kicker": "Welcome to",
        "from": "noreply@neb-network.app",
        "smtp_user": "keycloak-prod@neb-network.app",
        "apps": ["https://the.neb-network.app", "https://admin.neb-network.app",
                 "https://neb-network.app", "https://www.neb-network.app"],
    },
}


def client(cid, name, origins):
    return {
        "clientId": cid, "name": name, "enabled": True, "publicClient": True, "protocol": "openid-connect",
        "standardFlowEnabled": True, "directAccessGrantsEnabled": False, "implicitFlowEnabled": False,
        "redirectUris": [o + "/*" for o in origins], "webOrigins": origins,
        "attributes": {"pkce.code.challenge.method": "S256", "post.logout.redirect.uris": "+"},
        "frontchannelLogout": True, "fullScopeAllowed": True,
    }


def smtp(e, display):
    return {"host": "mail.nna-prod.svc.cluster.local", "port": "587", "from": e["from"], "fromDisplayName": display,
            "replyTo": "", "auth": "true", "user": e["smtp_user"], "ssl": "false", "starttls": "false"}


def realm(env):
    e = ENVS[env]
    return {
        "realm": "nna", "enabled": True, "displayName": e["display"],
        # the login page's header in the app's style (theme "nna"): "Welcome to" over "NEB Network"
        "displayNameHtml": '<span class="nna-kicker">' + e["kicker"] + '</span>NEB Network',
        "loginTheme": "nna",
        # sign-up, e-mail login, confirmation, password reset
        "registrationAllowed": True, "registrationEmailAsUsername": True, "loginWithEmailAllowed": True,
        "duplicateEmailsAllowed": False, "verifyEmail": True, "resetPasswordAllowed": True,
        "rememberMe": True, "editUsernameAllowed": False,
        # brute-force protection: lock for a while after 5 wrong passwords
        "bruteForceProtected": True, "failureFactor": 5, "waitIncrementSeconds": 60,
        "maxFailureWaitSeconds": 900, "maxDeltaTimeSeconds": 43200, "permanentLockout": False,
        "passwordPolicy": "length(8) and notUsername and notEmail",
        "sslRequired": "external",
        "internationalizationEnabled": True, "supportedLocales": ["de", "en"], "defaultLocale": "de",
        "accessTokenLifespan": 900, "ssoSessionIdleTimeout": 2592000, "ssoSessionMaxLifespan": 7776000,
        "offlineSessionIdleTimeout": 7776000,
        # mails go through our own mail service on k8s-prod (internal only, NNA-deployment service "mail").
        # Since 2026-11-13 with a login: the mail service only accepts this user and only the "from" address above;
        # the password comes from the cluster (env MAIL_SMTP_PASSWORD) and is set by setup.sh on every start.
        "smtpServer": smtp(e, e["display"]),
        "roles": {"realm": [
            {"name": "User", "description": "Normal NNA account"},
            {"name": "Admin", "description": "NNA admin panel"},
            {"name": "offline_access", "description": "${role_offline-access}"},
            {"name": "uma_authorization", "description": "${role_uma_authorization}"},
            # account roles (view-profile, manage-account, delete-account) are added to the default role after the
            # first start – the "account" client only exists once the realm is created (not yet during the import)
            {"name": "default-roles-nna", "composite": True, "composites": {
                "realm": ["User", "offline_access", "uma_authorization"]}},
        ]},
        "defaultRole": {"name": "default-roles-nna", "composite": True},
        # users may delete their own account (Apple guideline 5.1.1(v))
        "requiredActions": [
            {"alias": "delete_account", "name": "Delete Account", "providerId": "delete_account",
             "enabled": True, "defaultAction": False, "priority": 60, "config": {}},
            {"alias": "VERIFY_EMAIL", "name": "Verify Email", "providerId": "VERIFY_EMAIL",
             "enabled": True, "defaultAction": False, "priority": 50, "config": {}},
            {"alias": "UPDATE_PASSWORD", "name": "Update Password", "providerId": "UPDATE_PASSWORD",
             "enabled": True, "defaultAction": False, "priority": 30, "config": {}},
        ],
        "clients": [
            client("nna-webxr", "NEB Network App", [o for o in e["apps"] if "admin" not in o]),
            client("nna-admin", "NEB Network Admin", [o for o in e["apps"] if "admin" in o or "localhost" in o]),
        ],
        "eventsEnabled": True, "eventsExpiration": 2592000, "adminEventsEnabled": True,
        "enabledEventTypes": ["LOGIN", "LOGIN_ERROR", "REGISTER", "REGISTER_ERROR", "DELETE_ACCOUNT",
                              "VERIFY_EMAIL", "SEND_RESET_PASSWORD", "UPDATE_PASSWORD", "IDENTITY_PROVIDER_LOGIN"],
    }


# ---------------------------------------------------------------------------------------------------------------
# Realm "team" (prod only, since 2026-11-12): the team's VPN login. Headscale (headscale.test.neb-network.app) signs
# people in here instead of handing out keys. Separate from "nna" on purpose: no sign-up, no Google/Apple, accounts
# only from realms/team-users.json (setup.sh), password + authenticator code required (superadmins: password + passkey
# instead), users cannot edit their account (no account console roles) – so they cannot remove it or rename themselves.
# The username IS the VPN name (= Headscale user = personal environment in NNA-deployment k8s/personal.json).
TEAM_HEADSCALE = "https://headscale.test.neb-network.app"


def team_realm():
    e = ENVS["prod"]
    return {
        "realm": "team", "enabled": True, "displayName": "NEB Network · Team VPN",
        "displayNameHtml": '<span class="nna-kicker">Team VPN</span>NEB Network',
        "loginTheme": "nna",
        "registrationAllowed": False, "registrationEmailAsUsername": False, "loginWithEmailAllowed": True,
        "duplicateEmailsAllowed": False, "verifyEmail": False, "resetPasswordAllowed": True,
        "rememberMe": False, "editUsernameAllowed": False,
        "bruteForceProtected": True, "failureFactor": 5, "waitIncrementSeconds": 60,
        "maxFailureWaitSeconds": 900, "maxDeltaTimeSeconds": 43200, "permanentLockout": False,
        "passwordPolicy": "length(12) and notUsername and notEmail",
        "otpPolicyType": "totp", "otpPolicyAlgorithm": "HmacSHA1", "otpPolicyDigits": 6, "otpPolicyPeriod": 30,
        # passkey (WebAuthn) for superadmins: Face ID / fingerprint / device PIN required, bound to auth.neb-network.app
        "webAuthnPolicyRpEntityName": "NEB Network Team VPN", "webAuthnPolicyUserVerificationRequirement": "required",
        "webAuthnPolicyRequireResidentKey": "No", "webAuthnPolicyAttestationConveyancePreference": "not specified",
        "sslRequired": "external",
        "internationalizationEnabled": True, "supportedLocales": ["de", "en"], "defaultLocale": "en",
        "accessTokenLifespan": 300, "ssoSessionIdleTimeout": 1800, "ssoSessionMaxLifespan": 36000,
        "smtpServer": smtp(e, "NEB Network · Team VPN"),
        # no account-console roles: the default role holds nothing a user could use to change their account
        "roles": {"realm": [{"name": "default-roles-team", "composite": False},
                            {"name": "superadmin", "description": "VPN admin – login needs a passkey (setup.sh flow 'team browser')"}]},
        "defaultRole": {"name": "default-roles-team", "composite": False},
        "groups": [{"name": "vpn"}],
        "requiredActions": [
            {"alias": "CONFIGURE_TOTP", "name": "Configure OTP", "providerId": "CONFIGURE_TOTP",
             "enabled": True, "defaultAction": False, "priority": 10, "config": {}},
            {"alias": "webauthn-register", "name": "Webauthn Register", "providerId": "webauthn-register",
             "enabled": True, "defaultAction": False, "priority": 20, "config": {}},
            {"alias": "UPDATE_PASSWORD", "name": "Update Password", "providerId": "UPDATE_PASSWORD",
             "enabled": True, "defaultAction": False, "priority": 30, "config": {}},
        ],
        "eventsEnabled": True, "eventsExpiration": 7776000, "adminEventsEnabled": True,
        "enabledEventTypes": ["LOGIN", "LOGIN_ERROR", "SEND_RESET_PASSWORD", "UPDATE_PASSWORD",
                              "UPDATE_TOTP", "REMOVE_TOTP", "CODE_TO_TOKEN_ERROR"],
    }


# Client "nna-admin" in realm team (since 2026-11-13): the admin panel (admin.neb-network.app, admin.test…, the personal
# admin-<name>.dev…) signs in ONLY with the team account – same people, same password + second factor as the VPN, no
# sign-up. auth-service (grant_type=team) checks the token and the group "vpn" (claim "groups") and gives an admin
# session. Created/updated by setup.sh on every start (the realm already exists, so an import would not add it).
def team_admin_client():
    hosts = (["https://admin.neb-network.app", "https://admin.test.neb-network.app"]
             + [f"https://admin-{p}.dev.neb-network.app" for p in PEOPLE])
    return {
        "clientId": "nna-admin", "name": "NEB Network Admin (team login)", "enabled": True, "publicClient": True,
        "protocol": "openid-connect", "standardFlowEnabled": True, "directAccessGrantsEnabled": False,
        "implicitFlowEnabled": False, "serviceAccountsEnabled": False, "consentRequired": False,
        "redirectUris": [h + "/*" for h in hosts], "webOrigins": hosts,
        "attributes": {"pkce.code.challenge.method": "S256", "post.logout.redirect.uris": "+"},
        "frontchannelLogout": True, "fullScopeAllowed": False,
        "protocolMappers": [{
            "name": "groups", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper",
            "config": {"claim.name": "groups", "full.path": "false", "id.token.claim": "true",
                       "access.token.claim": "true", "userinfo.token.claim": "true"}}],
    }


# ---------------------------------------------------------------------------------------------------------------
# Realm "material" (since 2026-11-14): the login of the material library (materialien.neb-network.app) – its OWN realm,
# separate from the NNA app's "nna" (Nigel 2026-11-14): own sign-up, confirmation + reset mails, own accounts.
# The library's frontend signs in here (client "material-library", PKCE) and hands the token to its environment's
# auth-service (grant_type=material) – that links an existing library account by its confirmed e-mail and answers with
# the usual tokens, so the material backend stays unchanged. Created on first start (import), settings re-applied by
# setup.sh on every start like "nna". Test realm also serves the personal environments.
MATERIAL_HOSTS = {
    "test": ["https://materialien.test.neb-network.app"]
            + [f"https://materialien-{p}.dev.neb-network.app" for p in PEOPLE]
            + ["http://localhost:3000", "http://localhost:5173"],
    "prod": ["https://materialien.neb-network.app", "https://materialien.reallabor-zekiwa-zeitz.de"],
}


def material_realm(env):
    e = ENVS[env]
    name = "Materialbibliothek" + (" (Test)" if env == "test" else "")
    r = realm(env)
    r.update({
        "realm": "material", "displayName": name,
        "displayNameHtml": '<span class="nna-kicker">' + ("Test · " if env == "test" else "") + 'Materialbibliothek</span>NEB Network',
        "smtpServer": smtp(e, name),
        "roles": {"realm": [
            {"name": "User", "description": "Material library account"},
            {"name": "offline_access", "description": "${role_offline-access}"},
            {"name": "uma_authorization", "description": "${role_uma_authorization}"},
            {"name": "default-roles-material", "composite": True, "composites": {
                "realm": ["User", "offline_access", "uma_authorization"]}},
        ]},
        "defaultRole": {"name": "default-roles-material", "composite": True},
        "clients": [client("material-library", name, MATERIAL_HOSTS[env])],
    })
    r["enabledEventTypes"] = [t for t in r["enabledEventTypes"] if t != "IDENTITY_PROVIDER_LOGIN"]
    return r


if __name__ == "__main__":
    here = Path(__file__).parent
    for env in ENVS:
        r = realm(env)
        (here / f"nna-{env}.json").write_text(json.dumps(r, indent=2) + "\n")
        # settings applied on EVERY start by setup.sh (kcadm update realms/nna) – realm attributes only
        settings = {k: v for k, v in r.items() if k not in ("realm", "roles", "clients", "requiredActions", "defaultRole")}
        (here / f"nna-{env}-settings.json").write_text(json.dumps(settings, indent=2) + "\n")
        print("wrote", here / f"nna-{env}.json", "+ settings")
    for env in ENVS:   # realm "material" (material library login)
        r = material_realm(env)
        (here / f"material-{env}.json").write_text(json.dumps(r, indent=2) + "\n")
        settings = {k: v for k, v in r.items() if k not in ("realm", "roles", "clients", "requiredActions", "defaultRole")}
        (here / f"material-{env}-settings.json").write_text(json.dumps(settings, indent=2) + "\n")
        # the client is re-applied by setup.sh too (an import only runs once; new hosts must reach existing realms)
        (here / f"material-{env}-client.json").write_text(json.dumps(r["clients"][0], indent=2) + "\n")
        print("wrote", here / f"material-{env}.json", "+ settings + client")
    # client "nna-admin" in realm team: the admin panels of all environments sign in with the team account
    (here / "team-admin-client.json").write_text(json.dumps(team_admin_client(), indent=2) + "\n")
    print("wrote", here / "team-admin-client.json")
    r = team_realm()
    (here / "team-prod.json").write_text(json.dumps(r, indent=2) + "\n")
    settings = {k: v for k, v in r.items() if k not in ("realm", "roles", "groups", "requiredActions", "defaultRole")}
    (here / "team-prod-settings.json").write_text(json.dumps(settings, indent=2) + "\n")
    print("wrote", here / "team-prod.json", "+ settings")
    # team-users.json → tab-separated list for setup.sh (the Keycloak image has no JSON tool)
    tu = json.loads((here / "team-users.json").read_text())
    rows = []
    for u in tu["users"]:
        assert all("\t" not in str(v) and "\n" not in str(v) for v in u.values())
        # reset_second_factor_before: ISO time (UTC) – passkeys/codes created before it are removed once
        reset_ms = 0
        if u.get("reset_second_factor_before"):
            from datetime import datetime
            reset_ms = int(datetime.fromisoformat(u["reset_second_factor_before"].replace("Z", "+00:00")).timestamp() * 1000)
        rows.append("\t".join([u["username"], u["email"], u.get("firstName", ""), u.get("lastName", ""),
                               "1" if u.get("superadmin") else "0", str(reset_ms)]))
    (here / "team-users.tsv").write_text("\n".join(rows) + "\n")
    print("wrote", here / "team-users.tsv", f"({len(rows)} accounts)")
