package com.signops

import android.app.Activity
import android.content.Context
import android.os.Build
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import org.json.JSONObject

/**
 * Passkeys on your own domain, made and used through Android's Credential Manager.
 *
 * Before it works: add the app under Passkeys, Setup in the SignOps dashboard (package name and the SHA-256 of the signing
 * certificate), and host the assetlinks.json it shows at https://<your domain>/.well-known/assetlinks.json.
 */
class Passkeys internal constructor(private val signops: SignOps, context: Context) {
    private val manager = CredentialManager.create(context)

    data class Registered(val credentialId: String, val userId: String, val synced: Boolean)
    data class SignedIn(val signopsToken: String, val expiresAt: String)

    /** Makes a passkey for the user the token was made for. The token comes from your server (POST /v1/passkeys/registration-token). */
    suspend fun register(activity: Activity, token: String, name: String = Build.MODEL ?: "Android"): Registered {
        val options = signops.post("/v1/passkeys/register/options", JSONObject().put("token", token).put("platform", PLATFORM))
        val made = try {
            manager.createCredential(activity, CreatePublicKeyCredentialRequest(options.toString())) as CreatePublicKeyCredentialResponse
        } catch (e: CreateCredentialCancellationException) {
            throw SignOpsException(0, "cancelled", "The user closed the passkey prompt.")
        } catch (e: CreateCredentialException) {
            throw SignOpsException(0, "passkey_error", e.message ?: "The phone could not make a passkey.")
        }
        val out = signops.post(
            "/v1/passkeys/register/verify",
            JSONObject().put("token", token).put("platform", PLATFORM).put("name", name.take(80)).put("response", JSONObject(made.registrationResponseJson)),
        )
        return Registered(out.getString("credential_id"), out.getString("user_id"), out.optBoolean("synced"))
    }

    /**
     * Signs in with a passkey. Without userId the phone offers every passkey it has for your domain; with it, only that
     * user's. Send signopsToken to your server, which checks it with POST /v1/passkeys/verify before starting a session.
     */
    suspend fun signIn(activity: Activity, userId: String? = null): SignedIn {
        val body = JSONObject().put("platform", PLATFORM)
        if (userId != null) body.put("user_id", userId)
        val start = signops.post("/v1/passkeys/signin/options", body)
        val credential = try {
            manager.getCredential(activity, GetCredentialRequest(listOf(GetPublicKeyCredentialOption(start.getJSONObject("options").toString())))).credential
        } catch (e: GetCredentialCancellationException) {
            throw SignOpsException(0, "cancelled", "The user closed the passkey prompt.")
        } catch (e: NoCredentialException) {
            throw SignOpsException(0, "no_passkey", "There is no passkey for this app on the phone.")
        } catch (e: GetCredentialException) {
            throw SignOpsException(0, "passkey_error", e.message ?: "The phone could not use the passkey.")
        }
        val passkey = credential as? PublicKeyCredential ?: throw SignOpsException(0, "no_passkey", "The phone returned something other than a passkey.")
        val out = signops.post(
            "/v1/passkeys/signin/verify",
            JSONObject().put("session", start.getString("session")).put("platform", PLATFORM).put("response", JSONObject(passkey.authenticationResponseJson)),
        )
        return SignedIn(out.getString("signops_token"), out.optString("expires_at"))
    }

    private companion object { const val PLATFORM = "android" }
}
