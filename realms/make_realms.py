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
        "apps": ["https://the.test.neb-network.app", "https://admin.test.neb-network.app", "https://test.neb-network.app"]
                + [f"https://{a}-{p}.dev.neb-network.app" for p in PEOPLE for a in ("the", "admin")]
                + [f"https://{p}.dev.neb-network.app" for p in PEOPLE]
                + ["http://localhost:3000", "http://localhost:5173"],
    },
    "prod": {
        "display": "NEB Network",
        "kicker": "Welcome to",
        "from": "noreply@neb-network.app",
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
        # mails go through our own mail service on k8s-prod (internal only, NNA-deployment service "mail")
        "smtpServer": {"host": "mail.nna-prod.svc.cluster.local", "port": "587", "from": e["from"],
                       "fromDisplayName": e["display"], "replyTo": "", "auth": "false", "ssl": "false",
                       "starttls": "false"},
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
        "smtpServer": {"host": "mail.nna-prod.svc.cluster.local", "port": "587", "from": e["from"],
                       "fromDisplayName": "NEB Network · Team VPN", "replyTo": "", "auth": "false", "ssl": "false",
                       "starttls": "false"},
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


if __name__ == "__main__":
    here = Path(__file__).parent
    for env in ENVS:
        r = realm(env)
        (here / f"nna-{env}.json").write_text(json.dumps(r, indent=2) + "\n")
        # settings applied on EVERY start by setup.sh (kcadm update realms/nna) – realm attributes only
        settings = {k: v for k, v in r.items() if k not in ("realm", "roles", "clients", "requiredActions", "defaultRole")}
        (here / f"nna-{env}-settings.json").write_text(json.dumps(settings, indent=2) + "\n")
        print("wrote", here / f"nna-{env}.json", "+ settings")
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
