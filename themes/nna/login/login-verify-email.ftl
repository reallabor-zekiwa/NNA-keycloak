<#import "template.ftl" as layout>
<#import "buttons.ftl" as buttons>
<@layout.registrationLayout displayInfo=!isAppInitiatedAction??; section>
<!-- template: login-verify-email.ftl (NNA: keycloak.v2 26.8.2 + auto-continue) -->
    <#if section = "header">
        ${msg("emailVerifyTitle")}
    <#elseif section = "form">
        <p class="instruction">
            <#if verifyEmail??>
                ${msg("emailVerifyInstruction1",verifyEmail)}
            <#else>
                ${msg("emailVerifyInstruction4",user.email)}
            </#if>
        </p>
        <#if isAppInitiatedAction??>
            <form id="kc-verify-email-form" class="${properties.kcFormClass!}" action="${url.loginAction}" method="post">
                <@buttons.actionGroup horizontal=true>
                    <#if verifyEmail??>
                        <@buttons.button id="kc-resend" label="emailVerifyResend" type="secondary"/>
                    <#else>
                        <@buttons.button id="kc-send" label="emailVerifySend"/>
                    </#if>
                    <@buttons.button id="kc-cancel" label="doCancel" type="secondary" name="cancel-aia" value="true"/>
                </@buttons.actionGroup>
            </form>
        </#if>
    <#elseif section = "info">
        <#if !isAppInitiatedAction??>
            <p class="instruction">
                ${msg("emailVerifyInstruction2")}
                <br/>
                <a href="${url.loginAction}">${msg("doClickHere")}</a> ${msg("emailVerifyInstruction3")}
            </p>
            <#-- NNA (2026-11-11): continue by itself once the address is confirmed – often on another device or in
                 another browser (mail app → Safari) while this page waits inside the app. Opening this page again
                 never re-sends the mail (Keycloak VerifyEmail); once confirmed it redirects (→ app, or → sign-in
                 form when the account was created in this session). -->
            <span id="nna-verify-poll" data-url="${url.loginAction}" data-email="${(verifyEmail!(user.email)!'')}" hidden></span>
            <script>
              (function () {
                var url = document.getElementById("nna-verify-poll").getAttribute("data-url");
                var tries = 0;
                function check() {
                  if (document.hidden) { setTimeout(check, 3000); return; }
                  if (++tries > 200) return;                       // ~15 min
                  fetch(url, { credentials: "include", redirect: "manual", cache: "no-store" })
                    .then(function (r) {
                      if (r.type === "opaqueredirect" || (r.status >= 300 && r.status < 400)) {
                        // confirmed elsewhere: the next page (Keycloak restarts the sign-in) says so and fills in the email
                        try { sessionStorage.setItem("nna-email-confirmed", JSON.stringify({ email: document.getElementById("nna-verify-poll").getAttribute("data-email") || "", at: Date.now() })); } catch (e) {}
                        window.location.assign(url);
                      }
                      else setTimeout(check, 4000);
                    })
                    .catch(function () { setTimeout(check, 8000); });
                }
                setTimeout(check, 4000);
              })();
            </script>
        </#if>
    </#if>
</@layout.registrationLayout>
