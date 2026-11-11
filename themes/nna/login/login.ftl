<#import "template.ftl" as layout>
<#import "field.ftl" as field>
<#import "buttons.ftl" as buttons>
<#import "social-providers.ftl" as identityProviders>
<#import "passkeys.ftl" as passkeys>
<@layout.registrationLayout displayMessage=!messagesPerField.existsError('username','password') displayInfo=realm.password && realm.registrationAllowed && !registrationDisabled??; section>
<!-- template: login.ftl (NNA: keycloak.v2 26.8.2; e-mail from the app shown as text, only the password asked) -->

    <#-- NNA: the app's "Continue with email" passes the address (login_hint) – show it, ask only for the password -->
    <#assign nnaHint = (!usernameHidden?? && (login.username!'')?has_content)>
    <#if section = "header">
        <#if nnaHint>${msg("nnaEnterPassword")}<#else>${msg("loginAccountTitle")}</#if>
    <#elseif section = "form">
        <div id="kc-form">
          <div id="kc-form-wrapper">
            <#if realm.password>
                <form id="kc-form-login" class="${properties.kcFormClass!}" onsubmit="login.disabled = true; return true;" action="${url.loginAction}" method="post" novalidate="novalidate">
                    <#if !usernameHidden??>
                        <#assign label>
                            <#if !realm.loginWithEmailAllowed>${msg("username")}<#elseif !realm.registrationEmailAsUsername>${msg("usernameOrEmail")}<#else>${msg("email")}</#if>
                        </#assign>
                        <#if nnaHint>
                            <div class="nna-email" id="nna-email">
                                <span class="nna-email-addr">${login.username}</span>
                                <button type="button" class="nna-link" id="nna-email-change">${msg("nnaChangeEmail")}</button>
                            </div>
                            <#if messagesPerField.existsError('username','password')>
                                <p class="nna-field-error" aria-live="polite">${kcSanitize(messagesPerField.getFirstError('username','password'))?no_esc}</p>
                            </#if>
                        </#if>
                        <div id="nna-user-field"<#if nnaHint> hidden</#if>>
                        <@field.input name="username" label=label error=nnaHint?then('', messagesPerField.getFirstError('username','password'))
                            autofocus=!nnaHint autocomplete="${(enableWebAuthnConditionalUI?has_content)?then('username webauthn', 'username')}" value=login.username!'' />
                        </div>
                        <#if nnaHint>
                            <script>
                              document.getElementById("nna-email-change").addEventListener("click", function () {
                                document.getElementById("nna-email").hidden = true;
                                var f = document.getElementById("nna-user-field"); f.hidden = false;
                                var i = document.getElementById("username"); i.focus(); i.select();
                              });
                            </script>
                        </#if>
                        <@field.password name="password" label=msg("password") error="" forgotPassword=realm.resetPasswordAllowed autofocus=nnaHint autocomplete="current-password">
                            <#if realm.rememberMe && !usernameHidden??>
                                <@field.checkbox name="rememberMe" label=msg("rememberMe") value=login.rememberMe?? />
                            </#if>
                        </@field.password>
                    <#else>
                        <@field.password name="password" label=msg("password") forgotPassword=realm.resetPasswordAllowed autofocus=usernameHidden?? autocomplete="current-password">
                            <#if realm.rememberMe && !usernameHidden??>
                                <@field.checkbox name="rememberMe" label=msg("rememberMe") value=login.rememberMe?? />
                            </#if>
                        </@field.password>
                    </#if>

                    <input type="hidden" id="id-hidden-input" name="credentialId" <#if auth.selectedCredential?has_content>value="${auth.selectedCredential}"</#if>/>
                    <@buttons.loginButton />
                </form>
            </#if>
            </div>
        </div>
        <@passkeys.conditionalUIData />
    <#elseif section = "socialProviders" >
        <#if realm.password && social.providers?? && social.providers?has_content>
            <@identityProviders.show social=social/>
        </#if>
    <#elseif section = "info" >
        <#if realm.password && realm.registrationAllowed && !registrationDisabled??>
            <div id="kc-registration-container">
                <div id="kc-registration">
                    <span>${msg("noAccount")} <a href="${url.registrationUrl}">${msg("doRegister")}</a></span>
                </div>
            </div>
        </#if>
    </#if>

</@layout.registrationLayout>
