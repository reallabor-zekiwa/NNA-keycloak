#!/usr/bin/env python3
"""Writes realms/nna-test.json and realms/nna-prod.json (the realm "nna" as Keycloak imports it on first start).
Edit here, run `python3 realms/make_realms.py`, commit both JSON files. No secrets in here: Google/Apple client
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


if __name__ == "__main__":
    here = Path(__file__).parent
    for env in ENVS:
        r = realm(env)
        (here / f"nna-{env}.json").write_text(json.dumps(r, indent=2) + "\n")
        # settings applied on EVERY start by setup.sh (kcadm update realms/nna) – realm attributes only
        settings = {k: v for k, v in r.items() if k not in ("realm", "roles", "clients", "requiredActions", "defaultRole")}
        (here / f"nna-{env}-settings.json").write_text(json.dumps(settings, indent=2) + "\n")
        print("wrote", here / f"nna-{env}.json", "+ settings")
