# NNA-keycloak – the login server of the NEB Network App

Official Keycloak image plus our realm settings (realm `nna`). Later also the Sign in with Apple extension
(`providers/`) and the NNA login design (`themes/`).

| Environment | Address | Image |
|---|---|---|
| test (VPN) | https://auth.test.neb-network.app | `ghcr.io/reallabor-zekiwa/dev/keycloak` (branch `test`) |
| prod | https://auth.neb-network.app | `ghcr.io/reallabor-zekiwa/keycloak` (branch `main`) |

- **Realm settings:** edit `realms/make_realms.py`, run `python3 realms/make_realms.py`, commit the JSON files.
  `nna-<env>.json` creates the realm on the very first start; `nna-<env>-settings.json` (realm attributes) and the
  default roles are re-applied on **every** start by `setup.sh` (kcadm with the bootstrap admin). Clients, roles and
  identity providers created in the admin console stay as they are.
- **Google / Apple sign-in:** cluster secret `env-keycloak` (per namespace, created by an admin, never in git) with
  `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `APPLE_SERVICES_ID`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_P8_KEY`
  (raw .p8 content) – setup.sh configures both identity providers on the next start. Apple uses the extension
  `providers/apple-identity-provider-1.17.0.jar` (klausbetz/apple-identity-provider-keycloak, for Keycloak ≥ 26.5).
- **What the realm does:** sign-up with e-mail, e-mail confirmation, forgot password, users can delete their account,
  brute-force protection, roles `User` (default) and `Admin`. Clients `nna-webxr` and `nna-admin` (public, PKCE S256).
- **Mail:** via the internal mail service `mail.nna-prod.svc.cluster.local:587` (NNA-deployment, k8s-prod); sender
  `noreply@neb-network.app` (prod) / `noreply-test@neb-network.app` (test).
- **No secrets in git:** database and admin passwords are generated in the cluster (`{{secret:…}}` in
  NNA-deployment). Google/Apple client secrets are entered in the admin console → Identity providers.
- **Admin console:** `/admin` on the environment's address (test: VPN only).

## Realm `team` – the team's VPN login (prod only, since 2026-11-12)
Headscale (headscale.test.neb-network.app) signs team members in here instead of handing out keys.
- No sign-up, no Google/Apple; accounts only from `realms/team-users.json` (setup.sh creates missing ones on every start
  and keeps the group `vpn` and the role `superadmin` equal to that list). Username = VPN name = personal environment
  (NNA-deployment `k8s/personal.json`).
- Login (flow `team-browser`): password, then **superadmins (nigel) a passkey** (Face ID / fingerprint, registered on the
  first login), everyone else an authenticator app code. "Forgot password?" (flow `team-reset`): mail link + new password +
  the same second factor – the reset never removes a code or passkey. Lost device → an admin deletes the credential in
  the admin console (VPN only). No account console, so nobody can remove their second factor or rename themselves.
  Flows are built once by setup.sh; to change one, give it a new alias and bind that.
- Client `headscale` (confidential): secret = cluster secret `headscale-oidc` (key `HEADSCALE_OIDC_CLIENT_SECRET`), the same
  value in nna-prod (Keycloak) and nna-test (Headscale); created by an admin, never in git.
- Add/remove a person: edit `team-users.json`, run `python3 realms/make_realms.py`, also add/remove their e-mail in
  Headscale's `oidc.allowed_users` (NNA-deployment), deploy both.

Deploy: NNA-deployment → Actions → "Deploy NNA Services" → service `keycloak`.
