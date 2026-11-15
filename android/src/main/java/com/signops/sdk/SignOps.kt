package com.signops

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * SignOps in an Android app, with the app's publishable key (pk_live_ or pk_test_). Secret keys stay on your server.
 *
 *     val signops = SignOps(context, "pk_live_...")
 *     signops.passkeys.register(activity, registrationToken)
 *     val r = signops.passkeys.signIn(activity)          // send r.signopsToken to your server
 *     signops.approve.enroll(enrolToken, fcmToken)       // trust this phone for Approve
 *     signops.push.opened(remoteMessage.data)            // count an open
 */
class SignOps @JvmOverloads constructor(
    context: Context,
    val key: String,
    val baseUrl: String = "https://api.signops.dev",
) {
    init {
        checkKey(key)
        // Kept so the SDK's own notification taps (PushTapActivity) can report opens without your code running.
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("key", key).putString("base", baseUrl).apply()
    }

    internal val mode: String = if (key.startsWith("pk_test_")) "test" else "live"

    val passkeys = Passkeys(this, context.applicationContext)
    val approve = Approve(this, context.applicationContext)
    val push = Push(this)
    val inbox = Inbox(this)

    internal suspend fun post(path: String, body: JSONObject): JSONObject = request("POST", path, body, emptyMap())
    internal suspend fun get(path: String, headers: Map<String, String>): JSONObject = request("GET", path, null, headers)
    internal suspend fun post(path: String, body: JSONObject, headers: Map<String, String>): JSONObject = request("POST", path, body, headers)
    internal suspend fun delete(path: String, headers: Map<String, String>): JSONObject = request("DELETE", path, null, headers)

    private suspend fun request(method: String, path: String, body: JSONObject?, headers: Map<String, String>): JSONObject = withContext(Dispatchers.IO) {
        val conn = URL(baseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.setRequestProperty("authorization", "Bearer $key")
            conn.setRequestProperty("user-agent", "signops-android/$VERSION")
            for ((k, v) in headers) conn.setRequestProperty(k, v)
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("content-type", "application/json")
                conn.outputStream.use { it.write(body.toString().toByteArray()) }
            }
            val status = conn.responseCode
            val text = (if (status < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            if (status >= 400) throw errorFrom(status, text)
            JSONObject(text)
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        const val VERSION = "0.4.0"
        internal const val PREFS = "signops"

        /** From your FirebaseMessagingService: draws SignOps pushes with buttons and activities. False for anything else. */
        @JvmStatic @JvmOverloads
        fun handleMessage(context: Context, data: Map<String, String>, smallIcon: Int, channelId: String? = null): Boolean = Notifications.handle(context, data, smallIcon, channelId)

        /** Reports an open from a tap the SDK drew, on a background thread, with the key the app last configured. */
        internal fun reportOpen(context: Context, id: String, action: String?) {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val key = p.getString("key", null) ?: return
            val base = p.getString("base", "https://api.signops.dev")!!
            Thread {
                runCatching {
                    val conn = URL(base.trimEnd('/') + "/v1/push/$id/opened").openConnection() as HttpURLConnection
                    conn.requestMethod = "POST"; conn.doOutput = true; conn.connectTimeout = 10_000; conn.readTimeout = 10_000
                    conn.setRequestProperty("authorization", "Bearer $key"); conn.setRequestProperty("content-type", "application/json")
                    val body = JSONObject().put("platform", "android"); if (action != null) body.put("action", action)
                    conn.outputStream.use { it.write(body.toString().toByteArray()) }
                    conn.responseCode; conn.disconnect()
                }
            }.start()
        }

        /** Colours for the ready-made approve screen. Set once, before it opens. */
        @JvmStatic var approveColors: ApproveColors = ApproveColors()

        internal fun checkKey(key: String) {
            require(key.startsWith("pk_live_") || key.startsWith("pk_test_")) {
                "Use the app's publishable key (pk_live_ or pk_test_). A secret key must never ship in an app."
            }
        }

        /** The API's error shape: { "error": { "code": "...", "message": "..." } }. */
        internal fun errorFrom(status: Int, text: String): SignOpsException {
            val e = runCatching { JSONObject(text).optJSONObject("error") }.getOrNull()
            return SignOpsException(status, e?.optString("code")?.ifEmpty { null } ?: "error", e?.optString("message")?.ifEmpty { null } ?: "SignOps answered $status")
        }
    }
}

/**
 * An error from SignOps, or from the phone: "cancelled" (the user closed a prompt), "no_passkey", "passkey_error",
 * "not_enrolled" (Approve has no key on this phone), "no_lock" (the phone has no screen lock), "auth_failed".
 */
class SignOpsException(val status: Int, val code: String, message: String) : Exception(message)
