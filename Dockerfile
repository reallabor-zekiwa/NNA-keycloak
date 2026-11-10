# NNA login server: official Keycloak + our realm settings (+ later: Apple sign-in extension, NNA login theme).
# Built by .github/workflows/docker-build.yml, deployed by NNA-deployment (service "keycloak").
ARG KC_VERSION=26.8.2

FROM quay.io/keycloak/keycloak:${KC_VERSION} AS builder
ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true
# Extensions (e.g. Sign in with Apple) go into providers/, themes into themes/ – both are baked in by `kc.sh build`.
COPY providers/ /opt/keycloak/providers/
COPY themes/ /opt/keycloak/themes/
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:${KC_VERSION}
COPY --from=builder /opt/keycloak/ /opt/keycloak/
COPY --chown=1000:0 realms/ /opt/nna/realms/
COPY --chown=1000:0 start.sh setup.sh /opt/nna/
ENTRYPOINT ["/bin/bash", "/opt/nna/start.sh"]
