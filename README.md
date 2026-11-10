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
- **Google sign-in:** either in the admin console (Identity providers → Google), or as cluster secret `env-keycloak`
  with `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` – setup.sh then configures it on the next start.
- **What the realm does:** sign-up with e-mail, e-mail confirmation, forgot password, users can delete their account,
  brute-force protection, roles `User` (default) and `Admin`. Clients `nna-webxr` and `nna-admin` (public, PKCE S256).
- **Mail:** via the internal mail service `mail.nna-prod.svc.cluster.local:587` (NNA-deployment, k8s-prod); sender
  `noreply@neb-network.app` (prod) / `noreply-test@neb-network.app` (test).
- **No secrets in git:** database and admin passwords are generated in the cluster (`{{secret:…}}` in
  NNA-deployment). Google/Apple client secrets are entered in the admin console → Identity providers.
- **Admin console:** `/admin` on the environment's address (test: VPN only).

Deploy: NNA-deployment → Actions → "Deploy NNA Services" → service `keycloak`.
